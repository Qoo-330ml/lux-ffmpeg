#!/usr/bin/env python3
"""Generate the Headers/ layout of one Lux framework from an FFmpeg install tree.

Why this script exists
----------------------
FFmpeg's public headers include each other with a *library prefix*:

    libavformat/avformat.h  ->  #include "libavcodec/codec_par.h"
    libavcodec/codec_par.h  ->  #include "libavutil/avutil.h"

That only works when the include root (the directory that *contains*
``libavformat/``, ``libavcodec/`` ...) is on the compiler's include path.  A
framework is consumed through ``-F`` (framework search), not ``-I``, so the
include root is never on the include path.  MPVKit works around this by relying
on the case-insensitive default APFS volume: clang's framework lookup maps
``libavcodec/...`` to ``Libavcodec.framework/Headers/...`` only because
``libavcodec`` and ``Libavcodec`` are the same name on such a volume.

This script removes that dependency for both include spellings:

  * ``#include <Libavformat/avformat.h>``   -> framework search -> Headers/avformat.h
  * ``#include <libavformat/avformat.h>``   -> -I .../Headers    -> Headers/libavformat/avformat.h

and it materialises every include path the headers actually resolve to, as a
symlink to the canonical copy owned by the framework that ships it.  The tree
contains only file symlinks: no directory symlinks and no cycles, so recursive
tools (SwiftPM, Xcode, `find`) can walk it safely.  The canonical header stays
in its own framework, so every declaration has exactly one canonical home; only
the access path is duplicated.

Layout produced (F = framework module name, lib = its FFmpeg library):

    Headers/lib/avformat.h              real file (canonical public header)
    Headers/avformat.h                  -> lib/avformat.h
    Headers/libavcodec/codec_par.h      -> ../../Libavcodec.framework/Headers/libavcodec/codec_par.h
    Headers/libavcodec/libavutil/x.h    -> ../../../Libavutil.framework/Headers/libavutil/x.h

Usage:
    gen-framework-headers.py --include <ffmpeg install>/include \
        --framework-root <slice>/Libavformat.framework \
        --module Libavformat --lib libavformat \
        --sibling Libavcodec:libavcodec --sibling Libavutil:libavutil ...

All symlink targets are relative and are expressed inside the *slice directory*
(the parent of the .framework bundle), because the four frameworks are shipped
side by side: in an XCFramework slice, in SwiftPM's build directory and in the
app's Frameworks/ directory.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from collections import deque

INCLUDE_RE = re.compile(r'^\s*#\s*include\s+"([^"]+)"', re.MULTILINE)


def die(msg: str) -> "None":
    print(f"gen-framework-headers: error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read()


class Layout:
    def __init__(self, include_root: str, framework_root: str, module: str, lib: str,
                 siblings: dict[str, str]) -> None:
        self.include_root = include_root
        self.framework_root = os.path.abspath(framework_root)
        self.module = module
        self.lib = lib
        self.siblings = dict(siblings)                       # lib dir -> framework name
        self.module_of_lib = dict(self.siblings)   # lib dir -> module
        self.module_of_lib[lib] = module
        self.libraries = set(self.siblings) | {lib}
        self.headers_dir = os.path.join(self.framework_root, "Headers")
        self.by_basename: dict[str, list[str]] = {}
        for library in sorted(self.libraries):
            for name in sorted(os.listdir(os.path.join(include_root, library))):
                if name.endswith(".h"):
                    self.by_basename.setdefault(name, []).append(library)

    # ---------------------------------------------------------------- helpers
    def canonical(self, lib: str, name: str) -> str:
        return os.path.join(self.include_root, lib, name)

    def ensure_copy(self, relative_path: tuple[str, ...], lib: str, name: str) -> bool:
        """Materialise one include path as a real file *inside this bundle*.

        Copies (not symlinks) are deliberate: `codesign` rejects a bundle whose
        symlinks point outside it ("invalid destination for symbolic link in
        bundle"), so a framework cannot reference a sibling framework's headers.
        The closure is small (about 100 files per framework), and every copy is
        byte-identical to the canonical header of the library that owns it.
        """
        if lib == self.lib and relative_path == (lib, name):
            return False  # the canonical copy itself, written in step 1
        target = os.path.join(self.headers_dir, *relative_path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        source = self.canonical(lib, name)
        if not os.path.isfile(source):
            die(f"missing canonical header {source}")
        if os.path.islink(target):
            os.unlink(target)
        if os.path.exists(target):
            with open(source, "rb") as a, open(target, "rb") as b:
                if a.read() == b.read():
                    return False
            die(f"refusing to overwrite different file {target}")
        with open(source, "rb") as src, open(target, "wb") as out:
            out.write(src.read())
        return True

    def resolve_include(self, spec: str, from_dir: tuple[str, ...]):
        """Return (path, lib, header) for a quoted include, or None for private headers."""
        prefix, slash, rest = spec.partition("/")
        prefixed = bool(slash) and prefix in self.libraries
        name = rest if prefixed else os.path.basename(spec)
        candidates = self.by_basename.get(name, [])
        if prefixed:
            lib = prefix
        elif len(candidates) == 1:
            lib = candidates[0]
        elif len(from_dir) == 1 and from_dir[0] in candidates:
            lib = from_dir[0]
        elif len(from_dir) > 1 and from_dir[-1] in candidates:
            lib = from_dir[-1]
        elif candidates:
            lib = candidates[0]
        else:
            return None
        if lib not in self.libraries:
            return None
        if not os.path.isfile(self.canonical(lib, name)):
            return None
        directory = from_dir + ((prefix,) if prefixed else ())
        return directory + (name,), lib, name


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--include", required=True, help="FFmpeg install include/ directory")
    parser.add_argument("--framework-root", required=True, help=".../<Module>.framework")
    parser.add_argument("--module", required=True, help="framework module name, e.g. Libavformat")
    parser.add_argument("--lib", required=True, help="own FFmpeg library directory, e.g. libavformat")
    parser.add_argument("--sibling", action="append", default=[],
                        help="other library as Module:libdir, repeatable")
    parser.add_argument("--max-depth", type=int, default=8)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    siblings = {}
    for spec in args.sibling:
        module, _, lib = spec.partition(":")
        if not module or not lib:
            die(f"bad --sibling {spec!r}, expected Module:libdir")
        siblings[lib] = module
    if args.lib in siblings:
        die("the own library must not be listed as a sibling")

    layout = Layout(args.include, args.framework_root, args.module, args.lib, siblings)
    os.makedirs(os.path.join(layout.headers_dir, args.lib), exist_ok=True)

    # 1. canonical headers (real copies) + flat framework-style aliases
    own = sorted(n for n in os.listdir(os.path.join(args.include, args.lib)) if n.endswith(".h"))
    for name in own:
        with open(layout.canonical(args.lib, name), "rb") as src:
            data = src.read()
        dest = os.path.join(layout.headers_dir, args.lib, name)
        if os.path.lexists(dest):
            os.unlink(dest)
        with open(dest, "wb") as out:
            out.write(data)
        alias = os.path.join(layout.headers_dir, name)
        if os.path.islink(alias):
            os.unlink(alias)
        if not os.path.exists(alias):
            os.symlink(f"{args.lib}/{name}", alias)

    # 1b. mirror every sibling library's headers, so a plain `-I .../Headers`
    #     consumer can also `#include <libavcodec/avcodec.h>` from this framework.
    for sibling_lib in sorted(siblings):
        for name in sorted(os.listdir(os.path.join(args.include, sibling_lib))):
            if name.endswith(".h"):
                layout.ensure_copy((sibling_lib, name), sibling_lib, name)

    # 2. include closure: every path a quoted include can resolve to
    queue: deque[tuple[tuple[str, ...], str, str]] = deque()
    for name in own:
        queue.append(((args.lib, name), args.lib, name))
        queue.append(((name,), args.lib, name))

    created = 0
    visited: set[tuple[tuple[str, ...], str]] = set()
    unresolved: set[str] = set()
    while queue:
        path, lib, name = queue.popleft()
        key = (path, lib)
        if key in visited:
            continue
        visited.add(key)
        if len(path) > args.max_depth:
            die(f"include depth {len(path)} exceeds {args.max_depth}: {'/'.join(path)}")
        if len(path) > 1 and layout.ensure_copy(path, lib, name):
            created += 1
        directory = path[:-1]
        for spec in INCLUDE_RE.findall(read_text(layout.canonical(lib, name))):
            resolved = layout.resolve_include(spec, directory)
            if resolved is None:
                unresolved.add(spec)
                continue
            queue.append(resolved)

    if not args.quiet:
        print(f"{args.module}: {len(own)} canonical headers, {created} mesh copies, "
              f"{len(visited)} include paths, {len(unresolved)} private includes skipped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
