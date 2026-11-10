#!/usr/bin/env bash
# deps.lock 的解析、sha256 与下载工具函数;被 fetch-deps.sh / check-deps-lock.sh source。
# 单独执行没有意义。所有函数都不改写 lux/config/deps.lock。
#
# deps.lock 的行格式:name version sha256 url [key=value ...]
#   目前只定义了一个 key:selfstore=<相对仓库根的路径>,指本地自存源码包(不入 git)。

# deps_lock_sha256 <file> -> 打印 64 位小写 sha256
deps_lock_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# deps_lock_selfstore <rest-token...> -> 打印 selfstore= 的值;没有则打印空串
deps_lock_selfstore() {
  local tok
  for tok in "$@"; do
    case "$tok" in
      selfstore=*) printf '%s' "${tok#selfstore=}"; return 0 ;;
    esac
  done
  printf ''
}

# deps_lock_curl <url> <dest> -> 下载到 dest;失败时删掉半成品并返回非零
deps_lock_curl() {
  local url=$1 dest=$2
  if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 900 -o "$dest" "$url"; then
    rm -f "$dest"
    return 1
  fi
  return 0
}
