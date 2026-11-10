#!/usr/bin/env bash
#
# lux/test/run.sh — F0 的端到端验证(只在 macOS arm64 上跑)
#
#   1. 确认 macos-arm64 静态库存在(没有就先构建);
#   2. 在 lux/.build/fixtures/ 里合成一个 12s 的 H.264+AAC mkv(优先用系统 ffmpeg);
#   3. 用 lux/.build/macos-arm64/install/ 里的静态库编译并运行 lux/test/read_mkv.c;
#   4. 断言输出里出现 H.264/AAC 流信息、时长、关键帧偏移、包计数,失败返回非零。
#
# 后续追加的段:
#   6. 补丁集公开 API 探针(patch_probe)
#   7. 12-bit HEVC:VT 候选 + 硬解失败回退(hevc12_probe)
#   8. AV1 解码实测:libdav1d vs 原生 av1(av1_probe,dav1d 小节的实测证据)
#   9. TLS 后端:OpenSSL 对 1.3-only 与 1.2-only 服务端的握手 + HTTP 读取(tls_probe)
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
# libavcodec.a 里的 libdav1d 解码器引用 dav1d_* 符号;dav1d 是静态库(D4),
# 链接时显式列在 libavcodec.a 之后。所有链接 FFmpeg 静态库的探针都要带上它。
DAV1D_LIB="$REPO/lux/.build/deps/$TARGET/install/lib/libdav1d.a"
# D3 起 TLS 后端是 OpenSSL 3.5(静态 libssl.a/libcrypto.a),tscc 用静态 libz.a。
# 链接约定:所有 FFmpeg 静态库之后、-framework 之前追加 -L<deps>/lib -lssl -lcrypto -lz。
# libavutil.a 的 random_seed(OpenSSL RAND_bytes)、libavformat.a 的 tls_openssl、
# libavcodec.a 的 tscc(inflate)都靠这三个库解析。
DEPS_LIB_DIR="$REPO/lux/.build/deps/$TARGET/install/lib"
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
for lib in libavformat.a libavcodec.a libavfilter.a libswscale.a libswresample.a libavutil.a; do
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
        "$DAV1D_LIB" \
        "$INSTALL/lib/libavfilter.a" "$INSTALL/lib/libswscale.a" \
        "$INSTALL/lib/libswresample.a" "$INSTALL/lib/libavutil.a" \
        -L"$DEPS_LIB_DIR" -lssl -lcrypto -lz \
        -framework CoreFoundation -framework CoreVideo -framework CoreMedia \
        -framework VideoToolbox -framework AudioToolbox -framework Security \
        -framework CoreImage \
        > "$WORK/compile.log" 2>&1; then
    cat "$WORK/compile.log" >&2
    echo "[FAIL] read_mkv 编译/链接失败"; exit 1
fi
pass "read_mkv 编译链接成功: $BIN"

if ! xcrun --sdk macosx vtool -show-build "$BIN" 2>/dev/null | grep -q "platform MACOS"; then
    fail "read_mkv 不是 macOS 可执行文件"
fi
grep -q "LGPL version 2.1 or later" <(strings "$INSTALL/lib/libavutil.a") \
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
        "$DAV1D_LIB" \
        "$INSTALL/lib/libavfilter.a" "$INSTALL/lib/libswscale.a" \
        "$INSTALL/lib/libswresample.a" "$INSTALL/lib/libavutil.a" \
        -L"$DEPS_LIB_DIR" -lssl -lcrypto -lz \
        -framework CoreFoundation -framework CoreVideo -framework CoreMedia \
        -framework VideoToolbox -framework AudioToolbox -framework Security \
        -framework CoreImage \
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
            "$DAV1D_LIB" \
            "$INSTALL/lib/libavfilter.a" "$INSTALL/lib/libswscale.a" \
            "$INSTALL/lib/libswresample.a" "$INSTALL/lib/libavutil.a" \
        -L"$DEPS_LIB_DIR" -lssl -lcrypto -lz \
            -framework CoreFoundation -framework CoreVideo -framework CoreMedia \
            -framework VideoToolbox -framework AudioToolbox -framework Security \
        -framework CoreImage \
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
# 8. AV1 解码实测:libdav1d vs 原生 av1(dav1d 小节的实测证据)
# ---------------------------------------------------------------------------
# 样片是**入库的测试资产** lux/test/fixtures/lux-av1-fixture.mkv
# (320x240 / 25fps / 100 帧 / yuv420p / mkv,由 libsvtav1 生成,细节见同目录 README.md)。
# 运行时不下载、不调用宿主 ffmpeg:没有 libsvtav1 的机器也照样能跑。
# 每次运行都按 SHA256SUMS 校验来源;工作副本先写 .part、校验通过后才改名,
# 任何一步失败都删掉 .part,不留下半截文件。
# 原生 `av1` 解码器在 FFmpeg 8.1.3 里是 hwaccel-only(av1dec.c 在 !hwaccel 时返回
# ENOSYS),本构建 LUX_HWACCELS 只有 h264/hevc 的 VT,所以它解不出帧属于预期;
# 探针会把它记成 av1_result: unsupported_sw_decode,而不是把整段测试判失败。
FIXAV1_SRC="$LUX/test/fixtures/lux-av1-fixture.mkv"
FIXAV1_SUMS="$LUX/test/fixtures/SHA256SUMS"
FIXAV1="$FIXDIR/lux-av1-fixture.mkv"
AV1_READY=1

sha256_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

AV1_SHA=$(awk '$2 == "lux-av1-fixture.mkv" {print $1}' "$FIXAV1_SUMS" 2>/dev/null)

if [ ! -s "$FIXAV1_SRC" ]; then
    AV1_READY=0
    fail "缺少入库 AV1 夹具: $FIXAV1_SRC(见 lux/test/fixtures/README.md)"
elif [ -z "$AV1_SHA" ]; then
    AV1_READY=0
    fail "lux/test/fixtures/SHA256SUMS 里没有 lux-av1-fixture.mkv 的记录"
elif [ "$(sha256_of "$FIXAV1_SRC")" != "$AV1_SHA" ]; then
    AV1_READY=0
    fail "入库 AV1 夹具 sha256 不符(期望 $AV1_SHA): $FIXAV1_SRC"
else
    pass "入库 AV1 夹具校验通过: lux-av1-fixture.mkv (sha256 ${AV1_SHA:0:12}...)"
    if ! cp "$FIXAV1_SRC" "$FIXAV1.part" 2>"$WORK/fixture-av1.log"; then
        cat "$WORK/fixture-av1.log" >&2
        rm -f "$FIXAV1.part"
        AV1_READY=0
        fail "复制 AV1 夹具到 $FIXAV1.part 失败"
    elif [ "$(sha256_of "$FIXAV1.part")" != "$AV1_SHA" ]; then
        rm -f "$FIXAV1.part"
        AV1_READY=0
        fail "AV1 夹具工作副本(.part)的 sha256 不符"
    elif ! mv "$FIXAV1.part" "$FIXAV1"; then
        rm -f "$FIXAV1.part"
        AV1_READY=0
        fail "AV1 夹具 .part 改名失败"
    else
        pass "AV1 工作副本就绪: $FIXAV1 ($(stat -f %z "$FIXAV1") bytes)"
    fi
fi

if [ "$AV1_READY" = 1 ]; then
    AV1BIN="$WORK/av1_probe"
    printf '[run] 编译 av1_probe.c\n'
    if ! xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=14.0 -isysroot "$SDK" \
            -Wall -Wextra -Wno-unused-parameter -O1 \
            -I"$INSTALL/include" \
            -o "$AV1BIN" "$LUX/test/av1_probe.c" \
            "$INSTALL/lib/libavformat.a" "$INSTALL/lib/libavcodec.a" \
            "$DAV1D_LIB" \
            "$INSTALL/lib/libavfilter.a" "$INSTALL/lib/libswscale.a" \
            "$INSTALL/lib/libswresample.a" "$INSTALL/lib/libavutil.a" \
        -L"$DEPS_LIB_DIR" -lssl -lcrypto -lz \
            -framework CoreFoundation -framework CoreVideo -framework CoreMedia \
            -framework VideoToolbox -framework AudioToolbox -framework Security \
            -framework CoreImage \
            > "$WORK/av1_probe-compile.log" 2>&1; then
        cat "$WORK/av1_probe-compile.log" >&2
        fail "av1_probe 编译/链接失败"
    else
        pass "av1_probe 编译链接成功: $AV1BIN"

        AOUT="$WORK/av1_probe.out"
        if "$AV1BIN" "$FIXAV1" 60 > "$AOUT" 2>"$WORK/av1_probe.err"; then
            pass "AV1 解码探针通过(libdav1d 完整解出探针上限帧数)"
        else
            cat "$WORK/av1_probe.err" >&2
            fail "AV1 解码探针失败"
        fi
        sed 's/^/       /' "$AOUT"

        grep -q '^stream: .*codec=av1 width=320 height=240 pix_fmt=yuv420p' "$AOUT" \
            && pass "样片是 320x240 yuv420p 的 AV1" || fail "样片流信息不符合预期"
        grep -q '^decoder libdav1d: avail=1 open=1' "$AOUT" \
            && pass "libdav1d 解码器已注册且能打开" || fail "libdav1d 解码器不可用"

        # 宽高必须在同一条 grep 里同时断言:320 和 240 都不能丢。
        grep -q '^libdav1d: frames=[0-9]* width=320 height=240 expect=320x240 ' "$AOUT" \
            && pass "dav1d 解出的帧是 320x240(与 codecpar 一致)" \
            || fail "dav1d 解码宽高不是 320x240(或与 codecpar 不一致)"
        grep -q '^libdav1d: .*pix_fmt=yuv420p consistent=1' "$AOUT" \
            && pass "dav1d 输出 yuv420p 且逐帧一致" || fail "dav1d 输出格式不符合预期"

        # 帧数必须等于样片总帧数(100)或探针上限(60),并用 stop= 证明不是中途截断。
        n_av1=$(sed -n 's/^libdav1d: frames=\([0-9]*\).*/\1/p' "$AOUT")
        stop_av1=$(sed -n 's/^libdav1d: .*stop=\([a-z]*\).*/\1/p' "$AOUT")
        if [ "$n_av1" = 60 ] && [ "$stop_av1" = limit ]; then
            pass "dav1d 解出 $n_av1 帧 = 探针上限 60,stop=limit(没有中途截断)"
        elif [ "$n_av1" = 100 ] && [ "$stop_av1" = eof ]; then
            pass "dav1d 解完样片全部 100 帧,stop=eof"
        else
            fail "dav1d 帧数/终止原因不符: frames='$n_av1' stop='$stop_av1'(期望 60/limit 或 100/eof)"
        fi

        lum_av1=$(sed -n 's/^libdav1d: .*luma_avg=\([0-9.]*\).*/\1/p' "$AOUT")
        if [ -n "$lum_av1" ] && awk -v v="$lum_av1" 'BEGIN{exit !(v>1)}'; then
            pass "dav1d 第一帧 Y 均值 $lum_av1(确实解出了像素,不是空帧)"
        else
            fail "dav1d 第一帧 Y 均值异常: '$lum_av1'"
        fi

        grep -q '^decoder av1: avail=1 open=1' "$AOUT" \
            && pass "原生 av1 解码器已注册" || fail "原生 av1 解码器不可用"
        if grep -q '^av1_result: decoded$' "$AOUT"; then
            pass "原生 av1 也完整解出 >= 30 帧(对照路径可用)"
            grep -q '^compare: frames_match=1 dims_match=1 pixfmt_match=1$' "$AOUT" \
                && pass "两种解码器帧数/分辨率/像素格式全部一致" \
                || fail "两种解码器的 compare 结果不是全 1"
        elif grep -q '^av1_result: unsupported_sw_decode$' "$AOUT"; then
            pass "原生 av1 = hwaccel-only,本构建无 AV1 hwaccel(对照结论已记录)"
        else
            fail "原生 av1 状态异常"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 9. TLS 后端(D3):本构建的 openssl s_server 起 1.3-only 与 1.2-only 两个服务端
# ---------------------------------------------------------------------------
# 旧的 Secure Transport 连不上只支持 TLS 1.3 的服务端(-9836,见 lux/docs/tls-13-probe.md)。
# D3 换成 OpenSSL 后,这里用同一份 s_server(来自 deps 安装的 openssl)分别验证:
#   - 1.3-only(8443):探针必须握手成功并读到 HTTP 200;
#   - 1.2-only(8444):同上(证明后端没有把 1.2 服务端排除)。
# 探针不再"握手后阻塞在 read":它发 HTTP/1.0 GET,读到 EOF,并要求状态行 200;
# 读超时/EAGAIN 都算失败。外层再用 timeout(没有 coreutils 时用 perl alarm)兜底。
# 每个服务端都用 -naccept 1,并断言 s_server 日志里的 Protocol 是 TLSv1.3 / TLSv1.2。
TLS_DIR="$WORK/tls"
mkdir -p "$TLS_DIR"
OSSL_BIN="$REPO/lux/.build/deps/$TARGET/install/bin/openssl"
run_timeout() { # $1 秒;其余为命令
    local secs=$1; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -x "$OSSL_BIN" ]; then
    fail "找不到本构建的 openssl: $OSSL_BIN(先跑 build-deps.sh $TARGET openssl)"
else
    pass "openssl: $("$OSSL_BIN" version)"

    if [ ! -s "$TLS_DIR/cert.pem" ] || [ ! -s "$TLS_DIR/key.pem" ]; then
        if "$OSSL_BIN" req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 \
                -subj "/CN=localhost" -keyout "$TLS_DIR/key.pem" \
                -out "$TLS_DIR/cert.pem" > "$TLS_DIR/certgen.log" 2>&1; then
            pass "TLS 测试证书已生成(自签,仅本机回环)"
        else
            fail "TLS 测试证书生成失败"
            cat "$TLS_DIR/certgen.log" >&2
        fi
    else
        pass "TLS 测试证书已存在: $TLS_DIR/cert.pem"
    fi

    TLSPROBE="$WORK/tls_probe"
    printf '[run] 编译 tls_probe.c\n'
    if ! xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=14.0 -isysroot "$SDK" \
            -Wall -Wextra -Wno-unused-parameter -O1 \
            -I"$INSTALL/include" \
            -o "$TLSPROBE" "$LUX/test/tls_probe.c" \
            "$INSTALL/lib/libavformat.a" "$INSTALL/lib/libavcodec.a" \
            "$DAV1D_LIB" \
            "$INSTALL/lib/libavfilter.a" "$INSTALL/lib/libswscale.a" \
            "$INSTALL/lib/libswresample.a" "$INSTALL/lib/libavutil.a" \
            -L"$DEPS_LIB_DIR" -lssl -lcrypto -lz \
            -framework CoreFoundation -framework CoreVideo -framework CoreMedia \
            -framework VideoToolbox -framework AudioToolbox -framework Security \
            -framework CoreImage \
            > "$TLS_DIR/tls_probe-compile.log" 2>&1; then
        cat "$TLS_DIR/tls_probe-compile.log" >&2
        fail "tls_probe 编译/链接失败"
    else
        pass "tls_probe 编译链接成功: $TLSPROBE"

        tls_case() { # $1 标签 $2 端口 $3 s_server 版本参数 $4 控制组用的"错误版本"参数
            local label=$1 port=$2 flags=$3 control=$4
            local log="$TLS_DIR/$label.log" pid i ready=0

            # -naccept 2:第 1 次连接给控制组(错误版本,必须被拒),第 2 次给探针。
            "$OSSL_BIN" s_server -www -accept "127.0.0.1:$port" \
                -cert "$TLS_DIR/cert.pem" -key "$TLS_DIR/key.pem" \
                -naccept 2 $flags > "$log" 2>&1 &
            pid=$!

            i=0
            while [ "$i" -lt 100 ]; do
                grep -q "^ACCEPT" "$log" 2>/dev/null && { ready=1; break; }
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
                i=$((i + 1))
            done
            if [ "$ready" -ne 1 ]; then
                fail "$label: s_server 没起来($flags)"
                sed 's/^/       /' "$log" >&2
                kill "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                return
            fi

            # 控制组:用被该服务端禁用的版本连接,必须失败。这证明 -tls1_X 真的在生效,
            # 于是下面探针一旦成功,就只能是用服务端允许的那个版本(1.3-only / 1.2-only)。
            if run_timeout 15 "$OSSL_BIN" s_client -connect "127.0.0.1:$port" $control \
                    < /dev/null > "$TLS_DIR/$label.control.out" 2>&1; then
                fail "$label: 控制组 $control 竟然连上了(服务端版本限制没生效)"
            else
                pass "$label: 控制组 $control 被拒绝(服务端版本限制生效)"
            fi
            grep -m1 -i "alert protocol version" "$TLS_DIR/$label.control.out" \
                | sed 's/^/       /' || true

            if run_timeout 20 "$TLSPROBE" "tls://127.0.0.1:$port/" 8000 \
                    > "$TLS_DIR/$label.probe.out" 2>&1; then
                pass "$label: 探针握手 + HTTP 200 成功"
            else
                fail "$label: 探针失败(超时或响应非法)"
            fi
            sed 's/^/       /' "$TLS_DIR/$label.probe.out"

            # s_server 处理完 -naccept 1 会退出;最多再等 5s,然后收尸。
            i=0
            while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
                sleep 0.1
                i=$((i + 1))
            done
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true

        }

        # 1.3-only 服务端:控制组用 -tls1_2;1.2-only 服务端:控制组用 -tls1_3。
        tls_case tls13-only 8443 "-tls1_3" "-tls1_2"
        tls_case tls12-only 8444 "-tls1_2" "-tls1_3"
    fi
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$FAILS" -gt 0 ]; then
    printf 'RESULT: FAIL (%d 项)\n' "$FAILS"
    exit 1
fi
printf 'RESULT: PASS\n'
