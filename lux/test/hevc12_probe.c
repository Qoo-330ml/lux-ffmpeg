/*
 * lux/test/hevc12_probe.c — 验证 0004(HEVC 12-bit 的 VideoToolbox 候选)真的生效
 *
 * 做法:解一个 12-bit 4:2:0 的 mkv,在 get_format 回调里把解码器拿到的候选格式打出来,
 * 断言 AV_PIX_FMT_VIDEOTOOLBOX 出现在候选列表里。这条断言直接对应补丁:上游 FFmpeg 8.1.3
 * 的 YUV420P12 分支没有 VT 候选,打完 0004 才有。
 *
 * 硬件不支持该格式时 VT 初始化会失败,ff_get_format 会自动回退到软件格式——所以
 * "解出至少一帧"同时验证了回退路径不会把播放搞坏。
 *
 * 输出(供 run.sh 断言):
 *   stream_format: yuv420p12le
 *   candidate: ...
 *   vt_candidate: yes|no
 *   frames_decoded: N
 *   first_frame_format: ...
 *   RESULT: PASS|FAIL
 */
#include <stdio.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>

static int vt_offered;

static enum AVPixelFormat get_format_cb(AVCodecContext *avctx, const enum AVPixelFormat *fmt)
{
    const enum AVPixelFormat *p;

    for (p = fmt; *p != AV_PIX_FMT_NONE; p++) {
        const char *name = av_get_pix_fmt_name(*p);
        printf("candidate: %s\n", name ? name : "?");
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX)
            vt_offered = 1;
    }

    /* 有设备就优先 VT;没有就按解码器给的顺序取第一个(通常是软件格式)。 */
    if (avctx->hw_device_ctx) {
        for (p = fmt; *p != AV_PIX_FMT_NONE; p++)
            if (*p == AV_PIX_FMT_VIDEOTOOLBOX)
                return AV_PIX_FMT_VIDEOTOOLBOX;
    }
    return fmt[0];
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <12-bit-hevc.mkv>\n", argv[0]);
        return 2;
    }

    int ret, fails = 0;
    AVFormatContext *fmt = NULL;
    AVCodecContext *dec = NULL;
    AVPacket *pkt = NULL;
    AVFrame *frame = NULL;
    AVBufferRef *dev = NULL;
    int stream_index = -1;
    int frames = 0;
    char first_fmt[32] = "";

    if (avformat_open_input(&fmt, argv[1], NULL, NULL) < 0) {
        fprintf(stderr, "cannot open %s\n", argv[1]);
        return 2;
    }
    if (avformat_find_stream_info(fmt, NULL) < 0) {
        fprintf(stderr, "find_stream_info failed\n");
        avformat_close_input(&fmt);
        return 2;
    }

    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        if (fmt->streams[i]->codecpar->codec_id == AV_CODEC_ID_HEVC) {
            stream_index = (int)i;
            break;
        }
    }
    if (stream_index < 0) {
        fprintf(stderr, "no HEVC stream\n");
        avformat_close_input(&fmt);
        return 2;
    }

    AVCodecParameters *par = fmt->streams[stream_index]->codecpar;
    {
        const char *name = av_get_pix_fmt_name(par->format);
        printf("stream_format: %s\n", name ? name : "?");
    }

    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
    if (!codec) {
        fprintf(stderr, "no HEVC decoder in this build\n");
        avformat_close_input(&fmt);
        return 2;
    }

    dec = avcodec_alloc_context3(codec);
    if (!dec) {
        avformat_close_input(&fmt);
        return 2;
    }
    avcodec_parameters_to_context(dec, par);
    dec->get_format = get_format_cb;

    if (av_hwdevice_ctx_create(&dev, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) >= 0)
        dec->hw_device_ctx = av_buffer_ref(dev);
    else
        printf("note: no VideoToolbox device, decoding in software\n");

    if (avcodec_open2(dec, codec, NULL) < 0) {
        fprintf(stderr, "avcodec_open2 failed\n");
        av_buffer_unref(&dev);
        avcodec_free_context(&dec);
        avformat_close_input(&fmt);
        return 2;
    }

    pkt = av_packet_alloc();
    frame = av_frame_alloc();

    while (frames < 3 && av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index != stream_index) {
            av_packet_unref(pkt);
            continue;
        }
        ret = avcodec_send_packet(dec, pkt);
        av_packet_unref(pkt);
        if (ret < 0 && ret != AVERROR(EAGAIN))
            break;

        while (frames < 3) {
            ret = avcodec_receive_frame(dec, frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
                break;
            if (ret < 0)
                break;
            if (frames == 0) {
                const char *name = av_get_pix_fmt_name(frame->format);
                snprintf(first_fmt, sizeof(first_fmt), "%s", name ? name : "?");
            }
            frames++;
            av_frame_unref(frame);
        }
    }

    /* flush */
    if (frames == 0) {
        avcodec_send_packet(dec, NULL);
        while (frames < 1 && avcodec_receive_frame(dec, frame) >= 0) {
            const char *name = av_get_pix_fmt_name(frame->format);
            snprintf(first_fmt, sizeof(first_fmt), "%s", name ? name : "?");
            frames++;
            av_frame_unref(frame);
        }
    }

    printf("vt_candidate: %s\n", vt_offered ? "yes" : "no");
    printf("frames_decoded: %d\n", frames);
    printf("first_frame_format: %s\n", first_fmt[0] ? first_fmt : "-");

    if (!vt_offered) {
        printf("[FAIL] get_format 候选里没有 AV_PIX_FMT_VIDEOTOOLBOX(0004 未生效)\n");
        fails++;
    }
    if (frames < 1) {
        printf("[FAIL] 一帧都没解出来(回退路径有问题)\n");
        fails++;
    }

    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    av_buffer_unref(&dev);
    avformat_close_input(&fmt);

    printf("failures: %d\n", fails);
    printf("RESULT: %s\n", fails ? "FAIL" : "PASS");
    return fails ? 1 : 0;
}
