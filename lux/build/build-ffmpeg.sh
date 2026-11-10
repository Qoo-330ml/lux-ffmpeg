#!/usr/bin/env bash
#
# lux/build/build-ffmpeg.sh — 出 LGPL 最小静态库(.a)
#
#   ./lux/build/build-ffmpeg.sh macos-arm64     # 本机(arm64 macOS)
#   ./lux/build/build-ffmpeg.sh ios-arm64       # iOS device
#   ./lux/build/build-ffmpeg.sh ios-sim-arm64   # iOS simulator
#   ./lux/build/build-ffmpeg.sh clean           # 删掉 lux/.build/(会重新要时间)
#
# 约定:
#   * 源码树外构建:configure 在 lux/.build/<target>/ 里跑,源码树保持干净;
#   * 所有产物、日志、临时文件只在 lux/.build/ 内(TMPDIR 被指到 lux/.build/tmp);
#   * configure 参数全部来自 lux/config/ffmpeg-ios.conf,本脚本只负责编排。
#
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LUX=$(cd "$HERE/.." && pwd)
REPO=$(cd "$LUX/.." && pwd)
BUILD_ROOT="$LUX/.build"

# shellcheck source=../config/ffmpeg-ios.conf
. "$LUX/config/ffmpeg-ios.conf"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '[build] %s\n' "$*"; }

# ---------------------------------------------------------------- 参数 / 环境
target=${1:-}
[ -n "$target" ] || die "usage: $0 <macos-arm64|ios-arm64|ios-sim-arm64|clean>"

if [ "$target" = clean ]; then
    rm -rf "$BUILD_ROOT"
    log "removed $BUILD_ROOT"
    exit 0
fi

case " $LUX_TARGETS " in
    *" $target "*) ;;
    *) die "unknown target '$target' (expected: $LUX_TARGETS)" ;;
esac

# 所有临时目录都在仓库外的外置盘上,绝不落 $TMPDIR(/var/folders)。
mkdir -p "$BUILD_ROOT/tmp" "$BUILD_ROOT/logs"
export TMPDIR="$BUILD_ROOT/tmp"
export TMP="$TMPDIR"
export TEMP="$TMPDIR"
# Xcode / clang 的模块缓存也留在 lux/.build 里
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH"
export DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData"

BUILD="$BUILD_ROOT/$target"
LOGDIR="$BUILD_ROOT/logs"

INSTALL="$BUILD/install"

# 外部依赖(dav1d / zlib / OpenSSL)统一装在 lux/.build/deps/<target>/install。
# ffmpeg-ios.conf 用 LUX_DEPS_PREFIX 生成 -I/-L(zlib 的探测不走 pkg-config);
# pkg-config 只搜这一个前缀、清空 PKG_CONFIG_PATH,避免 Homebrew/系统库混进来。
DEPS_PREFIX="$BUILD_ROOT/deps/$target/install"
export LUX_DEPS_PREFIX="$DEPS_PREFIX"
for pc in dav1d zlib openssl; do
    [ -f "$DEPS_PREFIX/lib/pkgconfig/$pc.pc" ] \
        || die "缺少 $DEPS_PREFIX/lib/pkgconfig/$pc.pc — 先跑 ./lux/build/build-deps.sh $target dav1d zlib openssl"
done
export PKG_CONFIG_LIBDIR="$DEPS_PREFIX/lib/pkgconfig:$DEPS_PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH=""

ff_configure_opts "$target" "$INSTALL" || die "cannot resolve configure opts for '$target'"

# P2 出口:静态库也要带 -g,否则 dSYM 只有 UUID 没有 DWARF。
# 只往 --extra-cflags 追加调试信息开关;优化(-O2)、--disable-debug 与其它 configure
# 参数保持唯一来自 lux/config/ffmpeg-ios.conf(与 ff_framework_configure_opts 给
# 动态库加 LUX_FRAMEWORK_CFLAGS=-g 的做法一致)。
LUX_DEBUG_CFLAGS="${LUX_DEBUG_CFLAGS:--g}"
_ff_opts=()
for _opt in "${FF_OPTS[@]}"; do
    case "$_opt" in
        --extra-cflags=*) _ff_opts+=("--extra-cflags=${_opt#--extra-cflags=} $LUX_DEBUG_CFLAGS") ;;
        *)                _ff_opts+=("$_opt") ;;
    esac
done
FF_OPTS=("${_ff_opts[@]}")

log "target      : $target ($FF_HOST_OS_LABEL)"
log "sdk         : $FF_SDK_NAME $FF_SDK_VERSION -> $FF_SDK_PATH"
log "build dir   : $BUILD"
log "TMPDIR      : $TMPDIR"

# ---------------------------------------------------------------- 许可自检
# 先证明自己没在参数里夹带 GPL/nonfree,再开始 configure。
for opt in "${FF_OPTS[@]}"; do
    if printf '%s\n' "$opt" | grep -Eq -e "$LUX_FORBIDDEN_OPTS"; then
        die "forbidden configure option: $opt"
    fi
done
case " ${FF_OPTS[*]} " in
    *" --disable-gpl "*|*" --disable-nonfree "*) ;;
    *) die "--disable-gpl / --disable-nonfree missing from FF_OPTS" ;;
esac

# ---------------------------------------------------------------- 补丁集
# lux/patches/ 必须先零 fuzz 应用;指纹写进 BUILD-INFO,verify-license.sh 用它
# 证明"这个产物对应的补丁集"和仓库里的一致。
"$LUX/build/apply-patches.sh" ensure || die "lux 补丁集未就绪,先看 lux/build/apply-patches.sh status"
patches_count=$("$LUX/build/apply-patches.sh" count) || die "cannot count lux patches"
patches_digest=$("$LUX/build/apply-patches.sh" digest) || die "cannot digest lux patches"
log "patches     : $patches_count ($patches_digest)"

# ---------------------------------------------------------------- configure
# 每次从零开始:避免上一次 configure 的 config.h/.o 影响结果(日志保留在 logs/)
if [ -d "$BUILD" ]; then
    log "wiping previous $BUILD"
    rm -rf "$BUILD"
fi
mkdir -p "$BUILD"
cd "$BUILD"

printf '%s\n' "${FF_OPTS[@]}" > configure.opts.txt

start=$(date +%s)
log "configure ..."
if ! "$REPO/configure" "${FF_OPTS[@]}" > "$LOGDIR/$target-configure.log" 2>&1; then
    tail -40 "$LOGDIR/$target-configure.log" >&2
    die "configure failed, see $LOGDIR/$target-configure.log"
fi
cfg_elapsed=$(( $(date +%s) - start ))
license_line=$(grep -m1 '^License:' "$LOGDIR/$target-configure.log" || true)
log "configure done in ${cfg_elapsed}s: ${license_line:-<no License: line>}"

# 许可行的硬断言:必须是以 LGPL 开头的 license
case "$license_line" in
    "License: LGPL"*) ;;
    *) die "unexpected license line: ${license_line:-<none>}" ;;
esac

# ---------------------------------------------------------------- make
jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
log "make -j$jobs ..."
if ! make -j"$jobs" > "$LOGDIR/$target-make.log" 2>&1; then
    tail -60 "$LOGDIR/$target-make.log" >&2
    die "make failed, see $LOGDIR/$target-make.log"
fi
log "make install ..."
if ! make install >> "$LOGDIR/$target-make.log" 2>&1; then
    tail -40 "$LOGDIR/$target-make.log" >&2
    die "make install failed, see $LOGDIR/$target-make.log"
fi
end=$(date +%s)
elapsed=$(( end - start ))
log "make done, total ${elapsed}s"

# ---------------------------------------------------------------- 产物检查
missing=""
for lib in $LUX_STATIC_LIBS; do
    [ -f "$INSTALL/lib/$lib" ] || missing="$missing $lib"
done
[ -z "$missing" ] || die "missing static libraries:$missing"

total=0
{
    printf 'target=%s\n' "$target"
    printf 'baseline=%s\n' "$LUX_BASELINE_LABEL"
    printf 'sdk=%s %s\n' "$FF_SDK_NAME" "$FF_SDK_VERSION"
    printf 'min_os=%s\n' "$FF_HOST_OS_LABEL"
    printf 'configure_seconds=%s\n' "$cfg_elapsed"
    printf 'build_seconds=%s\n' "$elapsed"
    printf 'license=%s\n' "${license_line#License: }"
    printf 'patches_count=%s\n' "$patches_count"
    printf 'patches_digest=%s\n' "$patches_digest"
} > "$BUILD/BUILD-INFO.txt"

log "sizes:"
for lib in $LUX_STATIC_LIBS; do
    size=$(stat -f %z "$INSTALL/lib/$lib")
    total=$(( total + size ))
    printf '  %-18s %10d bytes\n' "$lib" "$size"
    printf 'size.%s=%s\n' "$lib" "$size" >> "$BUILD/BUILD-INFO.txt"
done
printf '  %-18s %10d bytes\n' "TOTAL" "$total"
printf 'size.total=%s\n' "$total" >> "$BUILD/BUILD-INFO.txt"

log "ok — artifacts in $INSTALL/lib/, next: ./lux/build/verify-license.sh $target"
