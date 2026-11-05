#!/usr/bin/env bash
#
# lux/test/swift-import/run.sh — F1 的 Swift 自检(macOS 真跑 + iOS 模拟器只编译)
#
#   ./lux/test/swift-import/run.sh              # 全部
#   ./lux/test/swift-import/run.sh --skip-ios   # 只跑 macOS(没有 xcframeworks 的 iOS 切片时用)
#
# 做四件事,任何一步失败即非零退出:
#   1. 确保 lux/.build/xcframeworks/ 里有可用的 xcframework(缺就先 build-frameworks.sh all);
#   2. 确保 F0 的合成夹具存在(缺就调用 lux/test/run.sh 生成);
#   3. macOS:swift build + swift test + 运行 lux-ffmpeg-probe 读夹具;
#   4. iOS Simulator:xcodebuild build(只编译,代理不能运行模拟器)。
#
# 所有产物都在 lux/.build/ 内(TMPDIR / scratch / DerivedData 全部重定向)。
#
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LUX=$(cd "$HERE/../.." && pwd)
BUILD_ROOT="$LUX/.build"
SCRATCH="$BUILD_ROOT/swift-import"
DERIVED="$BUILD_ROOT/xcodebuild-derived"
FIXTURE="$BUILD_ROOT/fixtures/lux-f0-fixture.mkv"

mkdir -p "$BUILD_ROOT/tmp" "$SCRATCH"
export TMPDIR="$BUILD_ROOT/tmp"
export TMP="$TMPDIR"
export TEMP="$TMPDIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH"

skip_ios=0
[ "${1:-}" = "--skip-ios" ] && skip_ios=1

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------------------
step "xcframework"
if [ ! -d "$BUILD_ROOT/xcframeworks/Libavformat.xcframework" ]; then
    printf '[run] 缺少 xcframework,先构建三个切片(约 3 分钟)\n'
    bash "$LUX/build/build-frameworks.sh" all || die "build-frameworks.sh all failed"
fi
for fw in Libavutil Libswresample Libavcodec Libavformat; do
    [ -d "$BUILD_ROOT/xcframeworks/$fw.xcframework" ] || die "missing $fw.xcframework"
done
printf '[ok] xcframeworks: %s\n' "$(ls "$BUILD_ROOT/xcframeworks" | tr '\n' ' ')"

# ---------------------------------------------------------------------------
step "fixture"
if [ ! -s "$FIXTURE" ]; then
    printf '[run] 夹具不存在,调用 F0 的 lux/test/run.sh 生成\n'
    bash "$LUX/test/run.sh" > "$BUILD_ROOT/logs/fixture-run.log" 2>&1 \
        || die "cannot create fixture, see $BUILD_ROOT/logs/fixture-run.log"
fi
[ -s "$FIXTURE" ] || die "missing $FIXTURE"
printf '[ok] fixture: %s (%s bytes)\n' "$FIXTURE" "$(stat -f %z "$FIXTURE")"

# ---------------------------------------------------------------------------
step "macOS: swift build"
if ! swift build --package-path "$HERE" --scratch-path "$SCRATCH"; then
    die "swift build failed"
fi

step "macOS: swift test"
if ! swift test --package-path "$HERE" --scratch-path "$SCRATCH"; then
    die "swift test failed"
fi

step "macOS: run lux-ffmpeg-probe"
PROBE="$SCRATCH/debug/lux-ffmpeg-probe"
[ -x "$PROBE" ] || die "missing $PROBE"
if ! "$PROBE" "$FIXTURE"; then
    die "lux-ffmpeg-probe failed"
fi

# ---------------------------------------------------------------------------
if [ "$skip_ios" = 0 ]; then
    step "iOS Simulator: xcodebuild build(只编译)"
    # generic/platform=iOS Simulator 默认会同时要 arm64 + x86_64,而我们只出 arm64 切片;
    # 明确 ARCHS=arm64(与 Apple Silicon 机型一致)。
    log="$BUILD_ROOT/logs/swift-import-xcodebuild.log"
    mkdir -p "$(dirname "$log")"
    if ! ( cd "$HERE" && xcodebuild build \
            -scheme LuxFFmpegImport \
            -destination 'generic/platform=iOS Simulator' \
            -derivedDataPath "$DERIVED" \
            ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
            CODE_SIGNING_ALLOWED=NO > "$log" 2>&1 ); then
        tail -40 "$log" >&2
        die "xcodebuild (iOS Simulator) failed, see $log"
    fi
    grep -q "BUILD SUCCEEDED" "$log" || die "xcodebuild did not report BUILD SUCCEEDED"
    printf '\n[ok] iOS Simulator 编译通过;模拟器运行不在本任务范围内(代理不能起模拟器)\n'
fi

printf '\nRESULT: PASS\n'
