/* F2-1 验收探针:枚举协议表,并用 avio 打开一个 https URL 读取前 64 KiB。
 * URL 只从环境变量 LUX_TEST_HTTPS_URL 读取,不写入仓库。
 * 用法: LUX_TEST_HTTPS_URL=https://... ./https_probe */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavformat/avio.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>

static int has_protocol(const char *name)
{
    void *opaque = NULL;
    const char *p;
    while ((p = avio_enum_protocols(&opaque, 0)))
        if (strcmp(p, name) == 0)
            return 1;
    return 0;
}

int main(void)
{
    const char *url = getenv("LUX_TEST_HTTPS_URL");
    static unsigned char buf[65536];
    int missing = 0;
    const char *want[] = {"https", "http", "tls", "tcp", "file"};

    for (size_t i = 0; i < sizeof(want) / sizeof(want[0]); i++) {
        int ok = has_protocol(want[i]);
        printf("protocol %-6s %s\n", want[i], ok ? "present" : "MISSING");
        if (!ok) missing++;
    }
    printf("avutil license: %s\n", avutil_license());
    if (missing) { printf("RESULT: FAIL (missing protocols)\n"); return 1; }
    if (!url || !*url) { printf("https read: NOT RUN (LUX_TEST_HTTPS_URL unset)\n"); return 2; }

    AVIOContext *io = NULL;
    int r = avio_open2(&io, url, AVIO_FLAG_READ, NULL, NULL);
    if (r < 0) {
        char err[256];
        av_strerror(r, err, sizeof(err));
        printf("https open: FAIL (%d: %s)\n", r, err);
        return 1;
    }
    int total = 0, n;
    while (total < (int)sizeof(buf) &&
           (n = avio_read(io, buf + total, (int)sizeof(buf) - total)) > 0)
        total += n;
    avio_closep(&io);
    printf("https read: OK (%d bytes)\n", total);
    printf("RESULT: PASS\n");
    return total > 0 ? 0 : 1;
}
