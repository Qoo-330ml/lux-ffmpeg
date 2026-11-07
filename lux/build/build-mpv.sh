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
  *) echo "build-mpv.sh: $TARGET not implemented yet" >&2; exit 2 ;;
esac
SRC="$REPO/lux/.build/deps/src"
PREFIX="$REPO/lux/.build/deps/$TARGET/install"
WORK="$REPO/lux/.build/deps/$TARGET/mpv"
XCF="$REPO/lux/.build/xcframeworks"
PCDIR="$REPO/lux/.build/deps/$TARGET/pc-ffmpeg"
export PYTHONPATH="$REPO/lux/.build/deps/pydeps"
. "$REPO/lux/config/deps-target.sh"; deps_target_setup "$TARGET"

rm -rf "$WORK"; mkdir -p "$WORK" "$PCDIR" "$PCDIR/include"
tar -C "$WORK" -xzf "$SRC/v0.41.0.tar.gz" --strip-components=1

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
# shaderc 在 mpv 0.41 里只为 win32-desktop 需要;SPIR-V 编译由 libplacebo 完成,这里关闭
# RemoteIO 子类型只存在于 iOS 的 AudioToolbox;macOS 切片关闭 audiounit(AVFoundation AO 仍可用)
# coreaudio(ao_coreaudio)只在 macOS 有 AudioDevice API,这里全部关闭;播放走 avfoundation / audiounit
AUDIOUNIT=disabled
IOS_GL=disabled
case "$TARGET" in ios-*) AUDIOUNIT=enabled; IOS_GL=enabled ;; esac
rm -rf "$WORK/build"
meson setup "$WORK/build" "$WORK" --prefix="$PREFIX" --buildtype=release \
  --default-library=shared $DEPS_MESON_CROSS \
  -Dc_args="$DEPS_CFLAGS" -Dc_link_args="$DEPS_LDFLAGS" \
  -Dlibmpv=true -Dcplayer=false -Dgpl=false \
  -Dlua=disabled -Djavascript=disabled -Dlibbluray=disabled -Dlibarchive=disabled \
  -Dvapoursynth=disabled -Dzimg=disabled -Drubberband=disabled -Dlibavdevice=disabled \
  -Dzlib=disabled -Dcocoa=disabled -Dmacos-cocoa-cb=disabled -Dswift-build=disabled \
  -Duchardet=enabled -Dlcms2=enabled \
  -Dgl=enabled -Dplain-gl=enabled -Dios-gl=$IOS_GL -Dvideotoolbox-gl=disabled -Dvideotoolbox-pl=enabled \
  -Dvulkan=enabled -Dshaderc=disabled -Daudiounit=$AUDIOUNIT -Dcoreaudio=disabled -Davfoundation=enabled \
  -Dtests=false -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled \
  > "$WORK/configure.log" 2>&1 || { tail -40 "$WORK/configure.log" >&2; exit 1; }
# 3. 编译与安装
ninja -C "$WORK/build" -j"$(sysctl -n hw.ncpu)" > "$WORK/build.log" 2>&1 || { grep -a -m5 'error' "$WORK/build.log" >&2; tail -20 "$WORK/build.log" >&2; exit 1; }
ninja -C "$WORK/build" install >> "$WORK/build.log" 2>&1
echo "[built] libmpv 0.41.0 ($TARGET) -> $PREFIX/lib"
