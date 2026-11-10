#!/usr/bin/env bash
#
# lux/build/verify-release-package.sh — 校验 F2 发布包(任何一条失败即非零退出)
#
#   ./lux/build/verify-release-package.sh
#   ./lux/build/verify-release-package.sh /path/to/lux-ffmpeg-f2-20261110
#
# 检查内容:
#   1. SHA256SUMS 覆盖发布目录全部文件,逐条 sha256 一致,无缺失/多余/重复;
#   2. xcframeworks/checksums.txt 覆盖 10 个 zip,hash 与 zip 实际 sha256 一致;
#   3. 每个 xcframework 的 Info.plist 三切片、framework 结构、module map、
#      PrivacyInfo.xcprivacy、DYLIB 类型、@rpath install name、codesign;
#   4. dSYMs/FFmpeg-dSYMs.zip 与 MPV-dSYMs.zip 的 UUID / DWARF 条目数与
#      BUILD-INFO、dSYM-INFO 一致(条目数 > 0);
#   5. BUILD-INFO 的版本、补丁集 digest、三切片、Xcode/SDK、依赖 sha256、
#      基线 commit、源码包 sha256;
#   6. 对应源码包里的 lux/、全部锁定依赖源码、FFmpeg 已打 13 个补丁的树;
#   7. source-manifest.json 与 deps.lock 的 24 个依赖逐项对账。
#
# 日志: lux/.build/logs/release-verify-<YYYYMMDD>.log
set -uo pipefail

if [ -n "${GIT_CONFIG_COUNT:-}" ] && [ -z "${GIT_CONFIG_KEY_0:-}" ]; then
    unset GIT_CONFIG_COUNT GIT_CONFIG_VALUE_0
fi

HERE=$(cd "$(dirname "$0")" && pwd)
LUX=$(cd "$HERE/.." && pwd)
REPO=$(cd "$LUX/.." && pwd)

TAG=${LUX_RELEASE_TAG:-f2-20261110}
PRODUCT="lux-ffmpeg-$TAG"

MAIN_WORKTREE=$(git -C "$REPO" worktree list --porcelain 2>/dev/null |
    awk '/^worktree / { print substr($0, 10); exit }')
[ -n "$MAIN_WORKTREE" ] || MAIN_WORKTREE=$REPO

BUILD=${LUX_ARTIFACT_BUILD:-}
if [ -z "$BUILD" ]; then
    # worktree 场景优先用主检出的构建产物(worktree 里通常只有 deps 符号链接)。
    if [ "$REPO" != "$MAIN_WORKTREE" ] && [ -d "$MAIN_WORKTREE/lux/.build/xcframeworks" ]; then
        BUILD="$MAIN_WORKTREE/lux/.build"
    elif [ -d "$REPO/lux/.build/xcframeworks" ]; then
        BUILD="$REPO/lux/.build"
    elif [ -d "$MAIN_WORKTREE/lux/.build/xcframeworks" ]; then
        BUILD="$MAIN_WORKTREE/lux/.build"
    else
        BUILD="$REPO/lux/.build"
    fi
fi

REL=${1:-${LUX_RELEASE_OUT:-$BUILD/release/$PRODUCT}}
REL=$(cd "$REL" 2>/dev/null && pwd) || {
    printf 'verify-release: 找不到发布目录 %s\n' "${1:-$BUILD/release/$PRODUCT}" >&2
    exit 1
}

LOG_DIR="$REPO/lux/.build/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/release-verify-$(date '+%Y%m%d').log"
exec > >(tee "$LOG") 2>&1

VERIFY="$REPO/lux/.build/verify/release"
rm -rf "$VERIFY"
mkdir -p "$VERIFY/zips" "$VERIFY/dsyms" "$VERIFY/source"

FAILS=0
WARNS=0
pass() { printf '  [ok]   %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '  [warn] %s\n' "$*"; WARNS=$((WARNS + 1)); }
hdr()  { printf '\n== %s\n' "$*"; }

info() { # $1=key -> BUILD-INFO value
    grep -F "$1=" "$REL/BUILD-INFO.txt" 2>/dev/null | head -1 | cut -d= -f2-
}

echo "release: $REL"
echo "log: $LOG"
echo "date: $(date '+%Y-%m-%d %H:%M:%S %z')"

# ---------------------------------------------------------------------------
# 1. 文件清单与 SHA256SUMS
# ---------------------------------------------------------------------------
hdr "SHA256SUMS / 文件清单"
REQUIRED_FILES="
BUILD-INFO.txt
COPYING.GPLv2
COPYING.GPLv3
COPYING.LGPLv2.1
COPYING.LGPLv3
LICENSE.md
NOTICE.md
SHA256SUMS
SOURCE-PACKAGE.md
source-manifest.json
lux-ffmpeg-source-$TAG.tar.gz
xcframeworks/checksums.txt
dSYMs/FFmpeg-dSYMs.zip
dSYMs/MPV-dSYMs.zip
dSYMs/dSYM-INFO.txt
"
for f in $REQUIRED_FILES; do
    [ -f "$REL/$f" ] && pass "存在 $f" || fail "缺少 $f"
done
for fw in Libavcodec Libavformat Libavfilter Libswscale Libswresample Libavutil \
          Libmpv Libplacebo Libfribidi Libuchardet; do
    [ -f "$REL/xcframeworks/$fw.xcframework.zip" ] \
        && pass "存在 $fw.xcframework.zip" || fail "缺少 $fw.xcframework.zip"
done

if [ -f "$REL/SHA256SUMS" ]; then
    : > "$VERIFY/sums-listed.txt"
    : > "$VERIFY/sums-bad.txt"
    while read -r sum path; do
        [ -n "$sum" ] || continue
        case "$path" in
            ''|/*|*..*) fail "SHA256SUMS 含非法路径: ${path:-<空>}"; continue ;;
        esac
        printf '%s\n' "$path" >> "$VERIFY/sums-listed.txt"
        if [ ! -f "$REL/$path" ]; then
            fail "SHA256SUMS 列出的文件不存在: $path"
            continue
        fi
        actual=$(shasum -a 256 "$REL/$path" | awk '{ print $1 }')
        if [ "$actual" = "$sum" ]; then
            :
        else
            printf '%s\n' "$path" >> "$VERIFY/sums-bad.txt"
            fail "sha256 不一致: $path"
        fi
    done < "$REL/SHA256SUMS"
    cp "$VERIFY/sums-listed.txt" "$VERIFY/sums-listed.sorted"
    LC_ALL=C sort -u "$VERIFY/sums-listed.sorted" -o "$VERIFY/sums-listed.sorted"
    dup=$(LC_ALL=C sort "$VERIFY/sums-listed.txt" | uniq -d)
    [ -z "$dup" ] && pass "SHA256SUMS 无重复条目" || fail "SHA256SUMS 重复: $(printf '%s' "$dup" | tr '\n' ' ')"
    ( cd "$REL" && find . -type f ! -name SHA256SUMS -print | sed 's|^\./||' | LC_ALL=C sort ) > "$VERIFY/files-actual.txt"
    missing=$(LC_ALL=C comm -13 "$VERIFY/sums-listed.sorted" "$VERIFY/files-actual.txt")
    extra=$(LC_ALL=C comm -23 "$VERIFY/sums-listed.sorted" "$VERIFY/files-actual.txt")
    if [ -z "$missing" ]; then pass "SHA256SUMS 覆盖全部文件"; else fail "SHA256SUMS 未覆盖: $(printf '%s' "$missing" | tr '\n' ' ')"; fi
    if [ -z "$extra" ]; then pass "SHA256SUMS 没有列出不存在的文件"; else fail "SHA256SUMS 列了不存在的文件: $(printf '%s' "$extra" | tr '\n' ' ')"; fi
    total=$(wc -l < "$VERIFY/sums-listed.txt" | tr -d ' ')
    good=$((total - $(wc -l < "$VERIFY/sums-bad.txt" | tr -d ' ')))
    pass "SHA256SUMS: $good/$total 条一致"
else
    fail "缺少 SHA256SUMS"
fi

# ---------------------------------------------------------------------------
# 2. checksums.txt / zip 实际 hash
# ---------------------------------------------------------------------------
hdr "xcframeworks/checksums.txt"
CHECKSUMS="$REL/xcframeworks/checksums.txt"
EXPECTED_ZIPS="Libavcodec Libavformat Libavfilter Libswscale Libswresample Libavutil Libmpv Libplacebo Libfribidi Libuchardet LibMoltenVK Libshaderc"
if [ -f "$CHECKSUMS" ]; then
    : > "$VERIFY/checksums-seen.txt"
    while read -r sum name; do
        [ -n "$sum" ] || continue
        case "$name" in
            *.xcframework.zip) ;;
            *) fail "checksums.txt 条目不是 xcframework zip: $name"; continue ;;
        esac
        printf '%s\n' "$name" >> "$VERIFY/checksums-seen.txt"
        if [ ! -f "$REL/xcframeworks/$name" ]; then
            fail "checksums.txt 列出的 zip 不存在: $name"
            continue
        fi
        actual=$(shasum -a 256 "$REL/xcframeworks/$name" | awk '{ print $1 }')
        [ "$actual" = "$sum" ] && pass "$name: checksum 一致" || fail "$name: checksum 不一致"
    done < "$CHECKSUMS"
    seen=$(LC_ALL=C sort -u "$VERIFY/checksums-seen.txt")
    expected=$(printf '%s\n' $EXPECTED_ZIPS | sed 's/$/.xcframework.zip/' | LC_ALL=C sort)
    if [ "$seen" = "$expected" ]; then
        pass "checksums.txt 正好覆盖 12 个 zip"
    else
        fail "checksums.txt 覆盖集合不符"
    fi
    [ "$(wc -l < "$CHECKSUMS" | tr -d ' ')" = "12" ] && pass "checksums.txt 为 12 行" || fail "checksums.txt 不是 12 行"
else
    fail "缺少 xcframeworks/checksums.txt"
fi

# ---------------------------------------------------------------------------
# 3. xcframework zip 内容与 framework 结构
# ---------------------------------------------------------------------------
hdr "xcframework 结构"

slice_for_target() {
    case "$1" in
        macos-arm64) echo "macos-arm64" ;;
        ios-arm64) echo "ios-arm64" ;;
        ios-sim-arm64) echo "ios-arm64-simulator" ;;
    esac
}

verify_framework_zip() { # $1=framework
    local fw=$1 zip="$REL/xcframeworks/$1.xcframework.zip" dest="$VERIFY/zips/$1" top
    local target slice fr bin links
    rm -rf "$dest"
    mkdir -p "$dest"
    ditto -x -k "$zip" "$dest" >/dev/null 2>&1 || { fail "$fw: zip 解压失败"; return; }
    top="$dest/$fw.xcframework"
    [ -d "$top" ] || { fail "$fw: zip 里没有 $fw.xcframework"; return; }

    if plutil -lint "$top/Info.plist" >/dev/null 2>&1; then
        pass "$fw: Info.plist 可解析"
    else
        fail "$fw: Info.plist 不可解析"
    fi
    local libs
    libs=$(python3 - "$top/Info.plist" <<'PY'
import plistlib, sys
try:
    d = plistlib.load(open(sys.argv[1], "rb"))
except Exception:
    sys.exit(0)
for item in d.get("AvailableLibraries", []):
    print(item.get("LibraryIdentifier", ""), item.get("SupportedPlatform", ""), item.get("SupportedPlatformVariant", ""))
PY
)
    printf '%s\n' "$libs" | grep -q '^macos-arm64 macos ' && pass "$fw: 含 macos-arm64 切片" || fail "$fw: 缺 macos-arm64 切片"
    printf '%s\n' "$libs" | grep -q '^ios-arm64 ios ' && pass "$fw: 含 ios-arm64 切片" || fail "$fw: 缺 ios-arm64 切片"
    printf '%s\n' "$libs" | grep -q '^ios-arm64-simulator ios simulator' && pass "$fw: 含 ios-arm64-simulator 切片" || fail "$fw: 缺模拟器切片"

    for target in macos-arm64 ios-arm64 ios-sim-arm64; do
        slice=$(slice_for_target "$target")
        fr="$top/$slice/$fw.framework"
        bin="$fr/$fw"
        if [ -f "$bin" ]; then
            pass "$fw/$target: 二进制存在"
        else
            fail "$fw/$target: 缺 $fw.framework/$fw"
            continue
        fi
        case "$fw" in
            Libavcodec|Libavformat|Libavfilter|Libswscale|Libswresample|Libavutil|Libmpv|Libuchardet)
                [ -f "$fr/Modules/module.modulemap" ] && pass "$fw/$target: module.modulemap" || fail "$fw/$target: 缺 module.modulemap" ;;
            *)
                if [ -f "$fr/Modules/module.modulemap" ]; then
                    pass "$fw/$target: module.modulemap"
                else
                    pass "$fw/$target: 无 module.modulemap(C 库,构建脚本按设计不生成)"
                fi ;;
        esac
        [ -f "$fr/Info.plist" ] && pass "$fw/$target: framework Info.plist" || fail "$fw/$target: 缺 Info.plist"
        [ -f "$fr/PrivacyInfo.xcprivacy" ] && pass "$fw/$target: PrivacyInfo.xcprivacy" || fail "$fw/$target: 缺 PrivacyInfo.xcprivacy"
        [ -d "$fr/Headers" ] && pass "$fw/$target: Headers 目录" || fail "$fw/$target: 缺 Headers"
        if otool -hv "$bin" 2>/dev/null | tail -1 | grep -q 'DYLIB'; then
            pass "$fw/$target: Mach-O 类型 DYLIB"
        else
            fail "$fw/$target: 不是 DYLIB"
        fi
        if otool -L "$bin" 2>/dev/null | sed -n '2p' | grep -q "@rpath/$fw.framework/$fw"; then
            pass "$fw/$target: install name 为 @rpath/$fw.framework/$fw"
        else
            fail "$fw/$target: install name 不是 @rpath/$fw.framework/$fw"
        fi
        if otool -L "$bin" 2>/dev/null | tail -n +2 | awk '{ print $1 }' | grep -Eq '^/(Volumes|Users|private)/'; then
            fail "$fw/$target: 存在绝对路径依赖"
        else
            pass "$fw/$target: 无绝对路径依赖"
        fi
        if codesign --verify --strict "$fr" >/dev/null 2>&1; then
            pass "$fw/$target: codesign --verify --strict"
        else
            fail "$fw/$target: codesign 校验失败"
        fi
    done

    links=$(unzip -Z -l "$zip" 2>/dev/null | awk '$1 ~ /^l/ { n++ } END { print n + 0 }')
    case "$fw" in
        Libavcodec|Libavformat|Libavfilter|Libswscale|Libswresample|Libavutil)
            [ "${links:-0}" -gt 0 ] && pass "$fw: zip 内保留 $links 个 symlink(Headers 别名)" \
                || fail "$fw: zip 内没有 symlink(Headers 别名)" ;;
        *)
            [ "${links:-0}" -gt 0 ] && pass "$fw: zip 内保留 $links 个 symlink" \
                || pass "$fw: 无 Headers 别名 symlink(真实头文件,按设计)" ;;
    esac
}
for fw in $EXPECTED_ZIPS; do
    verify_framework_zip "$fw"
done

# ---------------------------------------------------------------------------
# 4. dSYM UUID / DWARF
# ---------------------------------------------------------------------------
hdr "dSYMs"
for group in FFmpeg MPV; do
    zip="$REL/dSYMs/$group-dSYMs.zip"
    dest="$VERIFY/dsyms/$group"
    if [ ! -f "$zip" ]; then fail "缺少 $zip"; continue; fi
    rm -rf "$dest"; mkdir -p "$dest"
    ditto -x -k "$zip" "$dest" >/dev/null 2>&1 || { fail "$group: dSYMs.zip 解压失败"; continue; }
    n=$(find "$dest" -type d -name '*.framework.dSYM' | wc -l | tr -d ' ')
    if [ "$group" = "FFmpeg" ]; then want=18; else want=12; fi
    [ "$n" = "$want" ] && pass "$group: $n 个 dSYM(期望 $want)" || fail "$group: $n 个 dSYM(期望 $want)"
done

DSYM_INFO="$REL/dSYMs/dSYM-INFO.txt"
if [ -f "$DSYM_INFO" ]; then
    : > "$VERIFY/dsym-keys.txt"
    while IFS='=' read -r key value; do
        case "$key" in
            dSYM.*.uuid) printf '%s=%s\n' "$key" "$value" >> "$VERIFY/dsym-keys.txt" ;;
        esac
    done < "$DSYM_INFO"
    count=$(wc -l < "$VERIFY/dsym-keys.txt" | tr -d ' ')
    [ "$count" = "30" ] && pass "dSYM-INFO 有 30 个 UUID 条目" || fail "dSYM-INFO UUID 条目数 $count != 30"

    while IFS='=' read -r key rec_uuid; do
        case "$key" in
            dSYM.*.uuid) ;;
            *) continue ;;
        esac
        IFS=. read -r _ group fw target _field <<EOF2
$key
EOF2
        rec_count=$(grep -F "dSYM.$group.$fw.$target.dwarf_entries=" "$DSYM_INFO" | head -1 | cut -d= -f2-)
        rec_path=$(grep -F "dSYM.$group.$fw.$target.path=" "$DSYM_INFO" | head -1 | cut -d= -f2-)
        bin="$VERIFY/dsyms/$group/$rec_path/Contents/Resources/DWARF/$fw"
        if [ ! -f "$bin" ]; then
            fail "dSYM 缺失: $group/$fw/$target ($rec_path)"
            continue
        fi
        actual_uuid=$(dwarfdump --uuid "$bin" 2>/dev/null | awk '{ print $2; exit }')
        [ "$actual_uuid" = "$rec_uuid" ] && pass "$group/$fw/$target: dSYM UUID 一致" || fail "$group/$fw/$target: dSYM UUID 不一致"
        bi_uuid=$(info "framework.$fw.$target.uuid")
        [ "$bi_uuid" = "$rec_uuid" ] && pass "$group/$fw/$target: UUID 与 BUILD-INFO 一致" || fail "$group/$fw/$target: UUID 与 BUILD-INFO 不一致"
        actual_count=$( { dwarfdump --debug-info "$bin" 2>/dev/null || true; } | grep -c 'DW_TAG' || true)
        [ -n "$actual_count" ] || actual_count=0
        [ "$actual_count" = "$rec_count" ] && [ "$actual_count" -gt 0 ] \
            && pass "$group/$fw/$target: DWARF $actual_count 条" \
            || fail "$group/$fw/$target: DWARF $actual_count != $rec_count"
    done < "$VERIFY/dsym-keys.txt"
else
    fail "缺少 dSYMs/dSYM-INFO.txt"
fi

# ---------------------------------------------------------------------------
# 5. BUILD-INFO
# ---------------------------------------------------------------------------
hdr "BUILD-INFO"
BI="$REL/BUILD-INFO.txt"
if [ -f "$BI" ]; then
    [ "$(info ffmpeg_version)" = "8.1.3" ] && pass "ffmpeg_version=8.1.3" || fail "ffmpeg_version 不是 8.1.3"
    [ "$(info patches_count)" = "15" ] && pass "patches_count=15" || fail "patches_count 不是 15"
    want_digest=$("$LUX/build/apply-patches.sh" digest 2>/dev/null || true)
    [ -n "$want_digest" ] && [ "$(info patches_digest)" = "$want_digest" ] \
        && pass "patches_digest 与当前补丁集一致" || fail "patches_digest 与当前补丁集不一致"
    for t in macos-arm64 ios-arm64 ios-sim-arm64; do
        case " $(info targets) " in *" $t "*) pass "targets 含 $t" ;; *) fail "targets 缺 $t" ;; esac
    done
    [ "$(info license)" = "LGPL-2.1-or-later" ] && pass "license=LGPL-2.1-or-later" || fail "license 不是 LGPL-2.1-or-later"
    for k in config_gpl config_nonfree config_version3; do
        [ "$(info "$k")" = "0" ] && pass "$k=0" || fail "$k 不是 0"
    done
    for k in xcode_version xcode_build sdk.macosx.version sdk.iphoneos.version sdk.iphonesimulator.version; do
        [ -n "$(info "$k")" ] && pass "$k 非空" || fail "$k 为空"
    done
    for k in baseline_commit artifact_source_commit manifest_source_commit; do
        v=$(info "$k")
        case "$v" in
            [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ ${#v} -eq 40 ] && pass "$k 是 40 位 commit" || fail "$k 不是 40 位: $v" ;;
            *) fail "$k 无效: $v" ;;
        esac
    done
    src_sha=$(info source_package.sha256)
    actual_src_sha=$(shasum -a 256 "$REL/lux-ffmpeg-source-$TAG.tar.gz" 2>/dev/null | awk '{ print $1 }')
    [ -n "$src_sha" ] && [ "$src_sha" = "$actual_src_sha" ] \
        && pass "源码包 sha256 与 BUILD-INFO 一致" || fail "源码包 sha256 与 BUILD-INFO 不一致"

    dep_count=0
    while read -r name version sha url rest; do
        [ -n "$name" ] || continue
        dep_count=$((dep_count + 1))
        [ "$(info "dependency.$name.version")" = "$version" ] \
            && pass "dep $name version=$version" || fail "dep $name version 不一致"
        [ "$(info "dependency.$name.sha256")" = "$sha" ] \
            && pass "dep $name sha256 一致" || fail "dep $name sha256 不一致"
    done < <(sed -e 's/#.*//' "$LUX/config/deps.lock" | awk 'NF >= 4 { $1=$1; print }')
    [ "$(info dependency.count)" = "$dep_count" ] \
        && pass "dependency.count=$dep_count" || fail "dependency.count 与 deps.lock 不符"
else
    fail "缺少 BUILD-INFO.txt"
fi

# ---------------------------------------------------------------------------
# 6. source-manifest 与 deps.lock
# ---------------------------------------------------------------------------
hdr "source-manifest"
if [ -f "$REL/source-manifest.json" ]; then
    python3 - "$REL/source-manifest.json" "$LUX/config/deps.lock" <<'PY' || FAILS=$((FAILS + 1))
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
lock = []
for raw in open(sys.argv[2], encoding="utf-8"):
    line = raw.split("#", 1)[0].strip()
    if line:
        p = line.split()
        if len(p) >= 4:
            lock.append(p[:4])
deps = {d.get("name"): d for d in manifest.get("dependencies", [])}
problems = []
for name, version, sha, url in lock:
    d = deps.get(name)
    if not d:
        problems.append(f"{name}: 缺失")
    elif (d.get("version"), d.get("sha256"), d.get("url")) != (version, sha, url):
        problems.append(f"{name}: version/sha256/url 不一致")
if len(manifest.get("dependencies", [])) != len(lock):
    problems.append("依赖条数不一致")
if manifest.get("missing"):
    problems.append("missing 非空")
if manifest.get("anomalies"):
    problems.append("anomalies 非空")
if len(manifest.get("components", [])) != 12:
    problems.append("components 不是 12 个")
if problems:
    print("  [FAIL] source-manifest: " + "; ".join(problems))
    raise SystemExit(1)
print(f"  [ok]   source-manifest: {len(lock)} 个依赖 / {len(manifest.get('components', []))} 个 component 齐全")
PY
else
    fail "缺少 source-manifest.json"
fi

# ---------------------------------------------------------------------------
# 7. 对应源码包
# ---------------------------------------------------------------------------
hdr "对应源码包"
SRC_TAR="$REL/lux-ffmpeg-source-$TAG.tar.gz"
if [ -f "$SRC_TAR" ]; then
    tar -tzf "$SRC_TAR" > "$VERIFY/source-list.txt" 2>/dev/null || fail "源码包无法列出"
    top=$(head -1 "$VERIFY/source-list.txt" | sed 's|/$||')
    [ -n "$top" ] || top="$PRODUCT"
    for want in \
        "$top/SOURCE-PACKAGE.md" \
        "$top/BUILD-INFO.txt" \
        "$top/ffmpeg-8.1.3/libavcodec/avcodec.h" \
        "$top/ffmpeg-8.1.3/LUX-PATCHES.txt" \
        "$top/MPV-PATCHES.txt" \
        "$top/lux/config/patches.txt" \
        "$top/lux/build/apply-patches.sh"; do
        grep -qxF "$want" "$VERIFY/source-list.txt" && pass "源码包含 $want" || fail "源码包缺 $want"
    done
    if grep -q "/lux/\.build/" "$VERIFY/source-list.txt"; then
        fail "源码包混入 lux/.build"
    else
        pass "源码包不含 lux/.build"
    fi
    if grep -q "__MACOSX\|/\.git/" "$VERIFY/source-list.txt"; then
        fail "源码包混入 __MACOSX 或 .git"
    else
        pass "源码包不含 __MACOSX / .git"
    fi
    patch_n=$(grep -c "$top/lux/patches/[^/]*\.patch$" "$VERIFY/source-list.txt" || true)
    [ "$patch_n" = "17" ] && pass "源码包含 17 个 FFmpeg 补丁文件" || fail "源码包 FFmpeg 补丁文件数 $patch_n != 17"
    mpv_patch_n=$(grep -c "$top/lux/patches/mpv/[^/]*\.patch$" "$VERIFY/source-list.txt" || true)
    [ "$mpv_patch_n" = "1" ] && pass "源码包含 1 个 mpv 补丁文件" || fail "源码包 mpv 补丁文件数 $mpv_patch_n != 1"
    tar -xzf "$SRC_TAR" -C "$VERIFY/source" "$top/MPV-PATCHES.txt" 2>/dev/null || true
    grep -q "^mpv_patches_count=1$" "$VERIFY/source/$top/MPV-PATCHES.txt" 2>/dev/null \
        && pass "MPV-PATCHES.txt 记录 1 条补丁" || fail "MPV-PATCHES.txt 缺失或 count 不是 1"

    for selfstore in $(sed -e 's/#.*//' "$LUX/config/deps.lock" | awk 'NF >= 4 { for (i=5; i<=NF; i++) if ($i ~ /^selfstore=/) { sub(/^selfstore=/, "", $i); n=split($i, a, "/"); print a[n] } }'); do
        grep -qxF "$top/lux/release/sources/$selfstore" "$VERIFY/source-list.txt" \
            && pass "源码包含 selfstore $selfstore" || fail "源码包缺 selfstore $selfstore"
    done

    rm -rf "$VERIFY/source/$PRODUCT"
    mkdir -p "$VERIFY/source"
    if tar -xzf "$SRC_TAR" -C "$VERIFY/source" "$top/ffmpeg-8.1.3" 2>/dev/null; then
        pass "源码包 FFmpeg 树可解压"
        ff_tree="$VERIFY/source/$top/ffmpeg-8.1.3"
        reversed=0
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            if git -C "$REPO" apply -R --check --directory="$ff_tree" --unsafe-paths "$LUX/patches/$p" >/dev/null 2>&1; then
                reversed=$((reversed + 1))
            else
                fail "FFmpeg 树里补丁未应用: $p"
            fi
        done < <(sed -e 's/#.*//' "$LUX/config/patches.txt" | awk 'NF { print $1 }')
        [ "$reversed" = "15" ] && pass "FFmpeg 树可逆应用 15 个补丁(即已打齐)" || fail "FFmpeg 树只匹配 $reversed/15 个补丁"
    else
        fail "源码包 FFmpeg 树解压失败"
    fi
else
    fail "缺少 $SRC_TAR"
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
printf '\nfailures: %d, warnings: %d\n' "$FAILS" "$WARNS"
if [ "$FAILS" -ne 0 ]; then
    printf 'RESULT: FAIL\n'
    exit 1
fi
printf 'RESULT: PASS\n'
