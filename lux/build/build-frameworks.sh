#!/usr/bin/env bash
#
# lux/build/build-frameworks.sh — F1:把 F0 的 LGPL 最小构建做成动态 framework / xcframework
#
#   ./lux/build/build-frameworks.sh all            # 三个切片构建 + 打包 + xcframework + zip
#   ./lux/build/build-frameworks.sh macos-arm64    # 只构建 + 打包一个切片
#   ./lux/build/build-frameworks.sh ios-arm64
#   ./lux/build/build-frameworks.sh ios-sim-arm64
#   ./lux/build/build-frameworks.sh package        # 只用已有切片出 xcframework / zip / checksum
#   ./lux/build/build-frameworks.sh clean          # 删掉 lux/.build/frameworks 与 xcframeworks
#
# 约定(与 F0 相同):
#   * 源码树外构建:configure 在 lux/.build/frameworks/<target>/ 里跑;
#   * 所有产物、日志、临时文件只在 lux/.build/ 内(TMPDIR 被指到 lux/.build/tmp);
#   * configure 参数全部来自 lux/config/ffmpeg-ios.conf,本脚本只负责编排 + 打包。
#
# 为什么用 configure --enable-shared 而不是拿 F0 的 .a 重新 clang -dynamiclib:
#   FFmpeg 的 Makefile 里有一组 SHLIBOBJS,只在 --enable-shared 时编译
#   (例如 libavformat/mpegaudiotabs.o:libavformat/isom.o 引用 ff_mpa_freq_tab,
#   而该符号在 libavcodec 里是 hidden 的)。用静态 .a 链 dylib 时这些目标文件不存在,
#   ld64 会报 "fixup error (kind=arm64_adrp_lo12) ... does not have address"。
#   共享构建还自带 -exported_symbols_list(libav*.ver) 与版本号,少踩很多坑。
#
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LUX=$(cd "$HERE/.." && pwd)
REPO=$(cd "$LUX/.." && pwd)
BUILD_ROOT="$LUX/.build"
FRAMEWORK_ROOT="$BUILD_ROOT/frameworks"
DIST_ROOT="$BUILD_ROOT/xcframeworks"
LOGDIR="$BUILD_ROOT/logs"
GEN_HEADERS="$HERE/gen-framework-headers.py"

# shellcheck source=../config/ffmpeg-ios.conf
. "$LUX/config/ffmpeg-ios.conf"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
log()  { printf '[frameworks] %s\n' "$*"; }

mkdir -p "$BUILD_ROOT/tmp" "$LOGDIR"
export TMPDIR="$BUILD_ROOT/tmp"
export TMP="$TMPDIR"
export TEMP="$TMPDIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH"

mode=${1:-}
case "$mode" in
    all|macos-arm64|ios-arm64|ios-sim-arm64|package|clean) ;;
    *) die "usage: $0 <all|macos-arm64|ios-arm64|ios-sim-arm64|package|clean>" ;;
esac

if [ "$mode" = clean ]; then
    rm -rf "$FRAMEWORK_ROOT" "$DIST_ROOT"
    log "removed $FRAMEWORK_ROOT and $DIST_ROOT"
    exit 0
fi

# ---------------------------------------------------------------------------
# 平台元数据(Info.plist / vtool 对账共用)
# ---------------------------------------------------------------------------
platform_of_target() { # $1 = target -> Apple platform name (Info.plist)
    case "$1" in
        macos-arm64)    echo "MacOSX" ;;
        ios-arm64)      echo "iPhoneOS" ;;
        ios-sim-arm64)  echo "iPhoneSimulator" ;;
        *) return 1 ;;
    esac
}
min_os_of_target() {
    case "$1" in
        macos-arm64)    echo "14.0" ;;
        ios-arm64)      echo "17.0" ;;
        ios-sim-arm64)  echo "17.0" ;;
        *) return 1 ;;
    esac
}
sdk_of_target() {
    case "$1" in
        macos-arm64)    echo "macosx" ;;
        ios-arm64)      echo "iphoneos" ;;
        ios-sim-arm64)  echo "iphonesimulator" ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 构建一个目标的共享库(--enable-shared),再打包成 framework
# ---------------------------------------------------------------------------
build_target() {
    local target=$1
    local build="$FRAMEWORK_ROOT/$target"
    local install="$build/install"

    ff_framework_configure_opts "$target" "$install" || die "cannot resolve configure opts for '$target'"
    ff_target_setup "$target" || die "unknown target '$target'"

    # 与 build-ffmpeg.sh 相同的许可自检:参数里不能夹带 GPL/nonfree。
    local opt
    for opt in "${FF_OPTS[@]}"; do
        if printf '%s\n' "$opt" | grep -Eq -e "$LUX_FORBIDDEN_OPTS"; then
            die "forbidden configure option: $opt"
        fi
    done
    case " ${FF_OPTS[*]} " in
        *" --disable-gpl "*|*" --disable-nonfree "*) ;;
        *) die "--disable-gpl / --disable-nonfree missing from FF_OPTS" ;;
    esac

    if [ "${LUX_SKIP_FFMPEG_BUILD:-0}" = 1 ] && [ -f "$install/lib/libavformat.dylib" ]; then
        log "target=$target: reusing $install (LUX_SKIP_FFMPEG_BUILD=1)"
        package_target "$target"
        return 0
    fi

    log "target=$target sdk=$FF_SDK_NAME $FF_SDK_VERSION min=$FF_HOST_OS_LABEL"
    rm -rf "$build"
    mkdir -p "$build"
    cd "$build"
    printf '%s\n' "${FF_OPTS[@]}" > configure.opts.txt

    local start cfg_elapsed elapsed
    start=$(date +%s)
    if ! "$REPO/configure" "${FF_OPTS[@]}" > "$LOGDIR/$target-shared-configure.log" 2>&1; then
        tail -40 "$LOGDIR/$target-shared-configure.log" >&2
        die "configure failed (shared), see $LOGDIR/$target-shared-configure.log"
    fi
    cfg_elapsed=$(( $(date +%s) - start ))
    local license_line
    license_line=$(grep -m1 '^License:' "$LOGDIR/$target-shared-configure.log" || true)
    case "$license_line" in
        "License: LGPL"*) ;;
        *) die "unexpected license line: ${license_line:-<none>}" ;;
    esac

    local jobs
    jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    if ! make -j"$jobs" > "$LOGDIR/$target-shared-make.log" 2>&1; then
        tail -60 "$LOGDIR/$target-shared-make.log" >&2
        die "make failed (shared), see $LOGDIR/$target-shared-make.log"
    fi
    if ! make install >> "$LOGDIR/$target-shared-make.log" 2>&1; then
        tail -40 "$LOGDIR/$target-shared-make.log" >&2
        die "make install failed (shared), see $LOGDIR/$target-shared-make.log"
    fi
    elapsed=$(( $(date +%s) - start ))
    log "built $target in ${elapsed}s (configure ${cfg_elapsed}s), $license_line"

    {
        printf 'target=%s\n' "$target"
        printf 'sdk=%s %s\n' "$FF_SDK_NAME" "$FF_SDK_VERSION"
        printf 'min_os=%s\n' "$FF_HOST_OS_LABEL"
        printf 'configure_seconds=%s\n' "$cfg_elapsed"
        printf 'build_seconds=%s\n' "$elapsed"
        printf 'license=%s\n' "${license_line#License: }"
    } > "$build/BUILD-INFO.txt"

    package_target "$target"
}

# ---------------------------------------------------------------------------
# 打包一个目标切片:每个库一个 .framework
# ---------------------------------------------------------------------------
module_map_headers() { # $1 = framework, $2 = lib dir, $3 = target -> 打印 "header ..." 行
    local fw=$1 lib=$2 target=$3 h name skip
    while IFS= read -r h; do
        name=$(basename "$h")
        skip=no
        case "$fw" in
            Libavutil)
                case "$name" in
                    hwcontext_amf.h|hwcontext_cuda.h|hwcontext_d3d11va.h|hwcontext_d3d12va.h|hwcontext_dxva2.h|hwcontext_qsv.h|hwcontext_vaapi.h|hwcontext_vdpau.h|hwcontext_vulkan.h) skip=yes ;;
                    # iOS SDK 里没有 OpenCL/macOS 才有;放进模块会让整个模块编译失败
                    hwcontext_opencl.h) [ "$target" = macos-arm64 ] || skip=yes ;;
                esac
                ;;
            Libavcodec)
                case "$name" in
                    d3d11va.h|dxva2.h|qsv.h|vdpau.h) skip=yes ;;
                esac
                ;;
        esac
        [ "$skip" = yes ] && continue
        # framework 模块的 header 路径按包根解析(clang 还接受 ../Headers/...,两种都试过;
        # 用 ../Headers 是为了和 module map 所在目录(Modules/)保持显式相对关系)。
        printf '  header "../Headers/%s/%s"\n' "$lib" "$name"
    done < <(find "$WORK_HEADERS/$lib" -maxdepth 1 -type f -name '*.h' | sort)
}

bundle_id() { # $1 = framework
    printf '%s.%s\n' "$LUX_BUNDLE_ID_PREFIX" "$1"
}

# required-reason API:按 nm -u 的未定义符号判断,只声明二进制真的引用的类别。
emit_privacy_manifest() { # $1 = dylib, $2 = output plist
    local bin=$1 out=$2 syms categories="" reason_file="" reason_disk="" reason_boot=""
    syms=$(nm -u "$bin" 2>/dev/null | awk '{print $NF}')
    if printf '%s\n' "$syms" | grep -Eq '^_(stat|fstat|lstat|fstatat|getattrlist|fgetattrlist)(\$INODE64)?$'; then
        categories="$categories FileTimestamp"; reason_file="C617.1"
    fi
    if printf '%s\n' "$syms" | grep -Eq '^_(statfs|fstatfs|statvfs|fstatvfs|getattrlist|fgetattrlist)(\$INODE64)?$'; then
        categories="$categories DiskSpace"; reason_disk="E174.1"
    fi
    if printf '%s\n' "$syms" | grep -Eq '^_(mach_absolute_time|mach_continuous_time)$'; then
        categories="$categories SystemBootTime"; reason_boot="35F9.1"
    fi

    {
        cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
PLIST
        printf '    <key>NSPrivacyTracking</key>\n    <false/>\n'
        printf '    <key>NSPrivacyTrackingDomains</key>\n    <array/>\n'
        printf '    <key>NSPrivacyCollectedDataTypes</key>\n    <array/>\n'
        printf '    <key>NSPrivacyAccessedAPITypes</key>\n    <array>\n'
        if [ -n "$reason_file" ]; then
            printf '        <dict>\n'
            printf '            <key>NSPrivacyAccessedAPIType</key>\n            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>\n'
            printf '            <key>NSPrivacyAccessedAPITypeReasons</key>\n            <array><string>%s</string></array>\n' "$reason_file"
            printf '        </dict>\n'
        fi
        if [ -n "$reason_disk" ]; then
            printf '        <dict>\n'
            printf '            <key>NSPrivacyAccessedAPIType</key>\n            <string>NSPrivacyAccessedAPICategoryDiskSpace</string>\n'
            printf '            <key>NSPrivacyAccessedAPITypeReasons</key>\n            <array><string>%s</string></array>\n' "$reason_disk"
            printf '        </dict>\n'
        fi
        if [ -n "$reason_boot" ]; then
            printf '        <dict>\n'
            printf '            <key>NSPrivacyAccessedAPIType</key>\n            <string>NSPrivacyAccessedAPICategorySystemBootTime</string>\n'
            printf '            <key>NSPrivacyAccessedAPITypeReasons</key>\n            <array><string>%s</string></array>\n' "$reason_boot"
            printf '        </dict>\n'
        fi
        printf '    </array>\n</dict>\n</plist>\n'
    } > "$out"

    PRIVACY_CATEGORIES="${categories# }"
}

write_info_plist() { # $1 = target, $2 = framework, $3 = version, $4 = output
    local target=$1 fw=$2 version=$3 out=$4 platform minos sdk
    platform=$(platform_of_target "$target")
    minos=$(min_os_of_target "$target")
    sdk=$(sdk_of_target "$target")
    cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$fw</string>
    <key>CFBundleIdentifier</key>
    <string>$(bundle_id "$fw")</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$fw</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>$platform</string>
    </array>
    <key>MinimumOSVersion</key>
    <string>$minos</string>
    <key>DTPlatformName</key>
    <string>$sdk</string>
    <key>DTSDKName</key>
    <string>$sdk</string>
</dict>
</plist>
PLIST
}

package_target() {
    local target=$1
    local build="$FRAMEWORK_ROOT/$target"
    local install="$build/install"
    local slice="$build/slice"
    local fw lib dep old version dylib

    log "packaging $target slice"
    rm -rf "$slice"
    mkdir -p "$slice"
    : > "$build/PACKAGE-INFO.txt"

    for fw in $LUX_FRAMEWORKS; do
        lib=$(ff_lib_from_framework "$fw")
        dylib=$(find "$install/lib" -maxdepth 1 -name "$lib.[0-9]*.dylib" | sort | head -1)
        [ -n "$dylib" ] || die "missing $install/lib/$lib.<version>.dylib"
        version=$(ff_lib_version "$install" "$lib") || die "cannot read version for $lib"

        FR="$slice/$fw.framework"
        WORK_HEADERS="$FR/Headers"
        mkdir -p "$FR/Modules" "$WORK_HEADERS"

        # 1. binary + install name
        cp "$dylib" "$FR/$fw"
        chmod 755 "$FR/$fw"
        install_name_tool -id "@rpath/$fw.framework/$fw" "$FR/$fw"

        # 2. 依赖改成 @rpath/<Dep>.framework/<Dep>
        for dep in $(ff_framework_deps "$fw"); do
            local dep_lib
            dep_lib=$(ff_lib_from_framework "$dep")
            old=$(otool -L "$FR/$fw" | awk 'NR>1 {print $1}' | grep "/$dep_lib\." | head -1 || true)
            [ -n "$old" ] || die "$fw does not link against $dep ($dep_lib)"
            install_name_tool -change "$old" "@rpath/$dep.framework/$dep" "$FR/$fw"
        done

        # 3. 头文件 + framework 风格别名 + 精确 include 闭包(全部是文件级 symlink)
        local sibling_args=()
        for dep in $LUX_FRAMEWORKS; do
            [ "$dep" = "$fw" ] && continue
            sibling_args+=(--sibling "$dep:$(ff_lib_from_framework "$dep")")
        done
        python3 "$GEN_HEADERS" \
            --include "$install/include" \
            --framework-root "$FR" \
            --module "$fw" --lib "$lib" \
            "${sibling_args[@]}" > "$build/gen-headers-$fw.log"

        # 4. module map:只列 canonical 头(避免把 mesh 路径也收进模块造成重定义)
        {
            printf 'framework module %s [system] {\n' "$fw"
            module_map_headers "$fw" "$lib" "$target"
            printf '  export *\n'
            for dep in $(ff_framework_deps "$fw"); do
                printf '  use %s\n' "$dep"
            done
            # 系统框架:从 dylib 的 otool -L 里取,保证 link 声明与实际依赖一致
            otool -L "$FR/$fw" | awk 'NR>1 {print $1}' \
                | grep -E '^/System/Library/Frameworks/[^/]+\.framework/' \
                | sed -E 's|^/System/Library/Frameworks/([^/]+)\.framework/.*|\1|' \
                | sort -u | while IFS= read -r sysfw; do
                    printf '  link framework "%s"\n' "$sysfw"
                done
            printf '}\n'
        } > "$FR/Modules/module.modulemap"

        # 5. Info.plist / 隐私清单
        write_info_plist "$target" "$fw" "$version" "$FR/Info.plist"
        emit_privacy_manifest "$FR/$fw" "$FR/PrivacyInfo.xcprivacy"
        printf 'privacy.%s=%s\n' "$fw" "$PRIVACY_CATEGORIES" >> "$build/PACKAGE-INFO.txt"

        # 6. dSYM(必须在 strip 之前,且构建时带了 -g)
        dsymutil "$FR/$fw" -o "$slice/$fw.framework.dSYM" > "$build/dsymutil-$fw.log" 2>&1 \
            || die "dsymutil failed for $fw"
        strip -S "$FR/$fw"

        printf '%s %s %s\n' "$fw" "$version" "$(stat -f %z "$FR/$fw")"
    done

    # 7. ad-hoc 签名:必须等四个 framework 都打包完再签。
    #    跨 framework 的头文件镜像(Headers/libavcodec/... -> ../../Libavcodec.framework/...)会被
    #    codesign 当成 bundle 内容的一部分;先签的 framework 会在后一个 framework 出现头文件后
    #    被报 "file modified"。
    for fw in $LUX_FRAMEWORKS; do
        codesign --force --sign - --timestamp=none "$slice/$fw.framework" \
            > "$build/codesign-$fw.log" 2>&1 || die "codesign failed for $fw"
    done

    # 体积与耗时记录
    local total=0 size
    {
        printf 'target=%s\n' "$target"
        for fw in $LUX_FRAMEWORKS; do
            size=$(stat -f %z "$slice/$fw.framework/$fw")
            total=$(( total + size ))
            printf 'size.%s=%s\n' "$fw" "$size"
        done
        printf 'size.total=%s\n' "$total"
    } >> "$build/PACKAGE-INFO.txt"

    log "slice ready: $slice ($total bytes of binaries)"
}

# ---------------------------------------------------------------------------
# xcframework + zip + checksum
# ---------------------------------------------------------------------------
create_xcframeworks() {
    local fw target args out
    for target in $LUX_TARGETS; do
        [ -d "$FRAMEWORK_ROOT/$target/slice" ] || die "missing slice for $target (run build first)"
    done

    rm -rf "$DIST_ROOT"
    mkdir -p "$DIST_ROOT/dSYMs"
    for fw in $LUX_FRAMEWORKS; do
        args=()
        for target in $LUX_TARGETS; do
            args+=(-framework "$FRAMEWORK_ROOT/$target/slice/$fw.framework")
            mkdir -p "$DIST_ROOT/dSYMs/$target"
            cp -R "$FRAMEWORK_ROOT/$target/slice/$fw.framework.dSYM" "$DIST_ROOT/dSYMs/$target/"
        done
        out="$DIST_ROOT/$fw.xcframework"
        rm -rf "$out"
        log "xcodebuild -create-xcframework $fw"
        if ! xcodebuild -create-xcframework "${args[@]}" -output "$out" \
                > "$LOGDIR/xcframework-$fw.log" 2>&1; then
            tail -30 "$LOGDIR/xcframework-$fw.log" >&2
            die "xcodebuild -create-xcframework failed for $fw"
        fi
    done

    # zip(保留 symlink)+ checksum
    : > "$DIST_ROOT/checksums.txt"
    local zip
    for fw in $LUX_FRAMEWORKS; do
        zip="$DIST_ROOT/$fw.xcframework.zip"
        rm -f "$zip"
        ditto -c -k --sequesterRsrc --keepParent "$DIST_ROOT/$fw.xcframework" "$zip"
        checksum=$(swift package compute-checksum "$zip")
        printf '%s  %s\n' "$checksum" "$fw.xcframework.zip" >> "$DIST_ROOT/checksums.txt"
    done
    ( cd "$DIST_ROOT" && ditto -c -k --sequesterRsrc --keepParent dSYMs dSYMs.zip )
    cp "$DIST_ROOT/checksums.txt" "$DIST_ROOT/checksums.txt.tmp"
    log "xcframeworks in $DIST_ROOT"
    cat "$DIST_ROOT/checksums.txt"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
if [ "$mode" = all ]; then
    for target in $LUX_TARGETS; do
        build_target "$target"
    done
    create_xcframeworks
elif [ "$mode" = package ]; then
    create_xcframeworks
else
    build_target "$mode"
fi

log "ok — next: ./lux/build/verify-frameworks.sh"
