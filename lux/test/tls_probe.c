/* D3 验收探针:经 libavformat 的 tls:// 协议做一次真实握手 + HTTP 请求/读取。
 *
 * 背景:旧的 tls13_probe(lux/.build/tls-test,不入库)只 avio_open2 后 avio_read,
 * 对 1.2 对照服务端会一直阻塞 —— "没有报错" 被当成了成功,无法判定。这里改成
 * 明确的请求/响应:向 s_server -www 发一个 HTTP/1.0 请求,读到 EOF(或读满缓冲),
 * 并要求响应以 HTTP/1.x 开头且状态码 200。任何超时/半截响应都算失败。
 *
 * 用法: tls_probe <tls://host:port/> [timeout_ms]
 *   退出码 0 = 握手 + 请求 + 响应都成功;非 0 = 失败(附原因)。
 *
 * 证书校验默认关闭(verify=0):测试用的是 run.sh 现场生成的自签证书。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavformat/avio.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>

#define MAX_RESPONSE (64 * 1024)

static void print_av_error(const char *what, int err)
{
    char buf[256];
    av_strerror(err, buf, sizeof(buf));
    printf("tls_probe: %s: %s (%d)\n", what, buf, err);
}

int main(int argc, char **argv)
{
    const char *url = argc > 1 ? argv[1] : "tls://127.0.0.1:8443/";
    int timeout_ms = argc > 2 ? atoi(argv[2]) : 8000;
    const char *request = "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n";
    char *response;
    AVIOContext *io = NULL;
    AVDictionary *opts = NULL;
    char timeout_us[32];
    int ret, total = 0, n, read_error = 0;

    if (timeout_ms <= 0)
        timeout_ms = 8000;
    snprintf(timeout_us, sizeof(timeout_us), "%d", timeout_ms * 1000);

    printf("tls_probe: url=%s timeout_ms=%d verify=0\n", url, timeout_ms);

    av_dict_set(&opts, "verify", "0", 0);
    /* tcp 的 timeout 选项(微秒)会透传到底层 socket;读超时返回 EAGAIN,按失败处理。 */
    av_dict_set(&opts, "timeout", timeout_us, 0);

    ret = avio_open2(&io, url, AVIO_FLAG_READ_WRITE, NULL, &opts);
    av_dict_free(&opts);
    if (ret < 0) {
        print_av_error("open failed", ret);
        printf("RESULT: FAIL\n");
        return 1;
    }
    printf("tls_probe: handshake ok\n");

    /* avio_write() 返回 void(FFmpeg 8.x);写失败会在后续 read 上表现为错误/超时。 */
    avio_write(io, (const unsigned char *)request, (int)strlen(request));
    avio_flush(io);
    printf("tls_probe: wrote %zu bytes (HTTP GET)\n", strlen(request));

    response = malloc(MAX_RESPONSE + 1);
    if (!response) {
        avio_closep(&io);
        printf("RESULT: FAIL (out of memory)\n");
        return 1;
    }

    /* 读到 EOF:s_server -www 在 HTTP/1.0 请求后发完状态页就关闭连接。
     * 读超时/错误都算失败,避免把"卡住"误判成成功。 */
    while (total < MAX_RESPONSE) {
        n = avio_read(io, (unsigned char *)response + total, MAX_RESPONSE - total);
        if (n == AVERROR(EAGAIN)) {
            print_av_error("read timed out", n);
            read_error = 1;
            break;
        }
        if (n == AVERROR_EOF)
            break;          /* s_server -www 发完状态页后正常关闭 */
        if (n < 0) {
            print_av_error("read failed", n);
            read_error = 1;
            break;
        }
        if (n == 0)
            break;
        total += n;
    }
    avio_closep(&io);
    response[total] = '\0';

    printf("tls_probe: read %d bytes\n", total);

    if (total <= 0 || read_error) {
        printf("RESULT: FAIL (%s)\n", total <= 0 ? "no response" : "read error/timeout");
        free(response);
        return 1;
    }
    if (strncmp(response, "HTTP/1.", 7) != 0) {
        printf("tls_probe: unexpected response: %.40s\n", response);
        printf("RESULT: FAIL (not an HTTP response)\n");
        free(response);
        return 1;
    }

    /* 状态行:HTTP/1.0 200 ok */
    {
        char status[64] = {0};
        const char *eol = strstr(response, "\r\n");
        size_t len = eol ? (size_t)(eol - response) : strlen(response);
        if (len >= sizeof(status))
            len = sizeof(status) - 1;
        memcpy(status, response, len);
        printf("tls_probe: status=%s\n", status);
        if (!strstr(status, " 200")) {
            printf("RESULT: FAIL (status is not 200)\n");
            free(response);
            return 1;
        }
    }

    free(response);
    printf("RESULT: PASS\n");
    return 0;
}
