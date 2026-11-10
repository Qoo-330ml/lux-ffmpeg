/* P2-6 冒烟测试:libmpv 无头播放 + render API + LUX_MPV 允许项。
 *
 * 三节,任何一节失败都会让退出码非零,并在输出里逐条写明原因:
 *   1. 用 vo=null / ao=null 打开夹具,播放到 EOF(或超时),事件循环里不允许出现
 *      EOF 以外的结束原因(打开失败、解码错误、core 提前退出都算失败);
 *   2. 另起一个 vo=libmpv 的句柄,用 software render API("sw")创建并销毁渲染上下文。
 *      headless 下不画任何帧,只证明上下文能建起来、能干净释放;
 *   3. 逐行读允许清单(lux/test/mpv-allowlist.txt,名字抄自 lux-client 的
 *      MPVLaunchOverrides.allowedOptionNames),每个 mpv_set_option_string 都必须返回 0。
 *
 * 用法: mpv_smoke <fixture.mkv> <allowlist.txt> [timeout-seconds]
 * 退出码:0 = 三项全过;1 = 有失败项。
 *
 * 不访问网络,不读用户配置(config=no),不启动 GUI,不要求画面。
 */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <mpv/client.h>
#include <mpv/render.h>

#define MAX_OPTIONS 128
#define LINE_MAX_LEN 1024
#define NAME_MAX_LEN 128
#define VALUE_MAX_LEN 512
#define HINT_MAX_LEN 512

typedef struct {
    char name[NAME_MAX_LEN];
    char value[VALUE_MAX_LEN];
    char hint[HINT_MAX_LEN];
} option_t;

/* 失败计数:每个失败项 +1,最后决定退出码。 */
static int failures;

static void fail(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("FAIL: ");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    failures++;
}

static void trim(char *s)
{
    char *start = s;
    while (*start == ' ' || *start == '\t' || *start == '\r' || *start == '\n')
        start++;
    if (start != s)
        memmove(s, start, strlen(start) + 1);
    size_t len = strlen(s);
    while (len > 0) {
        char c = s[len - 1];
        if (c != ' ' && c != '\t' && c != '\r' && c != '\n')
            break;
        s[--len] = '\0';
    }
}

static double now_seconds(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return 0.0;
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* ------------------------------------------------------------------------- */
/* 1. 播放到 EOF                                                              */
/* ------------------------------------------------------------------------- */
static int playback_smoke(const char *path, double timeout)
{
    mpv_handle *h = mpv_create();
    if (!h) {
        fail("playback: mpv_create() returned NULL");
        return 1;
    }

    static const char *const opts[][2] = {
        {"vo", "null"},
        {"ao", "null"},
        {"audio-display", "no"},
        {"terminal", "no"},
        {"config", "no"},
        {"input-default-bindings", "no"},
        {"idle", "yes"},
        {"keep-open", "no"},
    };
    for (size_t i = 0; i < sizeof opts / sizeof opts[0]; i++) {
        int rc = mpv_set_option_string(h, opts[i][0], opts[i][1]);
        if (rc < 0) {
            fail("playback: set %s=%s: %s", opts[i][0], opts[i][1], mpv_error_string(rc));
            mpv_destroy(h);
            return 1;
        }
    }

    int rc = mpv_initialize(h);
    if (rc < 0) {
        fail("playback: mpv_initialize: %s", mpv_error_string(rc));
        mpv_destroy(h);
        return 1;
    }

    const char *cmd[] = {"loadfile", path, NULL};
    rc = mpv_command(h, cmd);
    if (rc < 0) {
        fail("playback: loadfile %s: %s", path, mpv_error_string(rc));
        mpv_terminate_destroy(h);
        return 1;
    }

    double start = now_seconds();
    int loaded = 0;
    int eof = 0;
    int failed = 0;

    for (;;) {
        double elapsed = now_seconds() - start;
        if (elapsed > timeout) {
            fail("playback: timeout after %.0fs (no EOF)", timeout);
            failed = 1;
            break;
        }
        mpv_event *ev = mpv_wait_event(h, 0.1);
        if (!ev)
            break;
        if (ev->event_id == MPV_EVENT_FILE_LOADED) {
            char *duration = mpv_get_property_string(h, "duration");
            printf("playback: file-loaded duration=%s\n", duration ? duration : "?");
            mpv_free(duration);
            loaded = 1;
        } else if (ev->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = ev->data;
            if (end->reason == MPV_END_FILE_REASON_EOF) {
                printf("playback: eof after %.2fs\n", now_seconds() - start);
                eof = 1;
            } else {
                fail("playback: end-file reason=%d error=%s", end->reason,
                     end->reason == MPV_END_FILE_REASON_ERROR ? mpv_error_string(end->error)
                                                              : "not an error");
                failed = 1;
            }
            break;
        } else if (ev->event_id == MPV_EVENT_SHUTDOWN) {
            fail("playback: core shut down before EOF");
            failed = 1;
            break;
        }
    }

    if (!eof && !failed) {
        fail("playback: event loop ended without EOF");
        failed = 1;
    }
    if (!loaded && !failed) {
        fail("playback: file never reached FILE_LOADED");
        failed = 1;
    }

    mpv_terminate_destroy(h);
    return failed;
}

/* ------------------------------------------------------------------------- */
/* 2. render API 创建/销毁                                                    */
/* ------------------------------------------------------------------------- */
static int render_smoke(void)
{
    mpv_handle *h = mpv_create();
    if (!h) {
        fail("render: mpv_create() returned NULL");
        return 1;
    }

    static const char *const opts[][2] = {
        {"vo", "libmpv"},
        {"ao", "null"},
        {"terminal", "no"},
        {"config", "no"},
        {"idle", "yes"},
    };
    for (size_t i = 0; i < sizeof opts / sizeof opts[0]; i++) {
        int rc = mpv_set_option_string(h, opts[i][0], opts[i][1]);
        if (rc < 0) {
            fail("render: set %s=%s: %s", opts[i][0], opts[i][1], mpv_error_string(rc));
            mpv_destroy(h);
            return 1;
        }
    }

    int rc = mpv_initialize(h);
    if (rc < 0) {
        fail("render: mpv_initialize: %s", mpv_error_string(rc));
        mpv_destroy(h);
        return 1;
    }

    mpv_render_context *ctx = NULL;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_SW},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    rc = mpv_render_context_create(&ctx, h, params);
    if (rc < 0 || !ctx) {
        printf("render: sw create=FAIL rc=%d (%s)\n", rc,
               rc < 0 ? mpv_error_string(rc) : "context is NULL");
        failures++;
        mpv_terminate_destroy(h);
        return 1;
    }

    printf("render: sw create=ok\n");
    mpv_render_context_free(ctx);
    printf("render: sw free=ok\n");

    mpv_terminate_destroy(h);
    return 0;
}

/* ------------------------------------------------------------------------- */
/* 3. 允许清单里的选项逐个 mpv_set_option_string                              */
/* ------------------------------------------------------------------------- */
static int load_allowlist(const char *path, option_t *opts, int max)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        fail("allowlist: cannot open %s: %s", path, strerror(errno));
        return -1;
    }

    char line[LINE_MAX_LEN];
    int n = 0;
    while (fgets(line, sizeof line, f)) {
        char hint[HINT_MAX_LEN] = "";
        char *hash = strchr(line, '#');
        if (hash) {
            snprintf(hint, sizeof hint, "%s", hash + 1);
            *hash = '\0';
        }
        trim(line);
        trim(hint);
        if (!*line)
            continue;

        char *eq = strchr(line, '=');
        if (!eq) {
            fail("allowlist: malformed line (no '='): %s", line);
            continue;
        }
        *eq = '\0';
        char *name = line;
        char *value = eq + 1;
        trim(name);
        trim(value);
        if (!*name) {
            fail("allowlist: malformed line (empty name)");
            continue;
        }
        if (n >= max) {
            fail("allowlist: more than %d entries", max);
            break;
        }
        snprintf(opts[n].name, sizeof opts[n].name, "%s", name);
        snprintf(opts[n].value, sizeof opts[n].value, "%s", value);
        snprintf(opts[n].hint, sizeof opts[n].hint, "%s", hint);
        n++;
    }
    fclose(f);
    return n;
}

static int options_smoke(const char *path)
{
    option_t opts[MAX_OPTIONS];
    int count = load_allowlist(path, opts, MAX_OPTIONS);
    if (count < 0)
        return 1;
    if (count == 0) {
        fail("allowlist: %s has no entries", path);
        return 1;
    }

    printf("allowlist: %s (%d entries)\n", path, count);

    int accepted = 0;
    int rejected = 0;
    char rejected_names[HINT_MAX_LEN] = "";

    for (int i = 0; i < count; i++) {
        /* 每个选项用一个新句柄:一个值被拒不会影响后面的项,结果也只反映这一项。 */
        mpv_handle *h = mpv_create();
        if (!h) {
            fail("option %s=%s: mpv_create() returned NULL", opts[i].name, opts[i].value);
            continue;
        }
        int rc = mpv_set_option_string(h, opts[i].name, opts[i].value);
        mpv_destroy(h);

        if (rc == 0) {
            printf("option %s=%s: ok\n", opts[i].name, opts[i].value);
            accepted++;
        } else {
            printf("option %s=%s: FAIL rc=%d (%s)\n", opts[i].name, opts[i].value, rc,
                   mpv_error_string(rc));
            if (opts[i].hint[0])
                printf("    hint: %s\n", opts[i].hint);
            rejected++;
            size_t used = strlen(rejected_names);
            if (used < sizeof rejected_names - 1) {
                snprintf(rejected_names + used, sizeof rejected_names - used, "%s%s",
                         used ? "," : "", opts[i].name);
            }
        }
    }

    printf("options_accepted: %d/%d\n", accepted, count);
    printf("options_rejected: %s\n", rejected ? rejected_names : "none");
    if (rejected) {
        failures++;
        return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------------- */
int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <fixture.mkv> <allowlist.txt> [timeout-seconds]\n", argv[0]);
        return 2;
    }
    const char *fixture = argv[1];
    const char *allowlist = argv[2];
    double timeout = 60.0;
    if (argc >= 4) {
        char *end = NULL;
        double parsed = strtod(argv[3], &end);
        if (end && *end == '\0' && parsed > 0.0)
            timeout = parsed;
    }

    /* 版本行只用于记录;同样不读用户配置。 */
    mpv_handle *info = mpv_create();
    if (info) {
        mpv_set_option_string(info, "config", "no");
        mpv_set_option_string(info, "terminal", "no");
        if (mpv_initialize(info) == 0) {
            char *ver = mpv_get_property_string(info, "mpv-version");
            char *ffv = mpv_get_property_string(info, "ffmpeg-version");
            printf("mpv_smoke: %s / FFmpeg %s\n", ver ? ver : "?", ffv ? ffv : "?");
            mpv_free(ver);
            mpv_free(ffv);
        }
        mpv_terminate_destroy(info);
    }

    printf("fixture: %s\n", fixture);
    playback_smoke(fixture, timeout);
    render_smoke();
    options_smoke(allowlist);

    printf("mpv_smoke: %s", failures ? "RESULT: FAIL" : "RESULT: PASS");
    if (failures)
        printf(" (%d)", failures);
    printf("\n");
    return failures ? 1 : 0;
}
