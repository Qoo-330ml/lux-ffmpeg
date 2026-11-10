#!/usr/bin/env bash
#
# lux/build/build-mpv-frameworks.sh — P2 第2/3步 + P2-4:把动态 libmpv 及其非系统依赖打包成
# framework,并给每个 framework 生成隐私清单与 dSYM 归档
#
#   ./lux/build/build-mpv-frameworks.sh macos-arm64     # 打包 + 自检
#   ./lux/build/build-mpv-frameworks.sh ios-arm64       # 同上(iOS device 切片)
#   ./lux/build/build-mpv-frameworks.sh ios-sim-arm64   # 同上(iOS simulator 切片)
#   ./lux/build/build-mpv-frameworks.sh xcframework     # 三切片 -> lux/.build/mpv-xcframeworks/
#   ./lux/build/build-mpv-frameworks.sh verify [target] # 只复检已有产物(不改文件);target=all 时逐个查
#   ./lux/build/build-mpv-frameworks.sh clean           # 删掉 lux/.build/mpv-frameworks 与 mpv-xcframeworks
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
#   lux/.build/mpv-frameworks/<target>/dSYMs/<Name>.framework.dSYM(每个 framework 一个)
#   lux/.build/mpv-frameworks/<target>/dSYMs.zip              (上面整目录的压缩包)
#   lux/.build/mpv-frameworks/<target>/P2-4-INFO.txt          (隐私扫描与 dSYM UUID 记录)
#   lux/.build/mpv-xcframeworks/<Name>.xcframework            (xcframework 子命令,三切片)
#   lux/.build/mpv-xcframeworks/<Name>.xcframework.zip
#   lux/.build/mpv-xcframeworks/checksums.txt                 (swift package compute-checksum)
#   lux/.build/mpv-xcframeworks/dSYMs/<target>/... + dSYMs.zip
#
# 隐私清单(P2-4,方法沿用 lux-client docs/PRIVACY.md):对每个 framework 的二进制跑
# `nm -u`,只把扫描命中的 required-reason API 类别写进该 framework 的 PrivacyInfo.xcprivacy;
# 扫不到的类别不声明(空的 NSPrivacyAccessedAPITypes 数组也算合法清单)。
#
# dSYM(P2-4):dsymutil 只能搬运二进制里已有的调试信息。P2 出口起 build-deps.sh 与
# build-mpv.sh 都以 -g 构建(release 优化不变),所以下面四个 dSYM 都应带 DWARF。
# 若输入又退回无 -g 的构建,dSYM 里就只剩 UUID:脚本会打 [warn] 并记进 P2-4-INFO.txt
# (dwarf=no);设置 LUX_MPV_DSYM_REQUIRE_DWARF=1 可把这种退化变成硬失败。
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
XCF_ROOT="$BUILD_ROOT/mpv-xcframeworks"
LOGDIR="$BUILD_ROOT/logs"

TARGETS="macos-arm64 ios-arm64 ios-sim-arm64"

MPV_FRAMEWORKS="Libmpv Libplacebo Libfribidi Libuchardet"
BUNDLE_ID_PREFIX="${LUX_MPV_BUNDLE_ID_PREFIX:-dev.lux.mpv}"

# bash 3.2(macOS 自带的 /bin/bash)里 ${v:+$'\n'} 不可靠,换行统一走这个变量。
NL=$'\n'

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
# warn 只提示,不计入 FAILS:用于「产物本身正确、但上游输入有局限」的情况(如 dSYM 无 DWARF)。
warn() { printf '  [warn] %s\n' "$*"; }

usage() {
    die "usage: $0 <macos-arm64|ios-arm64|ios-sim-arm64|xcframework|verify [target|all]|clean>"
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

# ---------------------------------------------------------------------------
# P2-4:隐私清单(required-reason API)与 dSYM 归档
# ---------------------------------------------------------------------------
# 声明内容只能来自扫描:对二进制跑 `nm -u` 取未定义符号,命中哪一类就只声明哪一类。
# 理由码取 Apple「required reason API」文档里与本项目实际用法相符的那条:
#   FileTimestamp  C617.1  —— 只访问 App 容器内的文件(mpv 的缓存/临时文件)
#   DiskSpace      E174.1  —— 写缓存前只读查询可用空间
#   SystemBootTime 35F9.1  —— 用 mach 单调时钟算播放时钟/音视频同步,不跨启动关联
#   UserDefaults   CA92.1  —— 只读写本 App 自己的偏好(本轮扫描未命中,留作兜底)
# 当前四个库的扫描结果见 lux/.build/logs/p2-4-privacy-<target>.log。
REASON_SYMS_FILETIME='^_(stat|fstat|lstat|fstatat|getattrlist|fgetattrlist|getattrlistbulk)(\$INODE64)?$'
REASON_SYMS_DISK='^_(statfs|fstatfs|statvfs|fstatvfs|getattrlist|fgetattrlist|getattrlistbulk)(\$INODE64)?$'
REASON_SYMS_BOOT='^_(mach_absolute_time|mach_continuous_time)$'
REASON_SYMS_DEFAULTS='^(_NSUserDefaults|_OBJC_CLASS_\$_NSUserDefaults)$'

symbol_hits() { # $1 = 符号列表(换行分隔), $2 = 正则 -> 命中的符号(空格分隔)
    # 用 { grep ... || true; } 而不是整条管道加 || true:只吞掉「没有匹配」(grep 退出 1),
    # 否则 set -o pipefail 会把「未命中」当成命令失败,函数在 set -e 下直接终止脚本。
    printf '%s\n' "$1" | { grep -E "$2" || true; } | sort -u | tr '\n' ' ' | sed -e 's/[[:space:]]*$//'
}

scan_reason_apis() { # $1 = 二进制 -> REASON_CATEGORIES(空格分隔) / REASON_HITS(每行一个类别)
    local bin=$1 syms cats="" hits="" m
    syms=$(nm -u "$bin" 2>/dev/null | awk '{print $NF}')

    m=$(symbol_hits "$syms" "$REASON_SYMS_FILETIME")
    if [ -n "$m" ]; then
        cats="$cats FileTimestamp"
        hits="$hits${hits:+$NL}FileTimestamp: $m"
    fi
    m=$(symbol_hits "$syms" "$REASON_SYMS_DISK")
    if [ -n "$m" ]; then
        cats="$cats DiskSpace"
        hits="$hits${hits:+$NL}DiskSpace: $m"
    fi
    m=$(symbol_hits "$syms" "$REASON_SYMS_BOOT")
    if [ -n "$m" ]; then
        cats="$cats SystemBootTime"
        hits="$hits${hits:+$NL}SystemBootTime: $m"
    fi
    m=$(symbol_hits "$syms" "$REASON_SYMS_DEFAULTS")
    if [ -n "$m" ]; then
        cats="$cats UserDefaults"
        hits="$hits${hits:+$NL}UserDefaults: $m"
    fi

    REASON_CATEGORIES=${cats# }
    REASON_HITS=$hits
    return 0
}

reason_code() { # $1 = 类别 -> 理由码
    case "$1" in
        FileTimestamp)  echo C617.1 ;;
        DiskSpace)      echo E174.1 ;;
        SystemBootTime) echo 35F9.1 ;;
        UserDefaults)   echo CA92.1 ;;
        *) return 1 ;;
    esac
}

emit_privacy_manifest() { # $1 = framework, $2 = 二进制, $3 = 输出 plist
    local fw=$1 bin=$2 out=$3 cat reason
    scan_reason_apis "$bin"

    {
        cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
PLIST
        for cat in $REASON_CATEGORIES; do
            reason=$(reason_code "$cat") || die "未知的 required-reason 类别: $cat"
            cat <<ENTRY
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategory$cat</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>$reason</string>
            </array>
        </dict>
ENTRY
        done
        cat <<'PLIST'
    </array>
</dict>
</plist>
PLIST
    } > "$out"

    # 原始证据:每个命中的符号都写进日志(与 lux-client PRIVACY.md 的扫描命令同一口径)。
    {
        printf '## %s %s\n' "$TARGET" "$fw"
        printf '# cmd: nm -u %s | awk {print $NF} | grep -E <required-reason>\n' "$bin"
        if [ -n "$REASON_CATEGORIES" ]; then
            printf '%s\n' "$REASON_HITS"
        else
            printf '(no required-reason API hits)\n'
        fi
        printf 'categories=%s\n\n' "${REASON_CATEGORIES:-<none>}"
    } >> "$LOGDIR/p2-4-privacy-$TARGET.log"

    # 每个 framework 的声明结果写进切片内的记录文件,便于离线复核。
    printf 'privacy.%s=%s\n' "$fw" "${REASON_CATEGORIES:-<none>}" >> "$SLICE/P2-4-INFO.txt"
}

archive_dsym() { # $1 = framework, $2 = 二进制
    local fw=$1 bin=$2 out="$SLICE/dSYMs/$1.framework.dSYM" log="$LOGDIR/p2-4-dsym-$TARGET.log"
    local uuid_bin uuid_dsym dwarf
    mkdir -p "$SLICE/dSYMs"
    rm -rf "$out"
    if ! dsymutil "$bin" -o "$out" >> "$log" 2>&1; then
        tail -5 "$log" >&2
        die "dsymutil failed for $fw"
    fi

    uuid_bin=$(dwarfdump --uuid "$bin" 2>/dev/null | awk '{print $2}' | head -1)
    uuid_dsym=$(dwarfdump --uuid "$out" 2>/dev/null | awk '{print $2}' | head -1)
    if [ -z "$uuid_bin" ] || [ "$uuid_bin" != "$uuid_dsym" ]; then
        die "$fw: dSYM UUID 与二进制不一致(bin='${uuid_bin:-none}' dsym='${uuid_dsym:-none}')"
    fi

    # dSYM 里有没有真正的 DWARF,取决于输入二进制是否带调试信息(dsymutil 只能搬运,不能凭空生成)。
    # 用 grep -c 而不是 grep -q:dwarfdump 的输出很长,grep -q 命中就退出会让上游吃 SIGPIPE,
    # 在 set -o pipefail 下整条管道返回 141,DWARF 明明存在也会被判成 no。
    dwarf_tags=$(dwarfdump --debug-info "$out" 2>/dev/null | { grep -c 'DW_TAG' || true; })
    if [ "${dwarf_tags:-0}" -gt 0 ]; then
        dwarf=yes
    else
        dwarf=no
    fi
    printf '%s %s dwarf=%s tags=%s\n' "$fw" "$uuid_dsym" "$dwarf" "${dwarf_tags:-0}" >> "$log"
    printf 'dsym.%s=uuid=%s dwarf=%s\n' "$fw" "$uuid_dsym" "$dwarf" >> "$SLICE/P2-4-INFO.txt"

    if [ "$dwarf" = no ]; then
        warn "$fw: dSYM 只有 UUID,没有 DWARF(输入二进制未带 -g,见 P2-4-INFO.txt)"
        if [ "${LUX_MPV_DSYM_REQUIRE_DWARF:-0}" = 1 ]; then
            die "$fw: dSYM 不含 DWARF,而 LUX_MPV_DSYM_REQUIRE_DWARF=1"
        fi
    fi
}

zip_dsyms() {
    local out="$SLICE/dSYMs.zip" log="$LOGDIR/p2-4-archive-$TARGET.log" n
    rm -f "$out"
    if ! ( cd "$SLICE" && ditto -c -k --sequesterRsrc --keepParent dSYMs "$out" ) >> "$log" 2>&1; then
        tail -5 "$log" >&2
        die "dSYMs.zip 打包失败"
    fi
    n=$(unzip -l "$out" 2>/dev/null | grep -c '\.dSYM/Contents/Info\.plist$' || true)
    [ "${n:-0}" -eq 4 ] || die "dSYMs.zip 里只有 $n 个 dSYM(期望 4)"
    printf 'zip=%s bytes=%s dsyms=%s\n' "$out" "$(stat -f %z "$out")" "$n" >> "$log"
    printf 'dsyms.zip.bytes=%s\n' "$(stat -f %z "$out")" >> "$SLICE/P2-4-INFO.txt"
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

    # P2-4 的日志每跑一个 target 重写一次:里面有本次扫描的原始符号与 dSYM UUID。
    : > "$LOGDIR/p2-4-privacy-$TARGET.log"
    : > "$LOGDIR/p2-4-dsym-$TARGET.log"
    : > "$LOGDIR/p2-4-archive-$TARGET.log"
    {
        printf 'target=%s\n' "$TARGET"
        printf 'built_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '# required-reason API 扫描: nm -u;dSYM: dsymutil,dwarf=yes/no 表示是否含调试信息\n'
    } > "$SLICE/P2-4-INFO.txt"

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
        # 隐私清单必须写在 codesign 之前,否则不在签名封存的 bundle 内容里。
        emit_privacy_manifest "$fw" "$fr/$fw" "$fr/PrivacyInfo.xcprivacy"
    done

    for fw in $MPV_FRAMEWORKS; do
        rewrite_deps "$fw" "$SLICE/$fw.framework/$fw"
    done

    # dSYM 从「依赖已改写完」的最终二进制抽,保证 UUID 与出货二进制一致。
    # 必须在 codesign 之前:签名会往文件末尾追加 LC_CODE_SIGNATURE。
    for fw in $MPV_FRAMEWORKS; do
        archive_dsym "$fw" "$SLICE/$fw.framework/$fw"
    done
    zip_dsyms

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

declared_categories() { # $1 = PrivacyInfo.xcprivacy -> 声明的类别(空格分隔,去掉 Apple 的 NSPrivacyAccessedAPICategory 前缀)
    local i=0 cat out=""
    while cat=$(plutil -extract "NSPrivacyAccessedAPITypes.$i.NSPrivacyAccessedAPIType" raw -o - "$1" 2>/dev/null); do
        out="$out ${cat#NSPrivacyAccessedAPICategory}"
        i=$((i + 1))
    done
    printf '%s\n' "${out# }"
}

sorted_words() { # $1 = 空格分隔的词 -> 排序去重后的一行
    printf '%s\n' "$1" | tr ' ' '\n' | sed -e '/^$/d' | sort -u | tr '\n' ' ' | sed -e 's/[[:space:]]*$//'
}

verify_slice() {
    local fw fr bin dep id deps bad vtool_out platform minos ass_count hits plist_platform plist_minos
    local privacy declared expected dsym uuid_bin uuid_dsym dwarf_count dsym_count
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

        # P2-4:隐私清单存在、可解析,且声明内容与「现场重扫 nm -u」的结果一致。
        privacy="$fr/PrivacyInfo.xcprivacy"
        if [ -f "$privacy" ] && plutil -lint "$privacy" >/dev/null 2>&1; then
            pass "PrivacyInfo.xcprivacy 是合法 plist"
            declared=$(declared_categories "$privacy")
            scan_reason_apis "$bin"
            expected=$(sorted_words "$REASON_CATEGORIES")
            declared=$(sorted_words "$declared")
            if [ "$declared" = "$expected" ]; then
                pass "隐私声明与 nm -u 扫描一致:${declared:-<none>}"
            else
                fail "隐私声明 '${declared:-<none>}' 与扫描结果 '${expected:-<none>}' 不一致"
            fi
        else
            fail "缺少或非法的 PrivacyInfo.xcprivacy"
        fi

        # P2-4:dSYM 存在,UUID 与出货二进制一致;DWARF 有无取决于上游是否带 -g。
        dsym="$SLICE/dSYMs/$fw.framework.dSYM"
        uuid_bin=$(dwarfdump --uuid "$bin" 2>/dev/null | awk '{print $2}' | head -1)
        uuid_dsym=$(dwarfdump --uuid "$dsym" 2>/dev/null | awk '{print $2}' | head -1)
        if [ -d "$dsym" ] && [ -n "$uuid_bin" ] && [ "$uuid_bin" = "$uuid_dsym" ]; then
            dwarf_count=$(dwarfdump --debug-info "$dsym" 2>/dev/null | grep -c 'DW_TAG' || true)
            if [ "${dwarf_count:-0}" -gt 0 ]; then
                pass "dSYM UUID=$uuid_dsym(DWARF 条目 $dwarf_count)"
            else
                pass "dSYM UUID=$uuid_dsym"
                warn "dSYM 无 DWARF:输入二进制未带 -g(见 $SLICE/P2-4-INFO.txt)"
            fi
        else
            fail "dSYM 缺失或 UUID 不一致(bin='${uuid_bin:-none}' dsym='${uuid_dsym:-none}')"
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

    # P2-4:dSYM 归档包(每个切片一个 zip,里面四个 .dSYM)。
    if [ -f "$SLICE/dSYMs.zip" ]; then
        pass "dSYMs.zip 存在($(stat -f %z "$SLICE/dSYMs.zip") bytes)"
    else
        fail "缺少 $SLICE/dSYMs.zip"
    fi
    dsym_count=$(find "$SLICE/dSYMs" -maxdepth 1 -name '*.framework.dSYM' -type d 2>/dev/null | wc -l | tr -d ' ')
    if [ "${dsym_count:-0}" -eq 4 ]; then
        pass "dSYMs/ 里有 4 个 .dSYM"
    else
        fail "dSYMs/ 里有 ${dsym_count:-0} 个 .dSYM(期望 4)"
    fi

    hdr "result"
    if [ "$FAILS" -eq 0 ]; then
        printf '  PASS (0 failures)\n'
        return 0
    fi
    printf '  FAIL (%d failures)\n' "$FAILS"
    return 1
}

# ---------------------------------------------------------------------------
# xcframework:四个 framework 的三切片 -> lux/.build/mpv-xcframeworks/
# ---------------------------------------------------------------------------
# 与 build-frameworks.sh 的 create_xcframeworks 同一套做法(xcodebuild -create-xcframework
# + ditto 保留 symlink + swift package compute-checksum),只是输入换成 mpv 栈的四个
# framework,输出落在独立目录,避免和 FFmpeg 的 xcframework 混在一起。
# dSYM 不是 xcframework 的组成部分(binaryTarget 只用 framework 本体),按切片单独归档。
create_xcframeworks() {
    local fw target args out zip checksum missing="" count total

    # 三个切片缺一不可:少一个切片的 xcframework 就是残的,不做「有几个算几个」。
    for target in $TARGETS; do
        [ -d "$OUT_ROOT/$target" ] || missing="$missing $target"
    done
    [ -z "$missing" ] || die "缺少切片:$missing — 先运行 $0 <target> 打包"

    rm -rf "$XCF_ROOT"
    mkdir -p "$XCF_ROOT/dSYMs"

    for fw in $MPV_FRAMEWORKS; do
        args=()
        for target in $TARGETS; do
            [ -d "$OUT_ROOT/$target/$fw.framework" ] || die "缺少 $OUT_ROOT/$target/$fw.framework"
            [ -d "$OUT_ROOT/$target/dSYMs/$fw.framework.dSYM" ] \
                || die "缺少 dSYM: $OUT_ROOT/$target/dSYMs/$fw.framework.dSYM"
            args+=(-framework "$OUT_ROOT/$target/$fw.framework")
            mkdir -p "$XCF_ROOT/dSYMs/$target"
            cp -R "$OUT_ROOT/$target/dSYMs/$fw.framework.dSYM" "$XCF_ROOT/dSYMs/$target/"
        done
        out="$XCF_ROOT/$fw.xcframework"
        log "xcodebuild -create-xcframework $fw"
        if ! xcodebuild -create-xcframework "${args[@]}" -output "$out" \
                > "$LOGDIR/p2-xcframework-$fw.log" 2>&1; then
            tail -30 "$LOGDIR/p2-xcframework-$fw.log" >&2
            die "xcodebuild -create-xcframework failed for $fw"
        fi
        # 立刻对账:切片数必须是 3,且每个切片里都有二进制与 Info.plist。
        count=$(python3 -c 'import plistlib,sys; print(len(plistlib.load(open(sys.argv[1],"rb")).get("AvailableLibraries",[])))' "$out/Info.plist" 2>/dev/null || echo 0)
        [ "${count:-0}" -eq 3 ] || die "$fw: xcframework 切片数 ${count:-0}(期望 3)"
        for target in "$out"/*/; do
            [ -d "$target" ] || continue
            [ -f "$target/$fw.framework/$fw" ] || die "$fw: 切片 $(basename "$target") 里没有 $fw.framework/$fw"
            [ -f "$target/$fw.framework/Info.plist" ] || die "$fw: 切片 $(basename "$target") 里没有 Info.plist"
        done
    done

    # zip(保留 symlink)+ checksum,格式与 FFmpeg 侧 checksums.txt 一致。
    : > "$XCF_ROOT/checksums.txt"
    for fw in $MPV_FRAMEWORKS; do
        zip="$XCF_ROOT/$fw.xcframework.zip"
        rm -f "$zip"
        ditto -c -k --sequesterRsrc --keepParent "$XCF_ROOT/$fw.xcframework" "$zip" \
            || die "ditto 打包失败: $fw"
        checksum=$(swift package compute-checksum "$zip") || die "compute-checksum 失败: $fw"
        printf '%s  %s\n' "$checksum" "$fw.xcframework.zip" >> "$XCF_ROOT/checksums.txt"
    done
    ( cd "$XCF_ROOT" && ditto -c -k --sequesterRsrc --keepParent dSYMs dSYMs.zip ) \
        || die "dSYMs.zip 打包失败"

    # 产物记录:切片、二进制体积、checksum,便于离线复核。
    {
        printf 'built_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'targets=%s\n' "$TARGETS"
        printf 'source=%s\n' "$OUT_ROOT"
        total=0
        for fw in $MPV_FRAMEWORKS; do
            printf 'xcframework.%s=slices=%s\n' "$fw" "$(printf '%s' "$TARGETS" | wc -w | tr -d ' ')"
            for target in $TARGETS; do
                printf 'size.%s.%s=%s\n' "$fw" "$target" "$(stat -f %z "$OUT_ROOT/$target/$fw.framework/$fw")"
                total=$((total + $(stat -f %z "$OUT_ROOT/$target/$fw.framework/$fw")))
            done
        done
        printf 'size.total=%s\n' "$total"
        printf 'dSYMs.zip.bytes=%s\n' "$(stat -f %z "$XCF_ROOT/dSYMs.zip")"
    } > "$XCF_ROOT/MPV-XCFRAMEWORK-INFO.txt"

    log "xcframeworks in $XCF_ROOT"
    cat "$XCF_ROOT/checksums.txt"
}

main() {
    # 外层为了取 PIPESTATUS 用了 set +e;这里必须恢复,否则 cp/install_name_tool
    # 的失败会被 tee 吞掉,脚本会带着半成品“通过”。
    set -euo pipefail
    local mode=${1:-macos-arm64} verify_target=${2:-macos-arm64} fw before after rc t
    case "$mode" in
        macos-arm64|ios-arm64|ios-sim-arm64|xcframework|verify|clean) ;;
        *) usage ;;
    esac

    mkdir -p "$LOGDIR"

    if [ "$mode" = clean ]; then
        rm -rf "$OUT_ROOT" "$XCF_ROOT"
        log "removed $OUT_ROOT and $XCF_ROOT"
        return 0
    fi

    if [ "$mode" = xcframework ]; then
        create_xcframeworks
        return $?
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
    verify)      logfile="$LOGDIR/p2-2-verify-${2:-macos-arm64}-$stamp.log" ;;
    clean)       logfile="$LOGDIR/p2-2-clean-$stamp.log" ;;
    xcframework) logfile="$LOGDIR/p2-xcframework-all-$stamp.log" ;;
    *)           logfile="$LOGDIR/p2-2-package-${1:-macos-arm64}-$stamp.log" ;;
esac
mkdir -p "$LOGDIR"

set +e
main "$@" 2>&1 | tee "$logfile"
status=${PIPESTATUS[0]}
set -e

printf '\n[mpv-frameworks] log: %s\n' "$logfile" | tee -a "$logfile"
exit "$status"
