#!/usr/bin/env bash
# 打包 B+ 的两个共享 Vulkan framework:
#   LibMoltenVK.framework  <- deps/<target>/install/lib/libMoltenVK.dylib
#   Libshaderc.framework   <- deps/<target>/install/lib/libshaderc.dylib
#
# 用法:
#   ./lux/build/build-vulkan-frameworks.sh <macos-arm64|ios-arm64|ios-sim-arm64>
#   ./lux/build/build-vulkan-frameworks.sh all
#   ./lux/build/build-vulkan-frameworks.sh package
#   ./lux/build/build-vulkan-frameworks.sh verify [target|all]
#   ./lux/build/build-vulkan-frameworks.sh clean
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LUX="$REPO/lux"
BUILD_ROOT="$LUX/.build"
ROOT="$BUILD_ROOT/vulkan-frameworks"
XCF_ROOT="$BUILD_ROOT/vulkan-xcframeworks"
LOGDIR="$BUILD_ROOT/logs"
FRAMEWORKS="LibMoltenVK Libshaderc"
TARGETS="macos-arm64 ios-arm64 ios-sim-arm64"

die() { printf 'build-vulkan-frameworks: %s\n' "$*" >&2; exit 1; }
log() { printf '[vulkan-frameworks] %s\n' "$*"; }
mkdir -p "$LOGDIR"

platform_of() { # Info.plist 的 CFBundleSupportedPlatforms
    case "$1" in
        macos-arm64) echo MacOSX ;;
        ios-arm64) echo iPhoneOS ;;
        ios-sim-arm64) echo iPhoneSimulator ;;
        *) return 1 ;;
    esac
}
vtool_platform_of() { # vtool -show-build 的 platform
    case "$1" in
        macos-arm64) echo MACOS ;;
        ios-arm64) echo IOS ;;
        ios-sim-arm64) echo IOSSIMULATOR ;;
        *) return 1 ;;
    esac
}
minos_of() {
    case "$1" in
        macos-arm64) echo 14.0 ;;
        ios-arm64|ios-sim-arm64) echo 17.0 ;;
        *) return 1 ;;
    esac
}
sdk_of() {
    case "$1" in
        macos-arm64) echo macosx ;;
        ios-arm64) echo iphoneos ;;
        ios-sim-arm64) echo iphonesimulator ;;
        *) return 1 ;;
    esac
}
version_of() { # $1 framework
    case "$1" in
        LibMoltenVK) echo 1.4.2 ;;
        Libshaderc) echo 2025.5 ;;
        *) return 1 ;;
    esac
}

write_info_plist() { # $1 target $2 framework $3 out
    local target=$1 fw=$2 out=$3 platform minos sdk ver
    platform=$(platform_of "$target"); minos=$(minos_of "$target"); sdk=$(sdk_of "$target"); ver=$(version_of "$fw")
    cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$fw</string>
    <key>CFBundleIdentifier</key><string>dev.lux.ffmpeg.$fw</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$fw</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$ver</string>
    <key>CFBundleVersion</key><string>$ver</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
    <key>MinimumOSVersion</key><string>$minos</string>
    <key>DTPlatformName</key><string>$sdk</string>
    <key>DTSDKName</key><string>$sdk</string>
</dict>
</plist>
PLIST
}

emit_privacy() { # $1 binary $2 output
    local bin=$1 out=$2 syms cats="" file="" disk="" boot=""
    syms=$(nm -u "$bin" 2>/dev/null | awk '{print $NF}')
    printf '%s\n' "$syms" | grep -Eq '^_(stat|fstat|lstat|fstatat|getattrlist|fgetattrlist)(\$INODE64)?$' && file="C617.1"
    printf '%s\n' "$syms" | grep -Eq '^_(statfs|fstatfs|statvfs|fstatvfs|getattrlist|fgetattrlist)(\$INODE64)?$' && disk="E174.1"
    printf '%s\n' "$syms" | grep -Eq '^_(mach_absolute_time|mach_continuous_time)$' && boot="35F9.1"
    {
        cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key><false/>
    <key>NSPrivacyTrackingDomains</key><array/>
    <key>NSPrivacyCollectedDataTypes</key><array/>
    <key>NSPrivacyAccessedAPITypes</key><array>
PLIST
        if [ -n "$file" ]; then
            printf '        <dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryFileTimestamp</string><key>NSPrivacyAccessedAPITypeReasons</key><array><string>%s</string></array></dict>\n' "$file"
        fi
        if [ -n "$disk" ]; then
            printf '        <dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryDiskSpace</string><key>NSPrivacyAccessedAPITypeReasons</key><array><string>%s</string></array></dict>\n' "$disk"
        fi
        if [ -n "$boot" ]; then
            printf '        <dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategorySystemBootTime</string><key>NSPrivacyAccessedAPITypeReasons</key><array><string>%s</string></array></dict>\n' "$boot"
        fi
        printf '    </array>\n</dict>\n</plist>\n'
    } > "$out"
}

package_target() { # $1 target
    local target=$1 prefix="$BUILD_ROOT/deps/$1/install" slice="$ROOT/$1/slice"
    local fw src fr ver log="$LOGDIR/vulkan-frameworks-$1.log"
    [ -d "$prefix/lib" ] || die "缺少依赖前缀: $prefix"
    rm -rf "$ROOT/$1"; mkdir -p "$slice"
    : > "$log"
    for fw in $FRAMEWORKS; do
        case "$fw" in
            LibMoltenVK) src="$prefix/lib/libMoltenVK.dylib" ;;
            Libshaderc)  src="$prefix/lib/libshaderc.dylib" ;;
        esac
        [ -f "$src" ] || die "缺少 $src — 先跑 build-moltenvk.sh / build-deps.sh shaderc"
        fr="$slice/$fw.framework"
        mkdir -p "$fr/Headers"
        cp "$src" "$fr/$fw"; chmod 755 "$fr/$fw"
        install_name_tool -id "@rpath/$fw.framework/$fw" "$fr/$fw"
        case "$fw" in
            LibMoltenVK)
                # 运行期由 FFmpeg dlopen,不需要给客户端 import;Vulkan-Headers 的
                # C++ 头有 20MB+,不随 framework 分发(保留空 Headers 以符合结构检查)。
                mkdir -p "$fr/Headers" ;;
            Libshaderc)
                mkdir -p "$fr/Headers/shaderc"
                cp -R "$prefix/include/shaderc/." "$fr/Headers/shaderc/" ;;
        esac
        write_info_plist "$target" "$fw" "$fr/Info.plist"
        emit_privacy "$fr/$fw" "$fr/PrivacyInfo.xcprivacy"
        dsymutil "$fr/$fw" -o "$slice/$fw.framework.dSYM" >> "$log" 2>&1 \
            || die "dsymutil failed for $fw ($target)"
        # dSYM 已经落盘,出货二进制 strip -x(保留导出符号;实测 shaderc/vk 仍可用)。
        strip -x "$fr/$fw" >> "$log" 2>&1 || true
        codesign --force --sign - --timestamp=none "$fr" >> "$log" 2>&1 \
            || die "codesign failed for $fw ($target)"
        printf '%s %s\n' "$fw" "$(otool -D "$fr/$fw" | tail -1)" >> "$ROOT/$1/BUILD-INFO.txt"
    done
    log "packaged $target -> $slice"
}

verify_target() { # $1 target
    local target=$1 slice="$ROOT/$1/slice" fw fr platform minos want_platform want_minos deps bad
    want_platform=$(vtool_platform_of "$target"); want_minos=$(minos_of "$target")
    for fw in $FRAMEWORKS; do
        fr="$slice/$fw.framework"
        [ -f "$fr/$fw" ] || die "缺少 $fr/$fw(先 package $target)"
        [ "$(otool -D "$fr/$fw" | tail -1)" = "@rpath/$fw.framework/$fw" ] \
            || die "$fw: install name 不是 @rpath/$fw.framework/$fw"
        platform=$(xcrun vtool -show-build "$fr/$fw" 2>/dev/null | awk '/platform /{print $2; exit}')
        minos=$(xcrun vtool -show-build "$fr/$fw" 2>/dev/null | awk '/minos /{print $2; exit}')
        [ "$platform" = "$want_platform" ] || die "$fw: platform $platform != $want_platform"
        [ "$minos" = "$want_minos" ] || die "$fw: minos $minos != $want_minos"
        deps=$(otool -L "$fr/$fw" | awk 'NR>2 {print $1}')
        bad=$(printf '%s\n' "$deps" | grep -Ev '^(@rpath/|/usr/lib/|/System/Library/Frameworks/|/System/Library/PrivateFrameworks/)' || true)
        [ -z "$bad" ] || die "$fw: 非系统/非 @rpath 依赖: $bad"
        codesign --verify --strict "$fr" >/dev/null 2>&1 || die "$fw: codesign --verify --strict 失败"
        plutil -lint "$fr/Info.plist" >/dev/null || die "$fw: Info.plist 无效"
    done
    log "verify $target PASS"
}

create_xcframeworks() {
    local fw target args out zip checksum
    for fw in $FRAMEWORKS; do
        for target in $TARGETS; do
            [ -d "$ROOT/$target/slice/$fw.framework" ] || die "缺少 $target/$fw(先跑 all)"
        done
    done
    rm -rf "$XCF_ROOT"; mkdir -p "$XCF_ROOT/dSYMs"
    for fw in $FRAMEWORKS; do
        args=()
        for target in $TARGETS; do
            args+=(-framework "$ROOT/$target/slice/$fw.framework")
            mkdir -p "$XCF_ROOT/dSYMs/$target"
            cp -R "$ROOT/$target/slice/$fw.framework.dSYM" "$XCF_ROOT/dSYMs/$target/" 2>/dev/null || true
        done
        out="$XCF_ROOT/$fw.xcframework"
        xcodebuild -create-xcframework "${args[@]}" -output "$out" \
            > "$LOGDIR/vulkan-xcframework-$fw.log" 2>&1 \
            || { tail -30 "$LOGDIR/vulkan-xcframework-$fw.log" >&2; die "create-xcframework failed for $fw"; }
        zip="$XCF_ROOT/$fw.xcframework.zip"; rm -f "$zip"
        ditto -c -k --sequesterRsrc --keepParent "$out" "$zip"
        checksum=$(swift package compute-checksum "$zip")
        printf '%s  %s\n' "$checksum" "$fw.xcframework.zip" >> "$XCF_ROOT/checksums.txt"
    done
    ( cd "$XCF_ROOT" && ditto -c -k --sequesterRsrc --keepParent dSYMs dSYMs.zip )
    log "xcframeworks -> $XCF_ROOT"
    cat "$XCF_ROOT/checksums.txt"
}

mode=${1:-}
case "$mode" in
    all)
        for t in $TARGETS; do package_target "$t"; verify_target "$t"; done
        create_xcframeworks ;;
    package) create_xcframeworks ;;
    verify)
        t=${2:-all}
        if [ "$t" = all ]; then for x in $TARGETS; do verify_target "$x"; done; else verify_target "$t"; fi ;;
    clean) rm -rf "$ROOT" "$XCF_ROOT"; log "removed $ROOT and $XCF_ROOT" ;;
    macos-arm64|ios-arm64|ios-sim-arm64)
        package_target "$mode"; verify_target "$mode" ;;
    *) die "用法: $0 <macos-arm64|ios-arm64|ios-sim-arm64|all|package|verify|clean>" ;;
esac
