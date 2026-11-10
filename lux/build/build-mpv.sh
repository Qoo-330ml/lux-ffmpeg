#!/usr/bin/env bash
# 构建动态 libmpv 0.41.0(LGPL-2.1+,-Dgpl=false)(F2-3 起步:只做 macOS arm64)。
# 依赖来自 build-deps.sh 的前缀(静态/动态混合,见 lux/config/deps-target.sh)与 lux-ffmpeg 的 F1 动态库。
# 用法: ./lux/build/build-mpv.sh <macos-arm64>
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="${1:?target required}"
case "$TARGET" in
  macos-arm64) XCF_SLICE="macos-arm64" ;;
  ios-arm64) XCF_SLICE="ios-arm64" ;;
  # xcframework 里模拟器切片的目录名是 ios-arm64-simulator(不是 ios-sim-arm64)
  ios-sim-arm64) XCF_SLICE="ios-arm64-simulator" ;;
  *) echo "build-mpv.sh: $TARGET not implemented yet" >&2; exit 2 ;;
esac
SRC="$REPO/lux/.build/deps/src"
PREFIX="$REPO/lux/.build/deps/$TARGET/install"
WORK="$REPO/lux/.build/deps/$TARGET/mpv"
XCF="$REPO/lux/.build/xcframeworks"
PCDIR="$REPO/lux/.build/deps/$TARGET/pc-ffmpeg"
# 安装前缀只用于“写进二进制”的 meson 配置与默认路径;真实产物仍安装到 PREFIX。
# 固定的占位路径不会把构建机目录带进发布产物,也不依赖 PREFIX 的位置。
INSTALL_PREFIX="/lux-install"
STAGE="$WORK/install-stage"
export PYTHONPATH="$REPO/lux/.build/deps/pydeps"
. "$REPO/lux/config/deps-target.sh"; deps_target_setup "$TARGET"

rm -rf "$WORK"; mkdir -p "$WORK" "$PCDIR" "$PCDIR/include"
tar -C "$WORK" -xzf "$SRC/v0.41.0.tar.gz" --strip-components=1

# 0a. mpv 源码补丁(lux/patches/mpv/,清单 lux/config/mpv-patches.txt)。
#     只改 mpv;FFmpeg 补丁集仍走 lux/config/patches.txt,两者互不影响。
#     WORK 每次都是新解包,所以补丁总能以 -N 零 fuzz 应用;失败即中止。
MPV_PATCH_DIR="$REPO/lux/patches/mpv"
MPV_PATCH_LIST="$REPO/lux/config/mpv-patches.txt"
if [ -f "$MPV_PATCH_LIST" ]; then
  while IFS= read -r patch_name; do
    [ -n "$patch_name" ] || continue
    patch_file="$MPV_PATCH_DIR/$patch_name"
    [ -f "$patch_file" ] || { echo "build-mpv.sh: 缺少 mpv 补丁: $patch_file" >&2; exit 1; }
    patch -d "$WORK" -p1 -N -s -i "$patch_file" \
      || { echo "build-mpv.sh: mpv 补丁应用失败: $patch_name" >&2; exit 1; }
    echo "[patch] $patch_name"
  done < <(sed -e 's/#.*//' "$MPV_PATCH_LIST" | awk 'NF { print $1 }')
fi

# meson.build_options() 会把 --cross-file 的实参原样写进 libmpv 的 Configuration。
# 传绝对路径会把构建机目录带进产物;这里把交叉文件放进 WORK,配合下面在 WORK 里
# 执行的 meson setup 用相对文件名传参,配置字符串里只会留下 meson-cross.ini。
cp "$REPO/lux/.build/deps/$TARGET/meson-cross.ini" "$WORK/meson-cross.ini"
DEPS_MESON_CROSS="--cross-file=meson-cross.ini"

# 0. iOS 切片的源码补丁(幂等):iOS SDK 不声明 AudioDeviceID / AudioStreamID / AudioObjectPropertyAddress 的
#    完整声明位置(后两者在 AudioHardwareBase.h),而 audiounit 输出会编译 ao_coreaudio_utils.h 与 ao_coreaudio_chmap.c。
#    这里只在 TARGET_OS_IPHONE 下补上与 Apple 头文件同义的 uint32_t typedef,并引入 AudioHardwareBase.h。
if [ "${TARGET#ios-}" != "$TARGET" ]; then
  python3 -I - "$WORK/audio/out/ao_coreaudio_utils.h" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "LUX_IOS_COREAUDIO_TYPEDEFS" not in s:
    block = (
        "#include <TargetConditionals.h>\n"
        "#include <CoreAudio/AudioHardwareBase.h>\n"
        "#if TARGET_OS_IPHONE\n"
        "#ifndef LUX_IOS_COREAUDIO_TYPEDEFS\n"
        "#define LUX_IOS_COREAUDIO_TYPEDEFS\n"
        "typedef uint32_t AudioDeviceID;\n"
        "typedef uint32_t AudioStreamID;\n"
        "#endif\n"
        "#endif\n"
    )
    lines = s.split("\n")
    idx = next((i for i, l in enumerate(lines) if l.startswith("#include") or l.startswith("#define")), 0)
    lines.insert(idx, block)
    open(p, "w", encoding="utf-8").write("\n".join(lines))
    print("patched", p)
else:
    print("already patched", p)
PY
fi

# 1. 为 lux-ffmpeg 的六个动态库写 pkg-config 文件(指向 xcframework 的对应切片,不链接静态库)
FW="$XCF/Libavutil.xcframework/$XCF_SLICE"
for lib in Libavutil Libswresample Libavcodec Libavformat Libavfilter Libswscale; do
  name="$(echo "$lib" | tr 'A-Z' 'a-z')"
  ln -sfn "$XCF/$lib.xcframework/$XCF_SLICE/$lib.framework/Headers/$name" "$PCDIR/include/$name"
done
# 版本号取自 F1 的 BUILD-INFO(libavcodec 62.28.103 等);mpv 的 pkg-config 版本检查需要这些数字
gen_pc() { # $1 pc-name $2 framework $3 version
  cat > "$PCDIR/$1.pc" <<PC
Name: $1
Description: $2 (lux-ffmpeg F1 dynamic framework)
Version: $3
Cflags: -I$PCDIR/include
Libs: -F$XCF/$2.xcframework/$XCF_SLICE -framework $2
PC
}
gen_pc libavutil Libavutil 60.26.103
gen_pc libswresample Libswresample 6.3.103
gen_pc libavcodec Libavcodec 62.28.103
gen_pc libavformat Libavformat 62.12.103
gen_pc libavfilter Libavfilter 11.14.103
gen_pc libswscale Libswscale 9.5.103
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PCDIR"
export PKG_CONFIG_PATH=""

# 2. meson 配置(选项名取自 mpv 0.41 的 meson.options)
# P2 出口:分发的 Libmpv.framework 要有带 DWARF 的 dSYM,所以在 c_args 里加 -g。
# buildtype 仍是 release(-O2 / -DNDEBUG),只多出调试信息,不改变代码生成。
# meson 不读 CFLAGS 环境变量,命令行 -Dc_args 会整体替换交叉文件里的默认值,
# 因此这里必须带上 DEPS_CFLAGS 全量再追加 -g。
MPV_CFLAGS="$DEPS_CFLAGS -g"
# B+:libmpv 的 iOS MoltenVK 上下文直接引用 vkGetInstanceProcAddr / vkDestroySurfaceKHR
# 等 5 个符号;libplacebo 现在动态链 MoltenVK,不再把这些符号导出给 libmpv,
# 所以这里显式链接同一份共享 libMoltenVK.dylib(不是第二份静态拷贝)。
# mpv 的 meson 默认带 -Wl,-dead_strip_dylibs + -undefined,dynamic_lookup:
# 不强制保留时,链接器会把 libMoltenVK.dylib 当未使用依赖丢掉。
# -needed_library 让 LC_LOAD_DYLIB 一定出现在产物里(libmpv 的 vk* 走 dynamic_lookup)。
MOLTENVK_LIBS="-Wl,-needed_library,$PREFIX/lib/libMoltenVK.dylib"
# shaderc 在 mpv 0.41 里只为 win32-desktop 需要;SPIR-V 编译由 libplacebo 完成,这里关闭
# RemoteIO 子类型只存在于 iOS 的 AudioToolbox;macOS 切片关闭 audiounit(AVFoundation AO 仍可用)
# coreaudio(ao_coreaudio)只在 macOS 有 AudioDevice API,这里全部关闭;播放走 avfoundation / audiounit
AUDIOUNIT=disabled
IOS_GL=disabled
AVFOUNDATION=enabled
case "$TARGET" in ios-*) AUDIOUNIT=enabled; IOS_GL=enabled; AVFOUNDATION=disabled ;; esac
rm -rf "$WORK/build"
# 在 WORK 里执行,让 --cross-file=meson-cross.ini 保持相对路径(见上)。
( cd "$WORK" && meson setup "$WORK/build" "$WORK" --prefix="$INSTALL_PREFIX" --buildtype=release \
  --default-library=shared $DEPS_MESON_CROSS \
  -Dc_args="$MPV_CFLAGS" -Dc_link_args="$DEPS_LDFLAGS $MOLTENVK_LIBS" \
  -Dlibmpv=true -Dcplayer=false -Dgpl=false \
  -Dlua=disabled -Djavascript=disabled -Dlibbluray=disabled -Dlibarchive=disabled \
  -Dvapoursynth=disabled -Dzimg=disabled -Drubberband=disabled -Dlibavdevice=disabled \
  -Dzlib=disabled -Dcocoa=disabled -Dmacos-cocoa-cb=disabled -Dswift-build=disabled \
  -Duchardet=enabled -Dlcms2=enabled \
  -Dgl=enabled -Dplain-gl=enabled -Dios-gl=$IOS_GL -Dvideotoolbox-gl=disabled -Dvideotoolbox-pl=enabled \
  -Dvulkan=enabled -Dshaderc=disabled -Daudiounit=$AUDIOUNIT -Dcoreaudio=disabled -Davfoundation=$AVFOUNDATION \
  -Dtests=false -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled \
  ) > "$WORK/configure.log" 2>&1 || { tail -40 "$WORK/configure.log" >&2; exit 1; }
# 3. 编译与安装
ninja -C "$WORK/build" -j"$(sysctl -n hw.ncpu)" > "$WORK/build.log" 2>&1 || { grep -a -m5 'error' "$WORK/build.log" >&2; tail -20 "$WORK/build.log" >&2; exit 1; }
# 安装先落到 DESTDIR,再把占位前缀 /lux-install 下的内容合并回 PREFIX:
# 这样二进制里记录的是 --prefix=/lux-install(以及 /lux-install/etc/mpv),
# 不会出现 deps/<target>/install 的绝对路径,产物位置也保持不变。
rm -rf "$STAGE"
DESTDIR="$STAGE" ninja -C "$WORK/build" install >> "$WORK/build.log" 2>&1
[ -d "$STAGE$INSTALL_PREFIX" ] || { echo "build-mpv.sh: 安装暂存目录缺失: $STAGE$INSTALL_PREFIX" >&2; exit 1; }
mkdir -p "$PREFIX"
( cd "$STAGE$INSTALL_PREFIX" && tar -cf - . ) | ( cd "$PREFIX" && tar -xf - )
rm -rf "$STAGE"
# 4. 回归检查:安装后的 libmpv 不得再把本检出的绝对路径带进产物。
for lib in "$PREFIX"/lib/libmpv.*.dylib; do
  [ -f "$lib" ] || continue
  if strings "$lib" | grep -qF "$REPO"; then
    echo "build-mpv.sh: $lib 仍包含构建路径 $REPO" >&2
    exit 1
  fi
done
echo "[built] libmpv 0.41.0 ($TARGET) -> $PREFIX/lib"
