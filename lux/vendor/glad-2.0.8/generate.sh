#!/usr/bin/env bash
# 重新生成 vendor/glad-2.0.8 的头文件(需要 glad2==2.0.8,装在 lux/.build/deps/pydeps)。
# 生成器内置了 Khronos 规范,不访问网络(见 README.md)。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$(mktemp -d "$REPO/lux/.build/glad-gen.XXXX")"
PYTHONPATH="$REPO/lux/.build/deps/pydeps" python3 -m glad --out-path="$OUT" --reproducible --merge \
  --api=gl:core,gles2,egl --extensions="$(cat "$HERE/extensions.txt")" c --header-only --mx > "$OUT/gen.log" 2>&1
mkdir -p "$HERE/include/glad"
cp "$OUT/include/glad/gl.h" "$OUT/include/glad/egl.h" "$HERE/include/glad/"
rm -rf "$OUT"
( cd "$HERE" && shasum -a 256 include/glad/gl.h include/glad/egl.h )
