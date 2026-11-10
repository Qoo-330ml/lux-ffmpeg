#!/usr/bin/env bash
# 校验 lux/config/deps.lock 的每一项:把 URL 的当前字节取下来算 sha256,与锁定值逐字节比对;
# 有 selfstore= 的条目另外核对本地自存副本。只读 deps.lock,任何不一致都只报告,绝不改写锁值。
# 不碰主检出 lux/.build/deps(下载缓存放在本仓库的 lux/.build/verify/deps-lock)。
# 用法: ./lux/build/check-deps-lock.sh [--fresh] [--offline] [--cache DIR] [--log FILE]
#   --fresh     忽略缓存,重新从 URL 下载每一项(默认:缓存存在且校验通过就直接复用)
#   --offline   不联网,只核对缓存与自存副本
#   --cache DIR 下载缓存目录(默认 lux/.build/verify/deps-lock)
#   --log FILE  日志文件(默认 lux/.build/logs/deps-lock-check-<YYYYmmdd>.log;传 - 表示只输出到终端)
#   --build-src DIR  顺带核对构建用的源码缓存(默认 lux/.build/deps/src),不存在则跳过
# 退出码:0 全部一致;1 有不一致/缺失;2 用法错误。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/lux/build/deps-lock-common.sh"
LOCK="$REPO/lux/config/deps.lock"
CACHE="$REPO/lux/.build/verify/deps-lock"
BUILD_SRC="${LUX_DEPS_SRC:-$REPO/lux/.build/deps/src}"
LOG="$REPO/lux/.build/logs/deps-lock-check-$(date +%Y%m%d).log"
FRESH=0
OFFLINE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh) FRESH=1 ;;
    --offline) OFFLINE=1 ;;
    --cache) CACHE="${2:?--cache 需要参数}"; shift ;;
    --cache=*) CACHE="${1#--cache=}" ;;
    --log) LOG="${2:?--log 需要参数}"; shift ;;
    --log=*) LOG="${1#--log=}" ;;
    --build-src) BUILD_SRC="${2:?--build-src 需要参数}"; shift ;;
    --build-src=*) BUILD_SRC="${1#--build-src=}" ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "check-deps-lock.sh: 未知选项 $1" >&2; exit 2 ;;
  esac
  shift
done
if [ "$LOG" != "-" ]; then
  mkdir -p "$(dirname "$LOG")"
  # 终端与日志同时要有内容:所有输出先 tee 一份到日志文件。
  exec > >(tee -a "$LOG") 2>&1
fi
mkdir -p "$CACHE"

echo "# deps.lock 校验 $(date '+%Y-%m-%d %H:%M:%S')"
echo "# 仓库:   $REPO"
echo "# 锁文件: $LOCK"
echo "# 锁文件 sha256: $(deps_lock_sha256 "$LOCK")"
echo "# 缓存:   $CACHE"
echo "# 模式:   $([ "$FRESH" -eq 1 ] && echo fresh || echo reuse)$([ "$OFFLINE" -eq 1 ] && echo ' + offline')"
echo

total=0
ok=0
fail=0
while read -r name version sha url rest || [ -n "${name:-}" ]; do
  case "${name:-}" in ''|\#*) continue ;; esac
  if [ -z "${version:-}" ] || [ -z "${sha:-}" ] || [ -z "${url:-}" ]; then
    echo "[FAIL] 锁文件行格式不对:$name ${version:-} ${sha:-} ${url:-}"
    fail=$((fail + 1))
    continue
  fi
  total=$((total + 1))
  # shellcheck disable=SC2086
  selfstore="$(deps_lock_selfstore ${rest:-})"
  notes=()
  bad=0

  # 1) 自存副本
  if [ -n "$selfstore" ]; then
    if [ -f "$REPO/$selfstore" ]; then
      got="$(deps_lock_sha256 "$REPO/$selfstore")"
      if [ "$got" = "$sha" ]; then
        notes+=("selfstore=ok")
      else
        notes+=("selfstore=FAIL($got)")
        bad=1
      fi
    else
      notes+=("selfstore=missing")
    fi
  else
    notes+=("selfstore=-")
  fi

  # 2) URL 字节
  cached="$CACHE/$(basename "$url")"
  if [ "$OFFLINE" -eq 1 ]; then
    if [ -f "$cached" ]; then
      got="$(deps_lock_sha256 "$cached")"
      if [ "$got" = "$sha" ]; then notes+=("url=cache-ok"); else notes+=("url=cache-FAIL($got)"); bad=1; fi
    else
      notes+=("url=skipped(offline)")
    fi
  elif [ "$FRESH" -eq 0 ] && [ -f "$cached" ]; then
    got="$(deps_lock_sha256 "$cached")"
    if [ "$got" = "$sha" ]; then
      notes+=("url=cache-ok")
    else
      # 缓存坏了就重下一次
      rm -f "$cached"
      if deps_lock_curl "$url" "$cached.part"; then
        got="$(deps_lock_sha256 "$cached.part")"
        if [ "$got" = "$sha" ]; then mv "$cached.part" "$cached"; notes+=("url=ok(redownloaded)"); else rm -f "$cached.part"; notes+=("url=FAIL($got)"); bad=1; fi
      else
        notes+=("url=FETCH-FAILED"); bad=1
      fi
    fi
  else
    rm -f "$cached.part"
    if deps_lock_curl "$url" "$cached.part"; then
      got="$(deps_lock_sha256 "$cached.part")"
      if [ "$got" = "$sha" ]; then
        mv "$cached.part" "$cached"
        notes+=("url=ok")
      else
        rm -f "$cached.part"
        notes+=("url=FAIL($got)")
        bad=1
      fi
    else
      notes+=("url=FETCH-FAILED")
      bad=1
    fi
  fi

  # 3) 构建用的源码缓存(可选,只报告)
  if [ -n "$BUILD_SRC" ] && [ -f "$BUILD_SRC/$(basename "$url")" ]; then
    got="$(deps_lock_sha256 "$BUILD_SRC/$(basename "$url")")"
    if [ "$got" = "$sha" ]; then notes+=("build-src=ok"); else notes+=("build-src=STALE($got)"); fi
  fi

  if [ "$bad" -eq 0 ]; then
    ok=$((ok + 1))
    printf '[ok]   %-18s %-12s %s  %s\n' "$name" "$version" "$sha" "${notes[*]}"
  else
    fail=$((fail + 1))
    printf '[FAIL] %-18s %-12s %s  %s\n' "$name" "$version" "$sha" "${notes[*]}"
  fi
done < "$LOCK"

echo
if [ "$total" -eq 0 ]; then
  echo "== deps.lock 里没有可校验的条目 =="
  exit 1
fi
echo "== $total 项:$ok OK,$fail FAIL(deps.lock 未被修改)=="
[ "$fail" -eq 0 ] || exit 1
