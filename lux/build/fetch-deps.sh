#!/usr/bin/env bash
# 按 lux/config/deps.lock 下载依赖源码并校验 sha256。源码落在 lux/.build/deps/src/(gitignored)。
# 用法: ./lux/build/fetch-deps.sh [name ...]   (不带参数则处理全部)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LOCK="$REPO/lux/config/deps.lock"
SRC="$REPO/lux/.build/deps/src"
mkdir -p "$SRC"
want=("$@")
fail=0
while read -r name version sha url rest; do
  case "$name" in ''|\#*) continue ;; esac
  if [ ${#want[@]} -gt 0 ]; then
    skip=1; for w in "${want[@]}"; do [ "$w" = "$name" ] && skip=0; done
    [ $skip -eq 1 ] && continue
  fi
  file="$SRC/$(basename "$url")"
  if [ ! -f "$file" ] || [ "$(shasum -a 256 "$file" | cut -c1-64)" != "$sha" ]; then
    curl -fsSL -m 900 -o "$file.part" "$url" && mv "$file.part" "$file"
  fi
  got="$(shasum -a 256 "$file" | cut -c1-64)"
  if [ "$got" = "$sha" ]; then echo "[ok]   $name $version"; else echo "[FAIL] $name $version sha256 $got"; fail=1; fi
done < "$LOCK"
exit $fail
