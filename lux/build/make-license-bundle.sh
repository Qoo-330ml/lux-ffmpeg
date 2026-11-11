#!/usr/bin/env bash
#
# lux/build/make-license-bundle.sh — 生成许可与源码清单(草稿,供法务审阅)
#
#   ./lux/build/make-license-bundle.sh                  # 默认处理 LUX_TARGETS 的全部切片
#   ./lux/build/make-license-bundle.sh --target macos-arm64
#   ./lux/build/make-license-bundle.sh --help
#
# 输出(全部在 lux/release/ 下,重复运行会重建):
#   lux/release/source-manifest.json
#   lux/release/NOTICE.md
#   lux/release/licenses/<name>/
#
# 输入:
#   lux/config/deps.lock                依赖的 name/version/sha256/url
#   lux/.build/deps/src/                源码包(通常是指向主检出的符号链接)
#   lux/.build/<target>/install/lib/    FFmpeg 静态库
#   lux/.build/xcframeworks/            FFmpeg xcframework 切片
#   lux/.build/mpv-frameworks/          libmpv 栈 framework(没有时回退到 deps dylib)
#
# 设计:
#   * 只整理事实,不判断许可适用;有歧义的条目写“待法务确认”。
#   * 不写时间戳到 JSON/NOTICE,重复运行内容一致(日志文件名除外)。
#   * 不修改已有文件;所有输出都在 lux/release/ 与 lux/.build/logs/。
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LUX=$(cd "$HERE/.." && pwd)
REPO=$(cd "$LUX/.." && pwd)
LOGDIR="$LUX/.build/logs"
mkdir -p "$LOGDIR" "$LUX/release"

# 某些 CI/沙箱会把 GIT_CONFIG_COUNT 设成 1 却漏掉 key,git 会在解析参数前失败。
# 只在这个脚本的子进程里清掉这组不完整的环境变量,不改全局配置。
if [ -n "${GIT_CONFIG_COUNT:-}" ] && [ -z "${GIT_CONFIG_KEY_0:-}" ]; then
    unset GIT_CONFIG_COUNT GIT_CONFIG_VALUE_0
fi

PYTHON=${PYTHON:-python3}
command -v "$PYTHON" >/dev/null 2>&1 || {
    printf 'make-license-bundle: 找不到 python3\n' >&2
    exit 1
}

stamp=$(date '+%Y%m%d-%H%M%S')
log="$LOGDIR/p3-b-license-bundle-$stamp-$$.log"

printf '[license-bundle] log: %s\n' "$log"

set +e
"$PYTHON" -I - "$REPO" "$@" 2>&1 <<'PY' | tee "$log"
from __future__ import annotations

import hashlib
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

SCHEMA_VERSION = 1
DRAFT = "草稿 — 待法务确认"
FFMPEG_LIBS = [
    "libavcodec",
    "libavformat",
    "libavfilter",
    "libswscale",
    "libswresample",
    "libavutil",
]
FFMPEG_FRAMEWORKS = {
    "libavcodec": "Libavcodec",
    "libavformat": "Libavformat",
    "libavfilter": "Libavfilter",
    "libswscale": "Libswscale",
    "libswresample": "Libswresample",
    "libavutil": "Libavutil",
}
STACK_FRAMEWORKS = ["Libmpv", "Libplacebo", "Libfribidi", "Libuchardet"]
STACK_STEMS = {
    "Libmpv": "libmpv",
    "Libplacebo": "libplacebo",
    "Libfribidi": "libfribidi",
    "Libuchardet": "libuchardet",
}
STACK_SOURCE = {
    "Libmpv": "mpv",
    "Libplacebo": "libplacebo",
    "Libfribidi": "fribidi",
    "Libuchardet": "uchardet",
}
# B+:独立的共享 Vulkan 运行时 framework。它们不从 mpv-frameworks/ 读,
# 而是 build-vulkan-frameworks.sh 产出到 vulkan-frameworks/<target>/slice/。
VULKAN_FRAMEWORKS = ["LibMoltenVK", "Libshaderc"]
VULKAN_STEMS = {
    "LibMoltenVK": "libMoltenVK",
    "Libshaderc": "libshaderc",
}
VULKAN_SOURCE = {
    "LibMoltenVK": "moltenvk",
    "Libshaderc": "shaderc",
}
FRAMEWORK_SLICE = {
    "macos-arm64": "macos-arm64",
    "ios-arm64": "ios-arm64",
    "ios-sim-arm64": "ios-arm64-simulator",
}

# 许可事实表:license, status, 是否含 GPL 条款/选项, 说明。
# status=identified 只表示“源码包里的许可文本已定位且表述清楚”,不是法律结论。
LICENSE_FACTS = {
    "freetype": (
        "FTL 或 GPL-2.0(二选一,待法务确认)",
        "needs-legal-review",
        True,
        "源码 LICENSE.TXT 明示 FTL 与 GPL-2.0 二选一;docs/FTL.TXT 与 docs/GPLv2.TXT 均已复制。",
    ),
    "harfbuzz": (
        "MIT",
        "identified",
        False,
        "COPYING 为 Old MIT;src/ms-use/COPYING 为另一份 MIT 文本,已一并复制。",
    ),
    "fribidi": (
        "LGPL-2.1-or-later",
        "identified",
        False,
        "COPYING 为 LGPL-2.1;源码头声明 2.1 或更高版本。",
    ),
    "libunibreak": (
        "Zlib",
        "identified",
        False,
        "LICENCE 为 zlib 风格许可。",
    ),
    "lcms2": (
        "MIT",
        "identified",
        False,
        "LICENSE 为 MIT。",
    ),
    "uchardet": (
        "MPL-1.1 或 GPL-2.0-or-later 或 LGPL-2.1-or-later(待法务确认)",
        "needs-legal-review",
        True,
        "COPYING 同时含 MPL-1.1、GPL-2.0、LGPL-2.1 文本;README 明示三选一;"
        "lux/build/build-deps.sh 注释写作 LGPL-2.1+,与源码表述不一致。",
    ),
    "libass": (
        "ISC",
        "identified",
        False,
        "COPYING 为 ISC。",
    ),
    "mpv": (
        "待法务确认",
        "needs-legal-review",
        True,
        "Copyright 明示默认 GPL-2.0+;构建使用 -Dgpl=false;"
        "同一文件说明该开关本身不构成 LGPL 授权。",
    ),
    "libplacebo": (
        "LGPL-2.1-or-later",
        "identified",
        False,
        "LICENSE 为 LGPL-2.1。",
    ),
    "shaderc": (
        "Apache-2.0",
        "identified",
        False,
        "LICENSE 为 Apache-2.0;third_party 的 glslang/SPIRV-Tools 许可见各自条目。",
    ),
    "glslang": (
        "BSD-3-Clause / BSD-2-Clause / MIT / Apache-2.0 / GPL-3.0-with-bison-exception(按文件,待法务确认)",
        "needs-legal-review",
        True,
        "LICENSE.txt 按文件列出 3-Clause BSD、2-Clause BSD、MIT、Apache-2.0,"
        "并含 “GPL 3 with special bison exception” 一节;未逐文件核对适用范围。",
    ),
    "spirv-tools": (
        "Apache-2.0",
        "identified",
        False,
        "LICENSE 为 Apache-2.0。",
    ),
    "spirv-headers": (
        "MIT(部分文档 CC-BY-4.0,待法务确认)",
        "needs-legal-review",
        False,
        "LICENSE 按文件列出 MIT;tools/jsoncpp 为 MIT;部分 .md 文档为 CC-BY-4.0。",
    ),
    "moltenvk": (
        "Apache-2.0",
        "identified",
        False,
        "LICENSE 为 Apache-2.0。",
    ),
    "vulkan-headers": (
        "Apache-2.0 或 MIT(按文件)",
        "identified",
        False,
        "LICENSE.md 明示文件按 Apache-2.0 或 MIT。",
    ),
    "spirv-cross": (
        "Apache-2.0(部分文件 MIT / Khronos Free Use / CC-BY-4.0,待法务确认)",
        "needs-legal-review",
        False,
        "LICENSE 为 Apache-2.0;LICENSES/ 另有 MIT、Khronos Free Use 与 CC-BY-4.0 文本。",
    ),
    "spirv-tools-mvk": (
        "Apache-2.0",
        "identified",
        False,
        "LICENSE 为 Apache-2.0。",
    ),
    "spirv-headers-mvk": (
        "MIT(部分文件 Apache-2.0 / 文档 CC-BY-4.0,待法务确认)",
        "needs-legal-review",
        False,
        "LICENSE 按文件列出 MIT;LICENSES/ 另有 Apache-2.0;部分文档为 CC-BY-4.0。",
    ),
    "volk": (
        "MIT",
        "identified",
        False,
        "LICENSE.md 为 MIT。",
    ),
    "cereal": (
        "BSD-3-Clause(含 zlib 许可的 external 组件)",
        "identified",
        False,
        "LICENSE 为 BSD-3-Clause;include/cereal/external/LICENSE 为 zlib 风格许可。",
    ),
    "fast_float": (
        "MIT 或 Apache-2.0 或 BSL-1.0(三选一,待法务确认)",
        "needs-legal-review",
        False,
        "LICENSE-APACHE、LICENSE-MIT、LICENSE-BOOST 三份并存;适用选择待法务确认。",
    ),
    "dav1d": (
        "BSD-2-Clause",
        "identified",
        False,
        "COPYING 为 BSD-2-Clause;静态并入 libavcodec(Libdav1d 解码器),见 lux/config/allowlist.md。",
    ),
    "zlib": (
        "Zlib",
        "identified",
        False,
        "LICENSE 为 zlib 风格许可;静态并入 libavcodec(tscc inflate)与 libavformat。",
    ),
    "openssl": (
        "Apache-2.0",
        "identified",
        False,
        "LICENSE.txt 为 Apache-2.0;静态并入 libavformat(TLS/DTLS/RTMP),见 lux/docs/tls-13-probe.md。",
    ),
}

# 静态/构建期归属。otool -L 只显示动态依赖,静态并入的组件用构建脚本与符号表补充。
# kind: static / static-transitive / build-time / header-only
STATIC_LINKAGE = {
    "libass": ("static", ["Libmpv"], "libass.a 静态链接;nm -gU 可查到 _ass_* 符号"),
    "freetype": ("static", ["Libmpv"], "freetype.a 静态链接;nm -gU 可查到 _FT_* 符号"),
    "harfbuzz": ("static", ["Libmpv"], "harfbuzz.a 静态链接;nm -gU 可查到 _hb_* 符号"),
    "libunibreak": ("static", ["Libmpv"], "libunibreak.a 静态链接;nm -gU 可查到 _init_linebreak 等符号"),
    "lcms2": ("static", ["Libplacebo"], "lcms2.a 静态链接;nm -gU 可查到 _cms* 符号"),
    "spirv-cross": ("static-transitive", ["LibMoltenVK"], "MoltenVK ExternalDependencies 的 libSPIRVCross.a"),
    "spirv-tools": ("static-transitive", ["Libshaderc"], "shaderc_shared 的 SPIRV-Tools 部分"),
    "spirv-tools-mvk": ("static-transitive", ["LibMoltenVK"], "MoltenVK ExternalDependencies 的 libSPIRVTools.a"),
    "glslang": ("static-transitive", ["Libshaderc"], "shaderc_shared 的 glslang 部分"),
    "spirv-headers": ("build-time", ["Libshaderc"], "shaderc 构建期头文件"),
    "spirv-headers-mvk": ("build-time", ["LibMoltenVK"], "MoltenVK/SPIRV-Tools 构建期头文件"),
    "vulkan-headers": ("build-time", ["LibMoltenVK", "Libshaderc"], "MoltenVK/shaderc 构建期头文件"),
    "volk": ("build-time", ["LibMoltenVK"], "MoltenVK 构建期 Vulkan 加载器源码/头文件"),
    "cereal": ("build-time", ["LibMoltenVK"], "MoltenVK 构建期头文件"),
    "fast_float": ("header-only", ["Libplacebo"], "libplacebo 构建期头文件"),
    "dav1d": ("static", ["Libavcodec"], "libdav1d.a 静态链接;nm -g 可查到 _dav1d_* 符号"),
    "zlib": ("static", ["Libavcodec", "Libavformat"], "libz.a 静态链接;nm -g 可查到 _inflate* 符号"),
    "openssl": ("static", ["Libavformat"], "libssl.a/libcrypto.a 静态链接;nm -g 可查到 _SSL_* 符号"),
}

LICENSE_NAME_RE = re.compile(
    r"^(copying|license|licence|notice|copyright|unlicense|patents)([._-][a-z0-9._-]+)?$",
    re.IGNORECASE,
)
LICENSE_SPECIAL_RE = re.compile(
    r"^(docs/)?(ftl|gplv2|gplv3|lgplv2\.1)\.(txt|md)$", re.IGNORECASE
)
BAD_LICENSE_SUFFIXES = (
    ".cfg",
    ".sh",
    ".py",
    ".json",
    ".xml",
    ".yml",
    ".yaml",
    ".toml",
    ".in",
    ".am",
    ".cmake",
    ".mk",
    ".pm",
)
EXCLUDED_LICENSE_DIRS = {
    "test",
    "tests",
    "perf",
    "demos",
    "demo",
    "plugins",
    "utils",
    "builds",
    "contrib",
    "third_party",
    "external",
    "examples",
    "kokoro",
}


def log(msg: str) -> None:
    print(f"[license-bundle] {msg}", flush=True)


def warn(msg: str) -> None:
    print(f"[license-bundle] WARN: {msg}", file=sys.stderr, flush=True)


def die(msg: str) -> None:
    print(f"[license-bundle] ERROR: {msg}", file=sys.stderr, flush=True)
    raise SystemExit(1)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def repo_rel(path: Path | str, repo: Path) -> str:
    """词法相对路径:不解析符号链接,避免把主检出绝对路径写进清单。"""
    p = os.path.normpath(str(path))
    base = os.path.normpath(str(repo))
    if p == base:
        return "."
    if p.startswith(base + os.sep):
        return p[len(base) + 1 :]
    return p


def normalize_path(path: str, target: str, repo: Path) -> str:
    """把构建目录的绝对路径换成占位符,便于公开清单。"""
    deps_link = repo / "lux" / ".build" / "deps"
    real_deps = deps_link.resolve()
    real_repo = real_deps.parents[2] if len(real_deps.parents) >= 3 else repo
    prefixes = [
        (str(real_deps / target / "install"), f"$DEPS/{target}/install"),
        (str(deps_link / target / "install"), f"$DEPS/{target}/install"),
        (str(real_repo), "$REPO"),
        (str(repo / "lux"), "$LUX"),
        (str(repo), "$REPO"),
    ]
    for prefix, repl in prefixes:
        if path == prefix:
            return repl
        if path.startswith(prefix + "/"):
            return repl + path[len(prefix) :]
    return path


def run(
    args: list[str],
    cwd: Path | None = None,
    check: bool = False,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    if env.get("GIT_CONFIG_COUNT") and not env.get("GIT_CONFIG_KEY_0"):
        env.pop("GIT_CONFIG_COUNT", None)
        env.pop("GIT_CONFIG_VALUE_0", None)
    proc = subprocess.run(
        args,
        cwd=str(cwd) if cwd else None,
        text=True,
        capture_output=True,
        env=env,
    )
    if check and proc.returncode != 0:
        die(f"命令失败: {' '.join(args)}\n{proc.stderr.strip()}")
    return proc


def parse_deps_lock(path: Path) -> list[dict]:
    deps: list[dict] = []
    seen: set[str] = set()
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 4:
            die(f"deps.lock:{lineno} 字段不足(name version sha256 url): {raw!r}")
        name, version, digest, url = parts[:4]
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            die(f"deps.lock:{lineno} sha256 不是 64 位小写十六进制: {digest!r}")
        if name in seen:
            die(f"deps.lock:{lineno} 重复依赖: {name}")
        seen.add(name)
        deps.append(
            {
                "name": name,
                "version": version,
                "sha256": digest,
                "url": url,
                "line": lineno,
            }
        )
    if not deps:
        die(f"deps.lock 没有依赖条目: {path}")
    return deps


def find_archive(src: Path, dep: dict, hash_cache: dict[Path, str]) -> tuple[Path | None, str | None]:
    """先按 URL basename 找,再按 sha256 扫;返回 (路径, 实际 sha256)。"""
    basename = os.path.basename(dep["url"].split("?", 1)[0])
    candidate = src / basename
    if candidate.is_file():
        actual = hash_cache.setdefault(candidate, sha256_file(candidate))
        if actual == dep["sha256"]:
            return candidate, actual
        warn(f"{dep['name']}: {basename} 的 sha256 与 deps.lock 不一致,继续按哈希扫描")

    for path in sorted(p for p in src.iterdir() if p.is_file()):
        if path == candidate:
            continue
        actual = hash_cache.setdefault(path, sha256_file(path))
        if actual == dep["sha256"]:
            return path, actual

    if candidate.is_file():
        actual = hash_cache[candidate]
        return candidate, actual
    return None, None


def is_license_rel(rel: str) -> bool:
    rel = rel.replace("\\", "/").lstrip("./")
    if not rel:
        return False
    base = posixpath.basename(rel)
    lower = base.lower()
    if lower.endswith(BAD_LICENSE_SUFFIXES):
        return False
    if LICENSE_SPECIAL_RE.match(rel):
        return True
    if rel.lower().startswith("licenses/") and rel.count("/") == 1:
        return lower.endswith((".txt", ".md"))
    if not LICENSE_NAME_RE.match(base):
        return False
    parts = rel.split("/")
    if len(parts) > 4:
        return False
    first = parts[0].lower()
    if first in EXCLUDED_LICENSE_DIRS:
        return False
    return True


def extract_license_files(
    archive: Path,
    dep_name: str,
    lic_root: Path,
) -> tuple[list[str], list[str]]:
    """从源码包中只读抽取许可文件;返回 (复制的相对路径, 源内相对路径)。"""
    copied: list[str] = []
    sources: list[str] = []
    if not archive.is_file():
        return copied, sources

    try:
        tf = tarfile.open(archive, "r:*")
    except (tarfile.TarError, OSError) as exc:
        warn(f"{dep_name}: 无法读取源码包 {archive.name}: {exc}")
        return copied, sources

    with tf:
        members = [m for m in tf.getmembers() if m.isfile()]
        names = [m.name.lstrip("./") for m in members]
        tops = {n.split("/", 1)[0] for n in names if "/" in n}
        top = next(iter(tops)) if len(tops) == 1 else ""

        selected: list[tuple[str, tarfile.TarInfo]] = []
        for member, name in zip(members, names):
            if name.startswith("./"):
                name = name[2:]
            if top and name.startswith(top + "/"):
                rel = name[len(top) + 1 :]
            else:
                rel = name
            rel = posixpath.normpath(rel)
            if rel.startswith("../") or "/../" in rel or rel == "..":
                continue
            if not is_license_rel(rel):
                continue
            if member.size > 2 * 1024 * 1024:
                warn(f"{dep_name}: 跳过超过 2 MiB 的许可候选 {rel}")
                continue
            selected.append((rel, member))

        for rel, member in sorted(selected, key=lambda item: item[0]):
            dest = lic_root / dep_name / Path(rel)
            dest.parent.mkdir(parents=True, exist_ok=True)
            fh = tf.extractfile(member)
            if fh is None:
                continue
            data = fh.read()
            if not data.strip():
                continue
            dest.write_bytes(data)
            copied.append(str(dest.relative_to(lic_root.parent)))
            sources.append(rel)

    return copied, sources


def detect_terms(texts: list[str]) -> list[str]:
    """只报告许可文本里出现的条款族,不做适用判断。"""
    blob = "\n".join(texts)
    terms: list[str] = []

    def has(pat: str) -> bool:
        return re.search(pat, blob, re.IGNORECASE | re.MULTILINE) is not None

    def heading_version(heading: str) -> str | None:
        # 只认独占一行的标题,避免把正文里的 “the ordinary GNU General
        # Public License, version 2” 误判成 GPL 条款。
        m = re.search(
            r"^[ \t]*" + heading + r"[ \t]*\r?\n[ \t]*Version[ \t]+([0-9]+(?:\.[0-9]+)?)",
            blob,
            re.IGNORECASE | re.MULTILINE,
        )
        return m.group(1) if m else None

    if has(r"FreeType Project LICENSE"):
        terms.append("FTL")
    lgpl_version = heading_version(r"GNU LESSER GENERAL PUBLIC LICENSE")
    gpl_version = heading_version(r"GNU GENERAL PUBLIC LICENSE")
    if lgpl_version == "2.1":
        terms.append("LGPL-2.1")
    if lgpl_version and lgpl_version.startswith("3"):
        terms.append("LGPL-3.0")
    if gpl_version and gpl_version.startswith("2"):
        terms.append("GPL-2.0")
    if gpl_version and gpl_version.startswith("3"):
        terms.append("GPL-3.0")
    if has(r"MOZILLA PUBLIC LICENSE[\s\S]{0,120}?Version 1\.1"):
        terms.append("MPL-1.1")
    if has(r"Apache License[\s\S]{0,80}?Version 2\.0"):
        terms.append("Apache-2.0")
    if has(r"\bMIT License\b") or has(r"Permission is hereby granted, free of charge"):
        terms.append("MIT")
    if has(r"\bISC License\b") or has(
        r"Permission to use, copy, modify, and/or distribute this software for any"
    ):
        terms.append("ISC")
    if has(r"This (?:software|source code) is provided 'as-is'") and has(r"Altered source versions"):
        terms.append("Zlib")
    if has(r"3-Clause BSD License") or (
        has(r"Redistribution and use in source and binary forms") and has(r"Neither the name")
    ):
        terms.append("BSD-3-Clause")
    if has(r"2-Clause BSD License"):
        terms.append("BSD-2-Clause")
    if has(r"Boost Software License"):
        terms.append("BSL-1.0")
    if has(r"Creative Commons Attribution 4\.0"):
        terms.append("CC-BY-4.0")
    if has(r"Khronos Free Use"):
        terms.append("Khronos-Free-Use")

    order = [
        "FTL",
        "LGPL-2.1",
        "LGPL-3.0",
        "GPL-2.0",
        "GPL-3.0",
        "MPL-1.1",
        "Apache-2.0",
        "MIT",
        "ISC",
        "Zlib",
        "BSD-3-Clause",
        "BSD-2-Clause",
        "BSL-1.0",
        "CC-BY-4.0",
        "Khronos-Free-Use",
    ]
    return [t for t in order if t in terms]


def parse_build_info(path: Path) -> dict[str, str]:
    info: dict[str, str] = {}
    if not path.is_file():
        return info
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in raw and not raw.lstrip().startswith("#"):
            key, value = raw.split("=", 1)
            info[key.strip()] = value.strip()
    return info


def parse_config_macros(path: Path) -> dict[str, int]:
    macros: dict[str, int] = {}
    if not path.is_file():
        return macros
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"^#define CONFIG_(GPL|NONFREE|VERSION3|LGPLV3) ([01])$", raw.strip())
        if m:
            macros[m.group(1)] = int(m.group(2))
    return macros


def spdx_from_build_license(value: str) -> str:
    low = (value or "").lower()
    if "version 3" in low:
        return "LGPL-3.0-or-later"
    if "version 2.1" in low:
        return "LGPL-2.1-or-later"
    return "待法务确认"


def map_dependency(dep_path: str) -> tuple[str | None, str | None]:
    """把 otool 依赖路径映射到 deps.lock 名称与 Framework 名。"""
    framework = None
    m = re.search(r"/([^/]+)\.framework/", dep_path)
    if m:
        framework = m.group(1)
    base = posixpath.basename(dep_path)
    base = re.sub(r"\.dylib$", "", base)
    base = re.sub(r"\.\d+(\.[0-9]+)*$", "", base)
    low = base.lower()
    if low.startswith("libav") or low.startswith("libsw"):
        return "ffmpeg", framework
    if low.startswith("libmpv"):
        return "mpv", framework
    if low.startswith("libplacebo"):
        return "libplacebo", framework
    if low.startswith("libfribidi"):
        return "fribidi", framework
    if low.startswith("libuchardet"):
        return "uchardet", framework
    if low.startswith("libass"):
        return "libass", framework
    if low.startswith("libfreetype"):
        return "freetype", framework
    if low.startswith("libharfbuzz"):
        return "harfbuzz", framework
    if low.startswith("libunibreak"):
        return "libunibreak", framework
    if low.startswith("liblcms2"):
        return "lcms2", framework
    if low.startswith("libshaderc"):
        return "shaderc", framework
    if low.startswith("libmoltenvk"):
        return "moltenvk", framework
    if low.startswith("libspirvcross"):
        return "spirv-cross", framework
    if low.startswith("libspirvtools"):
        return "spirv-tools", framework
    return None, framework


def otool_dependencies(binary: Path) -> tuple[list[str], str]:
    proc = run(["otool", "-L", str(binary)])
    if proc.returncode != 0:
        return [], proc.stderr.strip()
    lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    deps: list[str] = []
    for line in lines[1:]:
        path = line.split(" (compatibility", 1)[0].strip()
        if path:
            deps.append(path)
    if deps:
        # otool -L 的第一条依赖是自身的 install name。
        deps = deps[1:]
    return deps, ""


def display_path(path: Path, artifact_root: Path, repo: Path) -> str:
    """构建产物路径:优先仓库相对路径;落在仓库外时用 $BUILD 占位。"""
    p = os.path.normpath(str(path))
    ar = os.path.normpath(str(artifact_root))
    if p == ar:
        return "$BUILD"
    if p.startswith(ar + os.sep):
        rel = p[len(ar) + 1 :]
        if (ar + os.sep).startswith(os.path.normpath(str(repo)) + os.sep):
            return repo_rel(path, repo)
        return "$BUILD/" + rel.replace(os.sep, "/")
    return repo_rel(path, repo)


def find_stack_binary(
    lux: Path, target: str, framework: str, artifact_root: Path | None = None
) -> tuple[Path | None, str, str]:
    """优先用已打包的 framework,否则回退到 deps 里的 dylib。"""
    roots = [lux / ".build"]
    if artifact_root is not None and artifact_root != lux / ".build":
        roots.append(artifact_root)
    for root in roots:
        fw_path = root / "mpv-frameworks" / target / f"{framework}.framework" / framework
        if fw_path.is_file():
            return fw_path, "framework", f"otool -L {display_path(fw_path, artifact_root or root, lux.parent)}"
    libdir = lux / ".build" / "deps" / target / "install" / "lib"
    stem = STACK_STEMS[framework]
    candidates: list[Path] = []
    if libdir.is_dir():
        candidates.extend(sorted(libdir.glob(f"{stem}.*.dylib")))
        candidates.extend(sorted(libdir.glob(f"{stem}.dylib")))
    real = [p for p in candidates if p.is_file() and not p.is_symlink()]
    if real:
        path = real[0]
        return path, "dylib", f"otool -L {repo_rel(path, lux.parent)}"
    return None, "missing", ""


def find_vulkan_binary(
    lux: Path, target: str, framework: str, artifact_root: Path | None = None
) -> tuple[Path | None, str, str]:
    """B+ Vulkan framework:优先 vulkan-frameworks/<target>/slice,回退 deps dylib。"""
    roots = [lux / ".build"]
    if artifact_root is not None and artifact_root != lux / ".build":
        roots.append(artifact_root)
    for root in roots:
        fw_path = root / "vulkan-frameworks" / target / "slice" / f"{framework}.framework" / framework
        if fw_path.is_file():
            return fw_path, "framework", f"otool -L {display_path(fw_path, artifact_root or root, lux.parent)}"
    libdir = lux / ".build" / "deps" / target / "install" / "lib"
    stem = VULKAN_STEMS[framework]
    path = libdir / f"{stem}.dylib"
    if path.is_file():
        return path, "dylib", f"otool -L {repo_rel(path, lux.parent)}"
    return None, "missing", ""


def symbol_probe(binary: Path, needles: list[str]) -> list[str]:
    if not binary.is_file():
        return []
    proc = run(["nm", "-gU", str(binary)])
    if proc.returncode != 0:
        return []
    text = proc.stdout
    return [needle for needle in needles if needle in text]


def load_ffmpeg_target(
    repo: Path, artifact_root: Path, target: str, ffmpeg_configure_text: str
) -> dict:
    build_dir = artifact_root / target
    install_lib = build_dir / "install" / "lib"
    build_info_path = build_dir / "BUILD-INFO.txt"
    config_h = build_dir / "config.h"
    opts_path = build_dir / "configure.opts.txt"
    info = parse_build_info(build_info_path)
    macros = parse_config_macros(config_h)
    opts = []
    if opts_path.is_file():
        opts = [
            line.strip()
            for line in opts_path.read_text(encoding="utf-8", errors="replace").splitlines()
            if line.strip()
        ]
    version3 = "--enable-version3" in opts or macros.get("VERSION3") == 1
    build_license = info.get("license", "")
    build_spdx = spdx_from_build_license(build_license)
    if version3 and build_spdx == "LGPL-2.1-or-later":
        build_spdx = "LGPL-3.0-or-later"
    config_claims_version3 = bool(
        re.search(r"^\s*--enable-version3\s*$", ffmpeg_configure_text, re.MULTILINE)
    )

    libraries: list[dict] = []
    for lib in FFMPEG_LIBS:
        static_path = install_lib / f"{lib}.a"
        fw_name = FFMPEG_FRAMEWORKS[lib]
        slice_name = FRAMEWORK_SLICE[target]
        fw_path = (
            artifact_root
            / "xcframeworks"
            / f"{fw_name}.xcframework"
            / slice_name
            / f"{fw_name}.framework"
            / fw_name
        )
        libraries.append(
            {
                "name": lib,
                "license": build_spdx,
                "license_status": (
                    "needs-legal-review" if version3 or not build_info_path.is_file() else "identified"
                ),
                "static_library": display_path(static_path, artifact_root, repo) if static_path.is_file() else None,
                "static_library_size": static_path.stat().st_size if static_path.is_file() else None,
                "framework_binary": display_path(fw_path, artifact_root, repo) if fw_path.is_file() else None,
                "framework_binary_size": fw_path.stat().st_size if fw_path.is_file() else None,
            }
        )

    notes = []
    if not build_info_path.is_file():
        notes.append("缺少 BUILD-INFO.txt,无法核对产物许可")
    if not config_h.is_file():
        notes.append("缺少 config.h,无法核对 CONFIG_GPL/CONFIG_VERSION3")
    if version3:
        notes.append(
            "configure.opts.txt 含 --enable-version3 或 config.h 的 CONFIG_VERSION3=1;"
            f"BUILD-INFO 记录许可为“{build_license or '缺失'}”"
        )
    if version3 and not config_claims_version3:
        notes.append(
            "当前 lux/config/ffmpeg-ios.conf 没有生效的 --enable-version3 行,"
            "但该切片产物启用了 version3;产物可能早于当前配置,待法务确认"
        )

    return {
        "target": target,
        "build_info": display_path(build_info_path, artifact_root, repo) if build_info_path.is_file() else None,
        "configure_opts": display_path(opts_path, artifact_root, repo) if opts_path.is_file() else None,
        "license_recorded": build_license or "待法务确认",
        "license": build_spdx,
        "license_status": "needs-legal-review" if (version3 or not build_info_path.is_file()) else "identified",
        "version3": version3,
        "config_macros": macros,
        "configure_has_disable_gpl": "--disable-gpl" in opts,
        "configure_has_disable_nonfree": "--disable-nonfree" in opts,
        "configure_has_enable_version3": "--enable-version3" in opts,
        "libraries": libraries,
        "notes": notes,
    }


def main() -> int:
    if len(sys.argv) < 2:
        die("内部错误:缺少仓库路径")
    repo = Path(sys.argv[1]).absolute()
    args = sys.argv[2:]
    lux = repo / "lux"
    out_dir = lux / "release"
    lic_root = out_dir / "licenses"
    src_dir = lux / ".build" / "deps" / "src"
    deps_lock_path = lux / "config" / "deps.lock"
    patches_list_path = lux / "config" / "patches.txt"
    ffmpeg_conf_path = lux / "config" / "ffmpeg-ios.conf"
    apply_patches = lux / "build" / "apply-patches.sh"

    target_filter: str | None = None
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in ("-h", "--help"):
            print("用法: lux/build/make-license-bundle.sh [--target <macos-arm64|ios-arm64|ios-sim-arm64>]")
            print("输出: lux/release/source-manifest.json, lux/release/NOTICE.md, lux/release/licenses/")
            return 0
        if arg == "--target":
            i += 1
            if i >= len(args):
                die("--target 缺少参数")
            target_filter = args[i]
        elif arg.startswith("--target="):
            target_filter = arg.split("=", 1)[1]
        else:
            die(f"未知参数: {arg}")
        i += 1

    if not deps_lock_path.is_file():
        die(f"找不到 {deps_lock_path}")
    if not src_dir.is_dir():
        die(f"找不到源码目录 {src_dir};先创建符号链接: ln -s <主检出>/lux/.build/deps lux/.build/deps")

    # deps/src 常常是指向主检出的符号链接;FFmpeg 的 .build/<target> 与
    # xcframeworks 可能也在同一棵构建树里。优先本地 .build,缺失时用符号链接
    # 指向的那棵构建树,避免为了读产物再建额外的符号链接。
    build_root = lux / ".build"
    artifact_root = build_root
    real_build_root = src_dir.resolve().parent.parent
    if not (build_root / "macos-arm64").is_dir() and (real_build_root / "macos-arm64").is_dir():
        artifact_root = real_build_root
        log(f"artifact root: {artifact_root}(本地 .build 没有 FFmpeg 产物)")

    conf_text = ffmpeg_conf_path.read_text(encoding="utf-8") if ffmpeg_conf_path.is_file() else ""
    m = re.search(r'^LUX_TARGETS="([^"]*)"', conf_text, re.MULTILINE)
    default_targets = m.group(1).split() if m else ["macos-arm64", "ios-arm64", "ios-sim-arm64"]
    targets = [target_filter] if target_filter else default_targets
    if not targets:
        die("没有可处理的目标")
    for target in targets:
        if target not in FRAMEWORK_SLICE:
            die(f"未知目标: {target}(可用: {' '.join(FRAMEWORK_SLICE)})")
    log(f"targets: {' '.join(targets)}")

    # 输出目录整体重建,保证重复运行没有旧文件残留。
    out_dir.mkdir(parents=True, exist_ok=True)
    if lic_root.exists():
        shutil.rmtree(lic_root)
    lic_root.mkdir(parents=True)
    (out_dir / "source-manifest.json").unlink(missing_ok=True)
    (out_dir / "NOTICE.md").unlink(missing_ok=True)

    deps = parse_deps_lock(deps_lock_path)
    log(f"deps.lock: {len(deps)} 项")

    hash_cache: dict[Path, str] = {}
    missing: list[dict] = []
    anomalies: list[dict] = []
    dep_records: list[dict] = []
    dep_by_name: dict[str, dict] = {}

    for dep in deps:
        name = dep["name"]
        archive, actual_sha = find_archive(src_dir, dep, hash_cache)
        copied: list[str] = []
        sources: list[str] = []
        if archive is None:
            missing.append(
                {
                    "kind": "source-archive",
                    "name": name,
                    "detail": "deps/src 中找不到 URL basename 或 sha256 匹配的源码包",
                }
            )
            warn(f"{name}: 找不到源码包")
        else:
            copied, sources = extract_license_files(archive, name, lic_root)
            if not copied:
                missing.append(
                    {
                        "kind": "license-files",
                        "name": name,
                        "detail": f"{archive.name} 内未找到 COPYING/LICENSE/LICENCE 等许可文件",
                    }
                )
                warn(f"{name}: 找不到许可文件")

        texts: list[str] = []
        for rel in copied:
            try:
                texts.append((out_dir / rel).read_text(encoding="utf-8", errors="replace")[:500_000])
            except OSError:
                pass
        detected = detect_terms(texts) if texts else []

        license_text, status, gpl_terms, notes = LICENSE_FACTS.get(
            name,
            (
                "待法务确认",
                "needs-legal-review",
                False,
                "脚本没有该依赖的内置许可事实,见许可文件。",
            ),
        )
        if not copied:
            status = "missing"
            license_text = "待法务确认"
        elif status == "identified" and any(t.startswith("GPL") for t in detected):
            # 已识别条目却抽到 GPL 文本:不擅自下结论,转为待法务确认。
            if "GPL" not in license_text:
                status = "needs-legal-review"
                notes += " 许可文件里出现 GPL 条款,与内置事实不一致,待法务确认。"
        if archive is None:
            status = "missing"

        sha_match = bool(actual_sha and actual_sha == dep["sha256"])
        if archive is not None and not sha_match:
            anomalies.append(
                {
                    "kind": "sha256-mismatch",
                    "name": name,
                    "expected": dep["sha256"],
                    "actual": actual_sha,
                    "detail": "源码包 sha256 与 deps.lock 不一致",
                }
            )
            warn(f"{name}: sha256 不一致")

        record = {
            "name": name,
            "version": dep["version"],
            "sha256": dep["sha256"],
            "url": dep["url"],
            "archive": repo_rel(archive, repo) if archive else None,
            "archive_sha256": actual_sha,
            "sha256_verified": sha_match,
            "license": license_text,
            "license_status": status,
            "license_notes": notes,
            "license_files": copied,
            "license_source_files": sources,
            "license_terms_detected": detected,
            "gpl_or_nonfree_terms": bool(gpl_terms),
            "linkage": [],
        }
        dep_records.append(record)
        dep_by_name[name] = record

    # ---------------------------------------------------------------- FFmpeg
    # 源码身份取“最近一次触及源码的提交”,排除本清单自身的输出与脚本。
    # 这样提交清单文件不会改变清单里记录的源码 commit,重复运行保持稳定。
    source_log = run(
        [
            "git",
            "-C",
            str(repo),
            "log",
            "-1",
            "--format=%H%n%cI%n%s",
            "--",
            ".",
            ":(exclude)lux/release",
            ":(exclude)lux/build/make-license-bundle.sh",
        ]
    )
    head_commit = ""
    commit_date = ""
    commit_subject = ""
    if source_log.returncode == 0 and source_log.stdout.strip():
        lines = source_log.stdout.splitlines()
        head_commit = lines[0].strip()
        commit_date = lines[1].strip() if len(lines) > 1 else ""
        commit_subject = lines[2].strip() if len(lines) > 2 else ""
    if not head_commit:
        git_head = run(["git", "-C", str(repo), "rev-parse", "HEAD"])
        head_commit = git_head.stdout.strip() if git_head.returncode == 0 else ""
    git_branch = run(["git", "-C", str(repo), "rev-parse", "--abbrev-ref", "HEAD"])
    branch = git_branch.stdout.strip() if git_branch.returncode == 0 else ""

    patches_digest_proc = run(["bash", str(apply_patches), "digest"])
    patches_digest = patches_digest_proc.stdout.strip() if patches_digest_proc.returncode == 0 else ""
    patches_count_proc = run(["bash", str(apply_patches), "count"])
    patches_count = patches_count_proc.stdout.strip() if patches_count_proc.returncode == 0 else ""

    patch_entries: list[dict] = []
    if patches_list_path.is_file():
        for raw in patches_list_path.read_text(encoding="utf-8").splitlines():
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            patch_name = line.split()[0]
            patch_path = lux / "patches" / patch_name
            patch_entries.append(
                {
                    "name": patch_name,
                    "sha256": sha256_file(patch_path) if patch_path.is_file() else None,
                }
            )

    ffmpeg_targets: dict[str, dict] = {}
    for target in targets:
        ffmpeg_targets[target] = load_ffmpeg_target(repo, artifact_root, target, conf_text)
        tinfo = ffmpeg_targets[target]
        for lib in tinfo["libraries"]:
            if lib["static_library"] is None:
                missing.append(
                    {
                        "kind": "ffmpeg-static-library",
                        "name": f"{target}:{lib['name']}",
                        "detail": "缺少 lux/.build/<target>/install/lib/*.a",
                    }
                )
            if lib["framework_binary"] is None:
                missing.append(
                    {
                        "kind": "ffmpeg-framework-slice",
                        "name": f"{target}:{lib['name']}",
                        "detail": "缺少 xcframework 切片二进制(静态库仍可用于清单)",
                    }
                )

    ffmpeg_licenses = sorted({t["license"] for t in ffmpeg_targets.values()})
    if len(ffmpeg_licenses) == 1:
        ffmpeg_license = ffmpeg_licenses[0]
    else:
        parts = [
            f"{target}={info['license']}"
            for target, info in ffmpeg_targets.items()
        ]
        ffmpeg_license = "按切片不同:" + ";".join(parts) + "(待法务确认)"
    ffmpeg_status = (
        "needs-legal-review"
        if (
            len(ffmpeg_licenses) != 1
            or any(t["version3"] for t in ffmpeg_targets.values())
            or any(t["license_status"] == "needs-legal-review" for t in ffmpeg_targets.values())
            or any(t["license"] == "待法务确认" for t in ffmpeg_targets.values())
        )
        else "identified"
    )

    ffmpeg_files: list[str] = []
    ffmpeg_lic_dir = lic_root / "ffmpeg"
    ffmpeg_lic_dir.mkdir(parents=True, exist_ok=True)
    for fname in (
        "COPYING.LGPLv2.1",
        "COPYING.LGPLv3",
        "COPYING.GPLv2",
        "COPYING.GPLv3",
        "LICENSE.md",
    ):
        src = repo / fname
        if src.is_file():
            dest = ffmpeg_lic_dir / fname
            shutil.copyfile(src, dest)
            ffmpeg_files.append(str(dest.relative_to(out_dir)))
        else:
            missing.append(
                {
                    "kind": "license-files",
                    "name": "ffmpeg",
                    "detail": f"仓库根目录缺少 {fname}",
                }
            )

    ffmpeg_component = {
        "name": "ffmpeg",
        "kind": "ffmpeg-source-tree",
        "version": (re.search(r'^LUX_BASELINE_LABEL="([^"]*)"', conf_text, re.MULTILINE).group(1)
                    if re.search(r'^LUX_BASELINE_LABEL="([^"]*)"', conf_text, re.MULTILINE)
                    else "待法务确认"),
        "license": ffmpeg_license,
        "license_status": ffmpeg_status,
        "license_files": ffmpeg_files,
        "gpl_or_nonfree_terms": True,
        "source": {
            "repository": "lux-ffmpeg",
            "head_commit": head_commit or None,
            "head_commit_date": commit_date or None,
            "head_commit_subject": commit_subject or None,
            "branch": branch or None,
            "patches_txt": repo_rel(patches_list_path, repo),
            "patches_txt_sha256": sha256_file(patches_list_path) if patches_list_path.is_file() else None,
            "patches_digest": patches_digest or None,
            "patches_count": int(patches_count) if patches_count.isdigit() else None,
            "configure_file": repo_rel(ffmpeg_conf_path, repo),
            "configure_sha256": sha256_file(ffmpeg_conf_path) if ffmpeg_conf_path.is_file() else None,
            "patches": patch_entries,
        },
        "targets": ffmpeg_targets,
    }

    # ---------------------------------------------------------------- libmpv stack
    stack_targets: dict[str, dict] = {}
    dynamic_into: dict[str, set[str]] = {}
    dynamic_targets: dict[str, set[str]] = {}
    stack_missing: list[dict] = []

    for target in targets:
        frameworks: dict[str, dict] = {}
        for fw in STACK_FRAMEWORKS:
            binary, kind, command = find_stack_binary(lux, target, fw, artifact_root)
            entry: dict = {
                "binary": repo_rel(binary, repo) if binary else None,
                "binary_kind": kind,
                "otool_command": command or None,
                "dynamic_dependencies": [],
                "system_dependencies": [],
                "non_system_dependencies": [],
            }
            if binary is None:
                stack_missing.append(
                    {
                        "kind": "stack-binary",
                        "name": f"{target}:{fw}",
                        "detail": "既没有 mpv-frameworks framework,也没有 deps/<target>/install/lib 下的 dylib",
                    }
                )
                frameworks[fw] = entry
                continue

            deps_paths, err = otool_dependencies(binary)
            if err:
                stack_missing.append(
                    {
                        "kind": "otool-failed",
                        "name": f"{target}:{fw}",
                        "detail": err,
                    }
                )
            for raw in deps_paths:
                norm = normalize_path(raw, target, repo)
                if raw.startswith("/usr/lib/") or raw.startswith("/System/"):
                    entry["system_dependencies"].append(norm)
                    continue
                dep_name, framework_name = map_dependency(raw)
                item = {
                    "raw": norm,
                    "deps_lock_name": dep_name,
                    "framework": framework_name,
                    "license": (
                        dep_by_name[dep_name]["license"] if dep_name in dep_by_name else "待法务确认"
                    ),
                }
                entry["non_system_dependencies"].append(item)
                entry["dynamic_dependencies"].append(norm)
                if dep_name:
                    dynamic_into.setdefault(dep_name, set()).add(fw)
                    dynamic_targets.setdefault(dep_name, set()).add(target)
                else:
                    anomalies.append(
                        {
                            "kind": "unmapped-dependency",
                            "name": f"{target}:{fw}",
                            "detail": f"otool -L 依赖未在 deps.lock 找到来源: {norm}",
                        }
                    )
            source_name = STACK_SOURCE[fw]
            source_dep = dep_by_name.get(source_name, {})
            entry["source_dependency"] = source_name
            entry["license"] = source_dep.get("license", "待法务确认")
            entry["license_status"] = source_dep.get("license_status", "needs-legal-review")
            frameworks[fw] = entry

        stack_targets[target] = {"frameworks": frameworks}

    # ---------------------------------------------------------------- Vulkan 运行时
    vulkan_targets: dict[str, dict] = {}
    vulkan_missing: list[dict] = []
    for target in targets:
        frameworks: dict[str, dict] = {}
        for fw in VULKAN_FRAMEWORKS:
            binary, kind, command = find_vulkan_binary(lux, target, fw, artifact_root)
            entry: dict = {
                "binary": repo_rel(binary, repo) if binary else None,
                "binary_kind": kind,
                "otool_command": command or None,
                "dynamic_dependencies": [],
                "system_dependencies": [],
                "non_system_dependencies": [],
            }
            if binary is None:
                vulkan_missing.append(
                    {
                        "kind": "vulkan-binary",
                        "name": f"{target}:{fw}",
                        "detail": "vulkan-frameworks/<target>/slice 与 deps/<target>/install/lib 下都没有二进制",
                    }
                )
                frameworks[fw] = entry
                continue

            deps_paths, err = otool_dependencies(binary)
            if err:
                vulkan_missing.append(
                    {"kind": "otool-failed", "name": f"{target}:{fw}", "detail": err}
                )
            for raw in deps_paths:
                norm = normalize_path(raw, target, repo)
                if raw.startswith("/usr/lib/") or raw.startswith("/System/"):
                    entry["system_dependencies"].append(norm)
                    continue
                dep_name, framework_name = map_dependency(raw)
                item = {
                    "raw": norm,
                    "deps_lock_name": dep_name,
                    "framework": framework_name,
                    "license": (
                        dep_by_name[dep_name]["license"] if dep_name in dep_by_name else "待法务确认"
                    ),
                }
                entry["non_system_dependencies"].append(item)
                entry["dynamic_dependencies"].append(norm)
                if dep_name:
                    dynamic_into.setdefault(dep_name, set()).add(fw)
                    dynamic_targets.setdefault(dep_name, set()).add(target)
                else:
                    anomalies.append(
                        {
                            "kind": "unmapped-dependency",
                            "name": f"{target}:{fw}",
                            "detail": f"otool -L 依赖未在 deps.lock 找到来源: {norm}",
                        }
                    )
            source_name = VULKAN_SOURCE[fw]
            source_dep = dep_by_name.get(source_name, {})
            entry["source_dependency"] = source_name
            entry["license"] = source_dep.get("license", "待法务确认")
            entry["license_status"] = source_dep.get("license_status", "needs-legal-review")
            frameworks[fw] = entry
        vulkan_targets[target] = {"frameworks": frameworks}

    # 静态并入的符号证据
    static_evidence: dict[str, dict[str, list[str]]] = {}
    probes = {
        "libass": ["_ass_library_init", "_ass_renderer_init"],
        "freetype": ["_FT_Init_FreeType"],
        "harfbuzz": ["_hb_buffer_create"],
        "libunibreak": ["_init_linebreak", "_set_linebreaks_utf8"],
        "lcms2": ["_cmsCreateTransform", "_cmsOpenProfileFromMem"],
        "moltenvk": ["_vkCreateInstance"],
        "shaderc": ["shaderc_compile_into_spv"],
    }
    for target in targets:
        for fw, needles in (("Libmpv", ["libass", "freetype", "harfbuzz", "libunibreak"]),
                            ("Libplacebo", ["lcms2"])):
            binary, kind, _ = find_stack_binary(lux, target, fw, artifact_root)
            if binary is None:
                continue
            for dep_name in needles:
                hits = symbol_probe(binary, probes[dep_name])
                if hits:
                    static_evidence.setdefault(dep_name, {}).setdefault(target, []).extend(
                        f"{fw}:{hit}" for hit in hits
                    )

    stack_components: list[dict] = []
    for fw in STACK_FRAMEWORKS:
        source_name = STACK_SOURCE[fw]
        source_dep = dep_by_name.get(source_name, {})
        static_items = []
        for dep_name, (kind, into, evidence) in STATIC_LINKAGE.items():
            if fw not in into:
                continue
            symbol_hits = static_evidence.get(dep_name, {})
            item = {
                "name": dep_name,
                "kind": kind,
                "evidence": evidence,
            }
            if symbol_hits:
                item["symbol_evidence"] = {
                    target: hits for target, hits in symbol_hits.items()
                }
            static_items.append(item)
        bundled_gpl = [
            item["name"]
            for item in static_items
            if dep_by_name.get(item["name"], {}).get("gpl_or_nonfree_terms")
        ]
        component_status = source_dep.get("license_status", "needs-legal-review")
        if bundled_gpl:
            component_status = "needs-legal-review"
        stack_components.append(
            {
                "name": fw,
                "kind": "libmpv-stack-framework",
                "source_dependency": source_name,
                "license": source_dep.get("license", "待法务确认"),
                "license_status": component_status,
                "license_notes": source_dep.get("license_notes", ""),
                "bundled_gpl_review": bundled_gpl,
                "license_files": source_dep.get("license_files", []),
                "targets": {
                    target: stack_targets[target]["frameworks"].get(fw, {})
                    for target in targets
                },
                "statically_linked": static_items,
            }
        )

    # B+:Vulkan 运行时 framework 组件
    vulkan_components: list[dict] = []
    for fw in VULKAN_FRAMEWORKS:
        source_name = VULKAN_SOURCE[fw]
        source_dep = dep_by_name.get(source_name, {})
        static_items = []
        for dep_name, (kind, into, evidence) in STATIC_LINKAGE.items():
            if fw not in into:
                continue
            item = {"name": dep_name, "kind": kind, "evidence": evidence}
            symbol_hits = static_evidence.get(dep_name, {})
            if symbol_hits:
                item["symbol_evidence"] = {
                    target: hits for target, hits in symbol_hits.items()
                }
            static_items.append(item)
        bundled_gpl = [
            item["name"]
            for item in static_items
            if dep_by_name.get(item["name"], {}).get("gpl_or_nonfree_terms")
        ]
        component_status = source_dep.get("license_status", "needs-legal-review")
        if bundled_gpl:
            component_status = "needs-legal-review"
        vulkan_components.append(
            {
                "name": fw,
                "kind": "vulkan-framework",
                "source_dependency": source_name,
                "license": source_dep.get("license", "待法务确认"),
                "license_status": component_status,
                "license_notes": source_dep.get("license_notes", ""),
                "bundled_gpl_review": bundled_gpl,
                "license_files": source_dep.get("license_files", []),
                "targets": {
                    target: vulkan_targets[target]["frameworks"].get(fw, {})
                    for target in targets
                },
                "statically_linked": static_items,
            }
        )

    # 把动态/静态归属写回 deps 记录
    for record in dep_records:
        name = record["name"]
        links: list[dict] = []
        if name in dynamic_into:
            links.append(
                {
                    "kind": "dynamic",
                    "into": sorted(dynamic_into[name]),
                    "targets": sorted(dynamic_targets.get(name, [])),
                    "evidence": "otool -L " + ", ".join(
                        f"{t}:{f}" for t in sorted(dynamic_targets.get(name, []))
                        for f in sorted(dynamic_into[name])
                    ),
                }
            )
        if name in STATIC_LINKAGE:
            kind, into, evidence = STATIC_LINKAGE[name]
            links.append(
                {
                    "kind": kind,
                    "into": into,
                    "targets": targets,
                    "evidence": evidence,
                }
            )
        if name == "mpv":
            links.append(
                {
                    "kind": "framework-source",
                    "into": ["Libmpv"],
                    "targets": targets,
                    "evidence": "Libmpv.framework 的二进制来自 mpv 0.41.0 构建",
                }
            )
        if name == "libplacebo":
            links.append(
                {
                    "kind": "framework-source",
                    "into": ["Libplacebo"],
                    "targets": targets,
                    "evidence": "Libplacebo.framework 的二进制来自 libplacebo 7.360.1 构建",
                }
            )
        if name == "fribidi":
            links.append(
                {
                    "kind": "framework-source",
                    "into": ["Libfribidi"],
                    "targets": targets,
                    "evidence": "Libfribidi.framework 的二进制来自 fribidi 1.0.17 构建",
                }
            )
        if name == "uchardet":
            links.append(
                {
                    "kind": "framework-source",
                    "into": ["Libuchardet"],
                    "targets": targets,
                    "evidence": "Libuchardet.framework 的二进制来自 uchardet 0.0.8 构建",
                }
            )
        if name == "moltenvk":
            links.append(
                {
                    "kind": "framework-source",
                    "into": ["LibMoltenVK"],
                    "targets": targets,
                    "evidence": "LibMoltenVK.framework 的二进制来自 MoltenVK 1.4.2 libMoltenVK.a",
                }
            )
        if name == "shaderc":
            links.append(
                {
                    "kind": "framework-source",
                    "into": ["Libshaderc"],
                    "targets": targets,
                    "evidence": "Libshaderc.framework 的二进制来自 shaderc 2025.5 shaderc_shared",
                }
            )
        if not links:
            links.append(
                {
                    "kind": "unresolved",
                    "into": [],
                    "targets": [],
                    "evidence": "未在 otool -L 或静态归属表中定位",
                }
            )
            anomalies.append(
                {
                    "kind": "unresolved-linkage",
                    "name": name,
                    "detail": "依赖既不是动态依赖,也没有静态/构建期归属记录",
                }
            )
        record["linkage"] = links

    # FFmpeg 组件(六个库各一项)
    ffmpeg_components: list[dict] = []
    for lib in FFMPEG_LIBS:
        targets_info = {}
        for target in targets:
            lib_info = next(
                (item for item in ffmpeg_targets[target]["libraries"] if item["name"] == lib),
                None,
            )
            targets_info[target] = {
                "license": ffmpeg_targets[target]["license"],
                "license_status": ffmpeg_targets[target]["license_status"],
                "version3": ffmpeg_targets[target]["version3"],
                "static_library": lib_info["static_library"] if lib_info else None,
                "framework_binary": lib_info["framework_binary"] if lib_info else None,
            }
        ffmpeg_components.append(
            {
                "name": FFMPEG_FRAMEWORKS[lib],
                "kind": "ffmpeg-library",
                "source_dependency": "ffmpeg",
                "license": ffmpeg_license,
                "license_status": ffmpeg_status,
                "license_files": ffmpeg_files,
                "targets": targets_info,
                "internal_dependencies": {
                    "libavcodec": ["libavutil", "libswresample"],
                    "libavformat": ["libavcodec", "libavutil"],
                    "libavfilter": ["libavcodec", "libavformat", "libavutil", "libswscale", "libswresample"],
                    "libswscale": ["libavutil"],
                    "libswresample": ["libavutil"],
                    "libavutil": [],
                }.get(lib, []),
            }
        )

    # 待法务确认条目汇总
    review_items: list[dict] = []
    for comp in stack_components + vulkan_components:
        if comp.get("bundled_gpl_review"):
            review_items.append(
                {
                    "component": comp["name"],
                    "license": comp["license"],
                    "status": "needs-legal-review",
                    "note": "静态并入含 GPL 文本/选项的组件:"
                    + "、".join(comp["bundled_gpl_review"]),
                }
            )
    for record in dep_records:
        if record["license_status"] == "needs-legal-review" or record["license_status"] == "missing":
            review_items.append(
                {
                    "component": record["name"],
                    "license": record["license"],
                    "status": record["license_status"],
                    "note": record["license_notes"],
                }
            )
    if ffmpeg_status == "needs-legal-review":
        review_items.append(
            {
                "component": "ffmpeg",
                "license": ffmpeg_license,
                "status": "needs-legal-review",
                "note": "各切片产物记录的许可不一致或启用了 version3;见 ffmpeg.targets。",
            }
        )
    for target, info in ffmpeg_targets.items():
        if info["version3"]:
            review_items.append(
                {
                    "component": f"ffmpeg:{target}",
                    "license": info["license"],
                    "status": "needs-legal-review",
                    "note": "产物启用了 --enable-version3 / CONFIG_VERSION3=1;当前配置文件未写生效的 --enable-version3 行。",
                }
            )

    # 去重(组件 + 说明)
    seen_review = set()
    deduped_review = []
    for item in review_items:
        key = (item["component"], item["note"])
        if key in seen_review:
            continue
        seen_review.add(key)
        deduped_review.append(item)
    review_items = deduped_review

    if not head_commit:
        missing.append(
            {
                "kind": "git-identity",
                "name": "ffmpeg",
                "detail": "git rev-parse HEAD 失败,无法记录源码 commit",
            }
        )
    if not patches_digest:
        missing.append(
            {
                "kind": "patches-digest",
                "name": "ffmpeg",
                "detail": "apply-patches.sh digest 失败,无法记录补丁集指纹",
            }
        )
    if not ffmpeg_files:
        missing.append(
            {
                "kind": "license-files",
                "name": "ffmpeg",
                "detail": "仓库根目录没有可复制的 COPYING/LICENSE 文件",
            }
        )
    missing.extend(stack_missing)
    missing.extend(vulkan_missing)

    # 去重 missing
    seen_missing = set()
    deduped_missing = []
    for item in missing:
        key = (item["kind"], item["name"], item["detail"])
        if key in seen_missing:
            continue
        seen_missing.add(key)
        deduped_missing.append(item)
    missing = deduped_missing

    # 产物许可不一致的异常
    for target, info in ffmpeg_targets.items():
        if info["version3"]:
            anomalies.append(
                {
                    "kind": "artifact-license-version3",
                    "name": f"ffmpeg:{target}",
                    "detail": f"该切片产物记录为 {info['license']},当前配置未写生效的 --enable-version3;待法务确认",
                }
            )

    # ---------------------------------------------------------------- manifest
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "draft": True,
        "draft_notice": DRAFT,
        "scope": "FFmpeg 六库 + libmpv 栈(Libmpv/Libplacebo/Libfribidi/Libuchardet) + Vulkan 运行时(LibMoltenVK/Libshaderc)及其非系统依赖",
        "generated_by": "lux/build/make-license-bundle.sh",
        "repository": {
            "name": "lux-ffmpeg",
            "head_commit": head_commit or None,
            "head_commit_date": commit_date or None,
            "head_commit_subject": commit_subject or None,
            "head_commit_scope": "最近一次触及源码的提交(排除 lux/release 与本脚本)",
            "branch": branch or None,
        },
        "ffmpeg": ffmpeg_component,
        "libmpv_stack": {
            "targets": stack_targets,
            "components": stack_components,
            "non_system_dependencies": [
                {
                    "target": target,
                    "framework": fw,
                    "raw": dep["raw"],
                    "deps_lock_name": dep["deps_lock_name"],
                    "framework_dependency": dep["framework"],
                    "license": dep["license"],
                }
                for target in targets
                for fw in STACK_FRAMEWORKS
                for dep in stack_targets[target]["frameworks"].get(fw, {}).get(
                    "non_system_dependencies", []
                )
            ],
        },
        "vulkan_stack": {
            "targets": vulkan_targets,
            "components": vulkan_components,
            "non_system_dependencies": [
                {
                    "target": target,
                    "framework": fw,
                    "raw": dep["raw"],
                    "deps_lock_name": dep["deps_lock_name"],
                    "framework_dependency": dep["framework"],
                    "license": dep["license"],
                }
                for target in targets
                for fw in VULKAN_FRAMEWORKS
                for dep in vulkan_targets[target]["frameworks"].get(fw, {}).get(
                    "non_system_dependencies", []
                )
            ],
        },
        "components": ffmpeg_components + stack_components + vulkan_components,
        "dependencies": dep_records,
        "missing": missing,
        "anomalies": anomalies,
        "review_items": review_items,
        "gpl_nonfree_marker": "⚠ GPL/nonfree 需复核",
    }

    manifest_path = out_dir / "source-manifest.json"
    tmp_manifest = out_dir / ".source-manifest.json.tmp"
    tmp_manifest.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    os.replace(tmp_manifest, manifest_path)

    # ---------------------------------------------------------------- NOTICE
    def md(value: object) -> str:
        text = "" if value is None else str(value)
        return text.replace("|", "\\|").replace("\n", " ")

    def linkage_summary(record: dict) -> str:
        kinds = []
        for link in record["linkage"]:
            kind = link["kind"]
            into = "、".join(link.get("into", []))
            if kind == "dynamic":
                kinds.append(f"{into} 动态")
            elif kind == "static":
                kinds.append(f"{into} 静态")
            elif kind == "static-transitive":
                kinds.append(f"{into} 静态(传递)")
            elif kind == "build-time":
                kinds.append("构建期/头文件")
            elif kind == "header-only":
                kinds.append("头文件")
            elif kind == "framework-source":
                kinds.append(f"{into} 本体")
            else:
                kinds.append("未定位")
        return "、".join(dict.fromkeys(kinds)) if kinds else "未定位"

    def status_cn(status: str) -> str:
        return {
            "identified": "已定位(事实记录)",
            "needs-legal-review": "待法务确认",
            "missing": "缺失",
        }.get(status, status)

    lines: list[str] = []
    lines.append(f"# {DRAFT}")
    lines.append("")
    lines.append(
        "> 本文件由 `lux/build/make-license-bundle.sh` 生成,只整理源码包、构建产物和链接关系中的事实,"
        "不是法律意见,也不对许可适用作结论。标注“待法务确认”的条目需 D5/G4 法务审阅。"
    )
    lines.append("")
    lines.append("## 1. 生成范围与源码身份")
    lines.append("")
    lines.append(f"- 清单范围:{manifest['scope']}")
    lines.append(f"- 生成脚本:`{manifest['generated_by']}`")
    lines.append(f"- 仓库:lux-ffmpeg")
    lines.append(f"- 源码 HEAD(最近一次触及源码的提交,排除本清单生成物):`{head_commit or '缺失'}`")
    lines.append(f"- 分支:`{branch or '缺失'}`")
    lines.append(f"- 提交时间:`{commit_date or '缺失'}`")
    lines.append(f"- 提交标题:{commit_subject or '缺失'}")
    lines.append(
        f"- 补丁集:`lux/config/patches.txt` {len(patch_entries)} 条,"
        f"sha256 `{sha256_file(patches_list_path) if patches_list_path.is_file() else '缺失'}`"
    )
    lines.append(f"- apply-patches digest:`{patches_digest or '缺失'}`")
    lines.append(
        f"- 构建配置:`{repo_rel(ffmpeg_conf_path, repo)}`,"
        f"sha256 `{sha256_file(ffmpeg_conf_path) if ffmpeg_conf_path.is_file() else '缺失'}`"
    )
    lines.append("- 路径占位符:`$BUILD` = `lux/.build`;`$DEPS` = `lux/.build/deps`;`$REPO` = 仓库根目录。")
    lines.append("")

    lines.append("## 2. FFmpeg 六库")
    lines.append("")
    lines.append("| 目标 | 库 | 静态库 | Framework 切片 | 产物许可(草稿) | 状态 |")
    lines.append("| --- | --- | --- | --- | --- | --- |")
    for target in targets:
        info = ffmpeg_targets[target]
        for lib in info["libraries"]:
            lines.append(
                "| {t} | {n} | {s} | {f} | {lic} | {st} |".format(
                    t=md(target),
                    n=md(lib["name"]),
                    s=md(lib["static_library"] or "缺失"),
                    f=md(lib["framework_binary"] or "缺失"),
                    lic=md(info["license"]),
                    st=md(status_cn(info["license_status"])),
                )
            )
    lines.append("")
    for target in targets:
        info = ffmpeg_targets[target]
        lines.append(
            f"- `{target}`:BUILD-INFO 记录 `{info['license_recorded']}`;"
            f"version3={str(info['version3']).lower()};"
            f"--disable-gpl={str(info['configure_has_disable_gpl']).lower()};"
            f"--disable-nonfree={str(info['configure_has_disable_nonfree']).lower()}。"
        )
        for note in info["notes"]:
            lines.append(f"  - {note}")
    lines.append("")

    lines.append("## 3. libmpv 栈 Framework")
    lines.append("")
    lines.append("| 目标 | Framework | 二进制来源 | 许可(源码,草稿) | 状态 |")
    lines.append("| --- | --- | --- | --- | --- |")
    for target in targets:
        for fw in STACK_FRAMEWORKS:
            entry = stack_targets[target]["frameworks"].get(fw, {})
            comp = next((c for c in stack_components if c["name"] == fw), {})
            lines.append(
                "| {t} | {fw} | {src} | {lic} | {st} |".format(
                    t=md(target),
                    fw=md(fw),
                    src=md(entry.get("binary") or "缺失"),
                    lic=md(comp.get("license", "待法务确认")),
                    st=md(status_cn(comp.get("license_status", "needs-legal-review"))),
                )
            )
    lines.append("")

    lines.append("## 3b. Vulkan 运行时 Framework(LibMoltenVK / Libshaderc)")
    lines.append("")
    lines.append("| 目标 | Framework | 二进制来源 | 许可(源码,草稿) | 状态 |")
    lines.append("| --- | --- | --- | --- | --- |")
    for target in targets:
        for fw in VULKAN_FRAMEWORKS:
            entry = vulkan_targets[target]["frameworks"].get(fw, {})
            comp = next((c for c in vulkan_components if c["name"] == fw), {})
            lines.append(
                "| {t} | {fw} | {src} | {lic} | {st} |".format(
                    t=md(target),
                    fw=md(fw),
                    src=md(entry.get("binary") or "缺失"),
                    lic=md(comp.get("license", "待法务确认")),
                    st=md(status_cn(comp.get("license_status", "needs-legal-review"))),
                )
            )
    lines.append("")

    lines.append("## 4. Libmpv 栈的直接非系统依赖(otool -L)")
    lines.append("")
    for target in targets:
        lines.append(f"### {target}")
        lines.append("")
        lines.append("| Framework | 非系统依赖 | deps.lock 来源 |")
        lines.append("| --- | --- | --- |")
        any_dep = False
        for fw in STACK_FRAMEWORKS:
            entry = stack_targets[target]["frameworks"].get(fw, {})
            for dep in entry.get("non_system_dependencies", []):
                any_dep = True
                lines.append(
                    "| {fw} | `{raw}` | {src} |".format(
                        fw=md(fw),
                        raw=md(dep["raw"]),
                        src=md(dep["deps_lock_name"] or "未定位"),
                    )
                )
        if not any_dep:
            lines.append("| - | 无(或二进制缺失) | - |")
        lines.append("")
        for fw in STACK_FRAMEWORKS[1:] + VULKAN_FRAMEWORKS:
            entry = (
                stack_targets[target]["frameworks"].get(fw, {})
                if fw in STACK_FRAMEWORKS
                else vulkan_targets[target]["frameworks"].get(fw, {})
            )
            if entry.get("binary") and not entry.get("non_system_dependencies"):
                lines.append(f"- `{fw}`:otool -L 只有系统库,没有非系统动态依赖。")
        lines.append("")

    lines.append("otool -L 不显示静态并入的组件。以下为依据构建脚本/符号表整理的静态或构建期归属:")
    lines.append("")
    lines.append("| Framework | 组件 | 类型 | 依据 |")
    lines.append("| --- | --- | --- | --- |")
    for comp in stack_components:
        for item in comp["statically_linked"]:
            lines.append(
                "| {fw} | {n} | {k} | {e} |".format(
                    fw=md(comp["name"]),
                    n=md(item["name"]),
                    k=md(item["kind"]),
                    e=md(item["evidence"]),
                )
            )
    lines.append("")

    lines.append("## 5. 依赖与许可清单(deps.lock)")
    lines.append("")
    lines.append(f"deps.lock 共 {len(dep_records)} 项;sha256 校验结果与许可文件如下。")
    lines.append("")
    lines.append("| # | 依赖 | 版本 | 许可(草稿) | 状态 | 链接方式 | sha256 | 许可文件 |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for idx, record in enumerate(dep_records, 1):
        files = record["license_files"]
        if files:
            shown = ", ".join(f"`{md(p)}`" for p in files[:3])
            if len(files) > 3:
                shown += f" 等 {len(files)} 份"
        else:
            shown = "缺失"
        lines.append(
            "| {i} | {n} | {v} | {lic} | {st} | {lk} | {sha} | {files} |".format(
                i=idx,
                n=md(record["name"]),
                v=md(record["version"]),
                lic=md(record["license"]),
                st=md(status_cn(record["license_status"])),
                lk=md(linkage_summary(record)),
                sha=md("一致" if record["sha256_verified"] else "不一致/缺失"),
                files=shown,
            )
        )
    lines.append("")

    lines.append("## 6. ⚠ GPL/nonfree 需复核")
    lines.append("")
    lines.append(
        "本节按“清单中出现 GPL 文本、GPL 选项或 GPL 默认许可”列出条目并单独标记;"
        "是否构成 GPL/nonfree 许可适用,待法务确认。"
    )
    lines.append("")
    gpl_records = [r for r in dep_records if r["gpl_or_nonfree_terms"]]
    lines.append(
        "- <span style=\"color:red\">⚠ GPL/nonfree 需复核</span> — **FFmpeg**:"
        "源码树含 `COPYING.GPLv2` / `COPYING.GPLv3`;三个切片均带 `--disable-gpl` / `--disable-nonfree`;"
        "iOS 两切片另有 `--enable-version3`。产物许可见第 2 节,待法务确认。"
    )
    for record in gpl_records:
        lines.append(
            "- <span style=\"color:red\">⚠ GPL/nonfree 需复核</span> — **{n}**:{note}".format(
                n=md(record["name"]), note=md(record["license_notes"])
            )
        )
    lines.append(
        "- <span style=\"color:red\">⚠ GPL/nonfree 需复核</span> — **传递关系**:"
        "`Libmpv` 静态并入 freetype(FTL/GPL-2.0 二选一);"
        "`Libplacebo` 静态并入 glslang(含 GPL-3.0-with-bison-exception 一节)。"
        "静态归属见第 4 节,是否适用待法务确认。"
    )
    lines.append("")

    lines.append("## 7. 缺失与待确认")
    lines.append("")
    lines.append("### 缺失")
    lines.append("")
    if missing:
        lines.append("| 类型 | 名称 | 说明 |")
        lines.append("| --- | --- | --- |")
        for item in missing:
            lines.append(
                "| {k} | {n} | {d} |".format(
                    k=md(item["kind"]), n=md(item["name"]), d=md(item["detail"])
                )
            )
    else:
        lines.append("无缺失的源码包、许可文件或 framework 二进制。")
    lines.append("")
    lines.append("### 待法务确认")
    lines.append("")
    if review_items:
        lines.append("| 组件 | 许可(草稿) | 说明 |")
        lines.append("| --- | --- | --- |")
        for item in review_items:
            lines.append(
                "| {c} | {l} | {n} |".format(
                    c=md(item["component"]), l=md(item["license"]), n=md(item["note"])
                )
            )
    else:
        lines.append("无。")
    lines.append("")
    lines.append("### 其它异常")
    lines.append("")
    if anomalies:
        lines.append("| 类型 | 名称 | 说明 |")
        lines.append("| --- | --- | --- |")
        for item in anomalies:
            detail = item.get("detail", "")
            if "expected" in item:
                detail += f"(期望 {item['expected']},实际 {item.get('actual')})"
            lines.append(
                "| {k} | {n} | {d} |".format(
                    k=md(item["kind"]), n=md(item.get("name", "")), d=md(detail)
                )
            )
    else:
        lines.append("无。")
    lines.append("")

    lines.append("## 8. 许可文件索引")
    lines.append("")
    lines.append("| 组件 | 文件 |")
    lines.append("| --- | --- |")
    for record in dep_records:
        if record["license_files"]:
            for path in record["license_files"]:
                lines.append(f"| {md(record['name'])} | `{md(path)}` |")
        else:
            lines.append(f"| {md(record['name'])} | 缺失 |")
    for path in ffmpeg_files:
        lines.append(f"| ffmpeg | `{md(path)}` |")
    lines.append("")

    lines.append("## 9. 复现")
    lines.append("")
    lines.append("```sh")
    lines.append("./lux/build/make-license-bundle.sh")
    lines.append("# 只处理一个切片:")
    lines.append("./lux/build/make-license-bundle.sh --target macos-arm64")
    lines.append("```")
    lines.append("")
    lines.append(
        "脚本会重建 `lux/release/licenses/`、`lux/release/source-manifest.json` 与 "
        "`lux/release/NOTICE.md`;不修改源码、配置或已有构建脚本。"
    )
    lines.append("")

    notice_path = out_dir / "NOTICE.md"
    tmp_notice = out_dir / ".NOTICE.md.tmp"
    tmp_notice.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp_notice, notice_path)

    # ---------------------------------------------------------------- summary
    log(f"manifest: {repo_rel(manifest_path, repo)}")
    log(f"notice:   {repo_rel(notice_path, repo)}")
    log(f"licenses: {repo_rel(lic_root, repo)}")
    log(
        "summary: "
        f"deps={len(dep_records)}, "
        f"components={len(ffmpeg_components) + len(stack_components) + len(vulkan_components)}, "
        f"license_files={sum(len(r['license_files']) for r in dep_records) + len(ffmpeg_files)}, "
        f"missing={len(missing)}, anomalies={len(anomalies)}, review={len(review_items)}"
    )
    if missing:
        log("存在缺失项,清单已生成;详见 NOTICE.md 第 7 节")
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(1)
PY
status=${PIPESTATUS[0]}
set -e

printf '\n[license-bundle] log saved: %s\n' "$log"
exit "$status"
