#!/usr/bin/env bash
# 安装 glad2(以及它的传递依赖 Jinja2 / MarkupSafe)到项目内的 pydeps 目录。
# 用 `python3 -m pip install --require-hashes -r lux/config/requirements-glad.txt`,
# 每个包的字节都要与 requirements 文件里的 sha256 对得上;PyPI 上被替换/重打包会直接失败。
# 不使用系统 Python 的 site-packages,也不改全局环境。
# 用法: ./lux/build/install-glad.sh [--target DIR] [--force] [--dry-run]
#   --target DIR  安装目录(默认 $LUX_PYDEPS 或 lux/.build/deps/pydeps)
#   --force       已安装也重装(--upgrade)
#   --dry-run     只打印将要执行的命令
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
REQ="$REPO/lux/config/requirements-glad.txt"
TARGET="${LUX_PYDEPS:-$REPO/lux/.build/deps/pydeps}"
PY="${PYTHON:-python3}"
FORCE=0
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:?--target 需要参数}"; shift ;;
    --target=*) TARGET="${1#--target=}" ;;
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "install-glad.sh: 未知选项 $1" >&2; exit 2 ;;
  esac
  shift
done
[ -f "$REQ" ] || { echo "install-glad.sh: 缺少 $REQ" >&2; exit 1; }

cmd=("$PY" -m pip install --disable-pip-version-check --no-cache-dir
     --require-hashes --target "$TARGET" -r "$REQ")
if [ "$FORCE" -eq 1 ]; then cmd+=(--upgrade); fi

if [ "$DRY" -eq 1 ]; then
  printf '%q ' "${cmd[@]}"; echo
  exit 0
fi

mkdir -p "$TARGET"
echo "install-glad.sh: 安装到 $TARGET(--require-hashes)"
"${cmd[@]}"

# 装完自检:版本必须是 requirements 里钉住的那些,且 glad 模块可导入。
PYTHONPATH="$TARGET" "$PY" - "$REQ" <<'PY'
import importlib.metadata as md
import pathlib
import sys

req = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
want = {}
for line in req.splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "--hash" in line:
        continue
    if "==" in line:
        name, ver = line.split("==", 1)
        # 行尾用反斜杠续行,去掉它再比对
        want[name.strip()] = ver.strip().rstrip("\\").strip()
bad = []
for name, ver in want.items():
    try:
        got = md.version(name)
    except md.PackageNotFoundError:
        bad.append(f"{name} 未安装")
        continue
    print(f"  {name} {got}")
    if got != ver:
        bad.append(f"{name}:期望 {ver},实际 {got}")
import glad  # noqa: F401
print(f"  glad 模块: {pathlib.Path(glad.__file__).parent}")
if bad:
    sys.exit("install-glad.sh: 自检失败:" + ";".join(bad))
PY
