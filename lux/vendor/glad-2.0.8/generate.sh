#!/usr/bin/env bash
# 重新生成 vendor/glad-2.0.8 的头文件(需要 glad2==2.0.8,由 lux/build/install-glad.sh 按
# lux/config/requirements-glad.txt 的 sha256 装到 lux/.build/deps/pydeps)。
# 生成器内置了 Khronos 规范,不访问网络(见 README.md)。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
PYDEPS="${LUX_PYDEPS:-$REPO/lux/.build/deps/pydeps}"

# glad2 的可用性判定:必须①版本正好是 2.0.8②glad 包就在 $PYDEPS 下面。
# 只 import glad 不够 —— 系统/PYTHONPATH 里的其它 glad2 版本会悄悄顶替,
# 生成结果就不再对应 requirements-glad.txt 锁住的那份字节。
glad_ready() {
  # PYDEPS 排在最前:已装好的那份永远优先;PYDEPS 里没有时才会看到系统/PYTHONPATH 里的其它版本,
  # 而那种情况会被版本与路径检查判为不可用,从而触发重装。
  PYTHONPATH="$PYDEPS${PYTHONPATH:+:$PYTHONPATH}" python3 - "$PYDEPS" <<'PY'
import importlib.metadata as md
import pathlib
import sys

want = pathlib.Path(sys.argv[1]).resolve()
try:
    version = md.version("glad2")
except Exception:
    sys.exit(1)
if version != "2.0.8":
    sys.exit(1)
try:
    import glad
except Exception:
    sys.exit(1)
if want not in pathlib.Path(glad.__file__).resolve().parents:
    sys.exit(1)
PY
}

if ! glad_ready; then
  echo "generate.sh: $PYDEPS 里没有 glad2 2.0.8(或 glad 不在该目录),按 hash 锁重装" >&2
  "$REPO/lux/build/install-glad.sh" --target "$PYDEPS"
  if ! glad_ready; then
    echo "generate.sh: 装完仍找不到可用的 glad2 2.0.8,放弃生成" >&2
    exit 1
  fi
fi

mkdir -p "$REPO/lux/.build"
OUT="$(mktemp -d "$REPO/lux/.build/glad-gen.XXXX")"
PYTHONPATH="$PYDEPS${PYTHONPATH:+:$PYTHONPATH}" python3 -m glad --out-path="$OUT" --reproducible --merge \
  --api=gl:core,gles2,egl --extensions="$(cat "$HERE/extensions.txt")" c --header-only --mx > "$OUT/gen.log" 2>&1
mkdir -p "$HERE/include/glad"
cp "$OUT/include/glad/gl.h" "$OUT/include/glad/egl.h" "$HERE/include/glad/"
rm -rf "$OUT"
( cd "$HERE" && shasum -a 256 include/glad/gl.h include/glad/egl.h )
