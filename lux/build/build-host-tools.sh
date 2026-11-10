#!/usr/bin/env bash
# 构建 host 侧的 glslc(FFmpeg 的 spirv_compiler 需要它预编译 3 个滤镜的 SPIR-V)。
# 用法: ./lux/build/build-host-tools.sh [--force]
#
# 只用 deps.lock 里锁定的 shaderc / glslang / SPIRV-Tools / SPIRV-Headers 源码。
# 产物在 lux/.build/host-tools/install/bin/glslc,由 ffmpeg-ios.conf 的 --glslc= 使用。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO/lux/.build/deps/src"
ROOT="$REPO/lux/.build/host-tools"
WORK="$ROOT/work"
PREFIX="$ROOT/install"
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ -x "$PREFIX/bin/glslc" ] && [ "$FORCE" != 1 ]; then
  echo "[host-tools] glslc already built: $PREFIX/bin/glslc"
  "$PREFIX/bin/glslc" --version | head -1
  exit 0
fi

for a in v2025.5.tar.gz \
         7a47e2531cb334982b2a2dd8513dca0a3de4373d.tar.gz \
         262bdab48146c937467f826699a40da0fdfc0f1a.tar.gz \
         b824a462d4256d720bebb40e78b9eb8f78bbb305.tar.gz; do
  [ -f "$SRC/$a" ] || { echo "缺少源码归档: $SRC/$a(先跑 fetch-deps.sh)" >&2; exit 1; }
done

rm -rf "$WORK/shaderc"; mkdir -p "$WORK/shaderc" "$PREFIX/bin"
tar -C "$WORK/shaderc" -xzf "$SRC/v2025.5.tar.gz" --strip-components=1

extract_into() { # $1 archive $2 dest
  local tmp="$WORK/.unpack-$$"; rm -rf "$tmp"; mkdir -p "$tmp"
  tar -C "$tmp" -xf "$SRC/$1"
  rm -rf "$2"; mkdir -p "$(dirname "$2")"; mv "$tmp"/* "$2"
  rm -rf "$tmp"
}
mkdir -p "$WORK/shaderc/third_party"
extract_into 7a47e2531cb334982b2a2dd8513dca0a3de4373d.tar.gz "$WORK/shaderc/third_party/glslang"
extract_into 262bdab48146c937467f826699a40da0fdfc0f1a.tar.gz "$WORK/shaderc/third_party/spirv-tools"
extract_into b824a462d4256d720bebb40e78b9eb8f78bbb305.tar.gz "$WORK/shaderc/third_party/spirv-tools/external/spirv-headers"
mkdir -p "$WORK/shaderc/third_party/glslang/External" "$WORK/shaderc/third_party/spirv-tools/external"
ln -sfn ../../spirv-tools "$WORK/shaderc/third_party/glslang/External/spirv-tools"

SDK=$(xcrun --sdk macosx --show-sdk-path)
cmake -S "$WORK/shaderc" -B "$WORK/shaderc/build-host" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DENABLE_GLSLANG_BINARIES=ON \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON > "$ROOT/configure.log" 2>&1 \
  || { tail -40 "$ROOT/configure.log" >&2; exit 1; }
cmake --build "$WORK/shaderc/build-host" --target glslc_exe -j"$JOBS" > "$ROOT/build.log" 2>&1 \
  || { tail -40 "$ROOT/build.log" >&2; exit 1; }

BIN=$(find "$WORK/shaderc/build-host" -path '*/glslc/glslc' -type f | head -1)
[ -n "$BIN" ] || { echo "glslc not produced" >&2; exit 1; }
cp "$BIN" "$PREFIX/bin/glslc"; chmod 755 "$PREFIX/bin/glslc"
"$PREFIX/bin/glslc" --version | head -1
echo "[host-tools] glslc -> $PREFIX/bin/glslc"
