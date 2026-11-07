#!/usr/bin/env bash
# 构建 libmpv 依赖(F2-2)。源码来自 lux/.build/deps/src(先跑 fetch-deps.sh 校验)。
# 用法: ./lux/build/build-deps.sh <macos-arm64|ios-arm64|ios-sim-arm64> [库名 ...]
# 产物:lux/.build/deps/<target>/install(静态库 .a 与动态库 .dylib 分开装,不混用)。
# 许可:动态的只有 fribidi(LGPL-2.1+)与 uchardet(LGPL-2.1+ 选择);其余为静态并入 libmpv/libplacebo。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO/lux/.build/deps/src"
TARGET="${1:?target required}"; shift
. "$REPO/lux/config/deps-target.sh"
deps_target_setup "$TARGET"          # 设置 SDK/CC/CFLAGS/PREFIX/MESON 交叉文件等
PREFIX="$DEPS_PREFIX"
WORK="$REPO/lux/.build/deps/$TARGET/work"
mkdir -p "$WORK" "$PREFIX"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH=""
export CC="$DEPS_CC" CXX="$DEPS_CXX" AR="$DEPS_AR" RANLIB="$DEPS_RANLIB"
# libplacebo 的 glad 生成器(glad2 2.0.8,PyPI),装在项目内的 pydeps 目录
export PYTHONPATH="$REPO/lux/.build/deps/pydeps${PYTHONPATH:+:$PYTHONPATH}"
export CFLAGS="$DEPS_CFLAGS" CXXFLAGS="$DEPS_CFLAGS" LDFLAGS="$DEPS_LDFLAGS"
JOBS=$(sysctl -n hw.ncpu)
extract() { # $1 archive basename
  rm -rf "$WORK/$2"; mkdir -p "$WORK"
  tar -C "$WORK" -xf "$SRC/$1"
  local top; top=$(tar -tf "$SRC/$1" | head -1 | cut -d/ -f1)
  mv "$WORK/$top" "$WORK/$2"
}
meson_build() { # $1 name $2 srcdir [extra meson args...]
  local name=$1 dir=$2; shift 2
  rm -rf "$dir/build-$TARGET"
  meson setup "$dir/build-$TARGET" "$dir" --prefix="$PREFIX" --buildtype=release \
    --default-library=static $DEPS_MESON_CROSS "$@" > "$WORK/$name.log" 2>&1 || { tail -40 "$WORK/$name.log"; return 1; }
  ninja -C "$dir/build-$TARGET" -j"$JOBS" >> "$WORK/$name.log" 2>&1 && ninja -C "$dir/build-$TARGET" install >> "$WORK/$name.log" 2>&1
}
want() { [ $# -eq 0 ] || { for w in "$WANT"; do :; done; }; }
build_one() {
  local name=$1
  case "$name" in
    freetype)
      extract freetype-2.15.0.tar.xz freetype
      meson_build freetype "$WORK/freetype" -Dharfbuzz=disabled -Dpng=disabled -Dzlib=disabled -Dbzip2=disabled -Dbrotli=disabled -Dtests=disabled ;;
    harfbuzz)
      extract harfbuzz-15.0.0.tar.xz harfbuzz
      meson_build harfbuzz "$WORK/harfbuzz" -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dicu=disabled -Dcairo=disabled -Dtests=disabled -Ddocs=disabled -Dcoretext=enabled ;;
    fribidi)
      extract fribidi-1.0.17.tar.xz fribidi
      rm -rf "$WORK/fribidi/build-$TARGET"
      meson setup "$WORK/fribidi/build-$TARGET" "$WORK/fribidi" --prefix="$PREFIX" --buildtype=release \
        --default-library=shared $DEPS_MESON_CROSS -Ddocs=false -Dtests=false -Dbin=false > "$WORK/fribidi.log" 2>&1
      ninja -C "$WORK/fribidi/build-$TARGET" -j"$JOBS" >> "$WORK/fribidi.log" 2>&1
      ninja -C "$WORK/fribidi/build-$TARGET" install >> "$WORK/fribidi.log" 2>&1 ;;
    libunibreak)
      extract libunibreak-8.0.tar.gz libunibreak
      ( cd "$WORK/libunibreak" && ./configure --host="$DEPS_HOST" --prefix="$PREFIX" --enable-static --disable-shared > "$WORK/libunibreak.log" 2>&1 \
        && make -j"$JOBS" >> "$WORK/libunibreak.log" 2>&1 && make install >> "$WORK/libunibreak.log" 2>&1 ) ;;
    lcms2)
      extract lcms2-2.19.1.tar.gz lcms2
      ( cd "$WORK/lcms2" && ./configure --host="$DEPS_HOST" --prefix="$PREFIX" --enable-static --disable-shared --without-jpeg --without-tiff --without-zlib > "$WORK/lcms2.log" 2>&1 \
        && make -j"$JOBS" >> "$WORK/lcms2.log" 2>&1 && make install >> "$WORK/lcms2.log" 2>&1 ) ;;
    libass)
      extract libass-0.17.5.tar.xz libass
      ( cd "$WORK/libass" && ./configure --host="$DEPS_HOST" --prefix="$PREFIX" --enable-static --disable-shared --disable-fontconfig --disable-require-system-font-provider --disable-test > "$WORK/libass.log" 2>&1 \
        && make -j"$JOBS" >> "$WORK/libass.log" 2>&1 && make install >> "$WORK/libass.log" 2>&1 ) ;;
    shaderc)
      # 静态 shaderc_combined(Apache-2.0)。依赖 glslang / SPIRV-Tools / SPIRV-Headers,按 shaderc DEPS 的提交钉死。
      extract v2025.5.tar.gz shaderc
      mkdir -p "$WORK/shaderc/third_party"
      rm -rf "$WORK/shaderc/third_party/glslang" "$WORK/shaderc/third_party/spirv-tools"
      extract_into() { # $1 archive $2 dest
        local tmp="$WORK/.unpack-$$"; rm -rf "$tmp"; mkdir -p "$tmp"
        tar -C "$tmp" -xf "$SRC/$1"
        rm -rf "$2"; mv "$tmp"/* "$2"; rm -rf "$tmp"
      }
      extract_into 7a47e2531cb334982b2a2dd8513dca0a3de4373d.tar.gz "$WORK/shaderc/third_party/glslang"
      extract_into 262bdab48146c937467f826699a40da0fdfc0f1a.tar.gz "$WORK/shaderc/third_party/spirv-tools"
      extract_into b824a462d4256d720bebb40e78b9eb8f78bbb305.tar.gz "$WORK/shaderc/third_party/spirv-tools/external/spirv-headers"
      mkdir -p "$WORK/shaderc/third_party/glslang/External" "$WORK/shaderc/third_party/spirv-tools/external"
      ln -sfn ../../spirv-tools "$WORK/shaderc/third_party/glslang/External/spirv-tools"
      rm -rf "$WORK/shaderc/build-$TARGET"
      cmake -S "$WORK/shaderc" -B "$WORK/shaderc/build-$TARGET" -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DENABLE_GLSLANG_BINARIES=OFF \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT="$DEPS_SDK" $DEPS_CMAKE_SYSTEM \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPS_MIN_VERSION:-14.0}" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON > "$WORK/shaderc.log" 2>&1 \
        || { tail -30 "$WORK/shaderc.log" >&2; return 1; }
      cmake --build "$WORK/shaderc/build-$TARGET" --target shaderc_combined -j"$JOBS" >> "$WORK/shaderc.log" 2>&1 \
        || { tail -30 "$WORK/shaderc.log" >&2; return 1; }
      cp "$WORK/shaderc/build-$TARGET/libshaderc_combined.a" "$PREFIX/lib/" 2>/dev/null \
        || find "$WORK/shaderc/build-$TARGET" -name 'libshaderc_combined.a' -exec cp {} "$PREFIX/lib/" \;
      mkdir -p "$PREFIX/include"; cp -R "$WORK/shaderc/libshaderc/include/shaderc" "$PREFIX/include/"
      mkdir -p "$PREFIX/lib/pkgconfig"
      cat > "$PREFIX/lib/pkgconfig/shaderc.pc" <<PC
prefix=$PREFIX
includedir=\${prefix}/include
libdir=\${prefix}/lib
Name: shaderc
Description: shaderc (static combined library, Apache-2.0)
Version: 2025.5
Cflags: -I\${includedir}
Libs: -L\${libdir} -lshaderc_combined -lc++
PC
      ;;
    libplacebo)
      # 动态库(LGPL-2.1+),含 MoltenVK 静态库与 shaderc 静态库(由 pkg-config 提供)。
      extract libplacebo-v7.360.1.tar.gz libplacebo
      # glad 头文件已入库(vendor/glad-2.0.8,见其 README.md)。替换 glad 的构建期生成步骤,
      # 只保留它提供的 glad_dep;加载函数由宿主通过 get_proc_address 提供,因此关闭内置加载器。
      cp -R "$REPO/lux/vendor/glad-2.0.8/include/glad" "$WORK/libplacebo/src/opengl/include/"
      printf "%s\n" "glad_dep = declare_dependency(include_directories: include_directories('..'))" > "$WORK/libplacebo/src/opengl/include/glad/meson.build"
      # vk.xml 来自锁定的 Vulkan-Headers 归档(与 MoltenVK 同一提交),用于生成 Vulkan 辅助代码
      rm -rf "$WORK/vulkan-headers"; mkdir -p "$WORK/vulkan-headers"
      tar -C "$WORK/vulkan-headers" -xzf "$SRC/e3b1eec08173d6b825cd3ac88c885a63b621504a.tar.gz"
      VK_XML="$(find "$WORK/vulkan-headers" -path '*/registry/vk.xml' | head -1)"
      [ -n "$VK_XML" ] || { echo "vk.xml not found in Vulkan-Headers archive" >&2; return 1; }
      # MoltenVK 静态并入 libplacebo(Apache-2.0 放进 LGPL 动态库是允许的组合);链接参数取自 vulkan.pc
      LINK_VULKAN="$(PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" pkg-config --libs vulkan)"
      [ -n "$LINK_VULKAN" ] || { echo "vulkan.pc not found in $PREFIX" >&2; return 1; }
      # fast_float(header-only,MIT/Apache-2.0)为 libplacebo 的 3rdparty 子模块;按锁定的 v8.0.2 归档解开并加入 include 路径
      rm -rf "$WORK/fast_float"; mkdir -p "$WORK/fast_float"
      tar -C "$WORK/fast_float" -xzf "$SRC/v8.0.2.tar.gz" --strip-components=1
      rm -rf "$WORK/libplacebo/build-$TARGET"
      # iOS/macOS 的 clang 原生提供 C11 原子操作(compiler-rt),Apple 的 SDK 没有 libatomic;
      # libplacebo 的 cc.links 探测在 iOS 交叉链接下失败,会误加 find_library('atomic')。这里去掉该探测。
      case "$TARGET" in ios-*) python3 -I -c "import sys,pathlib; p=pathlib.Path(sys.argv[1]); s=p.read_text(); p.write_text(s.replace(\"if not cc.links(atomic_test)\", \"if false\"))" "$WORK/libplacebo/src/meson.build" ;; esac
      meson setup "$WORK/libplacebo/build-$TARGET" "$WORK/libplacebo" --prefix="$PREFIX" --buildtype=release \
        --default-library=shared $DEPS_MESON_CROSS \
        -Dcpp_args="$DEPS_CFLAGS -I$WORK/fast_float/include" \
        -Dc_link_args="$DEPS_LDFLAGS $LINK_VULKAN" -Dcpp_link_args="$DEPS_LDFLAGS $LINK_VULKAN" \
        -Dvulkan=enabled -Dvk-proc-addr=disabled -Dopengl=enabled -Dgl-proc-addr=disabled -Dvulkan-registry="$VK_XML" -Dshaderc=enabled -Dglslang=disabled \
        -Dlcms=enabled -Ddovi=disabled -Dlibdovi=disabled -Dunwind=disabled -Dd3d11=disabled \
        -Ddemos=false -Dtests=false > "$WORK/libplacebo.log" 2>&1 || { tail -40 "$WORK/libplacebo.log" >&2; return 1; }
      ninja -C "$WORK/libplacebo/build-$TARGET" -j"$JOBS" >> "$WORK/libplacebo.log" 2>&1 \
        && ninja -C "$WORK/libplacebo/build-$TARGET" install >> "$WORK/libplacebo.log" 2>&1 || { tail -40 "$WORK/libplacebo.log" >&2; return 1; } ;;
    uchardet)
      # 动态库(LGPL-2.1+,选 LGPL 许可),独立 framework 的候选;这里只构建 dylib 版本
      extract uchardet-0.0.8.tar.xz uchardet
      rm -rf "$WORK/uchardet/build-$TARGET"
      cmake -S "$WORK/uchardet" -B "$WORK/uchardet/build-$TARGET" -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC=OFF \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT="$DEPS_SDK" $DEPS_CMAKE_SYSTEM \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPS_MIN_VERSION:-14.0}" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 > "$WORK/uchardet.log" 2>&1
      cmake --build "$WORK/uchardet/build-$TARGET" -j"$JOBS" >> "$WORK/uchardet.log" 2>&1
      cmake --install "$WORK/uchardet/build-$TARGET" >> "$WORK/uchardet.log" 2>&1 ;;
    *) echo "unknown dep: $name" >&2; return 1 ;;
  esac
  echo "[built] $name ($TARGET)"
}
if [ $# -eq 0 ]; then set -- freetype harfbuzz fribidi libunibreak lcms2 libass uchardet shaderc libplacebo; fi
for n in "$@"; do build_one "$n"; done
