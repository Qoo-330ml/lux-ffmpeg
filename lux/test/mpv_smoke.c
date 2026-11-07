/* F2-3 冒烟:加载动态 libmpv,初始化(vo=null),读取版本号与 FFmpeg 版本。
 * 不播放任何内容,不访问网络。用法: mpv_smoke(需要链接 libmpv 与 lux-ffmpeg 的 framework) */
#include <stdio.h>
#include <mpv/client.h>

int main(void)
{
    mpv_handle *h = mpv_create();
    if (!h) { printf("mpv_create: FAIL\n"); return 1; }
    if (mpv_set_option_string(h, "vo", "null") < 0 ||
        mpv_set_option_string(h, "ao", "null") < 0) { printf("set options: FAIL\n"); return 1; }
    if (mpv_initialize(h) < 0) { printf("mpv_initialize: FAIL\n"); return 1; }
    char *ver = mpv_get_property_string(h, "mpv-version");
    char *ffv = mpv_get_property_string(h, "ffmpeg-version");
    printf("mpv-version: %s\nffmpeg-version: %s\n", ver ? ver : "?", ffv ? ffv : "?");
    mpv_free(ver); mpv_free(ffv);
    mpv_terminate_destroy(h);
    printf("RESULT: PASS\n");
    return 0;
}
