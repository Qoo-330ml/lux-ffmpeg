#!/usr/bin/env bash
#
# lux/build/make-release-package.sh — 生成可分发、可复原、可校验的 F2 发布包
#
#   ./lux/build/make-release-package.sh
#   LUX_RELEASE_TAG=f2-20261110 ./lux/build/make-release-package.sh
#   LUX_ARTIFACT_BUILD=/path/to/lux/.build ./lux/build/make-release-package.sh
#   LUX_RELEASE_OUT=/path/to/release/lux-ffmpeg-f2-20261110 ./lux/build/make-release-package.sh
#
# 输入(只读):
#   $LUX_ARTIFACT_BUILD/xcframeworks/          FFmpeg 6 个 xcframework zip + checksums.txt + dSYMs.zip
#   $LUX_ARTIFACT_BUILD/mpv-xcframeworks/      mpv 栈 4 个 xcframework zip + checksums.txt + dSYMs.zip
#   lux/release/licenses/, NOTICE.md, source-manifest.json
#   lux/config/deps.lock, lux/patches/, lux/config/patches.txt
#   lux/release/sources/                       自存依赖源码包(gitignored)
#   $LUX_ARTIFACT_BUILD/deps/src/              构建缓存里的其余锁定源码包(可选,用于补齐 URL-only 条目)
#   ../../COPYING.*                            仓库根目录的 LGPL/GPL 文本
#
# 输出:
#   $LUX_RELEASE_OUT/lux-ffmpeg-<tag>/
#     xcframeworks/*.zip + checksums.txt
#     dSYMs/FFmpeg-dSYMs.zip, MPV-dSYMs.zip, dSYM-INFO.txt
#     BUILD-INFO.txt, COPYING.*, LICENSE.md, NOTICE.md, source-manifest.json, SOURCE-PACKAGE.md
#     lux-ffmpeg-source-<tag>.tar.gz
#     SHA256SUMS
#
# 设计:
#   * 幂等:先删除旧输出目录再重建;不修改任何输入。
#   * 源码包里的 FFmpeg 树由 `git archive` 的基线树 + 13 个补丁生成,不需要在
#     工作区里 apply/revert;补丁应用结果与 apply-patches.sh 的补丁集一致。
#   * 输出默认落在主检出的 lux/.build/release/(worktree 场景),日志写本 worktree
#     的 lux/.build/logs/。所有临时文件都在 lux/.build/release-work/ 内。
#   * 不 push、不打 tag、不发布 release。
set -euo pipefail

if [ -n "${GIT_CONFIG_COUNT:-}" ] && [ -z "${GIT_CONFIG_KEY_0:-}" ]; then
    # 某些 CI/沙箱会设置不完整的 GIT_CONFIG_COUNT,git 在解析前就失败。
    unset GIT_CONFIG_COUNT GIT_CONFIG_VALUE_0
fi

HERE=$(cd "$(dirname "$0")" && pwd)
LUX=$(cd "$HERE/.." && pwd)
REPO=$(cd "$LUX/.." && pwd)

TAG=${LUX_RELEASE_TAG:-f2-20261110}
PRODUCT="lux-ffmpeg-$TAG"
SOURCE_TAR="lux-ffmpeg-source-$TAG.tar.gz"

die() { printf '\n[release] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[release] %s\n' "$*"; }
gitx() { git -C "$REPO" "$@"; }

# 主检出(第一个 worktree)。worktree 场景下 xcframeworks / sources 通常只在主检出里。
MAIN_WORKTREE=$(gitx worktree list --porcelain 2>/dev/null |
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
        die "找不到 xcframeworks;用 LUX_ARTIFACT_BUILD=<主检出>/lux/.build 指定"
    fi
fi
BUILD=$(cd "$BUILD" && pwd)
[ -d "$BUILD/xcframeworks" ] || die "缺少 $BUILD/xcframeworks"
[ -d "$BUILD/mpv-xcframeworks" ] || die "缺少 $BUILD/mpv-xcframeworks"

OUT=${LUX_RELEASE_OUT:-$BUILD/release/$PRODUCT}
case "$OUT" in
    */"$PRODUCT") ;;
    *) die "输出目录必须以 /$PRODUCT 结尾(当前: $OUT)" ;;
esac
[ -n "$OUT" ] && [ "$OUT" != "/" ] || die "拒绝使用空输出目录"

SOURCES=${LUX_RELEASE_SOURCES:-$REPO/lux/release/sources}
if [ ! -d "$SOURCES" ] && [ -d "$MAIN_WORKTREE/lux/release/sources" ]; then
    SOURCES="$MAIN_WORKTREE/lux/release/sources"
fi

FF_XCF="$BUILD/xcframeworks"
MPV_XCF="$BUILD/mpv-xcframeworks"
WORK="$REPO/lux/.build/release-work"
STAGE="$WORK/source/$PRODUCT"
LOG_DIR="$REPO/lux/.build/logs"
mkdir -p "$LOG_DIR" "$WORK"
LOG="$LOG_DIR/release-package-$(date '+%Y%m%d-%H%M%S').log"
exec > >(tee "$LOG") 2>&1

log "release: $PRODUCT"
log "repo: $REPO"
log "artifacts: $BUILD"
log "output: $OUT"
log "log: $LOG"

# ---------------------------------------------------------------------------
# 0. 输入与元数据
# ---------------------------------------------------------------------------
FF_FRAMEWORKS="Libavcodec Libavformat Libavfilter Libswscale Libswresample Libavutil"
MPV_FRAMEWORKS="Libmpv Libplacebo Libfribidi Libuchardet"
TARGETS="macos-arm64 ios-arm64 ios-sim-arm64"

for fw in $FF_FRAMEWORKS; do
    [ -f "$FF_XCF/$fw.xcframework.zip" ] || die "缺少 $FF_XCF/$fw.xcframework.zip"
done
for fw in $MPV_FRAMEWORKS; do
    [ -f "$MPV_XCF/$fw.xcframework.zip" ] || die "缺少 $MPV_XCF/$fw.xcframework.zip"
done
[ -f "$FF_XCF/checksums.txt" ] || die "缺少 $FF_XCF/checksums.txt"
[ -f "$MPV_XCF/checksums.txt" ] || die "缺少 $MPV_XCF/checksums.txt"
[ -f "$FF_XCF/dSYMs.zip" ] || die "缺少 $FF_XCF/dSYMs.zip"
[ -f "$MPV_XCF/dSYMs.zip" ] || die "缺少 $MPV_XCF/dSYMs.zip"
[ -f "$LUX/release/NOTICE.md" ] || die "缺少 lux/release/NOTICE.md"
[ -f "$LUX/release/source-manifest.json" ] || die "缺少 lux/release/source-manifest.json"
[ -d "$LUX/release/licenses" ] || die "缺少 lux/release/licenses/"
[ -f "$LUX/config/deps.lock" ] || die "缺少 lux/config/deps.lock"
[ -d "$LUX/patches" ] || die "缺少 lux/patches/"
[ -f "$REPO/COPYING.LGPLv2.1" ] || die "缺少仓库根目录 COPYING.LGPLv2.1"

PATCH_COUNT=$("$LUX/build/apply-patches.sh" count) || die "无法读取补丁条数"
PATCH_DIGEST=$("$LUX/build/apply-patches.sh" digest) || die "无法读取补丁集 digest"
[ "$PATCH_COUNT" = "13" ] || die "补丁条数是 $PATCH_COUNT,期望 13"
PATCH_LIST_SHA=$(shasum -a 256 "$LUX/config/patches.txt" | awk '{ print $1 }')
CONFIG_SHA=$(shasum -a 256 "$LUX/config/ffmpeg-ios.conf" | awk '{ print $1 }')

if gitx rev-parse --verify --quiet p1-allowlist >/dev/null; then
    BASELINE_COMMIT=$(gitx rev-parse p1-allowlist)
    BASELINE_REF="p1-allowlist"
else
    BASELINE_COMMIT=$(gitx rev-parse HEAD)
    BASELINE_REF=$(gitx rev-parse --abbrev-ref HEAD)
fi
BASELINE_SUBJECT=$(gitx show -s --format=%s "$BASELINE_COMMIT")
BASELINE_DATE=$(gitx show -s --format=%cI "$BASELINE_COMMIT")
PACKAGING_BRANCH=$(gitx rev-parse --abbrev-ref HEAD)
PACKAGING_COMMIT=$(gitx rev-parse HEAD)

FFMPEG_VERSION=$(cat "$REPO/VERSION")
FFMPEG_BASELINE=$(sed -n 's/^baseline=//p' "$BUILD/macos-arm64/BUILD-INFO.txt" | head -1)
[ -n "$FFMPEG_BASELINE" ] || FFMPEG_BASELINE="jellyfin-ffmpeg v${FFMPEG_VERSION}-2 (FFmpeg ${FFMPEG_VERSION})"

# 先整体捕获输出再解析:awk 提前 exit 会让 xcodebuild 收到 SIGPIPE,pipefail 下整个脚本以 141 退出
XCODE_INFO=$(xcodebuild -version 2>/dev/null || true)
XCODE_VERSION=$(printf '%s\n' "$XCODE_INFO" | awk '/^Xcode / { print $2; exit }')
XCODE_BUILD=$(printf '%s\n' "$XCODE_INFO" | awk '/^Build version/ { print $3; exit }')
SDK_MACOS=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)
SDK_MACOS_BUILD=$(xcrun --sdk macosx --show-sdk-build-version 2>/dev/null || true)
SDK_IOS=$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)
SDK_IOS_BUILD=$(xcrun --sdk iphoneos --show-sdk-build-version 2>/dev/null || true)
SDK_IOSSIM=$(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null || true)
SDK_IOSSIM_BUILD=$(xcrun --sdk iphonesimulator --show-sdk-build-version 2>/dev/null || true)
[ -n "$XCODE_VERSION" ] || die "xcodebuild -version 失败"
[ -n "$SDK_IOS" ] || die "找不到 iphoneos SDK"

FF_MTIME=$(date -u -r "$(stat -f %m "$FF_XCF/Libavcodec.xcframework.zip")" '+%Y-%m-%dT%H:%M:%SZ')
MPV_MTIME=$(date -u -r "$(stat -f %m "$MPV_XCF/Libmpv.xcframework.zip")" '+%Y-%m-%dT%H:%M:%SZ')
MPV_BUILT_AT=$(sed -n 's/^built_at=//p' "$MPV_XCF/MPV-XCFRAMEWORK-INFO.txt" | head -1)
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# 产物源码 commit:构建时间点之前最后一个触及非 lux 源码的提交。manifest 里的
# repository.head_commit 是清单生成时的 HEAD,两者都要记录,避免把打包提交
# 误当成产物源码。
MANIFEST_SOURCE_COMMIT=$(python3 - "$LUX/release/source-manifest.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    print(d.get("repository", {}).get("head_commit", ""))
except Exception:
    print("")
PY
)
case "$MANIFEST_SOURCE_COMMIT" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) die "source-manifest.json 里的 repository.head_commit 无效" ;;
esac
[ ${#MANIFEST_SOURCE_COMMIT} -eq 40 ] || die "manifest source commit 不是 40 位: $MANIFEST_SOURCE_COMMIT"

# 产物源码 commit:FFmpeg zip 的 mtime 之前最后一个提交。构建日志与 zip 时间都在
# a54c1fa(2026-11-10 18:42)之后、P2 冒烟提交之前;清单里的 head_commit 是清单
# 生成时的 HEAD(旧清单 e8c0961 早于 D3 的 OpenSSL/zlib,已过期),不能拿来当
# 产物来源。另记录构建时间点之前最后一个非 lux 源码提交,便于核对 FFmpeg 树内容。
ARTIFACT_SOURCE_COMMIT=$(gitx log -1 --format=%H --before="$FF_MTIME" HEAD 2>/dev/null || true)
[ ${#ARTIFACT_SOURCE_COMMIT} -eq 40 ] || ARTIFACT_SOURCE_COMMIT=$MANIFEST_SOURCE_COMMIT
case "$ARTIFACT_SOURCE_COMMIT" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) die "artifact source commit 无效: $ARTIFACT_SOURCE_COMMIT" ;;
esac
ARTIFACT_SOURCE_SUBJECT=$(gitx show -s --format=%s "$ARTIFACT_SOURCE_COMMIT" 2>/dev/null || true)
FFMPEG_SOURCE_COMMIT=$(gitx log -1 --format=%H --before="$MPV_BUILT_AT" -- . ':(exclude)lux' 2>/dev/null || true)
[ ${#FFMPEG_SOURCE_COMMIT} -eq 40 ] || FFMPEG_SOURCE_COMMIT=$ARTIFACT_SOURCE_COMMIT

# ---------------------------------------------------------------------------
# 1. 目录与 xcframework zip / checksums
# ---------------------------------------------------------------------------
rm -rf "$OUT"
mkdir -p "$OUT/xcframeworks" "$OUT/dSYMs" "$OUT/licenses"
rm -rf "$STAGE"
mkdir -p "$STAGE"

check_source_checksum() { # $1=checksums file, $2=zip name, $3=zip path
    local expected actual
    expected=$(awk -v n="$2" '$2 == n { print $1; exit }' "$1")
    [ -n "$expected" ] || die "$1 没有 $2 的校验和"
    actual=$(shasum -a 256 "$3" | awk '{ print $1 }')
    [ "$actual" = "$expected" ] || die "$3 的 sha256 与 $1 不一致"
}

log "复制 xcframework zip"
for fw in $FF_FRAMEWORKS; do
    check_source_checksum "$FF_XCF/checksums.txt" "$fw.xcframework.zip" "$FF_XCF/$fw.xcframework.zip"
    cp -p "$FF_XCF/$fw.xcframework.zip" "$OUT/xcframeworks/"
done
for fw in $MPV_FRAMEWORKS; do
    check_source_checksum "$MPV_XCF/checksums.txt" "$fw.xcframework.zip" "$MPV_XCF/$fw.xcframework.zip"
    cp -p "$MPV_XCF/$fw.xcframework.zip" "$OUT/xcframeworks/"
done

{
    for fw in $FF_FRAMEWORKS $MPV_FRAMEWORKS; do
        shasum -a 256 "$OUT/xcframeworks/$fw.xcframework.zip" |
            awk -v n="$fw.xcframework.zip" '{ print $1 "  " n }'
    done
} | LC_ALL=C sort -k2,2 > "$OUT/xcframeworks/checksums.txt"
[ "$(wc -l < "$OUT/xcframeworks/checksums.txt" | tr -d ' ')" = "10" ] || die "合并后的 checksums.txt 不是 10 行"
log "checksums.txt: 10 个 zip"

# ---------------------------------------------------------------------------
# 2. dSYM + dSYM-INFO / framework UUID
# ---------------------------------------------------------------------------
cp -p "$FF_XCF/dSYMs.zip" "$OUT/dSYMs/FFmpeg-dSYMs.zip"
cp -p "$MPV_XCF/dSYMs.zip" "$OUT/dSYMs/MPV-dSYMs.zip"

META="$WORK/framework-meta.txt"
: > "$META"

slice_id() { # target -> xcframework LibraryIdentifier
    case "$1" in
        macos-arm64) echo "macos-arm64" ;;
        ios-arm64) echo "ios-arm64" ;;
        ios-sim-arm64) echo "ios-arm64-simulator" ;;
        *) return 1 ;;
    esac
}

collect_dsyms() { # $1=group $2=dsym-root $3=xcf-root $4=frameworks
    local group=$1 root=$2 xcf=$3 frameworks=$4 target fw slice dsym_bin fw_bin uuid fw_uuid count
    for target in $TARGETS; do
        slice=$(slice_id "$target") || die "未知 target $target"
        for fw in $frameworks; do
            dsym_bin="$root/$target/$fw.framework.dSYM/Contents/Resources/DWARF/$fw"
            [ -f "$dsym_bin" ] || die "缺少 dSYM: $dsym_bin"
            fw_bin="$xcf/$fw.xcframework/$slice/$fw.framework/$fw"
            [ -f "$fw_bin" ] || die "缺少 framework 二进制: $fw_bin"
            dwarf_uuid_out=$(dwarfdump --uuid "$dsym_bin" 2>/dev/null || true)
            uuid=$(printf '%s\n' "$dwarf_uuid_out" | awk '{ print $2; exit }')
            fw_uuid=$(dwarfdump --uuid "$fw_bin" 2>/dev/null | awk '{ print $2; exit }')
            [ -n "$uuid" ] || die "读不到 dSYM UUID: $dsym_bin"
            [ "$uuid" = "$fw_uuid" ] || die "$group/$fw/$target UUID 不一致: dSYM=$uuid binary=$fw_uuid"
            count=$( { dwarfdump --debug-info "$dsym_bin" 2>/dev/null || true; } | grep -c 'DW_TAG' || true)
            [ -n "$count" ] || count=0
            [ "$count" -gt 0 ] || die "$group/$fw/$target 的 DWARF 没有 DW_TAG"
            printf '%s|%s|%s|%s|%s|%s|dSYMs/%s/%s.framework.dSYM\n' \
                "$group" "$fw" "$target" "$slice" "$uuid" "$count" "$target" "$fw" >> "$META"
        done
    done
}

log "收集 dSYM UUID / DWARF 条目"
collect_dsyms FFmpeg "$FF_XCF/dSYMs" "$FF_XCF" "$FF_FRAMEWORKS"
collect_dsyms MPV "$MPV_XCF/dSYMs" "$MPV_XCF" "$MPV_FRAMEWORKS"

{
    printf 'generated_at=%s\n' "$NOW"
    printf 'groups=FFmpeg,MPV\n'
    printf 'targets=%s\n' "$TARGETS"
    printf 'ffmpeg_dSYMs.zip.sha256=%s\n' "$(shasum -a 256 "$OUT/dSYMs/FFmpeg-dSYMs.zip" | awk '{ print $1 }')"
    printf 'mpv_dSYMs.zip.sha256=%s\n' "$(shasum -a 256 "$OUT/dSYMs/MPV-dSYMs.zip" | awk '{ print $1 }')"
    printf '# 每个 framework 的 dSYM UUID 与 DWARF 条目数(grep -c DW_TAG,经 dwarfdump 展开)\n'
    while IFS='|' read -r group fw target slice uuid count rel; do
        printf 'dSYM.%s.%s.%s.uuid=%s\n' "$group" "$fw" "$target" "$uuid"
        printf 'dSYM.%s.%s.%s.dwarf_entries=%s\n' "$group" "$fw" "$target" "$count"
        printf 'dSYM.%s.%s.%s.path=%s\n' "$group" "$fw" "$target" "$rel"
    done < "$META"
} > "$OUT/dSYMs/dSYM-INFO.txt"
log "dSYM-INFO: $(wc -l < "$OUT/dSYMs/dSYM-INFO.txt" | tr -d ' ') 行"

# ---------------------------------------------------------------------------
# 3. BUILD-INFO.txt
# ---------------------------------------------------------------------------
{
    printf 'release_tag=%s\n' "$TAG"
    printf 'product=%s\n' "$PRODUCT"
    printf 'ffmpeg_version=%s\n' "$FFMPEG_VERSION"
    printf 'ffmpeg_baseline=%s\n' "$FFMPEG_BASELINE"
    printf 'patches_count=%s\n' "$PATCH_COUNT"
    printf 'patches_digest=%s\n' "$PATCH_DIGEST"
    printf 'patches_txt_sha256=%s\n' "$PATCH_LIST_SHA"
    printf 'configure_sha256=%s\n' "$CONFIG_SHA"
    printf 'configure_file=lux/config/ffmpeg-ios.conf\n'
    printf 'targets=%s\n' "$TARGETS"
    printf 'xcode_version=%s\n' "$XCODE_VERSION"
    printf 'xcode_build=%s\n' "$XCODE_BUILD"
    printf 'sdk.macosx.version=%s\n' "$SDK_MACOS"
    printf 'sdk.macosx.build=%s\n' "$SDK_MACOS_BUILD"
    printf 'sdk.iphoneos.version=%s\n' "$SDK_IOS"
    printf 'sdk.iphoneos.build=%s\n' "$SDK_IOS_BUILD"
    printf 'sdk.iphonesimulator.version=%s\n' "$SDK_IOSSIM"
    printf 'sdk.iphonesimulator.build=%s\n' "$SDK_IOSSIM_BUILD"
    printf 'license=LGPL-2.1-or-later\n'
    printf 'config_gpl=0\n'
    printf 'config_nonfree=0\n'
    printf 'config_version3=0\n'
    printf 'baseline_ref=%s\n' "$BASELINE_REF"
    printf 'baseline_commit=%s\n' "$BASELINE_COMMIT"
    printf 'baseline_commit_subject=%s\n' "$BASELINE_SUBJECT"
    printf 'baseline_commit_date=%s\n' "$BASELINE_DATE"
    printf 'manifest_source_commit=%s\n' "$MANIFEST_SOURCE_COMMIT"
    printf 'artifact_source_commit=%s\n' "$ARTIFACT_SOURCE_COMMIT"
    printf 'artifact_source_commit_subject=%s\n' "$ARTIFACT_SOURCE_SUBJECT"
    printf 'artifact_source_note=%s\n' 'nearest commit before FFmpeg zip mtime; build tree may include uncommitted script fixes'
    printf 'ffmpeg_source_commit=%s\n' "$FFMPEG_SOURCE_COMMIT"
    printf 'packaging_branch=%s\n' "$PACKAGING_BRANCH"
    printf 'packaging_commit=%s\n' "$PACKAGING_COMMIT"
    printf 'ffmpeg_artifacts_mtime=%s\n' "$FF_MTIME"
    printf 'mpv_artifacts_mtime=%s\n' "$MPV_MTIME"
    printf 'mpv_built_at=%s\n' "$MPV_BUILT_AT"
    printf 'package_built_at=%s\n' "$NOW"
    printf 'checksums=%s\n' "xcframeworks/checksums.txt"
    while IFS='|' read -r group fw target slice uuid count rel; do
        printf 'framework.%s.%s.uuid=%s\n' "$fw" "$target" "$uuid"
        printf 'framework.%s.%s.dwarf_entries=%s\n' "$fw" "$target" "$count"
        printf 'framework.%s.%s.slice=%s\n' "$fw" "$target" "$slice"
        printf 'framework.%s.%s.dSYM=%s\n' "$fw" "$target" "$rel"
    done < "$META"
} > "$OUT/BUILD-INFO.txt"

# 依赖版本 / sha256(全部取自 deps.lock,含构建期/头文件依赖)
DEP_COUNT=0
{
    printf 'dependencies_source=lux/config/deps.lock\n'
    while read -r name version sha url rest; do
        [ -n "$name" ] || continue
        DEP_COUNT=$((DEP_COUNT + 1))
        printf 'dependency.%s.version=%s\n' "$name" "$version"
        printf 'dependency.%s.sha256=%s\n' "$name" "$sha"
        printf 'dependency.%s.url=%s\n' "$name" "$url"
        selfstore=$(printf '%s\n' "$rest" | tr ' ' '\n' | sed -n 's/^selfstore=//p')
        if [ -n "$selfstore" ]; then
            printf 'dependency.%s.selfstore=%s\n' "$name" "$selfstore"
        fi
    done < <(sed -e 's/#.*//' "$LUX/config/deps.lock" | awk 'NF >= 4 { $1=$1; print }')
} >> "$OUT/BUILD-INFO.txt"
printf 'dependency.count=%s\n' "$DEP_COUNT" >> "$OUT/BUILD-INFO.txt"
[ "$DEP_COUNT" -gt 0 ] || die "deps.lock 没有依赖"

# ---------------------------------------------------------------------------
# 4. 许可文本 / NOTICE / source-manifest
# ---------------------------------------------------------------------------
log "复制许可文本"
for f in COPYING.GPLv2 COPYING.GPLv3 COPYING.LGPLv2.1 COPYING.LGPLv3 LICENSE.md; do
    [ -f "$REPO/$f" ] && cp -p "$REPO/$f" "$OUT/$f"
done
# 随包许可文本(按组件分目录,保留 licenses/ 的层级)
( cd "$LUX/release" && tar --no-mac-metadata --no-xattrs -cf - licenses ) |
    tar --no-mac-metadata --no-xattrs -xf - -C "$OUT"
cp -p "$LUX/release/NOTICE.md" "$OUT/NOTICE.md"
cp -p "$LUX/release/source-manifest.json" "$OUT/source-manifest.json"

# 校对 source-manifest:每个 deps.lock 条目的来源、版本、sha256 必须齐全;
# components 必须覆盖 10 个 framework;不得有 missing/anomalies。
proofread_manifest() {
    python3 - "$OUT/source-manifest.json" "$LUX/config/deps.lock" "$OUT/BUILD-INFO.txt" <<'PY'
import json
import re
import sys

manifest_path, lock_path, build_info_path = sys.argv[1:4]
manifest = json.load(open(manifest_path, encoding="utf-8"))
lock = []
for lineno, raw in enumerate(open(lock_path, encoding="utf-8"), 1):
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    parts = line.split()
    if len(parts) < 4:
        raise SystemExit(f"deps.lock:{lineno}: 字段不足")
    lock.append({"name": parts[0], "version": parts[1], "sha256": parts[2], "url": parts[3]})

deps = manifest.get("dependencies") or []
by_name = {d.get("name"): d for d in deps}
missing = []
for dep in lock:
    got = by_name.get(dep["name"])
    if not got:
        missing.append(f"{dep['name']}: 清单缺失")
        continue
    for key in ("version", "sha256", "url"):
        if got.get(key) != dep[key]:
            missing.append(f"{dep['name']}: {key} 不一致 ({got.get(key)!r} != {dep[key]!r})")
    if not got.get("archive") and not dep.get("url"):
        missing.append(f"{dep['name']}: 没有来源(archive/url)")
if len(deps) != len(lock):
    missing.append(f"依赖条数 {len(deps)} != deps.lock {len(lock)}")
if manifest.get("missing"):
    missing.append(f"manifest.missing 非空: {manifest['missing']}")
if manifest.get("anomalies"):
    missing.append(f"manifest.anomalies 非空: {manifest['anomalies']}")

expected_components = {
    "Libavcodec", "Libavformat", "Libavfilter", "Libswscale", "Libswresample", "Libavutil",
    "Libmpv", "Libplacebo", "Libfribidi", "Libuchardet",
}
components = {c.get("name"): c for c in (manifest.get("components") or [])}
if set(components) != expected_components:
    missing.append(f"components 集合不符: {sorted(components)}")
for name, comp in components.items():
    if not comp.get("license_files"):
        missing.append(f"{name}: 没有 license_files")
    if set((comp.get("targets") or {})) != {"macos-arm64", "ios-arm64", "ios-sim-arm64"}:
        missing.append(f"{name}: targets 不是三个切片")
    if not comp.get("source_dependency"):
        missing.append(f"{name}: 没有 source_dependency")

info = {}
for raw in open(build_info_path, encoding="utf-8"):
    raw = raw.rstrip("\n")
    if "=" in raw and not raw.startswith("#"):
        k, v = raw.split("=", 1)
        info[k] = v
ff = manifest.get("ffmpeg", {}).get("source", {})
if ff.get("patches_count") != 13:
    missing.append(f"manifest.ffmpeg.patches_count={ff.get('patches_count')} != 13")
if ff.get("patches_digest") != info.get("patches_digest"):
    missing.append("manifest.ffmpeg.patches_digest 与 BUILD-INFO 不一致")
if ff.get("patches_txt_sha256") != info.get("patches_txt_sha256"):
    missing.append("manifest.ffmpeg.patches_txt_sha256 与 BUILD-INFO 不一致")
if ff.get("configure_sha256") != info.get("configure_sha256"):
    missing.append("manifest.ffmpeg.configure_sha256 与 BUILD-INFO 不一致")

if missing:
    print("source-manifest 校对失败:")
    for item in missing:
        print(f"  - {item}")
    raise SystemExit(1)
print(f"source-manifest 校对通过: {len(deps)} 个依赖, {len(components)} 个 component")
PY
}
proofread_manifest || die "source-manifest.json 校对失败"

# ---------------------------------------------------------------------------
# 5. 对应源码包(lux/ + 自存/缓存源码 + 已打补丁的 FFmpeg 树)
# ---------------------------------------------------------------------------
log "准备对应源码包"
mkdir -p "$STAGE/lux/release/sources"
# lux/ 全部内容,排除 .build 与 release/sources(源码包在下面单独写入)
rsync -a \
    --exclude='.build' \
    --exclude='release/sources' \
    --exclude='.DS_Store' \
    "$LUX/" "$STAGE/lux/"

# 建立 sha256 -> 文件索引(自存目录优先,其次构建缓存)
INDEX="$WORK/source-index.txt"
: > "$INDEX"
if [ -d "$SOURCES" ]; then
    for f in "$SOURCES"/*; do
        [ -f "$f" ] || continue
        case "$f" in *.tar.gz|*.tar.xz|*.tgz|*.zip) ;; *) continue ;; esac
        printf '%s  %s\n' "$(shasum -a 256 "$f" | awk '{ print $1 }')" "$f" >> "$INDEX"
    done
fi
if [ -d "$BUILD/deps/src" ]; then
    for f in "$BUILD/deps/src"/*; do
        [ -f "$f" ] || continue
        case "$f" in *.tar.gz|*.tar.xz|*.tgz|*.zip) ;; *) continue ;; esac
        printf '%s  %s\n' "$(shasum -a 256 "$f" | awk '{ print $1 }')" "$f" >> "$INDEX"
    done
fi

ARCHIVES="$WORK/source-archives.txt"
: > "$ARCHIVES"
INCLUDED=0
SELFSTORE_COUNT=0
EXTRA_COUNT=0
MISSING_ARCHIVES=""
while read -r name version sha url rest; do
    [ -n "$name" ] || continue
    selfstore=$(printf '%s\n' "$rest" | tr ' ' '\n' | sed -n 's/^selfstore=//p')
    archive=$(awk -v s="$sha" '$1 == s { print $2; exit }' "$INDEX")
    if [ -z "$archive" ]; then
        if [ -n "$selfstore" ]; then
            die "$name 的 selfstore 源码包缺失或 sha256 不符: $selfstore"
        fi
        MISSING_ARCHIVES="$MISSING_ARCHIVES $name"
        continue
    fi
    base=$(basename "$archive")
    cp -p "$archive" "$STAGE/lux/release/sources/$base"
    INCLUDED=$((INCLUDED + 1))
    if [ -n "$selfstore" ]; then
        origin="selfstore"
        SELFSTORE_COUNT=$((SELFSTORE_COUNT + 1))
    else
        origin="deps-cache"
        EXTRA_COUNT=$((EXTRA_COUNT + 1))
    fi
    printf '%s|%s|%s|%s|%s|%s\n' "$name" "$version" "$sha" "$base" "$origin" "$url" >> "$ARCHIVES"
done < <(sed -e 's/#.*//' "$LUX/config/deps.lock" | awk 'NF >= 4 { $1=$1; print }')

[ "$INCLUDED" -gt 0 ] || die "源码包一个依赖都没找到"
[ -z "$MISSING_ARCHIVES" ] || log "WARN: 以下 URL-only 依赖没有本地源码(不随包):$MISSING_ARCHIVES"

# 源码包内的来源索引,方便复原时逐个核对
{
    printf '# 对应源码包内的依赖源码(sha256 为 deps.lock 锁定值)\n'
    printf '# origin=selfstore 表示来自仓库 lux/release/sources/(gitignored);deps-cache 表示来自构建缓存\n'
    printf '# name\tversion\tsha256\tfile\torigin\turl\n'
    cat "$ARCHIVES"
} > "$STAGE/lux/release/sources/SOURCES-INDEX.txt"

# FFmpeg 基线树:只取 FFmpeg 源码路径,排除 lux / CI / jellyfin 打包目录
FF_PATHS=""
while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
        lux|.github|.forgejo|.DS_Store|build|builder|build.yaml|build-linux-*|build-windows-*|debian|docker-build*|msys2|cross-*.meson|toolchain-*.cmake)
            continue ;;
    esac
    FF_PATHS="$FF_PATHS $p"
done < <(gitx ls-tree --name-only HEAD)
mkdir -p "$STAGE/ffmpeg-$FFMPEG_VERSION"
# shellcheck disable=SC2086
gitx archive --format=tar HEAD -- $FF_PATHS | tar --no-mac-metadata --no-xattrs -xf - -C "$STAGE/ffmpeg-$FFMPEG_VERSION"

PATCHED_LIST="$STAGE/ffmpeg-$FFMPEG_VERSION/LUX-PATCHES.txt"
{
    printf 'ffmpeg_version=%s\n' "$FFMPEG_VERSION"
    printf 'baseline=%s\n' "$FFMPEG_BASELINE"
    printf 'baseline_commit=%s\n' "$BASELINE_COMMIT"
    printf 'patches_count=%s\n' "$PATCH_COUNT"
    printf 'patches_digest=%s\n' "$PATCH_DIGEST"
    printf '# 由 lux/build/make-release-package.sh 从 git archive 基线树 + lux/patches/ 生成\n'
} > "$PATCHED_LIST"
while IFS= read -r p; do
    [ -n "$p" ] || continue
    gitx apply --directory="$STAGE/ffmpeg-$FFMPEG_VERSION" --unsafe-paths "$LUX/patches/$p" \
        || die "源码包打补丁失败: $p"
    printf 'applied %s  %s\n' "$p" "$(shasum -a 256 "$LUX/patches/$p" | awk '{ print $1 }')" >> "$PATCHED_LIST"
    log "source: applied $p"
done < <(sed -e 's/#.*//' "$LUX/config/patches.txt" | awk 'NF { print $1 }')

for f in COPYING.GPLv2 COPYING.GPLv3 COPYING.LGPLv2.1 COPYING.LGPLv3 LICENSE.md; do
    [ -f "$REPO/$f" ] && cp -p "$REPO/$f" "$STAGE/$f"
done

# SOURCE-PACKAGE.md(发布目录与源码包内各一份)
cat > "$STAGE/SOURCE-PACKAGE.md" <<EOF
# lux-ffmpeg 对应源码包($TAG)

本包是 \`$PRODUCT\` 的 LGPL 对应源码。FFmpeg 以 LGPL-2.1-or-later 构建
(\`CONFIG_GPL=0\`、\`CONFIG_NONFREE=0\`、\`CONFIG_VERSION3=0\`),没有 GPL/nonfree 组件。

## 内容

\`\`\`
$PRODUCT/
  SOURCE-PACKAGE.md                 本文件
  BUILD-INFO.txt                    发布包元数据(另见发布目录)
  COPYING.*, LICENSE.md             许可文本
  lux/                              本仓库 lux/ 全部内容(不含 lux/.build)
    build/, config/, patches/, test/, docs/, release/licenses/ ...
    release/sources/                依赖源码包(见 SOURCES-INDEX.txt)
  ffmpeg-$FFMPEG_VERSION/           FFmpeg 基线树 + 13 个补丁已应用
    LUX-PATCHES.txt                 补丁清单与 sha256
\`\`\`

## 元数据

- FFmpeg: \`$FFMPEG_BASELINE\`
- 基线 commit: \`$BASELINE_COMMIT\` (\`$BASELINE_REF\`)
- 产物源码 commit: \`$ARTIFACT_SOURCE_COMMIT\`
- 补丁集: \`$PATCH_COUNT\` 条,digest \`$PATCH_DIGEST\`
- 依赖源码: $INCLUDED 个($SELFSTORE_COUNT 个 selfstore,$EXTRA_COUNT 个构建缓存)

## 可复现命令

在仓库根目录(本包的 \`lux/\` 与 \`ffmpeg-$FFMPEG_VERSION/\` 已就位时,可跳过第一步):

\`\`\`sh
# 1) 取 FFmpeg 基线树(只取 FFmpeg 源码,排除 lux/ 与打包目录)
git archive --format=tar HEAD -- \\
  configure Makefile VERSION RELEASE RELEASE_NOTES Changelog CREDITS MAINTAINERS \\
  README.md INSTALL.md LICENSE.md CONTRIBUTING.md .gitattributes .mailmap FUNDING.json \\
  COPYING.GPLv2 COPYING.GPLv3 COPYING.LGPLv2.1 COPYING.LGPLv3 \\
  Dockerfile.in Dockerfile.make Dockerfile.win64.in Dockerfile.win64.make \\
  compat doc ffbuild fftools libavcodec libavdevice libavfilter libavformat libavutil \\
  libswresample libswscale presets tests tools \\
  | tar -xf - -C ffmpeg-$FFMPEG_VERSION

# 2) 按 lux/config/patches.txt 的顺序应用补丁(零 fuzz)
while IFS= read -r p; do
  case "\$p" in ''|'#'*) continue ;; esac
  git apply --directory="\$PWD/ffmpeg-$FFMPEG_VERSION" --unsafe-paths "lux/patches/\$p" || exit 1
done < <(sed -e 's/#.*//' lux/config/patches.txt | awk 'NF { print \$1 }')

# 3) 校验补丁集 digest
bash lux/build/apply-patches.sh digest   # 应为 $PATCH_DIGEST

# 4) 重新打包
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -czf \\
  $SOURCE_TAR $PRODUCT
\`\`\`

## 校验

\`\`\`sh
shasum -a 256 -c SHA256SUMS
\`\`\`

发布目录里的 \`SHA256SUMS\` 覆盖本 tar.gz 与其他分发文件;\`xcframeworks/checksums.txt\`
覆盖 10 个 xcframework zip。任何不一致都应视为包损坏。

## 依赖源码缺口

$(if [ -z "$MISSING_ARCHIVES" ]; then
    printf '无:构建使用的 %s 个锁定依赖源码都已随包(SOURCES-INDEX.txt)。\n' "$INCLUDED"
else
    printf '以下 URL-only 依赖没有本地源码,未随包(仅 deps.lock 记录 URL + sha256):%s\n' "$MISSING_ARCHIVES"
fi)
EOF
cp -p "$STAGE/SOURCE-PACKAGE.md" "$OUT/SOURCE-PACKAGE.md"

cp -p "$OUT/BUILD-INFO.txt" "$STAGE/BUILD-INFO.txt"

log "打包对应源码 tar.gz($INCLUDED 个依赖源码)"
# 归一化 mtime,减少重复打包的字节差异
find "$STAGE" -exec touch -t 202611100000.00 {} + 2>/dev/null || true
( cd "$WORK/source" && COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs \
    --uid 0 --gid 0 --uname root --gname root \
    -czf "$OUT/$SOURCE_TAR" "$PRODUCT" )
SOURCE_SHA=$(shasum -a 256 "$OUT/$SOURCE_TAR" | awk '{ print $1 }')
printf 'source_package=%s\n' "$SOURCE_TAR" >> "$OUT/BUILD-INFO.txt"
printf 'source_package.sha256=%s\n' "$SOURCE_SHA" >> "$OUT/BUILD-INFO.txt"
printf 'source_archives.included=%s\n' "$INCLUDED" >> "$OUT/BUILD-INFO.txt"
printf 'source_archives.selfstore=%s\n' "$SELFSTORE_COUNT" >> "$OUT/BUILD-INFO.txt"
printf 'source_archives.deps_cache=%s\n' "$EXTRA_COUNT" >> "$OUT/BUILD-INFO.txt"
printf 'source_archives.missing=%s\n' "${MISSING_ARCHIVES# }" >> "$OUT/BUILD-INFO.txt"

# ---------------------------------------------------------------------------
# 6. SHA256SUMS(覆盖发布目录里除自身外的全部文件)
# ---------------------------------------------------------------------------
log "生成 SHA256SUMS"
(
    cd "$OUT"
    find . -type f ! -name SHA256SUMS -print |
        sed 's|^\./||' |
        LC_ALL=C sort |
        while IFS= read -r f; do
            shasum -a 256 "$f"
        done > SHA256SUMS
)
SUM_COUNT=$(wc -l < "$OUT/SHA256SUMS" | tr -d ' ')
log "SHA256SUMS: $SUM_COUNT 个文件"

log "输出目录: $OUT"
log "RESULT: PASS"
