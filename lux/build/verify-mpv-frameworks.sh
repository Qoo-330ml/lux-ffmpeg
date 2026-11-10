#!/usr/bin/env bash
#
# lux/build/verify-mpv-frameworks.sh — P2 第 7 步:libmpv 依赖闭包 / av_ 符号 / 三切片
#
#   ./lux/build/verify-mpv-frameworks.sh                  # 三个切片(默认)
#   ./lux/build/verify-mpv-frameworks.sh macos-arm64      # 只查一个切片
#   LUX_MPV_FRAMEWORK_ROOT=<dir> ./lux/build/verify-mpv-frameworks.sh macos-arm64
#                                                         # 用一份副本做阴性对照(见 P2-7 日志)
#   LUX_MPV_XCFRAMEWORK_ROOT=<dir> ./lux/build/verify-mpv-frameworks.sh  # mpv xcframework 的另一位置
#
# 检查内容(对应计划 §4.2 与 §6 P2 第 7 条):
#   A. 依赖闭包:Libmpv 的非系统依赖只能是 §4.2 的 9 个 framework
#      (6 个 Libav* + Libplacebo + Libfribidi + Libuchardet),其中 6 个 Libav* 与
#      Libplacebo/Libfribidi 必须齐全;Libuchardet 按 §4.2 允许 0 或 1;
#      Libdav1d 尚未决定(0 或 1),出现即 FAIL 并说明;绝对路径依赖一律 FAIL。
#      Libplacebo/Libfribidi/Libuchardet 的依赖同样只允许 @rpath 上述集合或系统库。
#      每个非系统依赖都必须能在当前切片找到实体(mpv-frameworks/ 或 xcframeworks/<slice>/),
#      否则 @rpath 在运行时解析不了。
#   B. 无 av_ 定义符号:四个 mpv framework 的 nm -gU(T/D/S 类)里不得出现 av_*
#      (avpriv_* 一并检查:它只可能来自被静态吞入的 FFmpeg);同时 Libmpv 必须仍有
#      av_* 的未定义引用,证明 FFmpeg 来自 Libav*.framework 而不是静态链接。
#   C. 三切片:macos-arm64 / ios-arm64 / ios-sim-arm64 各跑一遍;
#      对应 xcframework 切片目录必须存在(只读,本脚本不生成;mpv 自己的 xcframework
#      尚未打包时记 warning,可用 LUX_VERIFY_STRICT_XCFRAMEWORK=1 提前当 FAIL)。
#      mpv 栈的 xcframework 由 build-mpv-frameworks.sh xcframework 产出到
#      lux/.build/mpv-xcframeworks/(与 FFmpeg 的 lux/.build/xcframeworks/ 分开),两处都查、优先前者。
#
# 只读约定:lux/.build/mpv-frameworks 与 lux/.build/xcframeworks 允许是指向主检出的
# 符号链接(worktree 场景),脚本绝不写入;证据只打在 lux/.build/verify/mpv/。
# 输出格式与 verify-frameworks.sh 一致:[ok]/[FAIL]/[warn] + failures/warnings + RESULT。
#
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LUX=$(cd "$HERE/.." && pwd)
BUILD_ROOT="$LUX/.build"
MPV_ROOT="${LUX_MPV_FRAMEWORK_ROOT:-$BUILD_ROOT/mpv-frameworks}"
DIST_ROOT="$BUILD_ROOT/xcframeworks"
# mpv 栈的 xcframework 有独立输出目录(build-mpv-frameworks.sh xcframework);
# 先查这里,再回退到 xcframeworks/(旧布局),两种位置都接受。
MPV_XCF_ROOT="${LUX_MPV_XCFRAMEWORK_ROOT:-$BUILD_ROOT/mpv-xcframeworks}"
EVIDENCE="$BUILD_ROOT/verify/mpv"

# shellcheck source=../config/ffmpeg-ios.conf
. "$LUX/config/ffmpeg-ios.conf"

MPV_FRAMEWORKS="Libmpv Libplacebo Libfribidi Libuchardet"
# Libmpv 必须链接的 8 个:6 个 Libav* + Libplacebo + Libfribidi。
# Libuchardet 按 §4.2 允许 0 或 1,单独判定,不进这个列表。
REQUIRED_LIBMPV_DEPS="Libavcodec Libavfilter Libavformat Libavutil Libswresample Libswscale Libplacebo Libfribidi LibMoltenVK"

mkdir -p "$EVIDENCE"

FAILS=0
WARNS=0
pass() { printf '  [ok]   %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '  [warn] %s\n' "$*"; WARNS=$((WARNS + 1)); }
hdr()  { printf '\n== %s\n' "$*"; }

xcf_slice_id() { # $1 = target -> xcframework 的 LibraryIdentifier
    case "$1" in
        macos-arm64)   echo "macos-arm64" ;;
        ios-arm64)     echo "ios-arm64" ;;
        ios-sim-arm64) echo "ios-arm64-simulator" ;;
        *) return 1 ;;
    esac
}

is_allowed_dep() { # $1 = 依赖路径 -> 0 表示在 §4.2 白名单内
    case "$1" in
        @rpath/Libavutil.framework/Libavutil|\
        @rpath/Libswresample.framework/Libswresample|\
        @rpath/Libavcodec.framework/Libavcodec|\
        @rpath/Libavformat.framework/Libavformat|\
        @rpath/Libavfilter.framework/Libavfilter|\
        @rpath/Libswscale.framework/Libswscale|\
        @rpath/Libplacebo.framework/Libplacebo|\
        @rpath/Libfribidi.framework/Libfribidi|\
        @rpath/Libuchardet.framework/Libuchardet|\
        @rpath/LibMoltenVK.framework/LibMoltenVK|\
        @rpath/Libshaderc.framework/Libshaderc)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

mpv_xcf_path() { # $1 = framework -> mpv xcframework 路径(可能不存在)
    if [ -d "$MPV_XCF_ROOT/$1.xcframework" ]; then
        printf '%s\n' "$MPV_XCF_ROOT/$1.xcframework"
    else
        printf '%s\n' "$DIST_ROOT/$1.xcframework"
    fi
}

verify_target() {
    local target=$1
    local slice="$MPV_ROOT/$target"
    local xsid fw bin deps self_name xcf
    local closure_deps=""

    hdr "slice: $target"

    if [ ! -d "$slice" ]; then
        fail "$slice 不存在 — 先运行 lux/build/build-mpv-frameworks.sh $target"
        return 0
    fi

    xsid=$(xcf_slice_id "$target")

    # ---------------------------------------------------------------- C. xcframework 切片
    local missing_xcf=""
    for fw in $LUX_FRAMEWORKS; do
        xcf="$DIST_ROOT/$fw.xcframework"
        if [ -f "$xcf/$xsid/$fw.framework/$fw" ]; then
            :
        else
            missing_xcf="$missing_xcf $fw"
        fi
    done
    if [ -z "$missing_xcf" ]; then
        pass "xcframework: 6 个 Libav* 都有 $xsid 切片"
    else
        fail "xcframework: 缺少 $xsid 切片:$missing_xcf(先运行 lux/build/build-frameworks.sh package)"
    fi

    # mpv 四个 framework 的 xcframework 由 P2 打包步骤产出,不在本脚本职责内。
    # 已存在的按切片严格检查;整体缺失记 warning(P3 发布门之前必须补上)。
    local missing_mpv="" mpv_xcf=0
    for fw in $MPV_FRAMEWORKS; do
        xcf=$(mpv_xcf_path "$fw")
        if [ ! -d "$xcf" ]; then
            missing_mpv="$missing_mpv $fw"
            continue
        fi
        mpv_xcf=$((mpv_xcf + 1))
        if [ ! -f "$xcf/$xsid/$fw.framework/$fw" ]; then
            fail "$fw.xcframework: 缺少切片 $xsid"
        fi
    done
    if [ -n "$missing_mpv" ]; then
        if [ "${LUX_VERIFY_STRICT_XCFRAMEWORK:-0}" = 1 ]; then
            fail "mpv xcframework 尚未打包:$missing_mpv"
        else
            warn "mpv xcframework 尚未打包:$missing_mpv(P2 打包步骤未完成;P3 前必须存在,可用 LUX_VERIFY_STRICT_XCFRAMEWORK=1 强制)"
        fi
    else
        pass "mpv xcframework: $mpv_xcf 个都有 $xsid 切片"
    fi

    # ---------------------------------------------------------------- A/B. 每个 framework
    for fw in $MPV_FRAMEWORKS; do
        bin="$slice/$fw.framework/$fw"
        if [ ! -f "$bin" ]; then
            fail "$fw: 缺少二进制 $bin"
            continue
        fi
        pass "$fw: 二进制存在"

        # ------------------------------------------------------------ A.0 install name
        self_name=$(otool -D "$bin" 2>/dev/null | sed -n '2p') || true
        if [ "$self_name" = "@rpath/$fw.framework/$fw" ]; then
            pass "$fw: install name = $self_name"
        else
            fail "$fw: install name = '${self_name:-<none>}'(期望 @rpath/$fw.framework/$fw)"
        fi

        # 一次 dump 落盘:后面所有判定都基于证据文件,便于人工复核(见 P2-7 日志)。
        otool -L "$bin" > "$EVIDENCE/$target-$fw.deps.txt" 2>&1 || true
        nm -gU "$bin" > "$EVIDENCE/$target-$fw.defined.txt" 2>&1 || true
        nm -u "$bin" > "$EVIDENCE/$target-$fw.undefined.txt" 2>&1 || true

        deps=$(awk 'NR > 2 {print $1}' "$EVIDENCE/$target-$fw.deps.txt")
        if [ -z "$deps" ]; then
            fail "$fw: 读不到 otool -L 的依赖列表($EVIDENCE/$target-$fw.deps.txt)"
            continue
        fi

        # ------------------------------------------------------------ A.1 依赖白名单
        local dep non_sys=0 bad="" dav1d=0
        while IFS= read -r dep; do
            [ -n "$dep" ] || continue
            case "$dep" in
                /usr/lib/*|/System/Library/Frameworks/*) continue ;;
            esac
            non_sys=$((non_sys + 1))
            case "$dep" in
                *dav1d*) dav1d=1; continue ;;
            esac
            if ! is_allowed_dep "$dep"; then
                bad="$bad $dep"
            fi
        done <<< "$deps"

        if [ "$dav1d" -eq 1 ]; then
            fail "$fw: 依赖里出现 Libdav1d — §4.2 尚未决定(0 或 1),当前不允许;需所有者决策后加入白名单"
        fi
        if [ -n "$bad" ]; then
            fail "$fw: 非白名单 / 绝对路径依赖:$bad"
        fi
        if [ -z "$bad" ] && [ "$dav1d" -eq 0 ]; then
            pass "$fw: $non_sys 个非系统依赖全部在白名单内"
        fi

        # ------------------------------------------------------------ A.2 Libmpv 必需依赖
        if [ "$fw" = "Libmpv" ]; then
            local want missing=""
            for want in $REQUIRED_LIBMPV_DEPS; do
                if ! printf '%s\n' "$deps" | grep -qx "@rpath/$want.framework/$want"; then
                    missing="$missing $want"
                fi
            done
            if [ -n "$missing" ]; then
                fail "Libmpv: 缺少必需依赖:$missing"
            else
                pass "Libmpv: 必需依赖齐全(6 个 Libav* + Libplacebo + Libfribidi)"
            fi
            if printf '%s\n' "$deps" | grep -qx "@rpath/Libuchardet.framework/Libuchardet"; then
                pass "Libmpv: 链接 Libuchardet(§4.2 允许 0 或 1,按 P0 决策)"
            else
                pass "Libmpv: 未链接 Libuchardet(§4.2 允许 0 或 1)"
            fi
            if [ "$target" != "macos-arm64" ]; then
                # 不要用 grep -q:pipefail 下 strings 会因 SIGPIPE 被判失败(见 README §8.4)。
                if strings "$bin" 2>/dev/null | grep -F "iOS/MoltenVK (via Metal)" >/dev/null; then
                    pass "Libmpv: iOS MoltenVK 上下文已编译(ra_ctx_vulkan_moltenvk)"
                else
                    fail "Libmpv: 缺少 iOS MoltenVK 上下文 — 检查 lux/patches/mpv/ 是否应用"
                fi
            fi
        fi
        if [ "$fw" = "Libplacebo" ]; then
            # libplacebo 以 -Dvk-proc-addr=disabled 构建,不直接引用 vk* 符号,
            # 所以只链 Libshaderc;MoltenVK 由 Libmpv 直接链(见 REQUIRED_LIBMPV_DEPS)。
            if printf '%s\n' "$deps" | grep -qx "@rpath/Libshaderc.framework/Libshaderc"; then
                pass "Libplacebo: 共享 shaderc 依赖已链接(Libshaderc)"
            else
                fail "Libplacebo: 缺少 @rpath/Libshaderc.framework/Libshaderc"
            fi
        fi

        # ------------------------------------------------------------ B. av_ 定义符号
        local av_defs avpriv_defs n_av n_avpriv sample
        # nm 的列数随格式变化(有无地址列),这里按「T/D/S 字段 + 下一个字段」定位,
        # 避免依赖固定列号。T/D/S 是大写 = 本镜像内的外部定义。
        av_defs=$(awk '{ for (i = 1; i < NF; i++) if ($i ~ /^[TDS]$/ && $(i + 1) ~ /^_av_/) { print $(i + 1); break } }' \
            "$EVIDENCE/$target-$fw.defined.txt")
        avpriv_defs=$(awk '{ for (i = 1; i < NF; i++) if ($i ~ /^[TDS]$/ && $(i + 1) ~ /^_avpriv_/) { print $(i + 1); break } }' \
            "$EVIDENCE/$target-$fw.defined.txt")
        n_av=$(printf '%s\n' "$av_defs" | grep -c . || true)
        n_avpriv=$(printf '%s\n' "$avpriv_defs" | grep -c . || true)
        if [ "$n_av" -gt 0 ] || [ "$n_avpriv" -gt 0 ]; then
            # 只用 awk 采样,不用 head:pipefail 下 head 提前关管道会让上游吃 SIGPIPE。
            sample=$(printf '%s\n%s\n' "$av_defs" "$avpriv_defs" | \
                awk 'NF && c < 5 { printf "%s ", $0; c++ }')
            fail "$fw: 定义了 $((n_av + n_avpriv)) 个 FFmpeg 符号(应只由 Libav* 提供):$sample"
        else
            pass "$fw: 无 av_*/avpriv_* 定义符号(nm -gU 的 T/D/S)"
        fi

        # Libmpv 必须从 Libav* 里「引用」av_,若一个都没有,说明 FFmpeg 被静态吞了。
        if [ "$fw" = "Libmpv" ]; then
            local undef_av
            undef_av=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^_av_/) { n++; break } } END { print n + 0 }' \
                "$EVIDENCE/$target-$fw.undefined.txt")
            if [ "$undef_av" -gt 0 ]; then
                pass "Libmpv: $undef_av 个 av_* 未定义引用由 Libav*.framework 提供(非静态吞入)"
            else
                fail "Libmpv: 没有任何 av_* 未定义引用 — 疑似静态吞入 FFmpeg"
            fi
        fi

        closure_deps="$closure_deps
$deps"
    done

    # ---------------------------------------------------------------- A.3 依赖可解析
    local dep name missing_resolve=""
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        case "$dep" in
            /usr/lib/*|/System/Library/Frameworks/*) continue ;;
        esac
        name=${dep#@rpath/}
        name=${name%%.framework/*}
        if [ -f "$slice/$name.framework/$name" ] || \
           [ -f "$DIST_ROOT/$name.xcframework/$xsid/$name.framework/$name" ] || \
           [ -f "$BUILD_ROOT/vulkan-frameworks/$target/slice/$name.framework/$name" ] || \
           [ -f "$BUILD_ROOT/vulkan-xcframeworks/$name.xcframework/$xsid/$name.framework/$name" ]; then
            :
        else
            missing_resolve="$missing_resolve $dep"
        fi
    done <<< "$closure_deps"
    if [ -z "$missing_resolve" ]; then
        pass "全部 @rpath 依赖都能在 $target 切片解析(mpv-frameworks/ 或 xcframeworks/$xsid)"
    else
        fail "以下 @rpath 依赖在本切片找不到实体:$missing_resolve"
    fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
    read -r -a targets <<< "$LUX_TARGETS"
fi

for target in "${targets[@]}"; do
    case " $LUX_TARGETS " in
        *" $target "*) verify_target "$target" ;;
        *) fail "未知目标 '$target'(支持:$LUX_TARGETS)" ;;
    esac
done

printf '\nfailures: %d, warnings: %d\n' "$FAILS" "$WARNS"
if [ "$FAILS" -ne 0 ]; then
    printf 'RESULT: FAIL\n'
    exit 1
fi
printf 'RESULT: PASS\n'
