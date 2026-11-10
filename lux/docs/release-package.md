# 发布包与对应源码(F2 / P3-b)

本文说明 `lux-ffmpeg-f2-<日期>` 发布包的结构、生成/校验方法,以及 LGPL 对应源码
的边界。发布包本身不提交到 git(输出在 `lux/.build/release/`),仓库里只保留
脚本、许可清单与本文。

## 产物

在仓库根目录执行:

```sh
bash lux/build/make-release-package.sh
```

默认输出 `lux/.build/release/lux-ffmpeg-f2-20261110/`:

```
xcframeworks/                 6 个 Libav* + 4 个 libmpv 栈 zip,checksums.txt
dSYMs/                        FFmpeg-dSYMs.zip、MPV-dSYMs.zip、dSYM-INFO.txt
BUILD-INFO.txt                版本/补丁 digest/Xcode/SDK/依赖 sha256/commit
COPYING.*, LICENSE.md         LGPL 与其他随包许可文本
licenses/                     按组件分目录的许可文件(来自 lux/release/licenses/)
NOTICE.md                     许可事实记录(草稿,待法务确认)
source-manifest.json          组件/依赖来源与 sha256 清单
SOURCE-PACKAGE.md             对应源码包说明与可复现命令
lux-ffmpeg-source-<tag>.tar.gz
SHA256SUMS                    以上全部分发文件的 sha256
```

`checksums.txt` 只覆盖 10 个 xcframework zip;`SHA256SUMS` 覆盖发布目录里除自身
外的全部文件(含源码包和 dSYM zip)。两层都要校验。

## 对应源码

`lux-ffmpeg-source-<tag>.tar.gz` 包含:

* 本仓库 `lux/` 的全部内容(排除 `lux/.build/`);
* `lux/release/sources/` 下全部 selfstore 依赖源码包;构建缓存
  (`lux/.build/deps/src/`)里另外 8 个 URL-only 的锁定源码包也一并放入,
  并在 `SOURCES-INDEX.txt` 标注 `origin=selfstore|deps-cache`;
* `ffmpeg-8.1.3/`:由 `git archive` 的 FFmpeg 基线树加 `lux/patches/` 的
  13 个补丁生成,附 `LUX-PATCHES.txt`(补丁名 + sha256 + digest);
* `BUILD-INFO.txt`、`COPYING.*`、`LICENSE.md`、`SOURCE-PACKAGE.md`。

生成脚本不修改工作区源码:它把基线树解到 `lux/.build/release-work/`,在那里
`git apply` 补丁,再打包。复现命令写在源码包的 `SOURCE-PACKAGE.md` 里。

许可边界仍是 `CONFIG_GPL=0`、`CONFIG_NONFREE=0`、`CONFIG_VERSION3=0`
(LGPL-2.1-or-later)。`dav1d`(BSD-2-Clause)、`zlib`(Zlib)、`OpenSSL`(Apache-2.0)
是静态并入的宽松许可依赖,不引入 GPL 组件;许可事实见 `lux/config/allowlist.md`
与 `NOTICE.md`。

## 校验

```sh
bash lux/build/verify-release-package.sh [release-dir]
```

检查 `SHA256SUMS` 的覆盖与逐条 hash、`checksums.txt` 的 10 个 zip、每个
xcframework 的三切片结构与 `@rpath`/codesign、dSYM UUID 与 `DWARF` 条目数、
`BUILD-INFO` 的补丁 digest/依赖 sha256,以及源码包里 13 个补丁是否真的已应用。
日志写到 `lux/.build/logs/release-verify-<YYYYMMDD>.log`,最后输出 `RESULT: PASS`。

## lux-client 侧

`lux/release/fetch-lux-ffmpeg.sample.sh` 是给 `apple/scripts/fetch-lux-ffmpeg.sh`
的草案(不直接放进 lux-client):

```sh
fetch-lux-ffmpeg.sh <release-dir-or-url> <dest>
```

本地目录模式先全量校验 `SHA256SUMS`,再核对 `checksums.txt`;全部一致后才用
`ditto -x -k` 解到 `<dest>/Vendor/`。URL 模式只下载 10 个 zip 与两份校验文件,
并逐个核对已下载文件在两份清单里的 hash;dSYM/源码条目不下载。任何不一致都会
非零退出,并删除本次创建的临时目录与空的 `<dest>`;已有的 `<dest>/Vendor`
在成功前不会被替换。

## 发布边界

本仓库的 P3-b 只生成并校验本地发布目录:**不推送、不打远程 tag、不发布
GitHub release**。验收通过后由验收端在合并后的 `p1-allowlist` 上打本地 tag
(如 `f2-20261110`)。
