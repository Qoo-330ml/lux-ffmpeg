/*
 * lux/test/patch_probe.c — 验证 lux 补丁集里"公开可观测"的那部分真的进了产物
 *
 * 覆盖:
 *   0001  新增 AV_HWACCEL_FLAG_LOW_PRIORITY + hwaccel_flags 的 low_priority 选项
 *   0005  avcodec_parameters_from_context() 优先使用 sw_pix_fmt
 *   0006  aac_at 编码器在产物里(白名单靠它,补丁改了它的布局/采样率表)
 *   0007  mkv 封面用的 webp / mjpeg 解码器在产物里
 *   0008  DTS-HD HRA X / IMAX 的公开 profile 常量
 *   0010/0011  VT/CoreImage 滤镜注册进 libavfilter(avfilter_get_by_name)
 *   0002/0003 只做结构性改动,没有稳定的公开 API 可以观测,靠 build + code review 保证
 *
 * 退出码:0 = 全部通过,1 = 有失败。
 */
#include <stdio.h>
#include <stdarg.h>
#include <stdint.h>
#include <inttypes.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>

static int fails;

static void ok_check(int cond, const char *fmt, ...)
{
    va_list ap;
    printf("%s ", cond ? "[ok]  " : "[FAIL]");
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
    if (!cond)
        fails++;
}

static int check_low_priority(void)
{
#ifdef AV_HWACCEL_FLAG_LOW_PRIORITY
    ok_check(AV_HWACCEL_FLAG_LOW_PRIORITY == (1 << 4),
             "0001 AV_HWACCEL_FLAG_LOW_PRIORITY == 1<<4 (实际 0x%x)",
             (unsigned)AV_HWACCEL_FLAG_LOW_PRIORITY);
#else
    ok_check(0, "0001 AV_HWACCEL_FLAG_LOW_PRIORITY 未定义");
#endif

    AVCodecContext *c = avcodec_alloc_context3(NULL);
    if (!c) {
        ok_check(0, "0001 无法分配 AVCodecContext");
        return 0;
    }

    const AVOption *opt = av_opt_find(c, "low_priority", "hwaccel_flags", 0, 0);
    ok_check(opt != NULL, "0001 avcodec 选项 low_priority 存在(unit=hwaccel_flags)");
    if (opt)
        ok_check(opt->default_val.i64 == AV_HWACCEL_FLAG_LOW_PRIORITY,
                 "0001 low_priority 选项值 = 1<<4 (实际 %" PRId64 ")",
                 (int64_t)opt->default_val.i64);

    avcodec_free_context(&c);
    return 0;
}

static void check_codec_par(void)
{
    AVCodecContext *c = avcodec_alloc_context3(NULL);
    AVCodecParameters *par = avcodec_parameters_alloc();
    if (!c || !par) {
        ok_check(0, "0005 分配 AVCodecContext/AVCodecParameters 失败");
    } else {
        c->codec_type = AVMEDIA_TYPE_VIDEO;
        c->pix_fmt    = AV_PIX_FMT_VIDEOTOOLBOX;   /* 硬解帧格式 */
        c->sw_pix_fmt = AV_PIX_FMT_YUV420P10;      /* 实际软件格式 */
        c->width      = 1920;
        c->height     = 1080;

        int ret = avcodec_parameters_from_context(par, c);
        const char *name = av_get_pix_fmt_name(par->format);
        ok_check(ret >= 0 && par->format == AV_PIX_FMT_YUV420P10,
                 "0005 codec_par.format = %s(期望 yuv420p10le)", name ? name : "<none>");
    }
    avcodec_parameters_free(&par);
    avcodec_free_context(&c);
}

static void check_encoders(void)
{
    ok_check(avcodec_find_encoder_by_name("aac_at") != NULL,
             "0006 aac_at 编码器在产物里");
}

static void check_tier2(void)
{
    ok_check(avcodec_find_decoder(AV_CODEC_ID_WEBP) != NULL,
             "0007 webp 解码器在产物里(mkv 封面)");
    ok_check(avcodec_find_decoder(AV_CODEC_ID_MJPEG) != NULL,
             "0007 mjpeg 解码器在产物里(jpeg 封面)");
#ifdef AV_PROFILE_DTS_HD_HRA_X
    ok_check(AV_PROFILE_DTS_HD_HRA_X == 51 && AV_PROFILE_DTS_HD_HRA_X_IMAX == 52,
             "0008 DTS-HD HRA X / IMAX profile 常量 = 51 / 52");
#else
    ok_check(0, "0008 AV_PROFILE_DTS_HD_HRA_X 未定义");
#endif
}

static void check_filters(void)
{
    static const struct { const char *name; const char *tag; } filters[] = {
        { "scale_vt",     "0010" },
        { "transpose_vt", "0011" },
        { "format",       "avfilter" },
        { "scale",        "swscale" },
        { NULL, NULL },
    };
    int i;

    for (i = 0; filters[i].name; i++) {
        char msg[128];
        snprintf(msg, sizeof(msg), "%s 滤镜 %s 已注册", filters[i].tag, filters[i].name);
        ok_check(avfilter_get_by_name(filters[i].name) != NULL, "%s", msg);
    }
}

static void check_vt_device(void)
{
    AVBufferRef *dev = NULL;
    int ret = av_hwdevice_ctx_create(&dev, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0);
    ok_check(ret >= 0, "VideoToolbox 设备可创建(硬解前置条件)");
    av_buffer_unref(&dev);
}

int main(void)
{
    printf("patch_probe: lux 补丁集公开 API 检查\n");
    check_low_priority();
    check_codec_par();
    check_encoders();
    check_tier2();
    check_filters();
    check_vt_device();
    printf("failures: %d\n", fails);
    printf("RESULT: %s\n", fails ? "FAIL" : "PASS");
    return fails ? 1 : 0;
}
