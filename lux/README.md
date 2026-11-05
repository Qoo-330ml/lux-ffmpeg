# lux-ffmpeg — F0:LGPL 最小构建 spike

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
| 耗时(实测,`-j10`) | **57 s**(configure 42 s) | **57 s**(configure 35 s) | **72 s**(configure 43 s) |
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

以上数字是 `BUILD-INFO.txt` 里的实测值(每次构建重写)。整棵 `lux/.build/`(源码树外编译目录 +
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
