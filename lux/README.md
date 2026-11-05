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
| 合计 | 7,210,328 B(6.88 MiB) | 7,090,976 B(6.76 MiB) | 7,205,784 B(6.87 MiB) |

各库大小(F0 产物里只有这四个;`lib/` 下不会出现 avfilter/swscale/avdevice):

| 库 | macOS arm64 | iOS device | iOS sim arm64 |
| --- | --- | --- | --- |
| `libavformat.a` | 1,174,720 | 1,160,384 | 1,174,544 |
| `libavcodec.a` | 4,881,216 | 4,779,896 | 4,876,896 |
| `libswresample.a` | 135,904 | 132,808 | 135,984 |
| `libavutil.a` | 1,018,488 | 1,017,888 | 1,018,360 |
| **合计** | **7,210,328** | **7,090,976** | **7,205,784** |

以上数字是 `BUILD-INFO.txt` 里的实测值(每次构建重写)。耗时随磁盘缓存/并发波动,上表给的是多次实测的区间(单目标、串行、`-j10`;三个目标同时构建时单个会到 ~105 s)。整棵 `lux/.build/`(源码树外编译目录 +
日志 + 夹具 + 三个目标)约 **112 MB**。

## 2. 目录

```
lux/README.md                  # 本文件
lux/config/ffmpeg-ios.conf     # configure 参数的唯一真相(被 build 脚本 source)
lux/config/allowlist.md        # 白名单逐项理由 + 版本差异 + 上游 GPL 文件发现
lux/build/build-ffmpeg.sh      # macos-arm64 | ios-arm64 | ios-sim-arm64 | clean
lux/build/verify-license.sh    # 许可 / 符号 / 平台 / 组件对账,失败非零退出
lux/test/read_mkv.c            # 最小 C 程序:读 mkv,打印流信息/时长/首关键帧偏移
lux/test/run.sh                # 合成夹具 → 编译 read_mkv → 运行 → 断言
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
cd /Volumes/Toshiba/mywork/lux-ffmpeg
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

1. 四个 `.a` 齐全,且**没有** `libavfilter.a`/`libswscale.a`/`libavdevice.a`;
2. `config.h`:`CONFIG_GPL 0`、`CONFIG_NONFREE 0`、`CONFIG_VERSION3 1`、`CONFIG_LGPLV3 1`、
   `CONFIG_AVFILTER 0`、`CONFIG_SWSCALE 0`、`CONFIG_AVDEVICE 0`、`CONFIG_NETWORK 0`;
3. `configure` 日志里的 `License:` 行必须是 `License: LGPL version 3 or later`;参数里不得有
   GPL/nonfree/外部编码库;
4. `avutil_license()`:macOS 目标编译并运行探针(输出必须以 `LGPL` 开头);iOS 目标不能运行,
   改为检查 `libavutil.a` 里内嵌的许可标识(`libavutil license: LGPL version 3 or later`),
   并确认没有 `GPL`/`nonfree` 标识;
5. **GPL 源文件审计**:用 `*.d` 依赖文件反查每个 `.o` 的源文件(本例 417 个),扫源码头里的
   GPL 标记(LGPL 的 "Lesser" 不算);有 GPL 源文件被编译就失败。另外单独确认已知的两个上游
   GPL 目标文件不在归档里;
6. 符号表:四个 `.a` 的 `nm` 里没有 `x264|x265|fdk|xvid|vidstab|postproc|mp3lame|theora|dav1d|
   libvpx|libass|freetype|gnutls|openssl|…`;同时正向确认每个库都有 `av*/swr*` 符号(不是空归档);
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

- **基线**:jellyfin-ffmpeg `v8.1.3-2`,即 FFmpeg **8.1.3** + jellyfin 补丁(本仓库 `lux/8.1.3`
  分支,提交 `f2e0673`)。上游源码树是 **LGPL/GPL 混合**:`libavfilter` 下有 50 个文件是 GPL,
  `libavcodec/aarch64/ac3dsp_*` 与 `libavutil/aarch64/crc.S` 也是 GPL。本构建**只启用 LGPL 部分**。
- `configure` 输出:`License: LGPL version 3 or later`(因为 `--disable-gpl --disable-nonfree
  --enable-version3`);`config.h` 里 `CONFIG_GPL 0`、`CONFIG_NONFREE 0`、`CONFIG_VERSION3 1`、
  `CONFIG_LGPLV3 1`。
- 为什么还要额外审计:`CONFIG_GPL 0` 只保证 `#if CONFIG_GPL` 包住的代码不编,**不保证没有 GPL
  源文件被无条件编进去**。F0 就是用第 5 项检查(反查 `.o` 的源文件)抓到了两个这样的文件,
  见下节。GPL 滤镜之所以不会进来,是因为我们根本没编译 avfilter(`--disable-avfilter`),
  而不是因为 `CONFIG_GPL 0`。
- 静态链接本身的分发合规(LGPLv3 §4 的目标代码/重链接义务)是 F1 要解决的问题:动态
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
  `lux/config/allowlist.md`;`--disable-gpl --disable-nonfree --enable-version3` 的结果是
  `LGPL version 3 or later`。GPL 文件要么因为没开对应组件/库而不编译,要么由 6.1 的两个
  守卫排除,并由 `verify-license.sh` 第 5 项检查持续保证。
- 产物许可:FFmpeg 部分为 **LGPL-3.0-or-later**(`COPYING.LGPLv3`),对上游文件的两个改动
  以 `lux:` 提交记录在本仓库(见 `git log`)。
- 夹具(`lux/.build/fixtures/*.mkv`)是本机 `ffmpeg` 用 `lavfi` 测试图 + 正弦波现场合成的,
  不含任何第三方素材。

---

## 12. F1 — 动态 framework + xcframework

F0 证明了「能出 LGPL-only 的静态库」。F1 解决的是**链接方式**:LGPL 要求动态链接 / 可替换,
而 MPVKit 现有的 framework 只能靠 macOS 默认大小写不敏感的文件系统才能 `import`(A0 的发现)。
这一节记录 F1 的做法、产物、验证与踩过的坑。

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
   `-I`(canonical)、`-F`(framework)、`clang -fmodules`、`swiftc -typecheck` 编译同一个 TU,
   全部加 `-Werror=nonportable-include-path`。

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

三项变小主要是:`.a` 里每个成员的目标文件按段对齐、符号表完整保留(`--disable-stripping`),
而 dylib 把所有 `.o` 的段紧凑排布,并且 `strip -S` 去掉了调试信息;`Libswresample` 反而大了
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

* `binaryTarget` 是**动态**的 Mach-O,Xcode 会把它嵌入 `App.app/Frameworks/` 并签名;手写
  `project.pbxproj` 的工程必须实测 `xcodebuild archive` 后 `Payload/Lux.app/Frameworks/` 里确实有
  四个 framework,`otool -L` 里是 `@rpath/…`(`LD_RUNPATH_SEARCH_PATHS` 已有
  `@executable_path/Frameworks`);
* 每个 framework 自带 `PrivacyInfo.xcprivacy`;App 的总清单里那三条
  「替 MPVKit 报」的 required-reason 声明可以只保留 App 自己用到的,
  `scripts/check-privacy-manifest.py --app` 的扫描口径要一起改;
* dSYM 单独存档(不放进 App),上传 App Store Connect 时按需提交;
* 切底座时 A/B 两条线只换 binaryTarget,`import Libavformat` 等写法不变;MPVKit 的
  `Libav*` 与这四个同名模块**不能同时存在**,要一次性替换。

### 12.9 F2(libmpv)需要的前置

1. **白名单扩容**:`libavfilter`、`libswscale` 进构建。avfilter 是 GPL 文件最多的地方
   (F0 统计 50 个),`--disable-gpl` 不等于「不会编译 GPL 文件」,必须把 `verify-license.sh`
   的 `.d` 反查审计扩展到新组件,并逐项重写 `allowlist.md`。
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

- **源码**:jellyfin-ffmpeg `v8.1.3-2`(本例 = FFmpeg 8.1.3 + jellyfin 补丁)的完整源码,
  对应本仓库 `lux/8.1.3` 分支的 tag/提交;以及本仓库 `lux/` 下的构建脚本
  (`config/`、`build/`、`test/`)——它们是「如何从源码得到这个二进制」的对应源码。
- **补丁清单**(`lux:` 提交,`git log lux/8.1.3`):
  - `662b2fe lux: keep GPL-only aarch64 AC3/CRC objects out of LGPL builds`
    (`libavcodec/aarch64/Makefile`、`libavcodec/ac3dsp.c`、`libavutil/aarch64/Makefile`);
  - `56a5356`、`215b006` 是 F0 的文档/实测记录,不含二进制。
  F1 本身**没有改任何上游文件**,只加了 `lux/` 下的新文件。
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
- 大小写敏感 APFS 卷镜像上的 clang 两种 include、`@import`、`swiftc -typecheck` 全部通过。

**需要所有者 / Xcode / 真机**

- iOS 真机与模拟器上的**运行**(代理不能起模拟器):`lux-ffmpeg-probe` 在设备上跑一次;
- 在 lux-client 的 Xcode 工程里真正嵌入四个 framework(自动嵌入 + 签名),
  以及 `xcodebuild archive` 后 `Frameworks/` 的检查;
- App Store Connect 的 dSYM / 隐私清单上传检查;
- 首帧延迟、启动耗时(dyld 多 4 个镜像)、真实片源矩阵。

