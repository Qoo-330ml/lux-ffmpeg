# lux-ffmpeg — F0:LGPL 最小构建 spike(+ F1:动态 framework)

> F1(动态 framework / xcframework,给 Swift 直接 `import`)见 **§12**,产物在
> `lux/.build/xcframeworks/`,验证脚本是 `lux/build/verify-frameworks.sh`。
> 本节(F0)保持原样,静态产物与 `verify-license.sh` 仍然有效。

**结论:能出。** 用 jellyfin-ffmpeg `v8.1.3-2`(FFmpeg 8.1.3)的同一份 `configure` 配置,
在本机 arm64 macOS、iOS device(arm64)、iOS simulator(arm64)上各出一套**只含 LGPL 组件**的
静态库(`.a`),三套都通过本目录的许可/组件/平台检查,并且在 macOS 上用一个最小 C 程序真的读了一个
合成 mkv(H.264 + AAC)。

一句话的取舍:F0 不做动态 framework(那是 F1),不做网络/TLS,不开 avfilter/swscale,
所有产物都是静态 `.a`。**静态链接 + LGPLv3 的分发合规问题依然存在**,F0 只负责证明"能编、
是 LGPL、能用"。

---

## 1. 速览

| | macOS arm64 | iOS device | iOS simulator |
| --- | --- | --- | --- |
| 构建命令 | `./lux/build/build-ffmpeg.sh macos-arm64` | `... ios-arm64` | `... ios-sim-arm64` |
| SDK | macosx 26.5 | iphoneos 26.5 | iphonesimulator 26.5 |
| 最低系统 | macOS 14.0 | iOS 17.0 | iOS-simulator 17.0 |
| configure 输出 | `License: LGPL version 3 or later` | 同 | 同 |
| 耗时(实测,`-j10`) | **50–73 s**(configure 29–54 s) | **50–57 s**(configure 29–35 s) | **60–72 s**(configure 38–43 s) |
| 产物 | `lux/.build/<target>/install/lib/*.a` | 同 | 同 |
| 合计 | 9,201,200 B(8.77 MiB) | 9,068,056 B(8.65 MiB) | 9,196,312 B(8.77 MiB) |

各库大小(F2 起 avfilter/swscale 进产物;`lib/` 下仍然不会出现 avdevice):

| 库 | macOS arm64 | iOS device | iOS sim arm64 |
| --- | --- | --- | --- |
| `libavformat.a` | 1,175,416 | 1,161,104 | 1,175,248 |
| `libavcodec.a` | 5,113,344 | 5,009,048 | 5,108,568 |
| `libavfilter.a` | 306,424 | 303,360 | 306,512 |
| `libswscale.a` | 1,450,464 | 1,442,680 | 1,450,472 |
| `libswresample.a` | 136,120 | 133,024 | 136,200 |
| `libavutil.a` | 1,019,432 | 1,018,840 | 1,019,312 |
| **合计** | **9,201,200** | **9,068,056** | **9,196,312** |

以上数字是 `BUILD-INFO.txt` 里的实测值(每次构建重写)。耗时随磁盘缓存/并发波动,上表给的是多次实测的区间(单目标、串行、`-j10`;三个目标同时构建时单个会到 ~105 s)。整棵 `lux/.build/`(源码树外编译目录 +
日志 + 夹具 + 三个目标)约 **112 MB**。

## 2. 目录

```
lux/README.md                  # 本文件
lux/config/ffmpeg-ios.conf     # configure 参数的唯一真相(被 build 脚本 source)
lux/config/allowlist.md        # 白名单逐项理由 + 版本差异 + 上游 GPL 文件发现
lux/config/patches.txt         # 上游补丁集的顺序(apply-patches.sh 读它)
lux/patches/*.patch            # 刷新过的移植补丁(事实来源,见 §6.2)
lux/docs/patch-triage.md       # 106 个 jellyfin 补丁的分诊结论
lux/build/build-ffmpeg.sh      # macos-arm64 | ios-arm64 | ios-sim-arm64 | clean
lux/build/apply-patches.sh     # 补丁集 apply/check/revert/status/digest
lux/build/verify-license.sh    # 许可 / 符号 / 平台 / 组件对账 / 补丁指纹,失败非零退出
lux/build/fetch-deps.sh        # 按 deps.lock 取依赖源码,下载后强制校验 sha256(§16)
lux/build/check-deps-lock.sh   # 全量核对 deps.lock:URL 当前字节 + 自存副本,日志写 lux/.build/logs/
lux/build/install-glad.sh      # 按 requirements-glad.txt 的 hash 装 glad2 到 pydeps
lux/config/deps.lock           # 依赖源码锁:版本 + sha256 + selfstore(自存路径)
lux/config/requirements-glad.txt # glad2 / Jinja2 / MarkupSafe 的 hash 锁
lux/release/sources/           # 自存的依赖源码包(git 忽略,只在本机;见 §16)
lux/test/read_mkv.c            # 最小 C 程序:读 mkv,打印流信息/时长/首关键帧偏移
lux/test/patch_probe.c         # 补丁公开 API 探针(0001/0005/0006)
lux/test/hevc12_probe.c        # 12-bit HEVC:VT 候选 + 回退(0004)
lux/test/run.sh                # 合成夹具 → 编译三个 C 程序 → 运行 → 断言
lux/.build/                    # 全部产物(git 忽略)
```

## 3. 环境要求

- macOS + Xcode(Xcode 26.6 / SDK 26.5 上实测);
- `xcrun --sdk iphoneos|iphonesimulator --show-sdk-path` 可用;
- GNU make + clang(`/usr/bin/make` 3.81 实测可用);
- 合成夹具需要 PATH 里有带 `libx264` 的 `ffmpeg`(本机用 `/opt/homebrew/bin/ffmpeg 9.0.2`);
  **不联网**,不下载任何依赖或素材。

## 4. 构建

```sh
# 在仓库根目录执行(下面的命令都以仓库根为相对路径)
./lux/build/build-ffmpeg.sh macos-arm64      # 本机,可以真跑
./lux/build/build-ffmpeg.sh ios-arm64        # 交叉编译
./lux/build/build-ffmpeg.sh ios-sim-arm64
./lux/build/build-ffmpeg.sh clean            # 删掉 lux/.build/
```

要点:

- **源码树外构建**:`configure` 在 `lux/.build/<target>/` 里跑(源码树里除了 `lux/**` 和两个
  上游补丁文件,没有任何改动);
- **临时文件不出仓**:脚本把 `TMPDIR`/`TMP`/`TEMP` 指到 `lux/.build/tmp`,并设
  `CLANG_MODULE_CACHE_PATH`。构建后检查过 `$(getconf DARWIN_USER_TEMP_DIR)`、`/tmp`、
  `/private/tmp`,没有残留的 `ffconf*`;
- 每次构建前会 `rm -rf lux/.build/<target>`,避免旧 `config.h`/`.o` 影响结果(日志留在
  `lux/.build/logs/`);
- 参数里只要出现 `--enable-gpl`、`--enable-nonfree`、`--enable-libx264` 之类,脚本在 configure
  之前就退出;`License:` 行不以 `LGPL` 开头也会退出。

## 5. 验证

### 5.1 许可 / 符号 / 平台

```sh
./lux/build/verify-license.sh                    # 三个目标全查
./lux/build/verify-license.sh ios-arm64          # 单查
```

它做 8 组检查,任何一条失败即非零退出:

1. 六个 `.a` 齐全,且**没有** `libavdevice.a`/`libpostproc.a`;
2. `config.h`:`CONFIG_GPL 0`、`CONFIG_NONFREE 0`、`CONFIG_VERSION3 1`、`CONFIG_LGPLV3 1`、
   `CONFIG_AVFILTER 1`、`CONFIG_SWSCALE 1`、`CONFIG_AVDEVICE 0`、`CONFIG_NETWORK 0`;
3. `configure` 日志里的 `License:` 行必须是 `License: LGPL version 3 or later`;参数里不得有
   GPL/nonfree/外部编码库;
4. `avutil_license()`:macOS 目标编译并运行探针(输出必须以 `LGPL` 开头);iOS 目标不能运行,
   改为检查 `libavutil.a` 里内嵌的许可标识(`libavutil license: LGPL version 3 or later`),
   并确认没有 `GPL`/`nonfree` 标识;
5. **GPL 源文件审计**:用 `*.d` 依赖文件反查每个 `.o` 的源文件(本例 417 个),扫源码头里的
   GPL 标记(LGPL 的 "Lesser" 不算);有 GPL 源文件被编译就失败。另外单独确认已知的两个上游
   GPL 目标文件不在归档里;
6. 符号表:四个 `.a` 的 `nm` 里没有 `x264|x265|fdk|xvid|vidstab|postproc|mp3lame|theora|dav1d|
   libvpx|libass|freetype|gnutls|openssl|…`(libvpx 按它自己的 API 名 `vpx_codec_`/`vpx_img_`
   匹配;FFmpeg 内建的 `_ff_vpx_*` 是 LGPL 的 VP8 range coder,不算外部库);
   同时正向确认每个库都有 `av*/swr*` 符号(不是空归档);
7. 平台:`lipo -info` 必须是 arm64;`vtool -show-build`(vtool 不认 `.a`,从归档里抽
   `version.o`)必须是 `platform IOS / minos 17.0`、`platform IOSSIMULATOR / minos 17.0`、
   `platform MACOS / minos 14.0`;
8. 组件对账:把 `config_components.h` 里启用的 demuxer/muxer/parser/decoder/encoder/bsf/
   protocol/hwaccel 与 `lux/config/ffmpeg-ios.conf` 的白名单逐项比对(白名单缺项 = 失败;
   configure 自动 select 进来的 = `[warn]`)。

本次结果(三个目标一致):

```
failures: 0, warnings: 6
RESULT: PASS (LGPL-only)
```

- 每个目标 33 项 `[ok]`;唯一的 6 条 warning 是 `mlp` parser(`truehd_decoder_select`)和
  `vp9_superframe` bsf(`mov_muxer_select`)被 configure 自动带入,二者都是 LGPL。
- 组件对账结果:demuxer 3、muxer 2、parser 6、decoder 15、encoder 2、bsf 7、protocol 1、
  hwaccel 2 全部生效;启用的 codec 里没有 GPL/external 组件。

### 5.2 真的读一个 mkv

```sh
./lux/test/run.sh
```

它串起:检查/必要时构建 macOS 库 → 用系统 `ffmpeg` 在 `lux/.build/fixtures/` 合成
`lux-f0-fixture.mkv`(12 s,320x240 H.264 + 48 kHz AAC,`-g 50`,matroska 带 Cues)→ 用
`lux/.build/macos-arm64/install/` 的静态库编译 `read_mkv.c` → 运行 → 断言。

本次输出(节选,完整输出见 `lux/.build/macos-arm64/test/read_mkv.out`):

```
avutil_license: LGPL version 3 or later
libavformat: 62.12.103
libavcodec: 62.28.103
libavutil: 60.26.103
format: matroska,webm (Matroska / WebM)
streams: 2
duration: 12.021
stream #0: type=video codec=h264 encoder_name=h264 320x240
stream #1: type=audio codec=aac encoder_name=aac 48000Hz 2ch
first video packet: keyframe=1 pos=783 size=4709 pts=0
packets_total: 863
packets_stream_0: 299
packets_stream_1: 564
result: ok
RESULT: PASS
```

## 6. 许可记录

- **基线**:上游 FFmpeg **8.1.3**(取自 jellyfin-ffmpeg `v8.1.3-2`;该 tag 是 Debian 打包分支,
  源码树本身是 pristine 上游,`debian/patches/` 里的 106 个补丁**默认一个都不应用**)。
  实际编进产物的补丁只有两部分:§6.1 的 GPL 守卫(2 处源码改动)+ §6.2 从 jellyfin 补丁系列
  移植的 14 个补丁。上游源码树是 **LGPL/GPL 混合**:`libavfilter` 下有 50 个文件是 GPL,
  `libavcodec/aarch64/ac3dsp_*` 与 `libavutil/aarch64/crc.S` 也是 GPL。本构建**只启用 LGPL 部分**。
- `configure` 输出:`License: LGPL version 2.1 or later`(因为 `--disable-gpl --disable-nonfree`,
  且**不写** `--enable-version3`);`config.h` 里 `CONFIG_GPL 0`、`CONFIG_NONFREE 0`、
  `CONFIG_VERSION3 0`、`CONFIG_LGPLV3 0`。
- 为什么是 2.1+:D2 决定(2026-11-10,所有者确认)把许可下限降到 LGPL-2.1+,与 MPVKit / mpv /
  libplacebo 一致,也缩小了与 App Store 条款的张力(法务结论仍需确认)。P0-4 探针证明去掉
  `--enable-version3` 后启用的组件集合逐项不变,只有 `CONFIG_VERSION3`/`CONFIG_LGPLV3` 和
  configure 的许可行变了;当前白名单没有 gmp/mbedtls/libopencore-amr 等 version3 外部库。
  OpenSSL 3.5.9 已作为 TLS 后端(D3)纳入,但本构建无 GPL,configure 的 version3 断言不触发,
  `CONFIG_VERSION3` 仍为 0(三切片实测)。完整理由与「什么情况会被迫加回来」记在
  `lux/config/allowlist.md`「许可决定」。
- 为什么还要额外审计:`CONFIG_GPL 0` 只保证 `#if CONFIG_GPL` 包住的代码不编,**不保证没有 GPL
  源文件被无条件编进去**。F0 就是用第 5 项检查(反查 `.o` 的源文件)抓到了两个这样的文件,
  见下节。GPL 滤镜之所以不会进来,是因为我们根本没编译 avfilter(`--disable-avfilter`),
  而不是因为 `CONFIG_GPL 0`。
- 静态链接本身的分发合规(LGPL-2.1 §6 的目标代码/重链接义务)是 F1 要解决的问题:动态
  framework 是正解,F0 的静态 `.a` 只是 spike 产物,**不应直接进 App 包**。

### 6.1 对上游源码的补丁(`lux:` 提交)

两个文件是上游的 GPL 代码,但**没有被任何 configure 开关守卫**,只要在 aarch64 上开了
AC-3/E-AC-3 解码、或者编 libavutil,它们就会进 `libavcodec.a`/`libavutil.a`。用 configure 参数
绕不开(AC3DSP 由 `ac3_decoder`/`eac3_decoder` select,`--disable-ac3dsp` 会被重新 enable;
`crc.S` 的 `ARMV8-OBJS` 是无条件的),所以只能动源码,并单独提交:

| 补丁 | 改了什么 | 为什么不能只用脚本/参数解决 |
| --- | --- | --- |
| `libavcodec/aarch64/Makefile` + `libavcodec/ac3dsp.c` | 两个 GPL 目标文件只在 `CONFIG_GPL=yes` 时编译;`ff_ac3dsp_init_aarch64()` 的调用也加 `CONFIG_GPL` 守卫 | `AC3DSP` 是被 `ac3_decoder`/`eac3_decoder` `select` 的组件,`--disable-ac3dsp` 会被 configure 的 select 重新打开;而它们又是白名单里必须有的解码器。 |
| `libavutil/aarch64/Makefile` + `--disable-arm-crc` | `crc.o` 只在 `CONFIG_GPL=yes` 时编译;configure 关掉 `arm_crc` 扩展,让 `crc.h` 的内联走 C 实现 | `ARMV8-OBJS += aarch64/crc.o` 是无条件的;只关 `--disable-arm-crc` 虽然不引用 `ff_crc32_aarch64`,但仍然会编译那个 GPL 源文件(空目标文件也算"编译了 GPL 代码"),所以两边都要做。 |

代价:LGPL 构建里 **AC-3/E-AC-3 的 NEON DSP 被关掉**(退回 C 实现),`av_crc` 也失去 ARMv8
CRC32 硬件加速。前者影响 AC-3 解码性能(未量化,列在「未解决」),后者只影响 CRC 计算,对 F0
的白名单组件基本无感。GPL 构建(`--enable-gpl`)行为完全不变。

### 6.2 移植的上游补丁(`lux/patches/`)

产物不是纯上游:`lux/patches/` 里有 14 个从 jellyfin-ffmpeg 补丁系列刷新(并按客户端需要改造)
过的补丁,按 `lux/config/patches.txt` 的顺序应用,脚本是 `lux/build/apply-patches.sh`。

| lux 补丁 | 来源 | 内容 | 改造点 |
| --- | --- | --- | --- |
| `0001` | jellyfin 0048 | VT 解码低优先级(`AV_HWACCEL_FLAG_LOW_PRIORITY`)+ `skip_frame>=NONKEY` 时只解关键帧 | 无(只刷新上下文) |
| `0002` | jellyfin 0049 | VT hwcontext 的 `device_derive` | 无 |
| `0003` | jellyfin 0055 | 非 HEVC 的 VT 从 `RequireHardware` 改为 `EnableHardware`(允许软解回退) | 无 |
| `0004` | jellyfin 0057 | HEVC 12-bit 的 `get_format()` 候选里加 VT | **扩到 `YUV420P12`**(Main12 4:2:0;原补丁只覆盖 4:2:2/4:4:4),并去掉重复候选 |
| `0005` | jellyfin 0090 | `avcodec_parameters_from_context()` 优先用 `sw_pix_fmt` | 无 |
| `0006` | jellyfin 0062 | `aac_at` 的 7.1 布局标签、`supported_samplerates`、S32 采样格式 | 无 |
| `0007` | jellyfin 0088 | matroska 认 `image/webp` 封面 attachment | 白名单加了 `webp`/`mjpeg` 解码器(webp 会连带 `vp8`) |
| `0008` | jellyfin 0087 | DTS:X / DTS-HD HRA(X、IMAX)profile 识别 | 无(只加公开 profile 常量) |
| `0009` | jellyfin 0027 | Dolby Vision 配置校验后写进 mp4 | 只取 `movenc`/`dovi_isom`;删掉服务端的 hls/mpegts 分支 |
| `0010` | jellyfin 0043 | `scale_vt` 新增 `format` 选项(NV12↔P010) | 无 |
| `0011` | jellyfin 0045 | `transpose_vt` 改成 CoreImage 实现 | 白名单开 `coreimage`,产物多 `libavfilter.a`/`libswscale.a` |
| `0012` | jellyfin 0044 | `overlay_videotoolbox`(Metal) | 需要 Metal Toolchain;`--metalcc/--metallib` 指向目标 SDK |
| `0013` | jellyfin 0046 | `tonemap_videotoolbox`(Metal) | 同上 |
| `0014` | jellyfin 0056 | `bwdif`/`yadif_videotoolbox`(Metal) | 同上 |

用法与约束:

```sh
./lux/build/apply-patches.sh status     # 每个补丁 applied / not applied
./lux/build/apply-patches.sh check      # 全量试打一遍再回滚(验收)
./lux/build/apply-patches.sh apply      # 要求工作区干净
./lux/build/apply-patches.sh revert     # 提交代码前恢复干净工作区
```

- 应用是**零 fuzz** 的(`git apply`,不加 `-C`/`-3`);上游一漂移就重新生成补丁,不靠模糊匹配。
  6 个补丁里有 4 个(jellyfin 0044/0046/0047/0057)在原样 `git apply` 时会因上下文漂移失败,
  所以 `debian/patches/` 只能当参考,`lux/patches/` 才是事实来源。
- `build-ffmpeg.sh` / `build-frameworks.sh` 在 configure 前会 `apply-patches.sh ensure`,
  并把补丁条数与 `sha256` 指纹写进 `BUILD-INFO.txt`;`verify-license.sh` 核对这个指纹,
  **改了补丁没重建会直接 FAIL**。
- 补丁只改 LGPL 文件,§5.1 第 5 项的 GPL 源文件审计照常覆盖它们(本次仍是 417 个源文件、0 命中)。
- 没移植的补丁(服务端转码、Windows/Linux 硬件、fftools、avfilter 类)与理由见
  `lux/docs/patch-triage.md`。

## 7. 与 MPVKit 现有静态库的粗略对比

只做对比,没有把 MPVKit 的产物拷进来。数据来自 SwiftPM 的 artifact 缓存(zip 里的 LGPL
变体,`ios-arm64` 切片用 `lipo -thin arm64` 量):

| 库 | MPVKit 1.0.0(LGPL,iOS arm64) | Lux F0(iOS arm64) | 比例 |
| --- | --- | --- | --- |
| `Libavcodec.a` | 10,290,144 | 4,779,896 | 46% |
| `Libavformat.a` | 2,518,792 | 1,160,384 | 46% |
| `Libavutil.a` | 1,159,760 | 1,017,888 | 88% |
| `Libswresample.a` | 139,048 | 132,808 | 96% |
| **这四个合计** | **14,107,744** | **7,090,976** | **50%** |

差异来源:MPVKit 是"全组件 + 网络/TLS"构建(所有 demuxer/decoder/muxer/protocol 都在),
我们 `--disable-everything` 只留白名单;`libavutil` 几乎是同一份,所以只小 12%(说明白名单
裁剪的收益全在 avcodec/avformat)。注意 MPVKit 的 avfilter/swscale/avdevice/libmpv 是另外的
framework,F0 根本没构建它们,所以**总包体积不可直接相加对比**。

## 8. 遇到的坑

1. **`--disable-postproc` 会把 configure 直接打死。** FFmpeg 8.0 移除了 libpostproc,8.1.3 的
   configure 对未知的 `--disable-xxx` 选项是 `die`,不是警告。`--disable-libxml2`、
   `--disable-opencl` 同理(这两个只有 `--enable-` 形式)。
2. **未知的组件名却是静默忽略。** `--enable-bsf=trim` 不报错,但 `trim` 在 8.1.3 里根本不存在
   (`bitstream_filters.c` 没注册),结果 `config_components.h` 里连 `CONFIG_TRIM_BSF` 都没有。
   所以白名单必须和 `config_components.h` 对账(第 8 项检查),不能只看 configure 退码。
3. **`--disable-gpl` ≠ 没有 GPL 代码被编译**(本 spike 最有价值的发现)。见 6.1。
4. **`verify-license.sh` 里 `nm ... | grep -q` 会被 SIGPIPE 坑到**:`grep -q` 提前关管道,
   `pipefail` 下把 `nm` 的 SIGPIPE 当失败(表现为"库里没有 av* 符号")。改成先把符号落到文件
   再 grep。
5. **`vtool -show-build` 不认 `.a`**(报 `file is not mach-o`),`lipo -info` 认。所以平台信息是从
   归档里抽一个 `version.o` 出来查 `LC_BUILD_VERSION`,能看到 `platform IOS / minos 17.0`。
6. **`libavutil license:` 前缀**:`avutil_license()` 返回 `LGPL version 3 or later`,但归档里内嵌
   的字符串是 `libavutil license: LGPL version 3 or later`,用 `^LGPL` 锚定会漏。
7. 交叉编译时 `--cc="xcrun --sdk iphoneos clang"`(带空格的 cc)是能用的;平台/最低版本靠
   `-miphoneos-version-min` / `-mios-simulator-version-min` 确立,不需要 `-target`。只用 `-isysroot`
   不写这两个 `-m*` 的话,clang 会按宿主平台编,mach-o 的 `LC_BUILD_VERSION` 就错了。

## 9. 未解决 / 需要所有者确认

- **iOS 产物只做了静态检查,没在设备/模拟器上跑过**。F0 的 iOS 侧结论是"能编、架构/平台/最低
  版本正确、没有 GPL",不是"能在 iOS 上解码"。要真验证,需要一个最小 Xcode 工程把这些 `.a`
  链进去跑 `read_mkv`。
- **VideoToolbox 硬解只验证到"编进产物 + 组件对账启用"**,没有真的创建 `AVHWDeviceContext`
  解一帧。`aac_at` 也一样,只确认编进去了,没做编码功能测试。
- **AC-3 NEON DSP 在 LGPL 构建里被关掉**,性能损失未量化。建议 F1 做一次 AC-3/E-AC-3 解码
  benchmark;同时向上游报这两个没有被 `CONFIG_GPL` 守卫的文件(这是个真实的 LGPL 构建缺陷)。
- **remux(mkv → fMP4)没有端到端测试**。mov/mp4 muxer、`h264/hevc_mp4toannexb`、
  `aac_adtstoasc`、`dca_core`、`dovi_rpu` 只在组件对账层面确认启用;F0 的 C 程序只读不写。
- **白名单还很小**:没有 `swscale`/`avfilter`(libmpv 需要)、没有网络/TLS(HLS 用)、没有
  AV1(VP9/AV1 内容)、没有 `matroska` muxer。这些都要在 F1/F2 按需加,加之前先看它的
  `_select` 会拉进来什么。
- **静态链接 + LGPLv3 的合规问题依然悬着**:F0 的产物不适合直接进 App 包。

## 10. F1(动态 framework / xcframework)的前置事项

1. **动态库形态**:`--enable-shared --disable-static`,`-install_name @rpath/libavcodec.dylib`,
   符号可见性/`-fvisibility`、`compatibility_version`/`current_version` 都要定;`config.h` 里
   `CONFIG_SHARED` 相关分支要复查。
2. **axcframework 打包**:F0 已经有 device + simulator 两个 slice,`lipo`/`vtool` 检查可以复用;
   F1 要加 `Info.plist`/modulemap,并决定 framework 里放 dylib 还是 `-all_load` 静态库。
3. **重链接义务(LGPLv3 §4)**:动态库形态下要随包提供 `COPYING.LGPLv3`、修改说明(我们的两个
   `lux:` 补丁)、以及可替换/重链接的说明;`docs/LICENSES.md` 里加 FFmpeg 条目。
4. **功能扩展**:libmpv 需要的 `swscale`/`avfilter`(以及 mpv 的 `--enable-gpl=no` 配置)、
   网络协议 + TLS、AV1 解码;每加一项都要过一遍 `allowlist.md` 的"为什么在名单上"。
5. **性能基准**:AC-3 NEON 关闭的影响、VT 硬解真跑、`aac_at` 真跑。
6. **CI 化**:三个目标 × build + verify 现在串行约 3 分钟,可以做成脚本化 CI;`verify-license.sh`
   的退出码直接当门禁。
7. **向上游反馈** `libavcodec/aarch64/ac3dsp_*` 与 `libavutil/aarch64/crc.S` 的 GPL 许可缺口
   (或者在我们自己的仓库里长期维护这两个小补丁)。

## 11. 来源与许可

- **基线**:jellyfin-ffmpeg `v8.1.3-2`(内容 = FFmpeg **8.1.3** + jellyfin 补丁),本仓库
  `lux/8.1.3` 分支,提交 `f2e0673`。上游源码树是 **LGPL/GPL 混合**:`libavfilter` 下有 50 个
  文件是 GPL,`libavcodec/aarch64/ac3dsp_*` 与 `libavutil/aarch64/crc.S` 也是 GPL。
- **本构建只启用 LGPL 部分**:configure 参数见 `lux/config/ffmpeg-ios.conf`,白名单及逐项理由见
  `lux/config/allowlist.md`;`--disable-gpl --disable-nonfree` 且不加 `--enable-version3` 的结果是
  `LGPL version 2.1 or later`(D2,2026-11-10;理由见 allowlist.md「许可决定」)。GPL 文件要么
  因为没开对应组件/库而不编译,要么由 6.1 的两个守卫排除,并由 `verify-license.sh` 第 5 项检查
  持续保证。
- 产物许可:FFmpeg 部分为 **LGPL-2.1-or-later**(`COPYING.LGPLv2.1`),对上游文件的两个改动
  以 `lux:` 提交记录在本仓库(见 `git log`)。
- 夹具(`lux/.build/fixtures/*.mkv`)是本机 `ffmpeg` 用 `lavfi` 测试图 + 正弦波现场合成的(**例外**:AV1 样片 `lux/test/fixtures/lux-av1-fixture.mkv` 为入库的测试资产,sha256 见 `lux/test/fixtures/SHA256SUMS`,由 `run.sh` 复制到工作目录并校验),
  不含任何第三方素材。

---

## 12. F1 — 动态 framework + xcframework

F0 证明了「能出 LGPL-only 的静态库」。F1 解决的是**链接方式**:LGPL 要求动态链接 / 可替换,
而 MPVKit 现有的 framework 只能靠 macOS 默认大小写不敏感的文件系统才能 `import`(A0 的发现)。
这一节记录 F1 的做法、产物、验证与踩过的坑。

**更正(F2-1,2026-11-07):实际产物是六个库(另有 `Libavfilter` / `Libswscale`,见 `lux/config/ffmpeg-ios.conf` 的 `LUX_FRAMEWORKS`),下面以“四个”描述的段落仅指前四个库的历史细节,语义适用于全部六个。**

**一句话结论:四个库各出一个真正的动态 framework(`Libavutil` / `Libswresample` / `Libavcodec` /
`Libavformat`),三切片合成 xcframework;Swift 可以直接 `import Libavformat` 等,不需要 C shim、
不需要 `-I`,也不依赖大小写不敏感的文件系统(已在 Case-sensitive APFS 卷镜像上验证)。**

### 12.1 速览

| | macOS arm64 | iOS device | iOS simulator |
| --- | --- | --- | --- |
| 构建命令 | `./lux/build/build-frameworks.sh macos-arm64` | `... ios-arm64` | `... ios-sim-arm64` |
| 库形态 | `--enable-shared --disable-static` | 同 | 同 |
| 最低系统 | macOS 14.0 | iOS 17.0 | iOS-simulator 17.0 |
| 耗时(实测两次) | configure 35–43 s,总 **59–60 s** | configure 25–30 s,总 **40–58 s** | configure 38–39 s,总 **58–69 s** |
| 产物 | `lux/.build/frameworks/<target>/slice/*.framework` | 同 | 同 |

各 framework 的二进制大小(`stat -f %z`,单位字节):

| framework | macOS arm64 | iOS device | iOS sim arm64 |
| --- | --- | --- | --- |
| `Libavformat` | 858,096 | 858,096 | 858,032 |
| `Libavcodec` | 3,884,832 | 3,785,984 | 3,884,432 |
| `Libavutil` | 778,560 | 778,544 | 778,496 |
| `Libswresample` | 145,728 | 145,728 | 145,728 |
| **合计** | **5,667,216** | **5,568,352** | **5,666,688** |

xcframework 在 `lux/.build/xcframeworks/`(`Libavutil.xcframework` 等各 3 个切片),
zip + checksum 在同一个目录;dSYM 在 `lux/.build/xcframeworks/dSYMs/<target>/`。
**二进制不进 git**(`/lux/.build/` 已在 `.gitignore`)。

### 12.2 为什么用 `configure --enable-shared`,而不是拿 F0 的 `.a` 重链

任务书给了两个选项。先试的是 (b)(把 F0 的静态 `.a` 用 `clang -dynamiclib` 逐个链成 dylib),
在 `libavformat` 上直接失败:

```
ld: fixup error (kind=arm64_adrp_lo12) at '_ff_mp4_read_dec_config_descr'+0x188
    from libavformat.a[30](isom.o), target '_ff_mpa_freq_tab' does not have address
```

原因在 FFmpeg 的构建系统里:`libavformat/isom.o` 引用的 `ff_mpa_freq_tab` 在 libavcodec 里是
**hidden** 符号(`libavutil/attributes_internal.h` 的 `FF_VISIBILITY_PUSH_HIDDEN`),跨 dylib
根本不可见;FFmpeg 对此的解法是 `SHLIBOBJS` —— 只在 `--enable-shared` 时编译的补充目标文件
(`libavformat/Makefile: SHLIBOBJS-$(CONFIG_ISO_MEDIA) += mpegaudiotabs.o`)。静态构建里这些
`.o` 压根不存在,所以重链时必须手工补,等于复制 FFmpeg 的构建知识。

共享构建还顺带解决:

* `-Wl,-exported_symbols_list,libav*.ver`:只导出公开 API,内部符号不外泄;
* `-current_version` / `-compatibility_version` 与 `libav*.ver` 由 configure 生成;
* `install_name` 用 `--install-name-dir=@rpath` 直接写成 `@rpath/libavcodec.62.dylib`,
  中间产物里没有绝对路径,打包时只把文件名改成 framework 里的名字。

代价:共享构建与 F0 的静态构建各编一次对象文件(单目标多 ~60 s,可接受);F0 的
`build-ffmpeg.sh` / `verify-license.sh` 完全不变。

### 12.3 构建 + 打包流程

```sh
./lux/build/build-frameworks.sh all            # 三个切片 + xcframework + zip/checksum
./lux/build/build-frameworks.sh macos-arm64    # 只做一个切片(调试用)
./lux/build/build-frameworks.sh package        # 只用已有切片重出 xcframework
./lux/build/build-frameworks.sh clean
```

每个目标:configure(共享、`-g`、`-headerpad_max_install_names`)→ `make` → `make install` →
每个库打包一个 `.framework`:

1. `libavcodec.62.28.103.dylib` 拷成 `Libavcodec.framework/Libavcodec`;
   `install_name_tool -id @rpath/Libavcodec.framework/Libavcodec`,再把 `libswresample` /
   `libavutil` 两条依赖 `-change` 成 `@rpath/Libswresample.framework/Libswresample` 等;
2. `Headers/`(见 12.4)+ `Modules/module.modulemap`(`umbrella` + `export *` + 每个依赖一条
   `use` + 从 `otool -L` 推出系统框架的 `link framework`);
3. `Info.plist`:`CFBundleIdentifier=dev.lux.ffmpeg.<Name>`、`MinimumOSVersion`
   14.0/17.0、`CFBundleVersion` = 该库的 FFmpeg 版本(如 `62.28.103`);
4. `PrivacyInfo.xcprivacy`:用 `nm -u` 逐个 framework 实测 required-reason API
   (见 12.5),只声明真的用到的类别;
5. `dsymutil` 出 dSYM,再 `strip -S`(顺序不能反);
6. **四个 framework 全部打包完之后**再逐个 `codesign --force --sign -`(原因见 12.7 第 2 条)。

最后 `xcodebuild -create-xcframework` 把三个切片合成一个 xcframework,
`ditto -c -k --keepParent` 出 zip,`swift package compute-checksum` 写进 `checksums.txt`。

### 12.4 头文件布局:让两种 include 写法都不依赖大小写

FFmpeg 的公开头文件之间是**带库前缀**的相对包含:

```c
libavformat/avformat.h  →  #include "libavcodec/codec_par.h"
libavcodec/codec_par.h  →  #include "libavutil/avutil.h"
```

这要求 include root(包含 `libavformat/`、`libavcodec/` 的那一层)在编译器的搜索路径里。
用 framework 的消费者只给 `-F`,不给 `-I`,所以 include root 永远不在路径上。MPVKit 能工作,
是因为 macOS 默认 APFS 大小写不敏感:clang 的 framework 查找把 `libavcodec/...` 当成
`libavcodec.framework`,正好命中 `Libavcodec.framework`。在大小写敏感的卷上这个 include 直接失败
(A0 的结论,这里也复现过)。

F1 的布局(`lux/build/gen-framework-headers.py` 生成):

```
Libavformat.framework/Headers/
  libavformat/avformat.h              ← canonical,真文件,按库分子目录
  avformat.h -> libavformat/avformat.h ← framework 风格(<Libavformat/avformat.h>)
  libavcodec/codec_par.h              ← 包内副本(内容与 canonical 一致)
  libavformat/libavcodec/codec_par.h  ← include 闭包里实际用到的路径,逐个物化
  ...
```

要点:

* **canonical 在子目录里**(`Headers/libavformat/…`),`-I .../Headers` 就能用
  `#include <libavformat/avformat.h>`,与普通 FFmpeg 安装一致;
* **framework 风格别名**在 `Headers/` 顶层(同一 bundle 内的 symlink),
  `-F` 查找 `<Libavformat/avformat.h>` 直接命中;
* **include 闭包**:脚本从每个头文件实际出现的 `#include "libavXxx/…"` 递归解析,把每一条会用到
  的路径都生成出来(每个 framework 的 Headers 共 153–233 个文件,含 canonical 与闭包副本)。FFmpeg 的 `#include "libavutil/x.h"` 是相对
  *包含者所在目录*解析的,路径会一层层变深(`libavformat/libavcodec/libavutil/...`),闭包
  正好覆盖这些深度;最深 5 层子目录,无环;
* **不用跨 bundle 的 symlink**:`codesign` 会拒绝
  (`invalid destination for symbolic link in bundle`),所以闭包里的文件是**包内副本**
  (内容与 canonical 完全一致),四个 framework 各自自包含;
* 结果:`<libavformat/…>` 与 `<Libavformat/…>`、`clang -fmodules`、Swift 的
  `import Libavformat/…` 全部走**精确大小写**的路径。

### 12.5 验证

```sh
./lux/build/verify-frameworks.sh     # 三切片 + xcframework + 大小写敏感卷,失败非零
./lux/test/swift-import/run.sh       # macOS 真跑 + iOS Simulator 只编译
```

本次结果:**`failures: 0, warnings: 0`,`RESULT: PASS`**。检查项:

1. `otool -hv` 是 `DYLIB`(filetype 6),不是 archive/bundle;
2. `LC_ID_DYLIB` 全是 `@rpath/<Name>.framework/<Name>`;库之间是 `@rpath` 依赖,其余只有
   `/usr/lib` 与 `/System/Library/Frameworks`,没有绝对路径;
3. `vtool -show-build`:`MACOS` 14.0 / `IOS` 17.0 / `IOSSIMULATOR` 17.0;
4. 符号:`nm` 里没有 `x264|x265|fdk|dav1d|…`;`CONFIG_GPL 0`、`CONFIG_NONFREE 0`;
   macOS 上真链接一个小 C 程序,`avutil_license()` 输出 `LGPL version 3 or later`;
5. 结构:canonical 目录 + framework 别名 + module map(`use`/`link`)+ `Info.plist` +
   `PrivacyInfo.xcprivacy` + dSYM(UUID 与二进制一致);
6. `codesign --force --sign -` 后 `--verify --strict` 通过;
7. xcframework 三个切片齐全,zip 的 checksum 与 `checksums.txt` 一致;
8. **大小写敏感卷**:把 macOS 切片拷进 `Case-sensitive APFS` 稀疏镜像
   (`lux/.build/csimg/luxcs.sparseimage`),分别用
   `-I`(canonical)、`-F`(framework)、`clang -fmodules`、`swiftc -typecheck` 各自编译对应的
   TU,全部加 `-Werror=nonportable-include-path`。

`lux/test/swift-import/run.sh` 的输出(macOS,真跑):

```
versions: libavformat 62.12.103 / libavcodec 62.28.103 / libavutil 60.26.103 / libswresample 6.3.103
license: LGPL version 3 or later
format: matroska,webm
duration: 12.021
streams: 2
stream #0: type=video codec=h264 320x240 0Hz 0ch
stream #1: type=audio codec=aac 0x0 48000Hz 2ch
packets: 4
first frame: 320x240 @yuv420p
```

`swift test` 两个测试通过(license/LGPL、matroska/h264/aac、首帧 320x240 yuv420p、时长 12 s),
`xcodebuild -destination 'generic/platform=iOS Simulator'` 报 `BUILD SUCCEEDED`(只编译;
代理不能起模拟器)。

**required-reason API(实测,`nm -u`)**:

| framework | 未定义符号 | 声明 |
| --- | --- | --- |
| `Libavutil` | `_fstat` | `NSPrivacyAccessedAPICategoryFileTimestamp` / `C617.1` |
| `Libavformat` | `_fstat`、`_lstat` | 同上 |
| `Libavcodec`、`Libswresample` | 无 | 空 |

没有 `mach_absolute_time`/`statfs`(与 MPVKit 的 `Libmpv` 不同——那是 mpv 自己的缓存和时钟代码)。
manifest 是按二进制实测生成的,不靠猜。

### 12.6 体积

| | F0 静态 `.a`(iOS device) | F1 动态 framework(iOS device) | 比例 |
| --- | --- | --- | --- |
| `Libavformat` | 1,160,384 | 858,096 | 74% |
| `Libavcodec` | 4,779,896 | 3,785,984 | 79% |
| `Libavutil` | 1,017,888 | 778,544 | 76% |
| `Libswresample` | 132,808 | 145,728 | 110% |
| **合计** | **7,090,976** | **5,568,352** | **79%** |

一个合理解释是:`.a` 里每个成员的目标文件按段对齐、符号表完整保留(`--disable-stripping`),
而 dylib 把所有 `.o` 的段紧凑排布,并且 `strip -S` 去掉了调试信息(这是 aggregate 观察,
没有逐目标文件对账);`Libswresample` 反而大了
11%,是 dylib 的页对齐与导出表开销(它的代码量最小)。

与 MPVKit 1.0.0 的 LGPL 静态切片对比(只能粗略比,链接方式不同):

| | MPVKit(iOS arm64,静态) | Lux F1(iOS arm64,动态) | 比例 |
| --- | --- | --- | --- |
| `Libavcodec` | 10,290,144 | 3,785,984 | 37% |
| `Libavformat` | 2,518,792 | 858,096 | 34% |
| `Libavutil` | 1,159,760 | 778,544 | 67% |
| `Libswresample` | 139,048 | 145,728 | 105% |
| **合计** | **14,107,744** | **5,568,352** | **39%** |

分发物:四个 zip 合计约 16.1 MB(`Libavcodec` 7.4 MB、`Libavformat` 3.9 MB、
`Libavutil` 2.8 MB、`Libswresample` 1.9 MB),dSYM zip 约 15.3 MB。
整棵 `lux/.build/` 约 2.7 GB,其中 2 GB 是大小写敏感验证用的 APFS 稀疏镜像;`build-frameworks.sh all`(三目标 + xcframework + zip)端到端实测 **3 分 00 秒**。

### 12.7 踩过的坑

1. **`--enable-gpl` 之外还有 hidden 符号问题**:静态 `.a` 重链 dylib 会撞上 `SHLIBOBJS`
   (12.2)。以后再加库(avfilter/swscale)也必须走共享构建,不要回到重链。
2. **codesign 与跨 bundle 的 symlink 不兼容**:`Headers/libavcodec/x.h -> ../../Libavcodec.framework/...`
   会让 `codesign --verify` 报 `invalid destination for symbolic link in bundle`。改成包内副本。
   另外签名必须等四个 framework 都打包完:先签的 framework 会因为“兄弟包的头文件后来才出现”
   被报 `file modified`。
3. **`-F` 不会把 framework 的 `Headers` 加进 include 路径**:`#include "libavutil/x.h"` 只能靠
   相对路径或 framework 查找解析,`-I` 才是 include root。这是 12.4 那个布局存在的全部原因。
4. **module map 里的路径基准不一致**:`umbrella "Headers/libavformat"` 相对 framework 根能工作,
   但 `header "Headers/libavformat/avformat.h"` 找不到,必须写成 `../Headers/...`(相对 `Modules/`)。
   脚本里两种写法并存,是实测出来的。
5. **iOS SDK 没有 OpenCL**:`libavutil/hwcontext_opencl.h` 在 macOS SDK 能编译,在
   iPhoneOS/iPhoneSimulator 上找不到 `<OpenCL/cl.h>`,会让整个 `Libavutil` 模块编译失败。
   现在按目标把它排除出模块(文件仍然随 Header 发布)。
6. **`generic/platform=iOS Simulator` 默认要 arm64 + x86_64**:我们只出 arm64 切片,必须
   `ARCHS=arm64`,否则 xcodebuild 直接失败在 x86_64 上。
7. **dSYM 必须在 strip 之前**:`dsymutil` 从 dylib 的 DWARF 抽符号,`strip -S` 之后就没有了;
   顺序反了会得到一个空 dSYM 且 UUID 对不上。
8. **`unzip -l | grep -q` 的 SIGPIPE**:`set -o pipefail` 下 grep 提前退出会让 unzip 收到
   SIGPIPE、整条管道算失败(F0 的 README 里也有同款坑)。verify 脚本先把列表落到文件。
9. **`xcodebuild -create-xcframework` 不覆盖已有输出**:脚本每次 `rm -rf` 目标目录。
10. **迭代速度**:`LUX_SKIP_FFMPEG_BUILD=1 ./lux/build/build-frameworks.sh <target>` 复用
    已 install 的 dylib,只重打包(几秒),调头文件布局/模块时很好用。

### 12.8 在 lux-client 里怎么引用(只写文档,本次没有改 lux-client)

目标形态:`apple/Packages/LuxKit/Vendor/` 放 xcframework(不进 git),`Package.swift` 用
`binaryTarget(path:)`,业务代码直接 `import Libavformat`。

`Package.swift` 片段:

```swift
.target(
    name: "LuxRemux",
    dependencies: [
        .target(name: "Libavformat"),
        .target(name: "Libavcodec"),
        .target(name: "Libavutil"),
        .target(name: "Libswresample"),
    ]
),
.binaryTarget(name: "Libavformat", path: "Vendor/Libavformat.xcframework"),
.binaryTarget(name: "Libavcodec", path: "Vendor/Libavcodec.xcframework"),
.binaryTarget(name: "Libavutil", path: "Vendor/Libavutil.xcframework"),
.binaryTarget(name: "Libswresample", path: "Vendor/Libswresample.xcframework"),
```

下载脚本草案(放 `apple/scripts/fetch-lux-ffmpeg.sh`,产物只写 `apple/.build/` 与
`Packages/LuxKit/Vendor/`):

```sh
#!/usr/bin/env bash
# 用法: ./apple/scripts/fetch-lux-ffmpeg.sh <tag>   (例如 f1-20261106)
set -euo pipefail
TAG=${1:?usage: $0 <release-tag>}
BASE="https://github.com/Qoo-330ml/lux-ffmpeg/releases/download/$TAG"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Packages/LuxKit/Vendor"
mkdir -p "$DEST"
# 校验和来自 lux-ffmpeg 的 lux/.build/xcframeworks/checksums.txt
for fw in Libavutil Libswresample Libavcodec Libavformat; do
    curl --fail --location --silent --show-error \
        "$BASE/$fw.xcframework.zip" -o "$DEST/$fw.xcframework.zip"
    expected=$(curl --fail --location --silent "$BASE/checksums.txt" | awk -v n="$fw.xcframework.zip" '$2==n{print $1}')
    [ "$(shasum -a 256 "$DEST/$fw.xcframework.zip" | awk '{print $1}')" = "$expected" ] \
        || { echo "checksum mismatch: $fw"; exit 1; }
    rm -rf "$DEST/$fw.xcframework"
    ditto -x -k "$DEST/$fw.xcframework.zip" "$DEST"
    rm -f "$DEST/$fw.xcframework.zip"
done
```

注意点:

* `binaryTarget` 是**动态**的 Mach-O,按 Apple 的机制 Xcode 会把它嵌入 `App.app/Frameworks/`
  并签名;但本项目是手写 `project.pbxproj`,必须实测 `xcodebuild archive` 后
  `Payload/Lux.app/Frameworks/` 里确实有四个 framework,`otool -L` 里是 `@rpath/…`
  (`LD_RUNPATH_SEARCH_PATHS` 已有 `@executable_path/Frameworks`);
* 每个 framework 自带 `PrivacyInfo.xcprivacy`;App 的总清单里那三条
  「替 MPVKit 报」的 required-reason 声明可以只保留 App 自己用到的,
  `scripts/check-privacy-manifest.py --app` 的扫描口径要一起改;
* dSYM 单独存档(不放进 App),上传 App Store Connect 时按需提交;
* 切底座时 A/B 两条线只换 binaryTarget,`import Libavformat` 等写法不变;MPVKit 的
  `Libav*` 与这四个同名模块**不能同时存在**,要一次性替换。

### 12.9 F2(libmpv)需要的前置

1. **白名单扩容**:`libavfilter`、`libswscale` 已进构建(§6.2 的 0010–0014),`.d` 反查审计和
   `allowlist.md` 已覆盖;libmpv 还要的滤镜(scale/format 之外的)按需再加。avfilter 是 GPL 文件
   最多的地方(50 个),每加一项都要确认 `CONFIG_GPL=0` 且没有 GPL 源文件被无条件编译。
2. **`--disable-everything` 的 select 连锁**:avfilter / libmpv 需要的 filter、swscale、
   网络协议会通过 `_select` 拉进更多组件(verify 的 `[warn]` 机制会暴露),需要一次完整的
   组件对账。
3. **网络与 TLS**:mpv 的 http/hls 需要 `http`/`tcp`/`tls`/`crypto` 协议 + TLS 库
   (OpenSSL 或 gnutls)。这一步要外部源码,F1 刻意没有做;注意 OpenSSL 是 Apache-2.0、
   gnutls 是 LGPL,选谁要过 `allowlist.md`。
4. **framework 数量**:F2 至少再加 `Libavfilter`、`Libswscale`、`Libmpv`;打包脚本按
   `LUX_FRAMEWORKS` 列表循环,加名字 + 依赖关系即可,xcframework/zip/dSYM 流程复用。
5. **链接语义**:现在每个 framework 是 per-library dylib,FFmpeg 的所有目标文件都进自己的
   dylib;libmpv 聚合时要注意不要把 LGPL 组件静态吞进 `Libmpv`(`2026-11-04-mpv-lgpl-linking-research.md` 的结论),
   非 LGPL 的第三方库可以静态并入。体积影响要重新量。
6. **测试**:`lux/test/swift-import` 加 `import Libavfilter` / `import Libmpv` 的编译检查;
   `Libmpv` 的模块名保持不变,避免 A/B 线改代码。

### 12.10 LGPL 合规清单(F1 交付时需要随包提供)

- **源码**:上游 FFmpeg **8.1.3** 的完整源码(取自 jellyfin-ffmpeg `v8.1.3-2` 的源码树)+
  本仓库 `lux/patches/` 里的 14 个补丁(见 §6.2)+ `lux/` 下的构建脚本
  (`config/`、`build/`、`test/`)——它们共同是「如何从源码得到这个二进制」的对应源码。
  交付时用 `./lux/build/apply-patches.sh status` 与 `BUILD-INFO.txt` 里的 `patches_digest` 对账。
- **补丁清单**:
  - `662b2fe lux: keep GPL-only aarch64 AC3/CRC objects out of LGPL builds`
    (`libavcodec/aarch64/Makefile`、`libavcodec/ac3dsp.c`、`libavutil/aarch64/Makefile`);
  - `lux/patches/0001..0006`(移植自 jellyfin 补丁系列,逐条说明见 §6.2);
  - `56a5356`、`215b006` 是 F0 的文档/实测记录,不含二进制。
- **许可文本**:`COPYING.LGPLv3`(本仓库根目录);动态链接的四个 dylib 可被替换
  (替换后用自己的证书重签即可)。
- **dSYM**:单独存档,不随 App 提交(App Store Connect 需要时再上传)。
- **仍未解决的法律问题**:App Store 的 DRM/反编译条款与 LGPLv3 §4 前言之间的张力
  (见 `lux-client/apple/docs/reviews/2026-11-04-mpv-lgpl-linking-research.md` Q5),
  动态链接只是让 §4(d)(1) 的「可替换」在技术上成立,不代表法务结论。

### 12.11 已验证 / 需要所有者验证

**已验证(本机,代理能做的部分)**

- 三个切片的构建、打包、`verify-frameworks.sh` 全绿(0 failures);
- macOS 上 `swift build` / `swift test` / `lux-ffmpeg-probe` 真跑通过(读 F0 的合成 mkv,
  解出第一帧);
- iOS Simulator 的 `xcodebuild build` 通过(只编译);
- 大小写敏感 APFS 卷镜像上的 clang 两种 include、`@import`、`swiftc -typecheck` 全部通过;
  另外把整个 `lux/test/swift-import` 包拷到该卷上做过一次完整 `swift build` +
  `lux-ffmpeg-probe` 运行(这一步是一次性验证,没写进脚本;脚本里跑更快的 typecheck)。

**需要所有者 / Xcode / 真机**

- iOS 真机与模拟器上的**运行**(代理不能起模拟器):`lux-ffmpeg-probe` 在设备上跑一次;
- 在 lux-client 的 Xcode 工程里真正嵌入四个 framework(自动嵌入 + 签名),
  以及 `xcodebuild archive` 后 `Frameworks/` 的检查;
- App Store Connect 的 dSYM / 隐私清单上传检查;
- 首帧延迟、启动耗时(dyld 多 4 个镜像)、真实片源矩阵。

## 13. F2-1 网络与 TLS(2026-11-07;D3 于 2026-11-10 改为 OpenSSL)

- 配置:`lux/config/ffmpeg-ios.conf` 打开 `--enable-network`、`--enable-openssl`(D3 前是
  `--enable-securetransport`),协议表 `file http https tcp tls`。Secure Transport 只到 TLS 1.2,
  连不上 1.3-only 服务端(`-9836`,见 `lux/docs/tls-13-probe.md`);D3 改用 OpenSSL 3.5.9
  (Apache-2.0,静态 `libssl.a`/`libcrypto.a`),`CONFIG_VERSION3` 仍为 0。
- 验证:`verify-frameworks.sh` PASS;`verify-license.sh` PASS(LGPL-only;`CONFIG_NETWORK 1`、
  `CONFIG_OPENSSL 1`、`CONFIG_SECURETRANSPORT 0` 已加入检查)。
- https 探针:`lux/test/https_probe.c`,在 macOS 静态构建上链接(`clang ... -framework Security -framework CoreFoundation ...`),
  URL 只从环境变量 `LUX_TEST_HTTPS_URL` 读取,不写入仓库。实测:协议表 https/http/tls/tcp/file 均存在;
  F2-1 当时经 SecureTransport 打开一个公开 https 文件并读取 1810 字节,返回 PASS。
- TLS 1.3 回归:`lux/test/tls_probe.c` + `lux/test/run.sh` 第 9 段,用本构建的 `openssl s_server`
  起 1.3-only(8443)与 1.2-only(8444)服务端,探针发 HTTP/1.0 GET 并读到 200,两者都必须成功。

## 14. P2-2 / P2-3 libmpv framework 化(macOS + iOS 切片,2026-11-10)

- 脚本:`./lux/build/build-mpv-frameworks.sh macos-arm64` 复用
  `lux/.build/deps/macos-arm64/install/lib` 里已有的 libmpv 0.41.0 产物,不重新编译;
  libmpv 缺失时才调用 `build-mpv.sh`。
- 产物:`lux/.build/mpv-frameworks/macos-arm64/{Libmpv,Libplacebo,Libfribidi,Libuchardet}.framework`。
- iOS 切片(P2-3):`./lux/build/build-mpv-frameworks.sh ios-arm64|ios-sim-arm64` 输出到
  `lux/.build/mpv-frameworks/<target>/`,规则与 macOS 相同;Info.plist 为 `iPhoneOS`/`iphoneos`
  (模拟器 `iPhoneSimulator`/`iphonesimulator`),`MinimumOSVersion` 17.0(与 F1 切片一致)。
- 规则:四个 framework 的 install name 都是 `@rpath/<Name>.framework/<Name>`;Libmpv 的
  libfribidi / libplacebo 绝对路径依赖,以及 `@rpath/libuchardet.0.dylib`,都改成
  `@rpath/<Name>.framework/<Name>`;6 个 `@rpath/Libav*.framework` 与系统库原样保留。
- 校验:`./lux/build/build-mpv-frameworks.sh verify [target]` 检查 install name、非系统依赖、
  绝对路径残留、`ass_*` 导出符号、platform/minos、Info.plist 与 ad-hoc 签名;失败非零。
  `verify` 默认查 macos-arm64,`verify all` 逐个查已有切片。
- 说明:Libplacebo / Libfribidi 保留 Headers,但没有生成 module map(两者的头文件
  自引用方式不适合 framework 的 `-F` 搜索);Libmpv / Libuchardet 的 module map 已用
  `clang -fmodules` 验证。

## 15. P2 出口:调试符号、重建与 mpv xcframework(2026-11-10)

- **为什么要改**:P2 之前的 dSYM 只有 UUID,没有 DWARF。`dsymutil` 只能搬运二进制里
  已有的调试信息,所以 libmpv 与 deps 必须在编译期带 `-g`。FFmpeg 的动态构建本来就有
  `LUX_FRAMEWORK_CFLAGS=-g`(见 `lux/config/ffmpeg-ios.conf`),这一轮把静态 F0 构建也补齐。
- **`-g` 改动(只改构建脚本,不改 buildtype / 优化等级)**:
  - `lux/build/build-deps.sh`:autotools 与 CMake 走 `CFLAGS`/`CXXFLAGS`;
    meson 不读这两个环境变量,而且命令行 `-Dc_args`/`-Dcpp_args` 会整体替换交叉文件里的
    `[built-in options]`,所以每个 meson 调用(freetype/harfbuzz/dav1d/fribidi/libplacebo)
    都传 `DEPS_DEBUG_CFLAGS`(`DEPS_CFLAGS` + `-g`)。
  - `lux/build/build-mpv.sh`:`-Dc_args="$DEPS_CFLAGS -g"`。
  - `lux/build/build-ffmpeg.sh`:给 `--extra-cflags` 追加 `-g`(其余 configure 参数仍唯一
    来自 `lux/config/ffmpeg-ios.conf`)。
- **重建顺序**:`build-deps.sh <target>`(三切片)→ `build-ffmpeg.sh <target>`(F0 静态,
  `verify-license.sh` 的输入)→ `build-frameworks.sh all`(F1 三切片 + 6 个 xcframework)
  → `build-mpv.sh <target>` → `build-mpv-frameworks.sh <target>`。
  先重建 deps 再编 FFmpeg,dav1d 的 DWARF 才会一起进 libavcodec 的 dSYM。
- **mpv 栈 xcframework**:`./lux/build/build-mpv-frameworks.sh xcframework` 把三个切片的
  Libmpv / Libplacebo / Libfribidi / Libuchardet 打成 4 个 xcframework,输出
  `lux/.build/mpv-xcframeworks/`(与 FFmpeg 的 `lux/.build/xcframeworks/` 分开):
  `<Name>.xcframework`、`<Name>.xcframework.zip`、`checksums.txt`
  (`swift package compute-checksum`)、`dSYMs/<target>/` 与 `dSYMs.zip`、
  `MPV-XCFRAMEWORK-INFO.txt`。切片不全时脚本直接失败,不会产出残缺的 xcframework。
- **校验路径**:`verify-mpv-frameworks.sh` 现在两处都查 mpv 的 xcframework
  (优先 `mpv-xcframeworks/`,回退 `xcframeworks/`),`LUX_MPV_XCFRAMEWORK_ROOT` 可覆盖。
- **修掉一个误报**:`archive_dsym` 原来用 `dwarfdump | grep -q 'DW_TAG'`,在
  `set -o pipefail` 下 `grep -q` 提前退出会让 dwarfdump 吃 SIGPIPE(141),DWARF 明明
  存在也会被判成 `dwarf=no`。改成 `grep -c` 并把条目数写进 `P2-4-INFO.txt` / 日志。
## 16. P3 依赖源码固定(2026-11-10)

目标:构建用的每一份第三方源码都能按 `lux/config/deps.lock` 复现,PyPI 依赖也要有 hash。

### 16.1 结论

- 锁里 **22 项** 于 2026-11-10 全部从各自 URL 重新下载核对,sha256 与锁定值**逐字节一致**,
  一个版本号都没改。日志:`lux/.build/logs/deps-lock-check-20261110.log`(脚本见 16.3)。
- 上游发布资产核对结果(2026-11-10,逐个项目查 GitHub API / GitLab releases):
  - **mpv v0.41.0**:release 页除了 GitHub 自动生成的 Source code 归档(与 deps.lock 里的 tag archive
    是同一类),只有 8 个平台二进制 zip —— **没有任何上传的源码资产**;
  - **libplacebo v7.360.1**:`code.videolan.org` 的 `videolan/libplacebo` 根本没有 release
    (`/-/releases.atom` 为空),`downloads.videolan.org/pub/videolan/` 也没有 libplacebo 目录;
  - **shaderc v2025.5 及其 DEPS**(glslang / SPIRV-Tools / SPIRV-Headers)、**volk**、**cereal**、
    **Vulkan-Headers**、**SPIRV-Cross**:release 页只有自动生成的 Source code 归档(有的连 release 都没有),
    没有上传的源码资产;
  - **MoltenVK v1.4.2**:上传的资产是 `MoltenVK-all.tar` 之类的二进制包,源码也只有自动归档;
  - **fast_float v8.0.2**:上传的资产只有单头文件 `fast_float.h`,没有完整源码包;
  - 其余 8 项(freetype / harfbuzz / fribidi / libunibreak / lcms2 / uchardet / libass / dav1d)
    本来就是官方 release tarball(部分还带上游 `.sha256`),继续只用 URL。

所以:**14 项自存**(逐字节副本放 `lux/release/sources/`,已在 `lux/.gitignore` 里忽略,**不进仓库本体**),
**8 项只用 URL**。自存文件名是 `<name>-<version>`,路径写在 deps.lock 每行的 `selfstore=` 里;
取源码时 `fetch-deps.sh` 优先用自存副本(离线可构建),没有时才回退到 URL,两条路都强制校验 sha256。

### 16.2 清单

| 条目 | 版本 | 来源 | 自存 | sha256 |
| --- | --- | --- | --- | --- |
| `freetype` | `2.15.0` | 官方 release tarball | - | `93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5` |
| `harfbuzz` | `15.0.0` | 官方 release tarball | - | `968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df` |
| `fribidi` | `1.0.17` | 官方 release tarball | - | `6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2` |
| `libunibreak` | `8.0` | 官方 release tarball | - | `9c4fad6e517338a098373acc9f35579ae2c325e6446666fb9ac2666ba15ceba4` |
| `lcms2` | `2.19.1` | 官方 release tarball | - | `bfc54f7bab59fbc921012014a8032e4cba4abd46db47d46b76416a8c0b2815c8` |
| `uchardet` | `0.0.8` | 官方 release tarball | - | `e97a60cfc00a1c147a674b097bb1422abd9fa78a2d9ce3f3fdcc2e78a34ac5f0` |
| `libass` | `0.17.5` | 官方 release tarball | - | `2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc` |
| `mpv` | `0.41.0` | git archive | `lux/release/sources/mpv-0.41.0.tar.gz` | `ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209` |
| `libplacebo` | `7.360.1` | git archive | `lux/release/sources/libplacebo-7.360.1.tar.gz` | `14c0a99f4b01557ec9826ce6b1d52f6de21be274ba03fd5aab7307f18766dc39` |
| `shaderc` | `2025.5` | git archive | `lux/release/sources/shaderc-2025.5.tar.gz` | `fca5041b1fdea6daba167b63e04e55e5059fab40828342126169336643445447` |
| `glslang` | `7a47e2531cb334982b2a2dd8513dca0a3de4373d` | git archive | `lux/release/sources/glslang-7a47e2531cb334982b2a2dd8513dca0a3de4373d.tar.gz` | `272d2725b140e09e85b96eecdc59c2e00c1a14cda2301767e1bf3c363a44b931` |
| `spirv-tools` | `262bdab48146c937467f826699a40da0fdfc0f1a` | git archive | `lux/release/sources/spirv-tools-262bdab48146c937467f826699a40da0fdfc0f1a.tar.gz` | `8f830936b057003be77e90d37068ff6066eb87a1bab0033f8f2f5feaa966ce56` |
| `spirv-headers` | `b824a462d4256d720bebb40e78b9eb8f78bbb305` | git archive | `lux/release/sources/spirv-headers-b824a462d4256d720bebb40e78b9eb8f78bbb305.tar.gz` | `c693867f10a7760ef1bcf85419d51783586768cc2c601d03841bc6a8b2554b9c` |
| `moltenvk` | `1.4.2` | git archive | `lux/release/sources/moltenvk-1.4.2.tar.gz` | `6864db532f1dbbdb621a8d0ec13f24edae318fd9269dd3dd0cdff791334bb1cb` |
| `vulkan-headers` | `e3b1eec08173d6b825cd3ac88c885a63b621504a` | git archive | `lux/release/sources/vulkan-headers-e3b1eec08173d6b825cd3ac88c885a63b621504a.tar.gz` | `f492279345cbc10708b64fcd432b3ff6c8246a5837c4db2b649abba00cf82208` |
| `spirv-cross` | `6c09849fe88c48eaed08413aa022aaa136a3a057` | git archive | `lux/release/sources/spirv-cross-6c09849fe88c48eaed08413aa022aaa136a3a057.tar.gz` | `b81b9956289950570953738e666a031ca32ff64e4fc925eba89f227c42109518` |
| `spirv-tools-mvk` | `0d6fd73ca73830ccab5fa1f00ed5ed40124e2c55` | git archive | `lux/release/sources/spirv-tools-mvk-0d6fd73ca73830ccab5fa1f00ed5ed40124e2c55.tar.gz` | `20219c0962dffb0d7644bb3116a5923cfcf0526a569baa0b2a17343dd2fa6e5d` |
| `spirv-headers-mvk` | `29981f65241605e08b0ede4cfeb999fe3b723c6a` | git archive | `lux/release/sources/spirv-headers-mvk-29981f65241605e08b0ede4cfeb999fe3b723c6a.tar.gz` | `232899f1ad4104fb5bc377b94596c7621575eee62ad9a9e8f929b63a7dd8a7ad` |
| `volk` | `776893306c5d3b22b6185b5d4a258b81d94572bf` | git archive | `lux/release/sources/volk-776893306c5d3b22b6185b5d4a258b81d94572bf.tar.gz` | `ff5b63e1b7104b34955eb4a993b94882a55f8561e971b92119069e496e3496b5` |
| `cereal` | `a56bad8bbb770ee266e930c95d37fff2a5be7fea` | git archive | `lux/release/sources/cereal-a56bad8bbb770ee266e930c95d37fff2a5be7fea.tar.gz` | `12e10fb541270632f6683286ce8c7e8c321fe4addb53fa91ed498b95c1758f93` |
| `fast_float` | `8.0.2` | git archive | `lux/release/sources/fast_float-8.0.2.tar.gz` | `e14a33089712b681d74d94e2a11362643bd7d769ae8f7e7caefe955f57f7eacd` |
| `dav1d` | `1.5.4` | 官方 release tarball | - | `686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5` |

### 16.3 取源码与校验

- `lux/build/fetch-deps.sh [--fresh] [--from-url] [--offline] [--src DIR] [name ...]`:
  按锁取源码到 `lux/.build/deps/src/`(`LUX_DEPS_SRC` 可改)。**下载/复制先写 `.part`,
  校验通过才 rename 到目标名**;不一致就删掉半成品并 `exit 1`,不会覆盖缓存,更不会改写 deps.lock。
  自存副本若存在但 hash 不对,直接失败并提示,不会悄悄回退到 URL。
  `--from-url` **隐含 `--fresh`**:即使缓存里已有 hash 正确的文件也会重新下载,日志里会打出
  `[get] <name> <- <url>`,不会被 `[cached]` 短路(用于独立核对上游字节)。
- `lux/build/check-deps-lock.sh [--fresh] [--offline] [--cache DIR] [--log FILE] [--build-src DIR]`:
  逐项把 URL 的**当前字节**取下来核对,同时核对 `selfstore=` 与构建缓存;日志默认写
  `lux/.build/logs/deps-lock-check-<YYYYmmdd>.log`。
  - 退出码:`0` = 每一项都有通过 sha256 的副本;`1` = 有差异、下载失败,或 **`--offline` 下某项
    本地一份可用副本都没有**;`2` = 用法错误。
  - `--offline` 只看本地(下载缓存 / `selfstore=` / `--build-src`),**不会**把“没核对”算成通过:
    三项都没有的条目会打 `offline=NO-LOCAL-COPY`、计入 FAIL,并在末尾列出缺失清单。
    新 clone(没有 `lux/.build/verify`,也没有 `lux/release/sources/`)跑 `--offline` 必然是 exit 1,
    这是预期行为;要联网核对请去掉 `--offline` 或加 `--fresh`。
  - 下载缓存放在 `lux/.build/verify/deps-lock/`,不碰 `lux/.build/deps/`。
- 关于构建脚本:sha256 校验**只在** `fetch-deps.sh`(取源码、落缓存前)和 `check-deps-lock.sh`
  (核对)里做;`build-deps.sh` / `build-mpv.sh` / `build-moltenvk.sh` 只解包
  `lux/.build/deps/src` 中已校验过的归档,**自己不重算 hash**。所以构建前必须先跑
  `fetch-deps.sh`(缓存缺失或 hash 不符时它会失败),这是本任务明确选择的边界
  (另一条路是在每个 build 脚本解包前复算,会增加三处重复逻辑且本机无法完整回归)。
- 下载带重试(`--retry 5 --retry-all-errors`):上游偶发 5xx/断流时重试,不会因为一次网络抖动
  就误报成 hash 不符;真的取不到才算失败。
- 公共函数在 `lux/build/deps-lock-common.sh`(sha256 计算兼容 `sha256sum` / `shasum`)。
- 一次完整核对(会联网,约 55 MB):

  ```sh
  ./lux/build/check-deps-lock.sh --fresh
  # == 22 项:22 OK,0 FAIL(deps.lock 未被修改)==
  ```

### 16.4 glad2:PyPI 也要 hash

- `lux/config/requirements-glad.txt` 钉住 `glad2==2.0.8` 及其传递依赖 `Jinja2==3.1.6`、
  `MarkupSafe==3.0.4`;每个包列 sdist + 纯 Python 通用 wheel + macOS wheel 的 sha256
  (`pip download` 取到的产物算一遍,再与 PyPI 的 `digests.sha256` 交叉核对)。
- `lux/build/install-glad.sh [--target DIR] [--force]` 执行
  `python3 -m pip install --require-hashes --target lux/.build/deps/pydeps -r lux/config/requirements-glad.txt`,
  装完自检三个包的版本并 `import glad`。实测:正常安装通过;把任一 hash 改错后 pip 以
  `THESE PACKAGES DO NOT MATCH THE HASHES FROM THE REQUIREMENTS FILE` 失败。
- `lux/vendor/glad-2.0.8/generate.sh` 缺 glad2 时会先调 `install-glad.sh`;顺手修了它算错仓库根的
  老 bug(原来 `REPO` 少退一层,落到 `lux/`,导致 `lux/lux/.build/...` 路径不存在)。重新生成的头文件
  与仓库里的逐字节一致(gl.h `74854594…`、egl.h `d8961e43…`)。

### 16.5 边界与已知限制

- 自存包**不在 git 里**。换一台机器/新 clone 只能走 URL 兜底(同样的 sha256 校验);
  正式发布时应把 `lux/release/sources/` 一起放进发布资产或合规源码包(LGPL 的源码提供义务),
  并保留 16.2 的清单与 hash。
- 上游 archive 链接的字节仍可能变(标签移动、归档重新生成)。届时校验会**失败并报错**,
  而不是静默换掉内容;要更新就人工确认上游后同时改 `deps.lock` 的 sha256 与自存副本。
- 上游不提供源码签名(GitHub/GitLab archive、PyPI 之外的渠道也没有 GPG 清单),当前是
  “首次下载即锁定 + 每次重新下载复核”的 TOFU 模型,不是上游签名验证。
- `requirements-glad.txt` 的 wheel hash 只覆盖 macOS;换平台或换 CPython 版本需要补对应 wheel。
- 本次没有新增任何依赖,也没有重建/改写 `lux/.build/deps/`(只读它做 `build-src=ok` 对照)。
