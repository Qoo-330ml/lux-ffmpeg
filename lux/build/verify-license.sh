#!/usr/bin/env bash
#
# lux/build/verify-license.sh — LGPL 合规 / 组件对账 / 平台元数据检查
#
#   ./lux/build/verify-license.sh                    # 三个目标全查(未构建的目标算失败)
#   ./lux/build/verify-license.sh macos-arm64        # 只查一个
#
# 任何一条检查失败 → 退出码 1。可重复运行,只读 lux/.build/(临时探针也写在里面)。
#
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LUX=$(cd "$HERE/.." && pwd)
REPO=$(cd "$LUX/.." && pwd)
BUILD_ROOT="$LUX/.build"
VERIFY_ROOT="$BUILD_ROOT/verify"
mkdir -p "$VERIFY_ROOT"
export TMPDIR="$BUILD_ROOT/tmp"
mkdir -p "$TMPDIR"

# shellcheck source=../config/ffmpeg-ios.conf
. "$LUX/config/ffmpeg-ios.conf"

targets=("$@")
[ ${#targets[@]} -gt 0 ] || read -r -a targets <<< "$LUX_TARGETS"

FAILS=0
WARNS=0
pass() { printf '  [ok]   %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '  [warn] %s\n' "$*"; WARNS=$((WARNS + 1)); }
hdr()  { printf '\n== %s\n' "$*"; }

# 符号表里绝对不允许出现的东西(外部库 / GPL 组件 / 我们没构建的库)。
# theora/xvid 也只匹配外部库的 API。FFmpeg 自带的 ogg_codec 描述符
# `_ff_theora_codec` 与内建 IDCT `_ff_xvid_idct` 不是外部库(ogg/idctdsp 会参与构建)。
# 豁免:dav1d(AV1 软解)、zlib(tscc 的 inflate)、OpenSSL(TLS/DTLS/ffrtmpcrypt)
# 已纳入 LGPL-2.1+ 构建(2026-11-10 所有者决定)。dav1d 是 BSD-2-Clause、zlib 是 zlib
# 许可、OpenSSL 3.x 是 Apache-2.0,都与 LGPL-2.1+ 兼容,以静态库在链接期并入。
# 因此 `dav1d_*`、zlib 的 `inflate*`/`uncompress`/`zlibVersion`、OpenSSL 的
# `SSL_*`/`OPENSSL_*` 以及 FFmpeg 自己的 `ff_tls_openssl_*` 都不再算禁用符号;许可依据见
# lux/config/allowlist.md「外部依赖」一节。其它外部库/GPL 的规则保持原样。
FORBIDDEN_SYMBOL_RE='x264|x265|fdk|fdkaac|(^|_)xvid_(global|encore|decore|image|plugin|version)|vidstab|xavs|postproc|mp3lame|libmp3lame|(^|_)(th_(decode|encode|comment|info|packet|version|granule|setup|clear|merge)|theora_(decode|encode|version|comment|info|packet))|svt_|svtav1|libvpx|vpx_codec_|vpx_img_|faac|vo_aacenc|opencore|libass|fribidi|fontconfig|freetype|gnutls|libvorbis|libopus|zimg|placebo|shaderc|chromaprint|vid\.stab'
# 符号先落到文件再 grep:直接 `nm ... | grep -q` 会让 grep 提前关闭管道,
# 在 pipefail 下把 nm 的 SIGPIPE 当失败。
dump_symbols() { # $1 = archive, $2 = 输出文件
    nm -gj "$1" 2>/dev/null | sed '/^$/d; /:$/d' > "$2"
    return 0
}

# 源码头的 GPL 标记(必须排除 LGPL 的 "Lesser ... General Public License")
src_is_gpl() {
    head -60 "$1" 2>/dev/null |
        grep -Ei 'general public license|license: *gpl|gplv[23]|gpl-[23]' |
        grep -vi 'lesser' |
        grep -qi .
}

# 补丁集:BUILD-INFO 里记录的指纹必须等于仓库当前 lux/patches 的指纹,
# 否则说明产物和源码不对应(改了补丁没重建,或者构建时没打补丁)。
check_patches() { # $1 = build dir
    local build=$1
    local info="$build/BUILD-INFO.txt"
    local digest count rec

    digest=$("$LUX/build/apply-patches.sh" digest 2>/dev/null) || { fail "读取补丁集指纹失败"; return; }
    count=$("$LUX/build/apply-patches.sh" count 2>/dev/null)

    if [ ! -f "$info" ]; then
        fail "缺少 $info(不是用 lux/build/build-ffmpeg.sh 构建的?)"
        return
    fi
    rec=$(sed -n 's/^patches_digest=//p' "$info")
    case "$rec" in
        "")
            fail "BUILD-INFO.txt 没有 patches_digest(产物早于补丁集)"
            ;;
        "$digest")
            pass "补丁集一致:$count 条,$digest"
            ;;
        *)
            fail "补丁集指纹不一致:产物 $rec ≠ 仓库 $digest(需要重新构建)"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 单个目标的检查
# ---------------------------------------------------------------------------
verify_target() {
    local target=$1
    local build="$BUILD_ROOT/$target"
    local install="$build/install"
    local logdir="$BUILD_ROOT/logs"
    local tag

    hdr "target: $target"
    ff_target_setup "$target" || { fail "unknown target $target"; return; }

    if [ ! -f "$build/config.h" ]; then
        fail "$build/config.h 不存在 — 先运行 lux/build/build-ffmpeg.sh $target"
        return
    fi

    # ---------------------------------------------------------------- 1. 产物
    local lib missing=""
    for lib in $LUX_STATIC_LIBS; do
        [ -f "$install/lib/$lib" ] || missing="$missing $lib"
    done
    if [ -n "$missing" ]; then
        fail "缺少静态库:$missing"
        return
    fi
    pass "静态库齐全: $(printf '%s ' $LUX_STATIC_LIBS)"

    # 产物必须由当前补丁集生成
    check_patches "$build"

    # 不该出现的库文件(avfilter/swscale 自 F2 起是白名单内的产物)
    for lib in libavdevice.a libpostproc.a; do
        [ -f "$install/lib/$lib" ] && fail "不该存在的产物 $lib"
    done

    # ---------------------------------------------------------------- 2. 许可开关
    local check
    for check in "CONFIG_GPL 0" "CONFIG_NONFREE 0" "CONFIG_VERSION3 0" \
                 "CONFIG_LGPLV3 0" "CONFIG_AVFILTER 1" "CONFIG_SWSCALE 1" \
                 "CONFIG_AVDEVICE 0" "CONFIG_NETWORK 1" "CONFIG_OPENSSL 1" \
                 "CONFIG_ZLIB 1" "CONFIG_SECURETRANSPORT 0"; do
        local name=${check% *} want=${check#* }
        if grep -qE "^#define $name ${want}$" "$build/config.h"; then
            pass "config.h: $name = $want"
        else
            fail "config.h: $name 不是 $want (实际: $(grep -E "^#define $name " "$build/config.h" || echo '<缺失>'))"
        fi
    done

    # configure 的 License: 行
    local cfg_log="$logdir/$target-configure.log"
    local license_line=""
    [ -f "$cfg_log" ] && license_line=$(grep -m1 '^License:' "$cfg_log")
    case "$license_line" in
        "License: LGPL version 2.1 or later") pass "configure: $license_line" ;;
        "") fail "找不到 $cfg_log 里的 License: 行" ;;
        *)  fail "configure: 意外的许可行 '$license_line'" ;;
    esac

    # configure 参数里不得有 GPL/nonfree/外部编码库
    if [ -f "$build/configure.opts.txt" ]; then
        if grep -Eq -e "$LUX_FORBIDDEN_OPTS" "$build/configure.opts.txt"; then
            fail "configure 参数含禁用项: $(grep -E -e "$LUX_FORBIDDEN_OPTS" "$build/configure.opts.txt" | tr '\n' ' ')"
        else
            pass "configure 参数无 --enable-gpl/--enable-nonfree/外部 GPL 库"
        fi
        grep -q -- '--disable-gpl' "$build/configure.opts.txt" \
            && pass "configure 参数含 --disable-gpl" || fail "configure 参数缺 --disable-gpl"
        grep -q -- '--disable-nonfree' "$build/configure.opts.txt" \
            && pass "configure 参数含 --disable-nonfree" || fail "configure 参数缺 --disable-nonfree"
    else
        fail "$build/configure.opts.txt 不存在(不是用 lux/build/build-ffmpeg.sh 构建的?)"
    fi

    # D3 / b 类收口的硬断言:OpenSSL 后端必须真的生效,被排除的协议必须没被 select 回来。
    local want_comp comp_re
    for want_comp in CONFIG_TSCC_DECODER CONFIG_DTLS_PROTOCOL CONFIG_FFRTMPCRYPT_PROTOCOL; do
        grep -qE "^#define $want_comp 1$" "$build/config_components.h" \
            && pass "config_components.h: $want_comp = 1" \
            || fail "config_components.h: $want_comp 不是 1"
    done
    for comp_re in CONFIG_RTMPE_PROTOCOL CONFIG_RTMPTE_PROTOCOL \
                   CONFIG_DASH_DEMUXER CONFIG_LIBUAVS3D_DECODER; do
        if grep -qE "^#define $comp_re 1$" "$build/config_components.h"; then
            fail "config_components.h: $comp_re 被意外启用(应保持 0)"
        else
            pass "config_components.h: $comp_re = 0"
        fi
    done

    # ---------------------------------------------------------------- 3. avutil_license()
    local probe_dir="$VERIFY_ROOT/$target"
    mkdir -p "$probe_dir"
    if [ "$target" = macos-arm64 ]; then
        cat > "$probe_dir/license_probe.c" <<'EOF'
#include <stdio.h>
#include <libavutil/avutil.h>
int main(void) { printf("%s\n", avutil_license()); return 0; }
EOF
        local deps_prefix="$BUILD_ROOT/deps/$target/install"
        if xcrun --sdk macosx clang $FF_MIN_FLAG -isysroot "$FF_SDK_PATH" \
                -I"$install/include" -o "$probe_dir/license_probe" \
                "$probe_dir/license_probe.c" "$install/lib/libavutil.a" \
                -L"$deps_prefix/lib" -lssl -lcrypto -lz \
                -framework CoreFoundation -framework Security > "$probe_dir/probe-build.log" 2>&1; then
            local lic_out
            lic_out=$("$probe_dir/license_probe" 2>&1)
            case "$lic_out" in
                LGPL*) pass "avutil_license() = $lic_out" ;;
                *)     fail "avutil_license() = '$lic_out'(应以 LGPL 开头)" ;;
            esac
        else
            fail "license_probe 编译失败,见 $probe_dir/probe-build.log"
        fi
    else
        # 交叉编译的产物不能在本机运行:改为检查归档里嵌入的许可标识
        # (avutil_license() 返回的 "LGPL version 2.1 or later" 会以
        #  "libavutil license: LGPL version 2.1 or later" 的形式留在 .o 里)
        local lic_strings lic_lower
        lic_strings=$(strings -a "$install/lib/libavutil.a" |
                      grep -iE 'license:.*(lgpl|gpl|nonfree)' | sort -u)
        lic_lower=$(printf '%s\n' "$lic_strings" | tr 'A-Z' 'a-z')
        case "$lic_lower" in
            *"license: lgpl version 2.1 or later"*)
                pass "libavutil.a 内嵌许可标识: $(printf '%s' "$lic_strings" | tr '\n' '|')" ;;
            *)
                fail "libavutil.a 内找不到 LGPL 2.1 许可标识(实际: $(printf '%s' "$lic_strings" | tr '\n' '|'))" ;;
        esac
        if printf '%s\n' "$lic_lower" | grep -qE 'license: *(gpl|nonfree)'; then
            fail "libavutil.a 内嵌了非 LGPL 的许可标识: $(printf '%s' "$lic_strings" | tr '\n' '|')"
        else
            pass "libavutil.a 内没有 GPL/nonfree 许可标识"
        fi
    fi

    # ---------------------------------------------------------------- 4. GPL 源文件审计
    # 用 .d 依赖文件反查每个 .o 的源文件,再扫源码头的许可标记。
    local d src gpl_hits="" scanned=0
    while IFS= read -r d; do
        src=$(sed -e 's/\\$//' -e 's/[ 	][ 	]*/\n/g' "$d" | grep -E '\.(c|S|asm)$' | head -1)
        [ -n "$src" ] || continue
        scanned=$((scanned + 1))
        case "$src" in
            src/*) src="$build/$src" ;;
        esac
        if [ -f "$src" ] && src_is_gpl "$src"; then
            gpl_hits="$gpl_hits ${src#"$build"/}"
        fi
    done < <(find "$build" -name '*.d' -type f)
    if [ -n "$gpl_hits" ]; then
        fail "被编译的源文件里有 GPL 代码:$gpl_hits"
    else
        pass "GPL 源文件审计: 扫描 $scanned 个源文件,0 个 GPL 标记"
    fi

    # 已知的上游 GPL 文件(修过的),确认没有进归档
    local archive member bad_members=""
    for archive in "$install/lib"/*.a; do
        for member in $(ar t "$archive" | grep -E '^(ac3dsp_init_aarch64|ac3dsp_neon)\.o$'); do
            bad_members="$bad_members $(basename "$archive"):$member"
        done
    done
    [ -z "$bad_members" ] \
        && pass "归档内无已知 GPL 目标文件 (ac3dsp_init_aarch64.o / ac3dsp_neon.o)" \
        || fail "归档含已知 GPL 目标文件:$bad_members"

    # ---------------------------------------------------------------- 5. 符号表
    local hits symbols_ok=1 symdir="$probe_dir/symbols"
    mkdir -p "$symdir"
    for archive in "$install/lib"/*.a; do
        lib=$(basename "$archive")
        dump_symbols "$archive" "$symdir/$lib.txt"
        local symfile="$symdir/$lib.txt"
        # B+:libavfilter / libswscale 的 Vulkan 后端动态引用 shaderc(Apache-2.0)。
        # 这里只检查该库本身,不把 shaderc_* 当成静态吞入;正向确认引用确实存在。
        case "$lib" in
            libavfilter.a|libswscale.a)
                if grep -q '^_shaderc_compile_into_spv$' "$symfile"; then
                    pass "$lib: 动态引用 shaderc(Apache-2.0,非静态并入)"
                else
                    fail "$lib: 找不到 shaderc_compile_into_spv 引用(CONFIG_LIBSHADERC 异常)"
                    symbols_ok=0
                fi
                grep -v 'shaderc' "$symfile" > "$symfile.check" || true
                symfile="$symfile.check" ;;
        esac
        hits=$(grep -Ei -e "$FORBIDDEN_SYMBOL_RE" "$symfile" | sort -u)
        if [ -n "$hits" ]; then
            fail "$lib 符号表含禁用符号: $(printf '%s ' $hits)"
            symbols_ok=0
        fi
    done
    [ "$symbols_ok" = 1 ] && pass "符号表干净: 无 x264/x265/fdk/xvid/vidstab/postproc/未纳入的外部库符号(dav1d/zlib/OpenSSL 例外,许可见 allowlist)"

    # 正向确认:确实是我们构建的库(不是空归档/占位文件)
    for lib in libavformat.a libavcodec.a libavutil.a libswresample.a; do
        if grep -qE '^_(av|swr)' "$symdir/$lib.txt"; then
            pass "$lib 含 $(grep -cE '^_(av|swr)' "$symdir/$lib.txt") 个 av*/swr* 符号"
        else
            fail "$lib 里没有 av*/swr* 符号"
        fi
    done

    # ---------------------------------------------------------------- 6. 平台 / 架构 / 最低系统
    local lipo_out
    lipo_out=$(lipo -info "$install/lib/libavcodec.a" 2>&1)
    case "$lipo_out" in
        *"architecture: arm64"*) pass "lipo: $(printf '%s' "$lipo_out" | sed 's/.*architecture/architecture/')" ;;
        *) fail "lipo 不是 arm64: $lipo_out" ;;
    esac

    # vtool 不接受 .a,先抽一个成员出来看 LC_BUILD_VERSION
    ( cd "$probe_dir" && rm -f version.o && ar x "$install/lib/libavcodec.a" version.o ) >/dev/null 2>&1
    if [ -f "$probe_dir/version.o" ]; then
        local vt platform minos
        vt=$(vtool -show-build "$probe_dir/version.o" 2>&1)
        platform=$(printf '%s\n' "$vt" | awk '/platform /{print $2; exit}')
        minos=$(printf '%s\n' "$vt" | awk '/minos /{print $2; exit}')
        local want_platform want_minos
        case "$target" in
            ios-arm64)     want_platform=IOS;          want_minos=17.0 ;;
            ios-sim-arm64) want_platform=IOSSIMULATOR; want_minos=17.0 ;;
            macos-arm64)   want_platform=MACOS;        want_minos=14.0 ;;
        esac
        [ "$platform" = "$want_platform" ] \
            && pass "vtool: platform $platform" \
            || fail "vtool: platform '$platform' != $want_platform"
        [ "$minos" = "$want_minos" ] \
            && pass "vtool: minos $minos" \
            || fail "vtool: minos '$minos' != $want_minos"
    else
        fail "无法从 libavcodec.a 抽出 version.o 做 vtool 检查"
    fi

    # ---------------------------------------------------------------- 6b. B+ Vulkan 运行时开关
    local cfg_h="$build/config.h"
    if grep -q '^#define CONFIG_VULKAN 1$' "$cfg_h"; then
        pass "CONFIG_VULKAN=1"
    else
        fail "CONFIG_VULKAN 不是 1(B+ 的 Vulkan 运行时未编入)"
    fi
    if grep -q '^#define CONFIG_LIBSHADERC 1$' "$cfg_h"; then
        pass "CONFIG_LIBSHADERC=1"
    else
        fail "CONFIG_LIBSHADERC 不是 1(--enable-libshaderc 未生效)"
    fi

    # ---------------------------------------------------------------- 7. 组件对账
    local cc="$build/config_components.h"
    local kind suffix want enabled_list extra
    for kind in demuxer:DEMUXER muxer:MUXER parser:PARSER decoder:DECODER \
                encoder:ENCODER bsf:BSF protocol:PROTOCOL hwaccel:HWACCEL \
                filter:FILTER; do
        suffix=${kind#*:}
        case "$kind" in
            demuxer*) want=$LUX_DEMUXERS ;;
            muxer*)   want=$LUX_MUXERS ;;
            parser*)  want=$LUX_PARSERS ;;
            decoder*) want=$LUX_DECODERS ;;
            encoder*) want=$LUX_ENCODERS ;;
            bsf*)     want=$LUX_BSFS ;;
            protocol*) want=$LUX_PROTOCOLS ;;
            hwaccel*) want=$LUX_HWACCELS ;;
            filter*)  want=$LUX_FILTERS ;;
        esac
        enabled_list=$(grep -E "^#define CONFIG_[A-Z0-9_]+_${suffix} 1\$" "$cc" |
                       sed -E "s/^#define CONFIG_//; s/_${suffix} 1\$//" | tr 'A-Z' 'a-z' | sort)
        local v missing_comp=""
        for v in $want; do
            printf '%s\n' "$enabled_list" | grep -qx "$v" || missing_comp="$missing_comp $v"
        done
        if [ -n "$missing_comp" ]; then
            fail "$kind 白名单项未生效:$missing_comp"
        else
            pass "$kind 白名单 $(printf '%s' "$want" | wc -w | tr -d ' ') 项全部生效"
        fi
        extra=$(comm -13 <(printf '%s\n' $want | tr 'A-Z' 'a-z' | sort -u) \
                        <(printf '%s\n' "$enabled_list") 2>/dev/null | tr '\n' ' ')
        [ -n "${extra// /}" ] && warn "$kind 额外启用了(configure 自动 select): $extra"
    done

    # Metal 滤镜:只有 CONFIG_METAL=1 时才是构建承诺(否则是环境里没装 Metal Toolchain)
    if grep -qE '^#define CONFIG_METAL 1$' "$cc"; then
        local mf missing_m=""
        for mf in $LUX_FILTERS_METAL; do
            grep -qE "^#define CONFIG_$(printf '%s' "$mf" | tr 'a-z' 'A-Z')_FILTER 1$" "$cc" \
                || missing_m="$missing_m $mf"
        done
        [ -z "$missing_m" ] && pass "Metal 滤镜齐全: $LUX_FILTERS_METAL" \
                            || fail "Metal 滤镜未生效:$missing_m"
    else
        warn "CONFIG_METAL=0(没装 Metal Toolchain),Metal 滤镜未启用: $LUX_FILTERS_METAL"
    fi

    # 启用的解码器/编码器里不能出现 GPL 组件名
    local gpl_comp
    gpl_comp=$(grep -E "^#define CONFIG_[A-Z0-9_]+_(DECODER|ENCODER) 1\$" "$cc" |
               grep -Ei 'X264|X265|FDK|XVID|VIDSTAB|XAVS|MP3LAME|THEORA') || true
    [ -z "$gpl_comp" ] && pass "启用的 codec 里没有 GPL/external 组件" \
                       || fail "启用了 GPL/external codec: $(printf '%s ' $gpl_comp)"

    # ---------------------------------------------------------------- 8. 体积
    local total=0 size
    for lib in $LUX_STATIC_LIBS; do
        size=$(stat -f %z "$install/lib/$lib")
        total=$((total + size))
        printf '  [size] %-16s %9d bytes\n' "$lib" "$size"
    done
    printf '  [size] %-16s %9d bytes\n' TOTAL "$total"
}

for t in "${targets[@]}"; do
    verify_target "$t"
done

hdr "summary"
printf 'failures: %d, warnings: %d\n' "$FAILS" "$WARNS"
if [ "$FAILS" -gt 0 ]; then
    printf 'RESULT: FAIL\n'
    exit 1
fi
printf 'RESULT: PASS (LGPL-only)\n'
exit 0
