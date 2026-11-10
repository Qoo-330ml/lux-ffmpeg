#!/usr/bin/env bash
#
# lux/release/fetch-lux-ffmpeg.sample.sh — 给 lux-client 的 fetch 脚本草案
#
# 这不是 lux-client 里的正式脚本;正式位置是 apple/scripts/fetch-lux-ffmpeg.sh。
#
# 用法:
#   fetch-lux-ffmpeg.sh <release-dir-or-url> <dest>
#
#   <release-dir-or-url>  本地发布目录(含 SHA256SUMS、xcframeworks/checksums.txt)
#                         或发布目录的 URL(如 GitHub release 的 download/<tag>)
#   <dest>                目标目录;解压结果落到 <dest>/Vendor/<Name>.xcframework
#
# 行为:
#   1. 本地目录:先用 `shasum -a 256 -c SHA256SUMS` 校验全部文件,再逐个核对
#      xcframeworks/checksums.txt;URL 模式只下载分发所需的 10 个 zip +
#      两份校验文件(其余 dSYM/源码条目不下载),但仍逐个核对已下载文件在
#      SHA256SUMS 与 checksums.txt 里的 hash。
#   2. 全部一致后才解压;任何不一致/缺文件/结构不对都退出非零,并删除本次
#      产生的临时结果(<dest>/Vendor 原有的内容保持不动)。
#   3. 解压用 ditto -x -k,保留 zip 里的 symlink(Headers 别名)。
#
# 依赖:bash 3.2+、shasum、unzip、ditto、curl(URL 模式)、plutil(可选)。
set -euo pipefail

FRAMEWORKS="Libavcodec Libavformat Libavfilter Libswscale Libswresample Libavutil Libmpv Libplacebo Libfribidi Libuchardet"

die() { printf '[fetch] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[fetch] %s\n' "$*"; }

usage() {
    cat <<EOF
用法: $0 <release-dir-or-url> <dest>

  <release-dir-or-url>  本地发布目录或 URL(例如 .../releases/download/f2-20261110)
  <dest>                解压到 <dest>/Vendor/<Name>.xcframework

示例:
  $0 /path/to/lux-ffmpeg-f2-20261110 ./apple/Packages/LuxKit
  $0 https://github.com/Qoo-330ml/lux-ffmpeg/releases/download/f2-20261110 ./apple/Packages/LuxKit
EOF
}

[ $# -eq 2 ] || { usage; exit 2; }
SRC=${1%/}
DEST=$2
[ -n "$SRC" ] || die "release 参数为空"
[ -n "$DEST" ] || die "dest 参数为空"

case "$SRC" in
    http://*|https://*) MODE=url ;;
    *) MODE=dir ;;
esac
if [ "$MODE" = dir ]; then
    [ -d "$SRC" ] || die "发布目录不存在: $SRC"
    [ -f "$SRC/SHA256SUMS" ] || die "缺少 $SRC/SHA256SUMS"
    [ -f "$SRC/xcframeworks/checksums.txt" ] || die "缺少 $SRC/xcframeworks/checksums.txt"
fi

DEST_CREATED=0
if [ ! -d "$DEST" ]; then
    mkdir -p "$DEST" || die "无法创建目标目录: $DEST"
    DEST_CREATED=1
fi
TMP=$(mktemp -d "$DEST/.lux-ffmpeg-fetch.XXXXXX") || die "无法创建临时目录"
cleanup() {
    rc=$?
    trap - EXIT INT TERM
    rm -rf "$TMP"
    if [ "$DEST_CREATED" = 1 ] && [ -d "$DEST" ]; then
        # 只有本次新建且仍为空时才删,绝不碰用户已有内容。
        rmdir "$DEST" 2>/dev/null || true
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

fetch_url() { # $1=url $2=out
    mkdir -p "$(dirname "$2")"
    curl --fail --location --silent --show-error --retry 3 --connect-timeout 20 \
        "$1" -o "$2" || die "下载失败: $1"
}

sum_in_file() { # $1=sums file $2=path -> sha256 or empty
    awk -v p="$2" -v q="./$2" '$2 == p || $2 == q { print $1; exit }' "$1"
}

verify_zip_set() { # $1=checksums.txt $2=directory containing zips
    local checksums=$1 dir=$2 sum name actual seen=0
    : > "$TMP/zipnames.txt"
    while read -r sum name; do
        [ -n "$sum" ] || continue
        case "$name" in
            *.xcframework.zip) ;;
            *) die "checksums.txt 含非 xcframework zip 条目: $name" ;;
        esac
        [ -f "$dir/$name" ] || die "checksums.txt 列出的 zip 不存在: $name"
        actual=$(shasum -a 256 "$dir/$name" | awk '{ print $1 }')
        [ "$actual" = "$sum" ] || die "checksum 不一致: $name"
        printf '%s\n' "$name" >> "$TMP/zipnames.txt"
        seen=$((seen + 1))
    done < "$checksums"
    [ "$seen" -eq 10 ] || die "checksums.txt 不是 10 个 zip(实际 $seen)"
    local expected
    expected=$(printf '%s\n' $FRAMEWORKS | sed 's/$/.xcframework.zip/' | LC_ALL=C sort)
    [ "$(LC_ALL=C sort -u "$TMP/zipnames.txt")" = "$expected" ] \
        || die "checksums.txt 覆盖的 framework 集合不符"
}

if [ "$MODE" = dir ]; then
    REL=$SRC
    log "本地发布目录: $REL"
    log "校验 SHA256SUMS(全部文件)"
    ( cd "$REL" && shasum -a 256 -c SHA256SUMS ) || die "SHA256SUMS 校验失败"
    log "校验 xcframeworks/checksums.txt"
    verify_zip_set "$REL/xcframeworks/checksums.txt" "$REL/xcframeworks"
    ZIP_DIR="$REL/xcframeworks"
else
    REL=$SRC
    log "URL: $REL"
    mkdir -p "$TMP/remote/xcframeworks"
    fetch_url "$REL/SHA256SUMS" "$TMP/remote/SHA256SUMS"
    fetch_url "$REL/xcframeworks/checksums.txt" "$TMP/remote/xcframeworks/checksums.txt"
    expected_sum=$(sum_in_file "$TMP/remote/SHA256SUMS" "xcframeworks/checksums.txt")
    [ -n "$expected_sum" ] || die "SHA256SUMS 没有 xcframeworks/checksums.txt 条目"
    actual_sum=$(shasum -a 256 "$TMP/remote/xcframeworks/checksums.txt" | awk '{ print $1 }')
    [ "$actual_sum" = "$expected_sum" ] || die "checksums.txt 的 sha256 与 SHA256SUMS 不一致"

    while read -r sum name; do
        [ -n "$sum" ] || continue
        case "$name" in
            *.xcframework.zip) ;;
            *) die "checksums.txt 含非 xcframework zip 条目: $name" ;;
        esac
        fetch_url "$REL/xcframeworks/$name" "$TMP/remote/xcframeworks/$name"
        actual=$(shasum -a 256 "$TMP/remote/xcframeworks/$name" | awk '{ print $1 }')
        [ "$actual" = "$sum" ] || die "checksum 不一致: $name"
        sums_sum=$(sum_in_file "$TMP/remote/SHA256SUMS" "xcframeworks/$name")
        [ -n "$sums_sum" ] || die "SHA256SUMS 没有 xcframeworks/$name 条目"
        [ "$actual" = "$sums_sum" ] || die "SHA256SUMS 与 checksums.txt 对 $name 的 hash 不一致"
    done < "$TMP/remote/xcframeworks/checksums.txt"
    verify_zip_set "$TMP/remote/xcframeworks/checksums.txt" "$TMP/remote/xcframeworks"
    ZIP_DIR="$TMP/remote/xcframeworks"
    log "URL 模式只下载并校验 10 个 xcframework zip;SHA256SUMS 里的 dSYM/源码条目未下载"
fi

log "全部校验通过,开始解压到临时 Vendor"
VENDOR_TMP="$TMP/Vendor"
mkdir -p "$VENDOR_TMP"
for fw in $FRAMEWORKS; do
    ditto -x -k "$ZIP_DIR/$fw.xcframework.zip" "$VENDOR_TMP" \
        || die "解压失败: $fw.xcframework.zip"
done
find "$VENDOR_TMP" -type d -name '__MACOSX' -prune -exec rm -rf {} + 2>/dev/null || true
find "$VENDOR_TMP" -name '.DS_Store' -delete 2>/dev/null || true

for fw in $FRAMEWORKS; do
    top="$VENDOR_TMP/$fw.xcframework"
    [ -d "$top" ] || die "解压后缺 $fw.xcframework"
    [ -f "$top/Info.plist" ] || die "$fw.xcframework 缺 Info.plist"
    for target in macos-arm64 ios-arm64 ios-sim-arm64; do
        case "$target" in
            macos-arm64) slice=macos-arm64 ;;
            ios-arm64) slice=ios-arm64 ;;
            ios-sim-arm64) slice=ios-arm64-simulator ;;
        esac
        [ -f "$top/$slice/$fw.framework/$fw" ] \
            || die "$fw.xcframework 缺切片 $slice/$fw.framework/$fw"
    done
done
log "结构检查通过: 10 个 xcframework × 3 切片"

# 原子替换 <dest>/Vendor;失败时恢复旧目录。
OLD=""
if [ -e "$DEST/Vendor" ]; then
    OLD="$DEST/Vendor.lux-old.$$"
    mv "$DEST/Vendor" "$OLD" || die "无法备份已有的 $DEST/Vendor"
fi
if mv "$VENDOR_TMP" "$DEST/Vendor"; then
    [ -n "$OLD" ] && rm -rf "$OLD"
else
    [ -n "$OLD" ] && mv "$OLD" "$DEST/Vendor"
    die "安装到 $DEST/Vendor 失败"
fi

log "完成: $DEST/Vendor"
for fw in $FRAMEWORKS; do
    log "  $fw.xcframework"
done
exit 0
