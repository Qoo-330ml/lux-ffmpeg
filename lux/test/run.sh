#!/usr/bin/env bash
#
# lux/test/run.sh — F0 的端到端验证(只在 macOS arm64 上跑)
#
#   1. 确认 macos-arm64 静态库存在(没有就先构建);
#   2. 在 lux/.build/fixtures/ 里合成一个 12s 的 H.264+AAC mkv(优先用系统 ffmpeg);
#   3. 用 lux/.build/macos-arm64/install/ 里的静态库编译并运行 lux/test/read_mkv.c;
#   4. 断言输出里出现 H.264/AAC 流信息、时长、关键帧偏移、包计数,失败返回非零。
#
# 产物全部写在 lux/.build/ 内。
#
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LUX=$(cd "$HERE/.." && pwd)
REPO=$(cd "$LUX/.." && pwd)
BUILD_ROOT="$LUX/.build"
TARGET=macos-arm64
BUILD="$BUILD_ROOT/$TARGET"
INSTALL="$BUILD/install"
FIXDIR="$BUILD_ROOT/fixtures"
FIXTURE="$FIXDIR/lux-f0-fixture.mkv"
WORK="$BUILD/test"

export TMPDIR="$BUILD_ROOT/tmp"
mkdir -p "$TMPDIR" "$FIXDIR" "$WORK"

FAILS=0
pass() { printf '[ok]   %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }

# ---------------------------------------------------------------------------
# 1. 库
# ---------------------------------------------------------------------------
if [ ! -f "$INSTALL/lib/libavformat.a" ]; then
    printf '[run] %s 还没有构建,先构建\n' "$TARGET"
    bash "$LUX/build/build-ffmpeg.sh" "$TARGET" || { echo "build failed"; exit 1; }
fi
for lib in libavformat.a libavcodec.a libswresample.a libavutil.a; do
    [ -f "$INSTALL/lib/$lib" ] || { echo "missing $INSTALL/lib/$lib"; exit 1; }
done
pass "静态库: $INSTALL/lib/"

# ---------------------------------------------------------------------------
# 2. 夹具
# ---------------------------------------------------------------------------
# 需要 H.264 + AAC,关键帧每 2s(25fps -> -g 50),matroska 容器带 Cues。
gen_fixture() {
    local ffmpeg_bin=$1
    "$ffmpeg_bin" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=320x240:rate=25:duration=12" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=12" \
        -c:v libx264 -preset veryfast -profile:v high -pix_fmt yuv420p \
        -g 50 -keyint_min 50 -sc_threshold 0 -bf 2 \
        -c:a aac -b:a 128k -ac 2 \
        -metadata title="lux f0 fixture" \
        -metadata:s:v:0 encoder="fixture" \
        -f matroska "$FIXTURE"
}

if [ -s "$FIXTURE" ]; then
    pass "夹具已存在: $FIXTURE ($(stat -f %z "$FIXTURE") bytes)"
else
    SYS_FFMPEG=$(command -v ffmpeg || true)
    if [ -z "$SYS_FFMPEG" ]; then
        cat >&2 <<'EOF'
[FAIL] 找不到系统 ffmpeg,PATH 里没有可用的 ffmpeg。
       F0 需要它来合成夹具。两条路:
         a) 安装/暴露一个带 libx264 + AAC 的 ffmpeg 到 PATH;
         b) 在 lux/.build/ 里另外用 --enable-programs 构建一个 LGPL 的 macOS 工具集
            (同样不得 --enable-gpl),然后把它加进 PATH 再跑本脚本。
EOF
        exit 1
    fi
    printf '[run] 用 %s 合成夹具 -> %s\n' "$SYS_FFMPEG" "$FIXTURE"
    if ! gen_fixture "$SYS_FFMPEG"; then
        echo "[FAIL] 合成夹具失败(系统 ffmpeg 可能没有 libx264)"; exit 1
    fi
    pass "夹具已生成: $FIXTURE ($(stat -f %z "$FIXTURE") bytes)"
fi

# ---------------------------------------------------------------------------
# 3. 编译 read_mkv
# ---------------------------------------------------------------------------
BIN="$WORK/read_mkv"
SDK=$(xcrun --sdk macosx --show-sdk-path)
printf '[run] 编译 read_mkv.c\n'
if ! xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=14.0 -isysroot "$SDK" \
        -Wall -Wextra -Wno-unused-parameter -O1 \
        -I"$INSTALL/include" \
        -o "$BIN" "$LUX/test/read_mkv.c" \
        "$INSTALL/lib/libavformat.a" "$INSTALL/lib/libavcodec.a" \
        "$INSTALL/lib/libswresample.a" "$INSTALL/lib/libavutil.a" \
        -framework CoreFoundation -framework CoreVideo -framework CoreMedia \
        -framework VideoToolbox -framework AudioToolbox -framework Security \
        > "$WORK/compile.log" 2>&1; then
    cat "$WORK/compile.log" >&2
    echo "[FAIL] read_mkv 编译/链接失败"; exit 1
fi
pass "read_mkv 编译链接成功: $BIN"

if ! xcrun --sdk macosx vtool -show-build "$BIN" 2>/dev/null | grep -q "platform MACOS"; then
    fail "read_mkv 不是 macOS 可执行文件"
fi
grep -q "LGPL version 3 or later" <(strings "$INSTALL/lib/libavutil.a") \
    && pass "链接进二进制的 libavutil 是 LGPL 版本" || fail "二进制里没有 LGPL 许可字符串"

# ---------------------------------------------------------------------------
# 4. 运行
# ---------------------------------------------------------------------------
printf '[run] 运行 read_mkv %s\n' "$FIXTURE"
OUT="$WORK/read_mkv.out"
if ! "$BIN" "$FIXTURE" > "$OUT" 2>"$WORK/read_mkv.err"; then
    cat "$WORK/read_mkv.err" >&2
    cat "$OUT" >&2
    echo "[FAIL] read_mkv 退出码非零"; exit 1
fi
cat "$OUT"
[ -s "$WORK/read_mkv.err" ] && { echo "--- stderr:"; cat "$WORK/read_mkv.err"; }

# ---------------------------------------------------------------------------
# 5. 断言
# ---------------------------------------------------------------------------
grep -q "^avutil_license: LGPL" "$OUT" && pass "avutil_license 以 LGPL 开头" \
    || fail "avutil_license 不是 LGPL"
grep -q "^streams: 2$" "$OUT" && pass "2 路流(video+audio)" || fail "流数量不是 2"
grep -q "type=video codec=h264" "$OUT" && pass "视频流 = H.264" || fail "没找到 H.264 视频流"
grep -q "type=audio codec=aac" "$OUT" && pass "音频流 = AAC" || fail "没找到 AAC 音频流"
grep -q "^format: matroska" "$OUT" && pass "容器 = matroska" || fail "容器不是 matroska"

dur=$(awk '/^duration: /{print $2}' "$OUT")
if awk -v d="$dur" 'BEGIN{exit !(d>=10 && d<=20)}'; then
    pass "时长 $dur s (10–20s 区间)"
else
    fail "时长 '$dur' 不在 10–20s 之间"
fi

grep -q "^first video packet: keyframe=1" "$OUT" && pass "第一个视频包是关键帧" \
    || fail "第一个视频包不是关键帧"
pos=$(sed -n 's/^first video packet: .* pos=\(-\{0,1\}[0-9]*\).*/\1/p' "$OUT")
if [ -n "$pos" ] && [ "$pos" -gt 0 ] 2>/dev/null; then
    pass "第一个视频包在文件内偏移 pos=$pos"
else
    fail "第一个视频包的 pos 非法: '$pos'"
fi

total=$(awk '/^packets_total: /{print $2}' "$OUT")
if [ -n "$total" ] && [ "$total" -gt 100 ] 2>/dev/null; then
    pass "读到 EOF 共 $total 个包(> 100)"
else
    fail "包计数异常: '$total'"
fi
grep -q "^packets_stream_0: " "$OUT" && grep -q "^packets_stream_1: " "$OUT" \
    && pass "两路流都有包计数" || fail "缺少按流的包计数"

# ---------------------------------------------------------------------------
# 6. 补丁集:公开 API 探针
# ---------------------------------------------------------------------------
PROBE="$WORK/patch_probe"
printf '[run] 编译 patch_probe.c\n'
if ! xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=14.0 -isysroot "$SDK" \
        -Wall -Wextra -Wno-unused-parameter -O1 \
        -I"$INSTALL/include" \
        -o "$PROBE" "$LUX/test/patch_probe.c" \
        "$INSTALL/lib/libavformat.a" "$INSTALL/lib/libavcodec.a" \
        "$INSTALL/lib/libswresample.a" "$INSTALL/lib/libavutil.a" \
        -framework CoreFoundation -framework CoreVideo -framework CoreMedia \
        -framework VideoToolbox -framework AudioToolbox -framework Security \
        > "$WORK/patch_probe-compile.log" 2>&1; then
    cat "$WORK/patch_probe-compile.log" >&2
    fail "patch_probe 编译/链接失败"
else
    POUT="$WORK/patch_probe.out"
    if "$PROBE" > "$POUT" 2>&1; then
        pass "patch_probe 全过(0001/0005/0006)"
    else
        fail "patch_probe 有失败项"
    fi
    sed 's/^/       /' "$POUT"
fi

# ---------------------------------------------------------------------------
# 7. 12-bit HEVC:VT 候选 + 硬解失败回退(补丁 0004)
# ---------------------------------------------------------------------------
FIX12="$FIXDIR/lux-12bit-hevc.mkv"
SYS_FFMPEG=$(command -v ffmpeg || true)
HAVE_X265_12=no
if [ -n "$SYS_FFMPEG" ] && "$SYS_FFMPEG" -hide_banner -h encoder=libx265 2>/dev/null | grep -q yuv420p12le; then
    HAVE_X265_12=yes
fi

if [ "$HAVE_X265_12" = no ]; then
    printf '[skip] 系统 ffmpeg 没有 12-bit libx265,跳过 12-bit HEVC 解验证\n'
else
    if [ ! -s "$FIX12" ]; then
        printf '[run] 合成 12-bit HEVC 夹具 -> %s\n' "$FIX12"
        if "$SYS_FFMPEG" -hide_banner -loglevel error -y \
                -f lavfi -i "testsrc2=size=320x240:rate=10:duration=2" \
                -c:v libx265 -pix_fmt yuv420p12le \
                -x265-params log-level=error -f matroska "$FIX12" 2>"$WORK/fixture12.log"; then
            pass "12-bit 夹具已生成: $FIX12"
        else
            cat "$WORK/fixture12.log" >&2
            fail "12-bit 夹具生成失败"
        fi
    else
        pass "12-bit 夹具已存在: $FIX12"
    fi

    P12="$WORK/hevc12_probe"
    printf '[run] 编译 hevc12_probe.c\n'
    if ! xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=14.0 -isysroot "$SDK" \
            -Wall -Wextra -Wno-unused-parameter -O1 \
            -I"$INSTALL/include" \
            -o "$P12" "$LUX/test/hevc12_probe.c" \
            "$INSTALL/lib/libavformat.a" "$INSTALL/lib/libavcodec.a" \
            "$INSTALL/lib/libswresample.a" "$INSTALL/lib/libavutil.a" \
            -framework CoreFoundation -framework CoreVideo -framework CoreMedia \
            -framework VideoToolbox -framework AudioToolbox -framework Security \
            > "$WORK/hevc12-compile.log" 2>&1; then
        cat "$WORK/hevc12-compile.log" >&2
        fail "hevc12_probe 编译/链接失败"
    else
        O12="$WORK/hevc12_probe.out"
        if "$P12" "$FIX12" > "$O12" 2>"$WORK/hevc12_probe.err"; then
            pass "12-bit HEVC 解码通过(VT 候选 + 回退)"
        else
            cat "$WORK/hevc12_probe.err" >&2
            fail "12-bit HEVC 解码失败"
        fi
        grep -q '^vt_candidate: yes$' "$O12" && pass "0004:12-bit 的 get_format 候选里有 VideoToolbox" \
            || fail "0004 未生效:候选里没有 VideoToolbox"
        n12=$(awk '/^frames_decoded: /{print $2}' "$O12")
        if [ -n "$n12" ] && [ "$n12" -ge 1 ] 2>/dev/null; then
            pass "12-bit 解出 $n12 帧(回退路径正常)"
        else
            fail "12-bit 一帧都没解出来"
        fi
        sed 's/^/       /' "$O12"
    fi
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$FAILS" -gt 0 ]; then
    printf 'RESULT: FAIL (%d 项)\n' "$FAILS"
    exit 1
fi
printf 'RESULT: PASS\n'
