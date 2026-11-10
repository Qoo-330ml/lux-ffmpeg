/*
 * lux/test/av1_probe.c — AV1 软解实测(dav1d 1.5.4 与原生 av1 解码器对照)
 *
 * 背景:allowlist 的 dav1d 小节此前只验证到「解码器注册 + 构建/许可」,
 * 没有任何 AV1 样片跑过解码。本探针补上解码实测:
 *
 *   1. 用 libavformat 打开样片,找 AV1 视频流;
 *   2. 按名字取 `libdav1d`(静态编入 libavcodec 的 dav1d 1.5.4)解码前 N 帧;
 *   3. 换原生 `av1` 解码器对同一样片重复一遍,作为对照;
 *   4. 比较两边解出的帧数、分辨率与像素格式。
 *
 * 关于原生 `av1`(重要,实测结论):
 *   FFmpeg 8.1.3 的 `av1` 解码器(libavcodec/av1dec.c)**没有软件解码路径**,它只做
 *   OBU 解析,真正的解码必须由 hwaccel 完成;get_pixel_format() 在 !avctx->hwaccel 时
 *   直接返回 AVERROR(ENOSYS),源码注释也写明 "the av1 decoder doesn't support native
 *   decode"。本构建的 LUX_HWACCELS 只开 h264/hevc 的 VideoToolbox,所有
 *   CONFIG_AV1_*_HWACCEL 均为 0,因此原生 `av1` 在这个构建里解不出任何帧。
 *   探针把这种情况记为 `av1_result: unsupported_sw_decode`(而不是失败),同时保留
 *   「若将来 av1 真能解出帧就按相同标准比对」的分支。
 *
 * 两个解码器都不挂 hw_device_ctx,走纯软件路径。本步只实测 **8-bit 4:2:0**:
 * dav1d 的输出必须是 yuv420p,否则直接判 FAIL(luma_average() 也按 8-bit 读)。
 *
 * 失败注入(只给返工验证用):LUX_AV1_TEST_STUCK_EAGAIN=1 会让发送路径永远返回
 * EAGAIN,用来验证自旋保护会退出并 FAIL;正常运行不设置。
 *
 * 用法: av1_probe <file> [max_frames]    (max_frames 默认 60,N 至少 30)
 *
 * 输出(供 run.sh 断言):
 *   stream: index=0 codec=av1 width=320 height=240 pix_fmt=yuv420p
 *   decoder libdav1d: avail=1 open=1 impl="dav1d AV1 decoder by VideoLAN"
 *   libdav1d: frames=60 width=320 height=240 expect=320x240 pix_fmt=yuv420p consistent=1 stop=limit luma_avg=...
 *   decoder av1: avail=1 open=1 impl="Alliance for Open Media AV1"
 *   av1: frames=0 width=0 height=0 expect=320x240 pix_fmt=? consistent=0 stop=error
 *   av1_result: unsupported_sw_decode
 *   compare: frames_match=na dims_match=na pixfmt_match=na
 *   RESULT: PASS|FAIL
 *
 * 构建与运行见 lux/test/run.sh。链接时必须按 run.sh 的 DAV1D_LIB 追加 libdav1d.a。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/pixdesc.h>

#define DEFAULT_MAX_FRAMES 60
#define MIN_FRAMES         30

/* EAGAIN 自旋保护:同一个 packet 连续 EAGAIN 超过 spins 上限,或连续 no_progress 次
 * drain 一帧都没取到,就判定解码器卡死。正常路径下 send 之后必 drain,send 不该 EAGAIN。 */
#define MAX_EAGAIN_SPINS        1000
#define MAX_EAGAIN_NO_PROGRESS  32

/* 仅用于返工验证的故障注入:设置 LUX_AV1_TEST_STUCK_EAGAIN=1 时,发送路径永远假装
 * 返回 EAGAIN,用来确认自旋保护会退出并 FAIL。正常运行不设置该变量。 */
static int test_stuck_eagain;

typedef struct RunResult {
    int opened;                  /* 解码器找到并 avcodec_open2 成功 */
    int failed;                  /* 解码过程中出现非预期错误 */
    int enosys;                  /* 解码路径明确返回 ENOSYS(av1 无软件解码) */
    int frames;                  /* 实际解出的帧数 */
    int width;
    int height;
    int expect_width;            /* codecpar 里的宽高,用来核对解码输出 */
    int expect_height;
    enum AVPixelFormat pix_fmt;  /* 第一帧的格式 */
    int consistent;              /* 后续帧的分辨率/格式是否与第一帧一致 */
    double luma_avg;             /* 第一帧 Y 平面均值(证明真的出了像素) */
    const char *stop;            /* "limit" / "eof" / "error" */
} RunResult;

static void print_error(const char *what, int err)
{
    char buf[AV_ERROR_MAX_STRING_SIZE] = { 0 };
    av_strerror(err, buf, sizeof(buf));
    fprintf(stderr, "%s: %s (%d)\n", what, buf, err);
}

static const char *pix_name(enum AVPixelFormat fmt)
{
    const char *name = av_get_pix_fmt_name(fmt);
    return name ? name : "?";
}

/* 第一帧的 Y 平面均值:testsrc2 这类彩条图案不会是纯黑,可以证明解码出了真实像素。 */
static double luma_average(const AVFrame *frame)
{
    if (!frame->data[0] || frame->height <= 0)
        return -1.0;
    unsigned long long sum = 0;
    for (int y = 0; y < frame->height; y++) {
        const uint8_t *row = frame->data[0] + (size_t)y * frame->linesize[0];
        for (int x = 0; x < frame->width; x++)
            sum += row[x];
    }
    return (double)sum / ((double)frame->width * frame->height);
}

static void account_frame(RunResult *r, const AVFrame *frame)
{
    if (r->frames == 0) {
        r->width = frame->width;
        r->height = frame->height;
        r->pix_fmt = (enum AVPixelFormat)frame->format;
        r->consistent = 1;
        r->luma_avg = luma_average(frame);
    } else if (frame->width != r->width || frame->height != r->height ||
               frame->format != (int)r->pix_fmt) {
        r->consistent = 0;
    }
    r->frames++;
}

/*
 * 把解码器里已经就绪的帧取干净,直到 EAGAIN/EOF 或到达 max_frames。
 * 返回 0 表示正常(可能取到 0 帧),-1 表示真错误(已打印原因)。
 * ENOSYS 不在这里当错误:它是 av1 解码器「没有软件解码路径」的明确信号,
 * 记到 r->enosys,由调用方决定是 unsupported 还是 broken。
 */
static int drain_frames(AVCodecContext *dec, AVFrame *frame, RunResult *r, int max_frames)
{
    while (r->frames < max_frames) {
        int ret = avcodec_receive_frame(dec, frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
            return 0;
        if (ret == AVERROR(ENOSYS)) {
            r->enosys = 1;
            r->stop = "error";
            return 0;
        }
        if (ret < 0) {
            print_error("avcodec_receive_frame", ret);
            return -1;
        }
        account_frame(r, frame);
        av_frame_unref(frame);
    }
    return 0;
}

/*
 * 用一个指定的解码器把样片从头解到 max_frames 帧(或 EOF),结果写进 *r。
 * 每次调用都重新 open 一遍输入,这样两个解码器从完全相同的起点开始。
 */
static int probe_decoder(const char *path, const char *decoder_name, int max_frames, RunResult *r)
{
    int ret;
    AVFormatContext *fmt = NULL;
    AVCodecContext *dec = NULL;
    AVPacket *pkt = NULL;
    AVFrame *frame = NULL;
    int stream_index = -1;

    memset(r, 0, sizeof(*r));
    r->stop = "error";
    r->pix_fmt = AV_PIX_FMT_NONE;   /* memset 的 0 是 YUV420P,不能当「没有帧」 */
    r->luma_avg = -1.0;

    ret = avformat_open_input(&fmt, path, NULL, NULL);
    if (ret < 0) {
        print_error("avformat_open_input", ret);
        r->failed = 1;
        return -1;
    }
    ret = avformat_find_stream_info(fmt, NULL);
    if (ret < 0) {
        print_error("avformat_find_stream_info", ret);
        avformat_close_input(&fmt);
        r->failed = 1;
        return -1;
    }

    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        const AVCodecParameters *par = fmt->streams[i]->codecpar;
        if (par->codec_type == AVMEDIA_TYPE_VIDEO && par->codec_id == AV_CODEC_ID_AV1) {
            stream_index = (int)i;
            break;
        }
    }
    if (stream_index < 0) {
        fprintf(stderr, "no AV1 video stream in %s\n", path);
        avformat_close_input(&fmt);
        r->failed = 1;
        return -1;
    }

    /* 容器里的声明宽高:解码输出必须和它一致,否则说明解码/探测有问题。 */
    r->expect_width = fmt->streams[stream_index]->codecpar->width;
    r->expect_height = fmt->streams[stream_index]->codecpar->height;

    const AVCodec *codec = avcodec_find_decoder_by_name(decoder_name);
    if (!codec) {
        printf("decoder %s: avail=0 open=0\n", decoder_name);
        fprintf(stderr, "decoder '%s' not registered in this build\n", decoder_name);
        avformat_close_input(&fmt);
        r->failed = 1;
        return -1;
    }

    dec = avcodec_alloc_context3(codec);
    if (!dec) {
        fprintf(stderr, "avcodec_alloc_context3 failed\n");
        avformat_close_input(&fmt);
        r->failed = 1;
        return -1;
    }
    ret = avcodec_parameters_to_context(dec, fmt->streams[stream_index]->codecpar);
    if (ret < 0) {
        print_error("avcodec_parameters_to_context", ret);
        goto fail;
    }
    dec->pkt_timebase = fmt->streams[stream_index]->time_base;
    /* 纯软件解码:不设置 hw_device_ctx / get_format,拿到解码器的原生输出格式。 */
    ret = avcodec_open2(dec, codec, NULL);
    printf("decoder %s: avail=1 open=%d impl=\"%s\"\n",
           decoder_name, ret >= 0, codec->long_name ? codec->long_name : codec->name);
    if (ret < 0) {
        print_error("avcodec_open2", ret);
        goto fail;
    }
    r->opened = 1;

    pkt = av_packet_alloc();
    frame = av_frame_alloc();
    if (!pkt || !frame) {
        fprintf(stderr, "av_packet_alloc/av_frame_alloc failed\n");
        goto fail;
    }

    while (r->frames < max_frames) {
        int sent = 0;

        ret = av_read_frame(fmt, pkt);
        if (ret == AVERROR_EOF) {
            r->stop = "eof";
            break;
        }
        if (ret < 0) {
            print_error("av_read_frame", ret);
            goto fail;
        }
        if (pkt->stream_index != stream_index) {
            av_packet_unref(pkt);
            continue;
        }

        /*
         * send 返回 EAGAIN 表示解码器内部还有帧没取走,**这个 packet 并没有被消费**:
         * 先 drain 到 EAGAIN/EOF,再用同一个 pkt 重发;在成功之前绝不能 unref,
         * 否则会丢帧(旧实现就在 EAGAIN 时 unref 了)。
         *
         * 自旋保护:同一个 pkt 连续 EAGAIN 超过 MAX_EAGAIN_SPINS 次,或连续
         * MAX_EAGAIN_NO_PROGRESS 次 drain 一帧都没取到,就判定解码器卡死、直接 FAIL。
         * 正常情况下 send 之后都会 drain,send 不应该返回 EAGAIN。
         */
        int spins = 0, no_progress = 0;
        for (;;) {
            ret = test_stuck_eagain ? AVERROR(EAGAIN) : avcodec_send_packet(dec, pkt);
            if (ret != AVERROR(EAGAIN)) {
                sent = 1;
                break;
            }
            spins++;
            int before = r->frames;
            if (drain_frames(dec, frame, r, max_frames) < 0)
                goto fail;
            if (r->enosys || r->frames >= max_frames)
                break;      /* 已经没必要/没办法再送这个包 */
            if (r->frames == before)
                no_progress++;
            else
                no_progress = 0;
            if (spins >= MAX_EAGAIN_SPINS || no_progress >= MAX_EAGAIN_NO_PROGRESS) {
                printf("[FAIL] send_packet: decoder stuck — EAGAIN 自旋 spins=%d "
                       "no_progress=%d,已放弃\n", spins, no_progress);
                av_packet_unref(pkt);
                goto fail;
            }
        }
        av_packet_unref(pkt);

        if (r->enosys) {
            r->stop = "error";
            goto done;
        }
        if (!sent) {
            if (r->frames >= max_frames) {
                r->stop = "limit";
                goto done;
            }
            /* drain 完仍然 EAGAIN:libavcodec 不该出现,记错误而不是死循环。 */
            printf("[FAIL] send_packet: EAGAIN after draining, decoder is stuck\n");
            goto fail;
        }
        if (ret == AVERROR(ENOSYS)) {
            /* 原生 av1:没有软件解码路径,get_pixel_format 明确返回 ENOSYS。 */
            r->enosys = 1;
            r->stop = "error";
            goto done;
        }
        if (ret < 0) {
            print_error("avcodec_send_packet", ret);
            goto fail;
        }

        if (drain_frames(dec, frame, r, max_frames) < 0)
            goto fail;
        if (r->enosys) {
            r->stop = "error";
            goto done;
        }
        if (r->frames >= max_frames)
            r->stop = "limit";
    }

    /* 到达 EOF 时把解码器里缓冲的帧冲出来(受 max_frames 限制)。 */
    if (r->frames < max_frames && strcmp(r->stop, "eof") == 0) {
        ret = avcodec_send_packet(dec, NULL);
        if (ret == AVERROR(ENOSYS)) {
            r->enosys = 1;
            r->stop = "error";
            goto done;
        }
        if (ret < 0 && ret != AVERROR_EOF) {
            print_error("avcodec_send_packet (flush)", ret);
            goto fail;
        }
        if (drain_frames(dec, frame, r, max_frames) < 0)
            goto fail;
        if (r->enosys) {
            r->stop = "error";
            goto done;
        }
        if (r->frames >= max_frames && strcmp(r->stop, "eof") == 0)
            r->stop = "limit";   /* flush 阶段恰好打满上限:不是 EOF 截断,按 limit 记 */
    }

done:
    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
    return 0;

fail:
    r->failed = 1;
    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
    return -1;
}

int main(int argc, char **argv)
{
    if (argc < 2 || argc > 3) {
        fprintf(stderr, "usage: %s <av1-file> [max_frames]\n", argv[0]);
        return 2;
    }

    int max_frames = DEFAULT_MAX_FRAMES;
    if (argc == 3) {
        max_frames = atoi(argv[2]);
        if (max_frames < MIN_FRAMES) {
            fprintf(stderr, "max_frames 至少 %d(收到 %d)\n", MIN_FRAMES, max_frames);
            return 2;
        }
    }

    av_log_set_level(AV_LOG_ERROR);
    { const char *hook = getenv("LUX_AV1_TEST_STUCK_EAGAIN");
      test_stuck_eagain = hook && strcmp(hook, "1") == 0; }

    printf("av1_probe: input=%s max_frames=%d\n", argv[1], max_frames);
    if (test_stuck_eagain)
        printf("test_hook: LUX_AV1_TEST_STUCK_EAGAIN=1 (forced EAGAIN, expect FAIL)\n");
    printf("decoder_order: libdav1d av1\n");

    /* 流信息只打一次,方便断言样片本身是 AV1 / 320x240。 */
    {
        AVFormatContext *fmt = NULL;
        if (avformat_open_input(&fmt, argv[1], NULL, NULL) < 0 ||
            avformat_find_stream_info(fmt, NULL) < 0) {
            fprintf(stderr, "cannot open %s\n", argv[1]);
            if (fmt)
                avformat_close_input(&fmt);
            return 2;
        }
        for (unsigned i = 0; i < fmt->nb_streams; i++) {
            const AVCodecParameters *par = fmt->streams[i]->codecpar;
            if (par->codec_type != AVMEDIA_TYPE_VIDEO || par->codec_id != AV_CODEC_ID_AV1)
                continue;
            printf("stream: index=%u codec=av1 width=%d height=%d pix_fmt=%s\n",
                   i, par->width, par->height, pix_name((enum AVPixelFormat)par->format));
            break;
        }
        avformat_close_input(&fmt);
    }

    RunResult dav1d, native;
    int fails = 0;

    probe_decoder(argv[1], "libdav1d", max_frames, &dav1d);
    printf("libdav1d: frames=%d width=%d height=%d expect=%dx%d pix_fmt=%s consistent=%d stop=%s luma_avg=%.2f\n",
           dav1d.frames, dav1d.width, dav1d.height, dav1d.expect_width, dav1d.expect_height,
           pix_name(dav1d.pix_fmt), dav1d.consistent, dav1d.stop, dav1d.luma_avg);

    probe_decoder(argv[1], "av1", max_frames, &native);
    printf("av1: frames=%d width=%d height=%d expect=%dx%d pix_fmt=%s consistent=%d stop=%s luma_avg=%.2f\n",
           native.frames, native.width, native.height, native.expect_width, native.expect_height,
           pix_name(native.pix_fmt), native.consistent, native.stop, native.luma_avg);

    /* 帧数完整:要么正好达到探针上限(stop=limit),要么读到 EOF(stop=eof)。
     * 中途 stop=error 却只出了一部分帧,一律不算成功。 */
    int dav1d_complete = (strcmp(dav1d.stop, "limit") == 0 && dav1d.frames == max_frames) ||
                         (strcmp(dav1d.stop, "eof") == 0 && dav1d.frames > 0);
    int native_complete = (strcmp(native.stop, "limit") == 0 && native.frames == max_frames) ||
                          (strcmp(native.stop, "eof") == 0 && native.frames > 0);

    /* 解码输出的宽高必须和容器 codecpar 声明的一致。 */
    int dav1d_dims_ok = dav1d.expect_width > 0 && dav1d.expect_height > 0 &&
                        dav1d.width == dav1d.expect_width &&
                        dav1d.height == dav1d.expect_height;
    int native_dims_ok = native.expect_width > 0 && native.expect_height > 0 &&
                         native.width == native.expect_width &&
                         native.height == native.expect_height;

    int dav1d_8bit = dav1d.pix_fmt == AV_PIX_FMT_YUV420P;
    int dav1d_ok = dav1d.opened && !dav1d.failed && !dav1d.enosys &&
                   dav1d.frames >= MIN_FRAMES && dav1d.consistent &&
                   dav1d_dims_ok && dav1d_complete && dav1d_8bit;

    /* 原生 av1 一旦声称解出帧,就必须通过与 dav1d 相同的全部检查:
     * 帧数、逐帧一致、完整、宽高、像素格式、亮度均值,以及和 dav1d 的帧数/宽高/
     * 像素格式一致。任何一项不满足都计入 fails,不允许「只看帧数」的假阳性。 */
    int native_produced = native.opened && !native.failed && !native.enosys &&
                          native.frames >= MIN_FRAMES;
    int native_ok = native_produced && native.consistent && native_complete &&
                    native_dims_ok && native.luma_avg > 1.0 &&
                    native.pix_fmt == dav1d.pix_fmt &&
                    dav1d_ok && native.frames == dav1d.frames;
    int native_unsupported = native.opened && !native.failed && native.enosys &&
                             native.frames == 0;
    int native_partial_enosys = native.opened && native.enosys && native.frames > 0;

    if (!dav1d_ok) {
        if (!dav1d.opened)
            printf("[FAIL] libdav1d 解码器不可用或打开失败\n");
        else if (dav1d.enosys && dav1d.frames > 0)
            printf("[FAIL] libdav1d 解出 %d 帧后遇到 ENOSYS,输出不完整\n", dav1d.frames);
        else if (dav1d.enosys)
            printf("[FAIL] libdav1d 解码返回 ENOSYS\n");
        else if (dav1d.frames < MIN_FRAMES)
            printf("[FAIL] libdav1d 只解出 %d 帧(< %d)\n", dav1d.frames, MIN_FRAMES);
        else if (!dav1d.consistent)
            printf("[FAIL] libdav1d 输出帧的分辨率/格式前后不一致\n");
        else if (!dav1d_dims_ok)
            printf("[FAIL] libdav1d 解码宽高 %dx%d 与 codecpar %dx%d 不一致\n",
                   dav1d.width, dav1d.height, dav1d.expect_width, dav1d.expect_height);
        else if (!dav1d_8bit)
            printf("[FAIL] libdav1d 输出像素格式 %s 不是 yuv420p(本步只实测 8-bit 4:2:0)\n",
                   pix_name(dav1d.pix_fmt));
        else
            printf("[FAIL] libdav1d 帧数不完整: frames=%d stop=%s(max_frames=%d)\n",
                   dav1d.frames, dav1d.stop, max_frames);
        fails++;
    } else if (dav1d.luma_avg <= 0.0) {
        printf("[FAIL] libdav1d 第一帧的 Y 均值是 0,疑似没出真实像素\n");
        fails++;
    }

    if (native_partial_enosys) {
        printf("av1_result: partial_then_enosys\n");
        printf("[FAIL] 原生 av1 解出 %d 帧后遇到 ENOSYS(部分帧不算成功)\n", native.frames);
        fails++;
    } else if (native_produced) {
        printf("av1_result: %s\n", native_ok ? "decoded" : "decoded_mismatch");
        if (!native.consistent) {
            printf("[FAIL] 原生 av1 输出帧的分辨率/格式前后不一致\n");
            fails++;
        }
        if (!native_complete) {
            printf("[FAIL] 原生 av1 帧数不完整: frames=%d stop=%s(max_frames=%d)\n",
                   native.frames, native.stop, max_frames);
            fails++;
        }
        if (!native_dims_ok) {
            printf("[FAIL] 原生 av1 解码宽高 %dx%d 与 codecpar %dx%d 不一致\n",
                   native.width, native.height, native.expect_width, native.expect_height);
            fails++;
        }
        if (native.luma_avg <= 1.0) {
            printf("[FAIL] 原生 av1 第一帧 Y 均值 %.2f <= 1,疑似空帧/坏帧\n", native.luma_avg);
            fails++;
        }
        if (dav1d_ok) {
            if (native.frames != dav1d.frames) {
                printf("[FAIL] 两个解码器帧数不一致: dav1d=%d av1=%d(frames_match=0)\n",
                       dav1d.frames, native.frames);
                fails++;
            }
            if (native.width != dav1d.width || native.height != dav1d.height) {
                printf("[FAIL] 两个解码器解出的分辨率不一致: %dx%d vs %dx%d\n",
                       dav1d.width, dav1d.height, native.width, native.height);
                fails++;
            }
            if (native.pix_fmt != dav1d.pix_fmt) {
                printf("[FAIL] 两个解码器的像素格式不一致: %s vs %s\n",
                       pix_name(dav1d.pix_fmt), pix_name(native.pix_fmt));
                fails++;
            }
        }
    } else if (native_unsupported) {
        printf("av1_result: unsupported_sw_decode\n");
        printf("note: 原生 av1 解码器没有软件解码路径(av1dec.c 在 !hwaccel 时返回 ENOSYS),"
               "本构建设有编译任何 AV1 hwaccel,所以它解不出帧;dav1d 是唯一可用的 AV1 软解。\n");
    } else if (!native.opened) {
        printf("av1_result: unavailable\n");
        printf("[FAIL] 原生 av1 解码器不可用或打开失败\n");
        fails++;
    } else {
        printf("av1_result: broken\n");
        printf("[FAIL] 原生 av1 打开成功但解码异常(解出 %d 帧,stop=%s)\n",
               native.frames, native.stop);
        fails++;
    }

    int comparable = dav1d_ok && native_produced;
    printf("compare: frames_match=%s dims_match=%s pixfmt_match=%s\n",
           comparable ? (native.frames == dav1d.frames ? "1" : "0") : "na",
           comparable ? (native_dims_ok && native.width == dav1d.width &&
                         native.height == dav1d.height ? "1" : "0") : "na",
           comparable ? (native.pix_fmt == dav1d.pix_fmt ? "1" : "0") : "na");

    printf("failures: %d\n", fails);
    printf("RESULT: %s\n", fails ? "FAIL" : "PASS");
    return fails ? 1 : 0;
}
