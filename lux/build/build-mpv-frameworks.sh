#!/usr/bin/env bash
#
# lux/build/build-mpv-frameworks.sh — P2 第2/3步:把动态 libmpv 及其非系统依赖打包成 framework
#
#   ./lux/build/build-mpv-frameworks.sh macos-arm64     # 打包 + 自检
#   ./lux/build/build-mpv-frameworks.sh ios-arm64       # 同上(iOS device 切片)
#   ./lux/build/build-mpv-frameworks.sh ios-sim-arm64   # 同上(iOS simulator 切片)
#   ./lux/build/build-mpv-frameworks.sh verify [target] # 只复检已有产物(不改文件);target=all 时逐个查
#   ./lux/build/build-mpv-frameworks.sh clean           # 删掉 lux/.build/mpv-frameworks
#
# 输入(已有产物,不重建;缺失时才调用 build-mpv.sh <target>):
#   lux/.build/deps/<target>/install/lib/libmpv.<ver>.dylib
#   lux/.build/deps/<target>/install/lib/libplacebo.<ver>.dylib
#   lux/.build/deps/<target>/install/lib/libfribidi.<ver>.dylib
#   lux/.build/deps/<target>/install/lib/libuchardet.<ver>.dylib
#
# 输出:
#   lux/.build/mpv-frameworks/<target>/Libmpv.framework
#   lux/.build/mpv-frameworks/<target>/Libplacebo.framework
#   lux/.build/mpv-frameworks/<target>/Libfribidi.framework
#   lux/.build/mpv-frameworks/<target>/Libuchardet.framework
#
# 规则:
#   * 四个 framework 的 LC_ID_DYLIB 都是 @rpath/<Name>.framework/<Name>;
#   * Libav*.framework 依赖是 F1 已改好的 @rpath 形式,原样保留;
#   * /usr/lib 与 /System 下的系统库原样保留;
#   * 其它任何依赖都必须是 @rpath/<Name>.framework/<Name>,否则脚本失败。
#
# 目标:macos-arm64 / ios-arm64 / ios-sim-arm64。三个切片的规则完全相同,只有
# 依赖前缀、Info.plist 平台字段与最低系统版本按目标切换:
#   * MinimumOSVersion 与 F1 的切片一致(macos 14.0 / iOS 17.0,见 lux/config/ffmpeg-ios.conf);
#   * iOS device 为 iPhoneOS/iphoneos,simulator 为 iPhoneSimulator/iphonesimulator。
#
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LUX=$(cd "$HERE/.." && pwd)
BUILD_ROOT="$LUX/.build"
OUT_ROOT="$BUILD_ROOT/mpv-frameworks"
LOGDIR="$BUILD_ROOT/logs"

TARGETS="macos-arm64 ios-arm64 ios-sim-arm64"

MPV_FRAMEWORKS="Libmpv Libplacebo Libfribidi Libuchardet"
BUNDLE_ID_PREFIX="${LUX_MPV_BUNDLE_ID_PREFIX:-dev.lux.mpv}"

# 目标相关变量。TARGET/DEPS_INSTALL/LIBDIR/INCDIR/SLICE/MIN_OS/PLIST_*/BUILD_PLATFORM
# 全部由 set_target 设置,避免在函数里散落 target 判断。
set_target() {
    case "$1" in
        macos-arm64)
            MIN_OS="14.0"
            PLIST_PLATFORM="MacOSX"
            PLIST_SDK="macosx"
            BUILD_PLATFORM="MACOS"
            ;;
        ios-arm64)
            MIN_OS="17.0"
            PLIST_PLATFORM="iPhoneOS"
            PLIST_SDK="iphoneos"
            BUILD_PLATFORM="IOS"
            ;;
        ios-sim-arm64)
            MIN_OS="17.0"
            PLIST_PLATFORM="iPhoneSimulator"
            PLIST_SDK="iphonesimulator"
            BUILD_PLATFORM="IOSSIMULATOR"
            ;;
        *)
            return 1
            ;;
    esac
    TARGET="$1"
    DEPS_INSTALL="$BUILD_ROOT/deps/$TARGET/install"
    LIBDIR="$DEPS_INSTALL/lib"
    INCDIR="$DEPS_INSTALL/include"
    SLICE="$OUT_ROOT/$TARGET"
    return 0
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '[mpv-frameworks] %s\n' "$*"; }
hdr() { printf '\n== %s\n' "$*"; }
pass() { printf '  [ok]   %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }

usage() {
    die "usage: $0 <macos-arm64|ios-arm64|ios-sim-arm64|verify [target|all]|clean>"
}

fw_stem() { # framework -> dylib 名字前缀(不含版本与 .dylib)
    case "$1" in
        Libmpv)      echo libmpv ;;
        Libplacebo)  echo libplacebo ;;
        Libfribidi)  echo libfribidi ;;
        Libuchardet) echo libuchardet ;;
        *) return 1 ;;
    esac
}

dylib_for() { # $1 = stem -> 路径;优先真实文件,避免 libuchardet.0.dylib 这类符号链接
    local stem=$1 f
    f=$(find "$LIBDIR" -maxdepth 1 -type f -name "$stem.[0-9]*.dylib" | sort | head -1)
    [ -n "$f" ] || f=$(find "$LIBDIR" -maxdepth 1 -name "$stem.[0-9]*.dylib" | sort | head -1)
    [ -n "$f" ] || return 1
    printf '%s\n' "$f"
}

dylib_version() { # $1 = dylib -> "current version" (CFBundleVersion)
    local v
    v=$(otool -L "$1" | sed -n '2p' | sed -E 's/.*current version ([0-9]+(\.[0-9]+)*).*/\1/')
    case "$v" in
        [0-9]*) printf '%s\n' "$v" ;;
        *) printf '1.0\n' ;;
    esac
}

framework_dep_ok() { # $1 = dependency -> 0 表示 @rpath/<known>.framework/<known>
    local dep=$1 rest name leaf
    case "$dep" in
        @rpath/*.framework/*) ;;
        *) return 1 ;;
    esac
    rest=${dep#@rpath/}
    name=${rest%%.framework/*}
    leaf=${rest#*.framework/}
    [ "$name" = "$leaf" ] || return 1
    case " Libavutil Libswresample Libavcodec Libswscale Libavfilter Libavformat Libmpv Libplacebo Libfribidi Libuchardet " in
        *" $name "*) return 0 ;;
        *) return 1 ;;
    esac
}

copy_headers() { # $1 = framework, $2 = framework dir
    local fw=$1 fr=$2
    case "$fw" in
        Libmpv)
            cp -R "$INCDIR/mpv" "$fr/Headers/"
            ;;
        Libplacebo)
            cp -R "$INCDIR/libplacebo" "$fr/Headers/"
            ;;
        Libfribidi)
            cp "$INCDIR/fribidi/"*.h "$fr/Headers/"
            ;;
        Libuchardet)
            cp -R "$INCDIR/uchardet" "$fr/Headers/uchardet"
            ;;
        *) die "no header rule for $fw" ;;
    esac
}

write_module_map() { # $1 = framework, $2 = framework dir
    local fw=$1 fr=$2
    case "$fw" in
        Libmpv)
            cat > "$fr/Modules/module.modulemap" <<'MAP'
framework module Libmpv [system] {
  header "mpv/client.h"
  header "mpv/render.h"
  header "mpv/render_gl.h"
  header "mpv/stream_cb.h"
  export *
}
MAP
            ;;
        Libplacebo|Libfribidi)
            # 这两个库的头文件不适合做 Clang framework module:
            #   * libplacebo 用 <libplacebo/...> 自引用,framework 的 -F 搜索不会把
            #     Libplacebo.framework/Headers 加进 include path;
            #   * fribidi 的 fribidi-bidi-types.h 在 enum 里 include 一个用宏生成的
            #     列表,clang module 下宏状态与普通 -I 编译不同,会报 expected identifier。
            # 保留 Headers 供 -I 使用,不生成 module map。
            ;;
        Libuchardet)
            cat > "$fr/Modules/module.modulemap" <<'MAP'
framework module Libuchardet [system] {
  header "uchardet/uchardet.h"
  export *
}
MAP
            ;;
        *) die "no module map rule for $fw" ;;
    esac
    # 没有 module map 的 framework 不保留空的 Modules/ 目录。
    [ -f "$fr/Modules/module.modulemap" ] || rmdir "$fr/Modules" 2>/dev/null || true
}

write_info_plist() { # $1 = framework, $2 = version, $3 = output
    local fw=$1 version=$2 out=$3
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
    <string>$BUNDLE_ID_PREFIX.$fw</string>
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
        <string>$PLIST_PLATFORM</string>
    </array>
    <key>MinimumOSVersion</key>
    <string>$MIN_OS</string>
    <key>DTPlatformName</key>
    <string>$PLIST_SDK</string>
    <key>DTSDKName</key>
    <string>$PLIST_SDK</string>
</dict>
</plist>
PLIST
}

rewrite_deps() { # $1 = framework, $2 = binary
    local fw=$1 bin=$2 dep base target
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        case "$dep" in
            /usr/lib/*|/System/*) continue ;;
            @rpath/Libavutil.framework/Libavutil|@rpath/Libswresample.framework/Libswresample|@rpath/Libavcodec.framework/Libavcodec|@rpath/Libswscale.framework/Libswscale|@rpath/Libavfilter.framework/Libavfilter|@rpath/Libavformat.framework/Libavformat) continue ;;
            @rpath/Libmpv.framework/Libmpv|@rpath/Libplacebo.framework/Libplacebo|@rpath/Libfribidi.framework/Libfribidi|@rpath/Libuchardet.framework/Libuchardet) continue ;;
        esac
        base=${dep##*/}
        case "$base" in
            libmpv|libmpv.*)           target=Libmpv ;;
            libplacebo|libplacebo.*)   target=Libplacebo ;;
            libfribidi|libfribidi.*)   target=Libfribidi ;;
            libuchardet|libuchardet.*) target=Libuchardet ;;
            *) die "$fw: 不允许的非系统依赖: $dep" ;;
        esac
        log "$fw: $dep"
        log "  -> @rpath/$target.framework/$target"
        install_name_tool -change "$dep" "@rpath/$target.framework/$target" "$bin"
    done < <(otool -L "$bin" | awk 'NR>2 {print $1}')
}

dump_linkage() { # $1 = output file
    local fw fr out=$1
    {
        for fw in $MPV_FRAMEWORKS; do
            fr="$SLICE/$fw.framework"
            printf '===== %s =====\n' "$fw"
            printf -- '-- LC_ID_DYLIB --\n'
            otool -D "$fr/$fw" 2>/dev/null || true
            printf -- '-- LC_LOAD_DYLIB --\n'
            otool -L "$fr/$fw" 2>/dev/null || true
        done
    } > "$out"
    cat "$out"
}

package_slice() {
    local fw dylib version fr

    [ -d "$LIBDIR" ] || die "缺少依赖目录: $LIBDIR(先准备 lux/.build/deps 符号链接)"

    # libmpv 缺失才重建;已有产物直接复用。
    if ! dylib_for libmpv >/dev/null; then
        log "libmpv 产物缺失,调用 build-mpv.sh $TARGET"
        "$LUX/build/build-mpv.sh" "$TARGET"
    fi

    mkdir -p "$LOGDIR"
    rm -rf "$SLICE"
    mkdir -p "$SLICE"

    for fw in $MPV_FRAMEWORKS; do
        dylib=$(dylib_for "$(fw_stem "$fw")") || die "缺少 $(fw_stem "$fw").<ver>.dylib in $LIBDIR"
        version=$(dylib_version "$dylib")
        fr="$SLICE/$fw.framework"
        log "package $fw <- $dylib (version $version)"
        mkdir -p "$fr/Headers" "$fr/Modules"
        cp "$dylib" "$fr/$fw"
        chmod 755 "$fr/$fw"
        install_name_tool -id "@rpath/$fw.framework/$fw" "$fr/$fw"
        copy_headers "$fw" "$fr"
        write_module_map "$fw" "$fr"
        write_info_plist "$fw" "$version" "$fr/Info.plist"
    done

    for fw in $MPV_FRAMEWORKS; do
        rewrite_deps "$fw" "$SLICE/$fw.framework/$fw"
    done

    for fw in $MPV_FRAMEWORKS; do
        fr="$SLICE/$fw.framework"
        codesign --force --sign - --timestamp=none "$fr" \
            > "$LOGDIR/p2-2-codesign-$TARGET-$fw.log" 2>&1 || die "codesign failed for $fw"
    done

    {
        printf 'target=%s\n' "$TARGET"
        printf 'built_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'source_libmpv=%s\n' "$(dylib_for libmpv)"
        for fw in $MPV_FRAMEWORKS; do
            printf 'framework.%s=%s\n' "$fw" "$(dylib_version "$SLICE/$fw.framework/$fw")"
        done
    } > "$SLICE/BUILD-INFO.txt"

    log "frameworks in $SLICE"
}

verify_slice() {
    local fw fr bin dep id deps bad vtool_out platform minos ass_count hits plist_platform plist_minos
    FAILS=0

    hdr "verify: $SLICE"
    [ -d "$SLICE" ] || { fail "$SLICE 不存在 — 先运行 $0 $TARGET"; return 1; }

    for fw in $MPV_FRAMEWORKS; do
        fr="$SLICE/$fw.framework"
        bin="$fr/$fw"
        hdr "$fw"

        if [ ! -f "$bin" ]; then
            fail "$fw: 缺少二进制 $bin"
            continue
        fi

        id=$(otool -D "$bin" 2>/dev/null | sed -n '2p')
        if [ "$id" = "@rpath/$fw.framework/$fw" ]; then
            pass "install name = $id"
        else
            fail "install name = '${id:-<none>}' (期望 @rpath/$fw.framework/$fw)"
        fi

        # 依赖:系统库或已知的 @rpath framework;其余一律失败。
        deps=$(otool -L "$bin" | awk 'NR>2 {print $1}')
        bad=""
        while IFS= read -r dep; do
            [ -n "$dep" ] || continue
            case "$dep" in
                /usr/lib/*|/System/*) continue ;;
            esac
            if framework_dep_ok "$dep"; then
                continue
            fi
            bad="$bad $dep"
        done <<< "$deps"
        if [ -n "$bad" ]; then
            fail "非 @rpath/非系统依赖:$bad"
        else
            pass "依赖全部是 @rpath/<Name>.framework/<Name> 或系统库"
        fi

        # 绝对路径残留检查:直接看 load commands,避免 strings 里的调试路径误报。
        hits=$(otool -l "$bin" | grep -F "$DEPS_INSTALL" || true)
        if [ -n "$hits" ]; then
            fail "load command 里残留主检出绝对路径: $(printf '%s ' $hits)"
        else
            pass "无主检出绝对路径残留 ($DEPS_INSTALL)"
        fi

        vtool_out=$(vtool -show-build "$bin" 2>/dev/null)
        platform=$(printf '%s\n' "$vtool_out" | awk '/platform/ {print $2; exit}')
        minos=$(printf '%s\n' "$vtool_out" | awk '/minos/ {print $2; exit}')
        if [ "$platform" = "$BUILD_PLATFORM" ] && [ "$minos" = "$MIN_OS" ]; then
            pass "platform=$platform minos=$minos"
        else
            fail "platform=$platform minos=$minos (期望 $BUILD_PLATFORM $MIN_OS)"
        fi

        if [ -f "$fr/Info.plist" ] && plutil -lint "$fr/Info.plist" >/dev/null 2>&1; then
            pass "Info.plist 可解析"
            plist_platform=$(plutil -extract CFBundleSupportedPlatforms.0 raw -o - "$fr/Info.plist" 2>/dev/null || true)
            plist_minos=$(plutil -extract MinimumOSVersion raw -o - "$fr/Info.plist" 2>/dev/null || true)
            if [ "$plist_platform" = "$PLIST_PLATFORM" ] && [ "$plist_minos" = "$MIN_OS" ]; then
                pass "Info.plist CFBundleSupportedPlatforms=$plist_platform MinimumOSVersion=$plist_minos"
            else
                fail "Info.plist 平台 '${plist_platform:-<none>}' / MinimumOSVersion '${plist_minos:-<none>}' (期望 $PLIST_PLATFORM / $MIN_OS)"
            fi
        else
            fail "Info.plist 缺失或不可解析"
        fi

        if codesign --verify --strict "$fr" >/dev/null 2>&1; then
            pass "codesign --verify --strict"
        else
            fail "codesign --verify --strict"
        fi

        if [ "$fw" = Libmpv ]; then
            ass_count=$(nm -gU "$bin" 2>/dev/null | awk '{print $NF}' | grep -c '^_ass_' || true)
            if [ "${ass_count:-0}" -gt 0 ]; then
                pass "导出 ass_* 符号 $ass_count 个"
            else
                fail "没有导出 ass_* 符号(libass 未静态并入?)"
            fi

            for dep in Libavutil Libswresample Libavcodec Libswscale Libavfilter Libavformat Libplacebo Libfribidi Libuchardet; do
                if printf '%s\n' "$deps" | grep -qx "@rpath/$dep.framework/$dep"; then
                    pass "依赖 $dep -> @rpath/$dep.framework/$dep"
                else
                    fail "缺少依赖 @rpath/$dep.framework/$dep"
                fi
            done
        fi
    done

    hdr "result"
    if [ "$FAILS" -eq 0 ]; then
        printf '  PASS (0 failures)\n'
        return 0
    fi
    printf '  FAIL (%d failures)\n' "$FAILS"
    return 1
}

main() {
    # 外层为了取 PIPESTATUS 用了 set +e;这里必须恢复,否则 cp/install_name_tool
    # 的失败会被 tee 吞掉,脚本会带着半成品“通过”。
    set -euo pipefail
    local mode=${1:-macos-arm64} verify_target=${2:-macos-arm64} fw before after rc t
    case "$mode" in
        macos-arm64|ios-arm64|ios-sim-arm64|verify|clean) ;;
        *) usage ;;
    esac

    mkdir -p "$LOGDIR"

    if [ "$mode" = clean ]; then
        rm -rf "$OUT_ROOT"
        log "removed $OUT_ROOT"
        return 0
    fi

    if [ "$mode" = verify ]; then
        # verify 默认只查 macos-arm64(与第2步一致);verify all 逐个查已有切片。
        if [ "$verify_target" = all ]; then
            rc=0
            for t in $TARGETS; do
                if [ ! -d "$OUT_ROOT/$t" ]; then
                    log "skip $t(没有产物)"
                    continue
                fi
                set_target "$t" || die "unknown target: $t"
                verify_slice || rc=1
            done
            return $rc
        fi
        set_target "$verify_target" || usage
        verify_slice
        return $?
    fi

    set_target "$mode" || usage
    [ -d "$LIBDIR" ] || die "缺少依赖目录: $LIBDIR"

    before="$LOGDIR/p2-2-install-names-$TARGET-before.log"
    after="$LOGDIR/p2-2-install-names-$TARGET-after.log"

    hdr "before: source dylibs"
    {
        for fw in $MPV_FRAMEWORKS; do
            printf '===== %s =====\n' "$fw"
            otool -D "$(dylib_for "$(fw_stem "$fw")")"
            otool -L "$(dylib_for "$(fw_stem "$fw")")"
        done
    } | tee "$before"

    package_slice

    hdr "after: frameworks"
    dump_linkage "$after"

    verify_slice
}

# 所有输出同时进日志;main 在管道里跑,所以显式取 PIPESTATUS[0] 作为退出码。
stamp=$(date '+%Y%m%d-%H%M%S')
case "${1:-macos-arm64}" in
    verify) logfile="$LOGDIR/p2-2-verify-${2:-macos-arm64}-$stamp.log" ;;
    clean)  logfile="$LOGDIR/p2-2-clean-$stamp.log" ;;
    *)      logfile="$LOGDIR/p2-2-package-${1:-macos-arm64}-$stamp.log" ;;
esac
mkdir -p "$LOGDIR"

set +e
main "$@" 2>&1 | tee "$logfile"
status=${PIPESTATUS[0]}
set -e

printf '\n[mpv-frameworks] log: %s\n' "$logfile" | tee -a "$logfile"
exit "$status"
