#!/usr/bin/env bash
# 按 lux/config/deps.lock 取依赖源码,并在落到缓存之前强制校验 sha256:不一致立即失败,
# 不会把坏文件留在 lux/.build/deps/src 里,也不会改写 deps.lock 的锁定值。
# 源码落在 $LUX_DEPS_SRC(默认 lux/.build/deps/src,gitignored),文件名保持 URL 的 basename,
# 与 build-*.sh 里引用归档名的方式一致。
# 每一项优先用 deps.lock 里 selfstore= 指明的自存副本(逐字节副本,离线可用),缺失时回退到 URL。
# 用法: ./lux/build/fetch-deps.sh [--fresh] [--from-url] [--offline] [--src DIR] [name ...]
#   --fresh     忽略已有缓存,重新取一次(仍然强制校验)
#   --from-url  忽略自存副本,强制从 URL 取(用于核对上游字节)
#   --offline   只用缓存/自存副本,不联网
#   --src DIR   缓存目录(默认 $LUX_DEPS_SRC 或 lux/.build/deps/src)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/lux/build/deps-lock-common.sh"
LOCK="$REPO/lux/config/deps.lock"
SRC="${LUX_DEPS_SRC:-$REPO/lux/.build/deps/src}"
FRESH=0
FROM_URL=0
OFFLINE=0
want=()
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh) FRESH=1 ;;
    --from-url) FROM_URL=1 ;;
    --offline) OFFLINE=1 ;;
    --src) SRC="${2:?--src 需要参数}"; shift ;;
    --src=*) SRC="${1#--src=}" ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) echo "fetch-deps.sh: 未知选项 $1" >&2; exit 2 ;;
    *) want+=("$1") ;;
  esac
  shift
done
mkdir -p "$SRC"

fetch_one() { # $1 name $2 version $3 sha256 $4 url $5 rest(可能含 selfstore= 与行尾注释)
  local name=$1 version=$2 sha=$3 url=$4 rest=$5
  local dest="$SRC/$(basename "$url")"
  local selfstore store=""
  local tmp="$dest.part.$$"
  local got
  # shellcheck disable=SC2086  # 需要按空白切分 rest,才能取出 selfstore= 这种 key=value
  selfstore="$(deps_lock_selfstore $rest)"
  if [ -n "$selfstore" ]; then store="$REPO/$selfstore"; fi

  if [ "$FRESH" -eq 0 ] && [ -f "$dest" ] && [ "$(deps_lock_sha256 "$dest")" = "$sha" ]; then
    echo "[cached] $name $version  $(basename "$dest")"
    return 0
  fi

  rm -f "$tmp"
  # 1. 自存副本(除非 --from-url)
  if [ "$FROM_URL" -eq 0 ] && [ -n "$store" ] && [ -f "$store" ]; then
    cp "$store" "$tmp"
    got="$(deps_lock_sha256 "$tmp")"
    if [ "$got" != "$sha" ]; then
      rm -f "$tmp"
      echo "[FAIL] $name $version:自存副本 $selfstore 的 sha256 是 $got,与锁定值不符;不覆盖锁值,也不回退到 URL" >&2
      echo "       请删除/重建该自存副本,或先确认上游发布是否被重打。" >&2
      return 1
    fi
    mv "$tmp" "$dest"
    echo "[ok]     $name $version  <- selfstore:$selfstore"
    return 0
  fi

  # 2. URL
  if [ "$OFFLINE" -eq 1 ]; then
    rm -f "$tmp"
    echo "[FAIL] $name $version:离线模式,缓存缺失或校验失败,且没有可用的自存副本" >&2
    return 1
  fi
  if ! deps_lock_curl "$url" "$tmp"; then
    echo "[FAIL] $name $version:下载失败 $url" >&2
    return 1
  fi
  got="$(deps_lock_sha256 "$tmp")"
  if [ "$got" != "$sha" ]; then
    rm -f "$tmp"
    echo "[FAIL] $name $version:下载内容的 sha256 是 $got,与锁定值 $sha 不符(已丢弃,未覆盖缓存)" >&2
    return 1
  fi
  mv "$tmp" "$dest"
  echo "[ok]     $name $version  <- url:$url"
  return 0
}

selected() { # $1 name
  [ ${#want[@]} -eq 0 ] && return 0
  local w
  for w in "${want[@]}"; do [ "$w" = "$1" ] && return 0; done
  return 1
}

fail=0
seen=0
while read -r name version sha url rest || [ -n "${name:-}" ]; do
  case "${name:-}" in ''|\#*) continue ;; esac
  if [ -z "${version:-}" ] || [ -z "${sha:-}" ] || [ -z "${url:-}" ]; then
    echo "[FAIL] deps.lock 行格式不对:$name ${version:-} ${sha:-} ${url:-}" >&2
    fail=1
    continue
  fi
  selected "$name" || continue
  seen=$((seen + 1))
  fetch_one "$name" "$version" "$sha" "$url" "${rest:-}" || fail=1
done < "$LOCK"

if [ "$seen" -eq 0 ]; then
  echo "fetch-deps.sh: deps.lock 里没有匹配的条目(${want[*]:-全部})" >&2
  exit 2
fi
if [ "$fail" -ne 0 ]; then
  echo "fetch-deps.sh: 有依赖未通过 sha256 校验,已中止" >&2
  exit 1
fi
echo "fetch-deps.sh: $seen 项全部通过 sha256 校验($SRC)"
