#!/usr/bin/env bash
# 重新生成 vendor/glad-2.0.8 的头文件(需要 glad2==2.0.8,由 lux/build/install-glad.sh 按
# lux/config/requirements-glad.txt 的 sha256 装到 lux/.build/deps/pydeps)。
# 生成器内置了 Khronos 规范,不访问网络(见 README.md)。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
PYDEPS="$REPO/lux/.build/deps/pydeps"
# 缺 glad2 时先按 hash 锁装一遍;已装则 pip 会直接判为 satisfied,不联网。
if ! PYTHONPATH="$PYDEPS" python3 -c 'import glad' >/dev/null 2>&1; then
  "$REPO/lux/build/install-glad.sh" --target "$PYDEPS"
fi
OUT="$(mktemp -d "$REPO/lux/.build/glad-gen.XXXX")"
PYTHONPATH="$PYDEPS" python3 -m glad --out-path="$OUT" --reproducible --merge \
  --api=gl:core,gles2,egl --extensions="$(cat "$HERE/extensions.txt")" c --header-only --mx > "$OUT/gen.log" 2>&1
mkdir -p "$HERE/include/glad"
cp "$OUT/include/glad/gl.h" "$OUT/include/glad/egl.h" "$HERE/include/glad/"
rm -rf "$OUT"
( cd "$HERE" && shasum -a 256 include/glad/gl.h include/glad/egl.h )
