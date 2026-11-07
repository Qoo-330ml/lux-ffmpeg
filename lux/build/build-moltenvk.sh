#!/usr/bin/env bash
# 构建 MoltenVK 1.4.2(Apache-2.0)静态库,并安装到依赖前缀(F2-2b)。
# 用法: ./lux/build/build-moltenvk.sh <macos-arm64|ios-arm64|ios-sim-arm64>
# 只用 lux/config/deps.lock 中锁定的源码;所有构建目录都在 lux/.build/ 内。
# 当前只实现 macos-arm64;iOS 切片待 F2-3 验证 xcodebuild 的 -sdk 路径后补充。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="${1:?target required}"
case "$TARGET" in
  macos-arm64) PLATFORM="macOS"; SCHEME_OS="macOS"; MVK_TARGET="MoltenVK-macOS"; SDK="macosx" ;;
  *) echo "build-moltenvk.sh: $TARGET not implemented yet (F2-3)" >&2; exit 2 ;;
esac
SRC="$REPO/lux/.build/deps/src"
ROOT="$REPO/lux/.build/deps/$TARGET/moltenvk"
PREFIX="$REPO/lux/.build/deps/$TARGET/install"
DD="$ROOT/dd"
rm -rf "$ROOT/src"; mkdir -p "$ROOT/src" "$DD" "$PREFIX/lib" "$PREFIX/include"

# 1. 解开 MoltenVK 源码
tar -C "$ROOT/src" -xzf "$SRC/v1.4.2.tar.gz"
MVK="$ROOT/src/MoltenVK-1.4.2"

# 2. 按锁定的提交号放置外部依赖(目录名与 MoltenVK 的 fetchDependencies 一致)
python3 -I - "$SRC" "$MVK" <<'PY'
import os, shutil, sys, tarfile
src, mvk = sys.argv[1], sys.argv[2]
def unpack(archive, dest):
    tmp = dest + ".tmp"
    shutil.rmtree(tmp, ignore_errors=True); os.makedirs(tmp)
    with tarfile.open(os.path.join(src, archive)) as t:
        t.extractall(tmp, filter="data")
    top = os.listdir(tmp)[0]
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    os.rename(os.path.join(tmp, top), dest)
    shutil.rmtree(tmp, ignore_errors=True)
ext = os.path.join(mvk, "External")
os.makedirs(ext, exist_ok=True)
unpack("a56bad8bbb770ee266e930c95d37fff2a5be7fea.tar.gz", os.path.join(ext, "cereal"))
unpack("e3b1eec08173d6b825cd3ac88c885a63b621504a.tar.gz", os.path.join(ext, "Vulkan-Headers"))
unpack("6c09849fe88c48eaed08413aa022aaa136a3a057.tar.gz", os.path.join(ext, "SPIRV-Cross"))
unpack("0d6fd73ca73830ccab5fa1f00ed5ed40124e2c55.tar.gz", os.path.join(ext, "SPIRV-Tools"))
unpack("29981f65241605e08b0ede4cfeb999fe3b723c6a.tar.gz", os.path.join(ext, "SPIRV-Tools", "external", "spirv-headers"))
unpack("776893306c5d3b22b6185b5d4a258b81d94572bf.tar.gz", os.path.join(ext, "Volk"))
PY
# SPIRV-Tools 的预生成头文件(MoltenVK 自带模板,fetchDependencies 的默认路径)
unzip -o -q -d "$MVK/External/SPIRV-Tools" "$MVK/Templates/spirv-tools/build.zip"
rm -rf "$MVK/External/SPIRV-Tools/__MACOSX"

# 3. 外部静态库(SPIRVCross / SPIRVTools)
( cd "$MVK" && xcodebuild build -project ExternalDependencies.xcodeproj -scheme "ExternalDependencies-$SCHEME_OS" \
    -configuration Release -destination "generic/platform=$PLATFORM" -derivedDataPath "$DD/ext" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES ) > "$ROOT/ext.log" 2>&1 || { tail -30 "$ROOT/ext.log" >&2; exit 1; }
ln -sfn Release "$MVK/External/build/Latest"

# 4. MoltenVK 库本体(-target 而不是 scheme,避开 MoltenVKShaderConverter 对 x86_64 切片的假设)
( cd "$MVK" && xcodebuild build -project MoltenVKPackaging.xcodeproj -target "$MVK_TARGET" -configuration Release \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SYMROOT="$DD/products" OBJROOT="$DD/obj" ) > "$ROOT/mvk.log" 2>&1 \
  || { tail -30 "$ROOT/mvk.log" >&2; exit 1; }
LIB="$DD/products/Release/libMoltenVK.a"
[ -f "$LIB" ] || { echo "libMoltenVK.a not produced" >&2; exit 1; }

# 5. 安装到前缀:静态库 + Vulkan 头文件 + vulkan.pc(供 libplacebo 找到头文件与 MoltenVK)
cp "$LIB" "$PREFIX/lib/libMoltenVK.a"
mkdir -p "$PREFIX/include/vulkan"
cp -R "$MVK/External/Vulkan-Headers/include/vulkan/." "$PREFIX/include/vulkan/"
cp -R "$MVK/External/Vulkan-Headers/include/vk_video" "$PREFIX/include/" 2>/dev/null || true
mkdir -p "$PREFIX/lib/pkgconfig"
cat > "$PREFIX/lib/pkgconfig/vulkan.pc" <<PC
prefix=$PREFIX
includedir=\${prefix}/include
libdir=\${prefix}/lib
Name: Vulkan
Description: Vulkan API (MoltenVK 1.4.2, static)
Version: 1.4.357
Cflags: -I\${includedir}
Libs: -L\${libdir} -lMoltenVK -framework Metal -framework IOSurface -framework QuartzCore -framework IOKit -framework CoreGraphics -framework Foundation -framework AppKit
PC
echo "[built] moltenvk 1.4.2 ($TARGET) -> $PREFIX/lib/libMoltenVK.a"
