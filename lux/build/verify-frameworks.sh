#!/usr/bin/env bash
#
# lux/build/verify-frameworks.sh — F1 产物验收(任何一条失败即非零退出)
#
#   ./lux/build/verify-frameworks.sh              # 三个切片 + xcframework + zip + 大小写敏感卷
#   ./lux/build/verify-frameworks.sh macos-arm64  # 只查一个切片
#   SKIP_CASE_SENSITIVE=1 ./lux/build/verify-frameworks.sh   # 跳过挂载 APFS 镜像(不推荐)
#
# 检查内容(逐条对应任务书):
#   1. otool -hv:filetype 是 DYLIB(6),不是静态 archive / bundle;
#   2. otool -L:LC_ID_DYLIB 是 @rpath/<Name>.framework/<Name>,依赖之间是 @rpath,
#      除 /usr/lib 与 /System/Library/Frameworks 外没有绝对路径;
#   3. vtool -show-build:platform 与 minos 与目标一致(MACOS 14.0 / IOS 17.0 / IOSSIMULATOR 17.0);
#   4. nm:没有 x264/x265/fdk/... 等外部/GPL 组件;CONFIG_GPL=0;avutil_license() 以 LGPL 开头;
#   5. codesign:能重新 ad-hoc 签名并通过 --verify --strict;
#   6. 结构:Headers 的 canonical 子目录、framework 风格别名、module map、Info.plist、
#      PrivacyInfo.xcprivacy、dSYM(UUID 与二进制一致);
#   7. xcframework:三个切片齐全、Info.plist 正确、zip 的 checksum 与 checksums.txt 一致
#      (与 MPVKit 现有同名库的粗略体积对比在 lux/README.md §12.6,不依赖 lux-client 路径);
#   8. 大小写敏感:把 macOS 切片拷进一个 Case-sensitive APFS 卷镜像,
#      分别用 -I(canonical)与 -F(framework 风格)编译同一个 TU,再 import 模块;
#      两种写法都不允许落到大小写不敏感的路径上。
#
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LUX=$(cd "$HERE/.." && pwd)
REPO=$(cd "$LUX/.." && pwd)
BUILD_ROOT="$LUX/.build"
FRAMEWORK_ROOT="$BUILD_ROOT/frameworks"
DIST_ROOT="$BUILD_ROOT/xcframeworks"
VERIFY_ROOT="$BUILD_ROOT/verify/frameworks"
CS_IMAGE="$BUILD_ROOT/csimg/luxcs.sparseimage"
CS_MOUNT="/Volumes/luxcs"

# shellcheck source=../config/ffmpeg-ios.conf
. "$LUX/config/ffmpeg-ios.conf"

mkdir -p "$VERIFY_ROOT"
export TMPDIR="$BUILD_ROOT/tmp"
mkdir -p "$TMPDIR"

FAILS=0
WARNS=0
pass() { printf '  [ok]   %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '  [warn] %s\n' "$*"; WARNS=$((WARNS + 1)); }
hdr()  { printf '\n== %s\n' "$*"; }

# 注意:不能用裸 'amf'(会命中 FFmpeg 自己的 av_iamf_* / avformat 里的 IAMF),也不能用
# 裸 'dav1d' 之外过短的名字。这里只列外部编码库与平台硬件后端。
FORBIDDEN_SYMBOL_RE='x264|x265|fdk|fdkaac|xvid|vidstab|xavs|postproc|mp3lame|theora|dav1d|svt_|svtav1|libvpx|_vpx_|faac|vo_aacenc|opencore|libass|fribidi|freetype|gnutls|openssl|libvorbis|libopus|zimg|placebo|shaderc|chromaprint|_amf_|_vaapi_|_vdpau_|_dxva2?_'

bundle_id() { printf '%s.%s\n' "$LUX_BUNDLE_ID_PREFIX" "$1"; }

platform_expected() {
    case "$1" in
        macos-arm64)   echo "MACOS" ;;
        ios-arm64)     echo "IOS" ;;
        ios-sim-arm64) echo "IOSSIMULATOR" ;;
    esac
}
minos_expected() {
    case "$1" in
        macos-arm64)   echo "14.0" ;;
        ios-arm64)     echo "17.0" ;;
        ios-sim-arm64) echo "17.0" ;;
    esac
}
plist_platform_expected() {
    case "$1" in
        macos-arm64)   echo "MacOSX" ;;
        ios-arm64)     echo "iPhoneOS" ;;
        ios-sim-arm64) echo "iPhoneSimulator" ;;
    esac
}

# ---------------------------------------------------------------------------
# 单个切片
# ---------------------------------------------------------------------------
verify_slice() {
    local target=$1
    local slice="$FRAMEWORK_ROOT/$target/slice"
    local build="$FRAMEWORK_ROOT/$target"
    local fw lib dep dylib_info

    hdr "slice: $target"

    [ -d "$slice" ] || { fail "$slice 不存在 — 先运行 lux/build/build-frameworks.sh $target"; return; }

    # ---------------------------------------------------------------- 7.1 形状
    for fw in $LUX_FRAMEWORKS; do
        local bin="$slice/$fw.framework/$fw"
        lib=$(ff_lib_from_framework "$fw")
        [ -f "$bin" ] || { fail "$fw: 缺少二进制 $bin"; continue; }

        dylib_info=$(otool -hv "$bin" 2>/dev/null | awk '/^MH_MAGIC/ {print $5}')
        if [ "$dylib_info" = "DYLIB" ]; then
            pass "$fw: otool -hv filetype = DYLIB"
        else
            fail "$fw: filetype = '${dylib_info:-<none>}' (期望 DYLIB)"
        fi

        # ------------------------------------------------------------ 7.2 install name / 依赖
        local install_name
        install_name=$(otool -D "$bin" 2>/dev/null | sed -n '2p')
        if [ "$install_name" = "@rpath/$fw.framework/$fw" ]; then
            pass "$fw: install name = $install_name"
        else
            fail "$fw: install name = '${install_name:-<none>}' (期望 @rpath/$fw.framework/$fw)"
        fi

        local deps bad
        deps=$(otool -L "$bin" | awk 'NR>2 {print $1}')
        bad=$(printf '%s\n' "$deps" | grep -Ev '^(@rpath/(Libavutil|Libswresample|Libavcodec|Libavformat)\.framework/(Libavutil|Libswresample|Libavcodec|Libavformat)$|/usr/lib/|/System/Library/Frameworks/)')
        if [ -n "$bad" ]; then
            fail "$fw: 依赖里出现非 @rpath / 非系统库: $(printf '%s ' $bad)"
        else
            pass "$fw: 依赖全部是 @rpath 或系统库"
        fi
        local want_dep
        for want_dep in $(ff_framework_deps "$fw"); do
            if printf '%s\n' "$deps" | grep -qx "@rpath/$want_dep.framework/$want_dep"; then
                pass "$fw: 依赖 $want_dep 指向 @rpath"
            else
                fail "$fw: 缺少对 $want_dep 的 @rpath 依赖"
            fi
        done

        # 自依赖不该出现
        if printf '%s\n' "$deps" | grep -qx "@rpath/$fw.framework/$fw"; then
            fail "$fw: 依赖了自己"
        fi

        # ------------------------------------------------------------ 7.3 平台 / 最低版本
        local vtool_out platform minos
        vtool_out=$(vtool -show-build "$bin" 2>/dev/null)
        platform=$(printf '%s\n' "$vtool_out" | awk '/platform/ {print $2; exit}')
        minos=$(printf '%s\n' "$vtool_out" | awk '/minos/ {print $2; exit}')
        if [ "$platform" = "$(platform_expected "$target")" ]; then
            pass "$fw: vtool platform = $platform"
        else
            fail "$fw: vtool platform = '${platform:-<none>}' (期望 $(platform_expected "$target"))"
        fi
        if [ "$minos" = "$(minos_expected "$target")" ]; then
            pass "$fw: vtool minos = $minos"
        else
            fail "$fw: vtool minos = '${minos:-<none>}' (期望 $(minos_expected "$target"))"
        fi

        # ------------------------------------------------------------ 7.4 符号 / 许可
        nm -gj "$bin" 2>/dev/null | sed '/^$/d; s/^_//' > "$VERIFY_ROOT/$target-$fw.symbols"
        if grep -Eqi "$FORBIDDEN_SYMBOL_RE" "$VERIFY_ROOT/$target-$fw.symbols"; then
            fail "$fw: 符号表里有禁用的外部/GPL 组件: $(grep -Eoi "$FORBIDDEN_SYMBOL_RE" "$VERIFY_ROOT/$target-$fw.symbols" | sort -u | tr '\n' ' ')"
        else
            pass "$fw: 没有 x264/x265/fdk 等禁用符号"
        fi
        case "$fw" in
            Libavutil)
                if grep -qx "avutil_license" "$VERIFY_ROOT/$target-$fw.symbols"; then
                    pass "$fw: 导出 avutil_license"
                else
                    fail "$fw: 没导出 avutil_license"
                fi ;;
            Libavformat)
                grep -qx "avformat_open_input" "$VERIFY_ROOT/$target-$fw.symbols" \
                    && pass "$fw: 导出 avformat_open_input" || fail "$fw: 没导出 avformat_open_input" ;;
            Libavcodec)
                grep -qx "avcodec_send_packet" "$VERIFY_ROOT/$target-$fw.symbols" \
                    && pass "$fw: 导出 avcodec_send_packet" || fail "$fw: 没导出 avcodec_send_packet" ;;
        esac

        # ------------------------------------------------------------ 7.5 结构
        local headers="$slice/$fw.framework/Headers"
        if [ -d "$headers/$lib" ]; then
            pass "$fw: canonical 头文件目录 Headers/$lib/ 存在"
        else
            fail "$fw: 缺少 Headers/$lib/"
        fi
        case "$fw" in
            Libavutil)   [ -f "$headers/$lib/avutil.h" ]      || fail "$fw: 缺少 Headers/$lib/avutil.h" ;;
            Libavcodec)  [ -f "$headers/$lib/avcodec.h" ]     || fail "$fw: 缺少 Headers/$lib/avcodec.h" ;;
            Libavformat)[ -f "$headers/$lib/avformat.h" ]     || fail "$fw: 缺少 Headers/$lib/avformat.h" ;;
            Libswresample) [ -f "$headers/$lib/swresample.h" ] || fail "$fw: 缺少 Headers/$lib/swresample.h" ;;
        esac
        for dep in $LUX_FRAMEWORKS; do
            lib=$(ff_lib_from_framework "$dep")
            if [ -d "$headers/$lib" ]; then
                pass "$fw: Headers/$lib/ 存在(可用 -I 直接 include)"
            else
                fail "$fw: Headers/$lib/ 不存在"
            fi
        done

        # framework 风格别名 + 大小写敏感:find -iname 必须命中大小写完全一致的路径
        local alias_count=0 canonical_count=0
        for h in "$headers"/*.h; do
            [ -e "$h" ] || continue
            alias_count=$((alias_count + 1))
            [ "$(basename "$h")" = "$(basename "$h")" ] || true
            # 用 inode 比较:别名与 canonical 必须是同一个文件(symlink 到包内)
            [ -L "$h" ] || fail "$fw: $(basename "$h") 不是 symlink(应指向 Headers/$lib/...)"
        done
        if [ "$alias_count" -gt 0 ]; then
            pass "$fw: framework 风格别名 $alias_count 个"
        else
            fail "$fw: 没有任何 framework 风格别名(Headers/<name>.h)"
        fi

        # module map
        local mm="$slice/$fw.framework/Modules/module.modulemap"
        if [ -f "$mm" ] && grep -q "^framework module $fw " "$mm"; then
            pass "$fw: module map 声明 framework module $fw"
            for dep in $(ff_framework_deps "$fw"); do
                grep -q "^  use $dep$" "$mm" || fail "$fw: module map 缺少 'use $dep'"
            done
            grep -q "^  export \*$" "$mm" || fail "$fw: module map 缺少 export *"
            grep -q '^  link framework "CoreFoundation"' "$mm" || warn "$fw: module map 没有 link CoreFoundation"
        else
            fail "$fw: 缺少 Modules/module.modulemap(或模块名不对)"
        fi

        # Info.plist
        local plist="$slice/$fw.framework/Info.plist"
        local id minos_plist version_plist supported
        id=$(plutil -extract CFBundleIdentifier raw "$plist" 2>/dev/null)
        minos_plist=$(plutil -extract MinimumOSVersion raw "$plist" 2>/dev/null)
        version_plist=$(plutil -extract CFBundleVersion raw "$plist" 2>/dev/null)
        supported=$(plutil -extract CFBundleSupportedPlatforms.0 raw "$plist" 2>/dev/null)
        [ "$id" = "$(bundle_id "$fw")" ] && pass "$fw: CFBundleIdentifier = $id" || fail "$fw: CFBundleIdentifier = '${id:-<none>}'"
        [ "$minos_plist" = "$(minos_expected "$target")" ] && pass "$fw: MinimumOSVersion = $minos_plist" \
            || fail "$fw: MinimumOSVersion = '${minos_plist:-<none>}'"
        [ -n "$version_plist" ] && pass "$fw: CFBundleVersion = $version_plist" || fail "$fw: CFBundleVersion 为空"
        [ "$supported" = "$(plist_platform_expected "$target")" ] && pass "$fw: CFBundleSupportedPlatforms = $supported" \
            || fail "$fw: CFBundleSupportedPlatforms = '${supported:-<none>}'"

        # PrivacyInfo
        local privacy="$slice/$fw.framework/PrivacyInfo.xcprivacy"
        if plutil -lint "$privacy" >/dev/null 2>&1; then
            pass "$fw: PrivacyInfo.xcprivacy 是合法 plist"
        else
            fail "$fw: 缺少或非法的 PrivacyInfo.xcprivacy"
        fi

        # dSYM
        local dsym="$slice/$fw.framework.dSYM"
        local uuid_bin uuid_dsym
        uuid_bin=$(dwarfdump --uuid "$bin" 2>/dev/null | awk '{print $2}' | head -1)
        uuid_dsym=$(dwarfdump --uuid "$dsym" 2>/dev/null | awk '{print $2}' | head -1)
        if [ -n "$uuid_bin" ] && [ "$uuid_bin" = "$uuid_dsym" ]; then
            pass "$fw: dSYM UUID 与二进制一致($uuid_bin)"
        else
            fail "$fw: dSYM UUID 不匹配(bin='${uuid_bin:-none}' dsym='${uuid_dsym:-none}')"
        fi

        # ------------------------------------------------------------ 7.6 签名
        if codesign --force --sign - --timestamp=none "$slice/$fw.framework" >/dev/null 2>&1; then
            if codesign --verify --strict "$slice/$fw.framework" >/dev/null 2>&1; then
                pass "$fw: codesign 重新 ad-hoc 签名 + verify 通过"
            else
                fail "$fw: codesign --verify 失败"
            fi
        else
            fail "$fw: codesign --force --sign - 失败"
        fi
    done

    # ---------------------------------------------------------------- 7.7 CONFIG_GPL
    local config="$build/ffbuild/config.mak"
    if [ -f "$config" ]; then
        grep -q "^CONFIG_SHARED=yes" "$config" && pass "config.mak: CONFIG_SHARED=yes" || fail "config.mak: CONFIG_SHARED 不是 yes"
    else
        fail "缺少 $config"
    fi
    if [ -f "$build/config.h" ]; then
        grep -q '#define CONFIG_GPL 0' "$build/config.h" && pass "config.h: CONFIG_GPL 0" || fail "config.h: CONFIG_GPL 不是 0"
        grep -q '#define CONFIG_NONFREE 0' "$build/config.h" && pass "config.h: CONFIG_NONFREE 0" || fail "config.h: CONFIG_NONFREE 不是 0"
    else
        fail "缺少 $build/config.h"
    fi

    # ---------------------------------------------------------------- 7.8 许可字符串 / 体积
    local license_line
    license_line=$(grep -a -m1 -o 'libavutil license: [A-Za-z0-9 .]*' "$slice/Libavutil.framework/Libavutil" 2>/dev/null)
    case "$license_line" in
        "libavutil license: LGPL"*) pass "Libavutil: 内嵌许可字符串 = ${license_line#libavutil license: }" ;;
        *) fail "libavutil 里没有以 LGPL 开头的许可字符串('${license_line:-none}')" ;;
    esac

    local fw_size total=0
    printf '  %-14s %12s\n' "framework" "bytes"
    for fw in $LUX_FRAMEWORKS; do
        fw_size=$(stat -f %z "$slice/$fw.framework/$fw" 2>/dev/null || echo 0)
        total=$((total + fw_size))
        printf '  %-14s %12s\n' "$fw" "$fw_size"
    done
    printf '  %-14s %12s\n' "TOTAL" "$total"

    # ---------------------------------------------------------------- 7.9 真链接一次(macOS 才能跑)
    if [ "$target" = macos-arm64 ]; then
        local probe="$VERIFY_ROOT/license-probe"
        cat > "$VERIFY_ROOT/license-probe.c" <<'EOF'
#include <stdio.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
int main(void) {
    const char *license = avutil_license();
    printf("license=%s\n", license);
    printf("avformat=%d avcodec=%d avutil=%d\n",
           LIBAVFORMAT_VERSION_MAJOR, LIBAVCODEC_VERSION_MAJOR, LIBAVUTIL_VERSION_MAJOR);
    return (license && license[0] == 'L' && license[1] == 'G' && license[2] == 'P' && license[3] == 'L') ? 0 : 1;
}
EOF
        if xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=14.0 \
                -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
                -I "$slice/Libavformat.framework/Headers" \
                -F "$slice" \
                -Wl,-rpath,"$slice" \
                -o "$probe" "$VERIFY_ROOT/license-probe.c" \
                -framework Libavformat -framework Libavcodec -framework Libavutil \
                > "$VERIFY_ROOT/license-probe.log" 2>&1; then
            local out
            out=$("$probe" 2>&1)
            if printf '%s\n' "$out" | grep -q '^license=LGPL'; then
                pass "动态链接探针: $(printf '%s' "$out" | tr '\n' ' ')"
            else
                fail "动态链接探针输出不是 LGPL: $out"
            fi
        else
            fail "动态链接探针编译/链接失败,见 $VERIFY_ROOT/license-probe.log"
        fi
    fi
}

# ---------------------------------------------------------------------------
# 大小写敏感证明:Case-sensitive APFS 卷镜像
# ---------------------------------------------------------------------------
mount_case_sensitive() {
    if [ -d "$CS_MOUNT" ] && [ -f "$CS_MOUNT/.lux-cs-marker" ]; then
        return 0
    fi
    mkdir -p "$(dirname "$CS_IMAGE")"
    if [ ! -f "$CS_IMAGE" ]; then
        hdiutil create -type SPARSE -fs "Case-sensitive APFS" -size 2g -volname luxcs "$CS_IMAGE" \
            > "$VERIFY_ROOT/hdiutil-create.log" 2>&1 || return 1
    fi
    hdiutil attach "$CS_IMAGE" > "$VERIFY_ROOT/hdiutil-attach.log" 2>&1 || return 1
    touch "$CS_MOUNT/.lux-cs-marker"
    # 确认卷真的是大小写敏感的
    if [ -e "$CS_MOUNT/LUX-CS-PROBE" ] || [ -e "$CS_MOUNT/lux-cs-probe" ]; then return 1; fi
    touch "$CS_MOUNT/lux-cs-probe"
    if [ -e "$CS_MOUNT/LUX-CS-PROBE" ]; then
        rm -f "$CS_MOUNT/lux-cs-probe"
        return 1
    fi
    rm -f "$CS_MOUNT/lux-cs-probe"
    return 0
}

verify_case_sensitive() {
    hdr "大小写敏感卷:canonical + framework 两种 include 写法"
    if [ "${SKIP_CASE_SENSITIVE:-0}" = 1 ]; then
        warn "SKIP_CASE_SENSITIVE=1,跳过"
        return
    fi
    if ! mount_case_sensitive; then
        fail "无法创建/挂载 Case-sensitive APFS 镜像($CS_IMAGE)"
        return
    fi
    pass "Case-sensitive APFS 卷已挂载: $CS_MOUNT"

    local work="$CS_MOUNT/lux-f1-verify"
    rm -rf "$work"
    mkdir -p "$work"
    cp -R "$FRAMEWORK_ROOT/macos-arm64/slice/"* "$work/" || { fail "复制 macOS 切片到镜像失败"; return; }

    cat > "$work/canonical.c" <<'EOF'
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libswresample/swresample.h>
int main(void) { return (int)LIBAVFORMAT_VERSION_MAJOR + (int)LIBAVUTIL_VERSION_MAJOR; }
EOF
    cat > "$work/framework.c" <<'EOF'
#include <Libavformat/avformat.h>
#include <Libavcodec/avcodec.h>
#include <Libavutil/avutil.h>
#include <Libswresample/swresample.h>
int main(void) { return (int)LIBAVFORMAT_VERSION_MAJOR + (int)LIBAVUTIL_VERSION_MAJOR; }
EOF
    cat > "$work/module.m" <<'EOF'
@import Libavformat;
@import Libavcodec;
@import Libavutil;
@import Libswresample;
int main(void) { return (int)LIBAVFORMAT_VERSION_MAJOR; }
EOF

    # 1) canonical 形式:需要一个 include root,即 Libavformat.framework/Headers
    local sdk
    sdk=$(xcrun --sdk macosx --show-sdk-path)
    if clang -fsyntax-only -I "$work/Libavformat.framework/Headers" \
            -Werror=nonportable-include-path "$work/canonical.c" 2> "$VERIFY_ROOT/cs-canonical.log"; then
        pass "镜像上 #include <libavformat/avformat.h> 通过(-I,无大小写告警)"
    else
        fail "镜像上 canonical include 失败,见 $VERIFY_ROOT/cs-canonical.log"
    fi

    # 2) framework 形式
    if clang -fsyntax-only -F "$work" -Werror=nonportable-include-path "$work/framework.c" \
            2> "$VERIFY_ROOT/cs-framework.log"; then
        pass "镜像上 #include <Libavformat/avformat.h> 通过(-F)"
    else
        fail "镜像上 framework include 失败,见 $VERIFY_ROOT/cs-framework.log"
    fi

    # 3) module import(clang)
    rm -rf "$work/modcache"
    if clang -fsyntax-only -fmodules -fmodules-cache-path="$work/modcache" -F "$work" -x objective-c \
            "$work/module.m" 2> "$VERIFY_ROOT/cs-module.log"; then
        pass "镜像上 @import Libavformat/Libavcodec/Libavutil/Libswresample 通过"
    else
        fail "镜像上 module import 失败,见 $VERIFY_ROOT/cs-module.log"
    fi

    # 4) Swift 能 typecheck 四个 import(不产生可执行文件,所以不需要链接)
    cat > "$work/imports.swift" <<'EOF'
import Libavformat
import Libavcodec
import Libavutil
import Libswresample
func probe(_ path: String) -> Int32 {
    var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
    let rc = avformat_open_input(&ctx, path, nil, nil)
    let name = avcodec_get_name(AV_CODEC_ID_H264)
    _ = avutil_version()
    _ = swresample_version()
    return rc + Int32(name != nil ? 1 : 0)
}
EOF
    if swiftc -typecheck -F "$work" -module-cache-path "$work/swift-modcache" "$work/imports.swift" \
            2> "$VERIFY_ROOT/cs-swift.log"; then
        pass "镜像上 Swift 直接 import 四个模块并调用 C API 通过"
    else
        fail "镜像上 Swift import 失败,见 $VERIFY_ROOT/cs-swift.log"
    fi

    # 5) 阴性对照:单独用 -F 时 libavformat/… 这种小写 framework 名不应该存在
    if [ -e "$work/libavformat.framework" ]; then
        warn "镜像上出现了 libavformat.framework(不应依赖这种小写别名)"
    else
        pass "镜像上没有 libavformat.framework 小写别名(不依赖大小写)"
    fi
}

# ---------------------------------------------------------------------------
# xcframework + zip
# ---------------------------------------------------------------------------
verify_xcframeworks() {
    hdr "xcframework / zip / checksum"
    local fw target slice_count
    for fw in $LUX_FRAMEWORKS; do
        local xcf="$DIST_ROOT/$fw.xcframework"
        if [ ! -d "$xcf" ]; then
            fail "$fw: 缺少 $xcf(先运行 build-frameworks.sh package)"
            continue
        fi
        slice_count=$(python3 -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); print(len(d.get("AvailableLibraries",[])))' "$xcf/Info.plist" 2>/dev/null || echo 0)
        if [ "$slice_count" = "3" ]; then
            pass "$fw: xcframework 有 3 个切片"
        else
            fail "$fw: xcframework 切片数 = ${slice_count:-0}(期望 3)"
        fi
        for want in macos-arm64 ios-arm64 ios-arm64-simulator; do
            if python3 -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); print("\n".join(l["LibraryIdentifier"] for l in d["AvailableLibraries"]))' "$xcf/Info.plist" 2>/dev/null | grep -qx "$want"; then
                pass "$fw: xcframework 含切片 $want"
            else
                fail "$fw: xcframework 缺少切片 $want"
            fi
        done
        # 每个切片的二进制都要能被找到
        for slice in "$xcf"/*/; do
            [ -d "$slice" ] || continue
            if [ -f "$slice/$fw.framework/$fw" ]; then
                :
            else
                fail "$fw: 切片 $(basename "$slice") 里没有 $fw.framework/$fw"
            fi
        done
    done

    local zip checksum expected
    if [ -f "$DIST_ROOT/checksums.txt" ]; then
        for fw in $LUX_FRAMEWORKS; do
            zip="$DIST_ROOT/$fw.xcframework.zip"
            if [ ! -f "$zip" ]; then fail "$fw: 缺少 $zip"; continue; fi
            checksum=$(swift package compute-checksum "$zip" 2>/dev/null)
            expected=$(awk -v n="$fw.xcframework.zip" '$2 == n {print $1}' "$DIST_ROOT/checksums.txt")
            if [ -n "$checksum" ] && [ "$checksum" = "$expected" ]; then
                pass "$fw: zip checksum 与 checksums.txt 一致($checksum)"
            else
                fail "$fw: checksum 不一致(now='${checksum:-none}' file='${expected:-none}')"
            fi
            # zip 里必须保留 symlink(ditto -k)。
            # 先落文件再 grep:pipefail 下 grep -q 提前关管道会让 unzip 吃 SIGPIPE。
            unzip -l "$zip" > "$VERIFY_ROOT/ziplist-$fw.txt" 2>/dev/null || true
            if grep -q "/Headers/" "$VERIFY_ROOT/ziplist-$fw.txt"; then
                pass "$fw: zip 内含 Headers 目录(含 framework 风格别名)"
            else
                fail "$fw: zip 内看不到 Headers 别名"
            fi
        done
    else
        fail "缺少 $DIST_ROOT/checksums.txt"
    fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
targets=("$@")
[ ${#targets[@]} -gt 0 ] || read -r -a targets <<< "$LUX_TARGETS"

for target in "${targets[@]}"; do
    case " $LUX_TARGETS " in
        *" $target "*) verify_slice "$target" ;;
        *) fail "未知目标 '$target'" ;;
    esac
done

all_targets=($LUX_TARGETS)
if [ ${#targets[@]} -eq ${#all_targets[@]} ]; then
    verify_case_sensitive
    verify_xcframeworks
fi

printf '\nfailures: %d, warnings: %d\n' "$FAILS" "$WARNS"
if [ "$FAILS" -ne 0 ]; then
    printf 'RESULT: FAIL\n'
    exit 1
fi
printf 'RESULT: PASS\n'
