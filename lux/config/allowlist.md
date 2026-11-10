# F0 白名单 — 每项为什么在名单上

本文件是 `lux/config/ffmpeg-ios.conf` 里那份白名单的说明书。**改配置必须同时改这里**。
组件名以 FFmpeg 8.1.3 的 `configure` 为准(`libavcodec/bitstream_filters.c`、
`libavformat/allformats.c`、`libavcodec/allcodecs.c` 里注册的名字)。

原则:

1. F0 只回答"能不能出一套 LGPL 的最小 iOS 构建",不追求功能完整;
2. 只开**播放本地文件 + 本地 remux(mkv → fMP4)**闭环里真正会被调用到的东西;
3. 任何 `--enable-gpl` / `--enable-nonfree` / 外部 GPL 编码库(x264/x265/fdk-aac/…)一律不开;
4. `--disable-everything` 之后只按本名单打开,名单之外的东西**一个都不开**。

## P1 D4 原生 LGPL 补齐(2026-11-10)

本节按 `capabilities-mpvkit.json` 与 P1 开始时的白名单做差集。D4 的决定是**以 MPVKit 1.0.0 的能力为基线,
默认全部保留**,但本步只加入 FFmpeg 自带、无需新增第三方库的组件。分类口径:

- **a) 原生 LGPL**:当前 FFmpeg 8.1.3 自带,本步加入白名单。
- **b) 需要外部库**:留到 D4 后续步骤,逐条登记在「D4 后续步骤」。
- **c) 有意不要 / 当前版本不可用**:不加,保留理由与替代路径。

`mlp` 与 `webp` 不在 MPVKit 的导出符号里,但它们**确实存在**于 FFmpeg 8.1.3:
`configure:3194` 有 `mlp_decoder_select="mlp_parser"`, `configure:3313` 有
`webp_decoder_select="vp8_decoder"`;`libavcodec/allcodecs.c` 分别注册 `ff_mlp_decoder` 与 `ff_webp_decoder`。
两项本来就在 P1 白名单里,因此不是 D4 新增项,也不属于 MPVKit 缺口。

### a) 本步新增:demuxer(容器/流)

| 组件 | 理由 |
| --- | --- |
| `aac` `ac3` `eac3` `flac` `mp3` `wav` `aiff` `amr` `ape` `ogg` `caf` `loas` | MPVKit 支持的裸音频/单轨容器;用于服务器上的音频文件与分离音轨。原生 LGPL,无外部依赖。 |
| `av1` `hevc` `h264` `m4v` `vc1` `flv` `live_flv` `mpegvideo` `avi` `asf` `dv` `mpegps` `mpegtsraw` `rm` `kux` `ivr` | MPVKit 的常见视频容器/裸流集合,覆盖 AVI、FLV、ASF/WMV、MPEG-PS、RM、酷狗 KUX、IVR 等历史片源。全部是原生 demuxer。 |
| `concat` `hls` `rtp` `rtsp` `sdp` `webm_dash_manifest` | 播放列表/网络流入口。`hls` 对应 `.strm`/m3u8,`rtsp`/`rtp`/`sdp` 是 MPVKit 基线的实时流能力;均只依赖 FFmpeg 自身组件。 |
| `ass` `srt` `webvtt` | 字幕文件 demuxer,与已有字幕 decoder 配对;不是蓝光导航。 |

### a) 本步新增:protocol(传输)

| 组件 | 理由 |
| --- | --- |
| `async` `cache` `concat` `concatf` `crypto` `data` `fd` `ffrtmphttp` `md5` `pipe` `subfile` `tee` | 本地/组合/缓存协议,供播放列表、分片与 MPV 播放链使用。`crypto` 是 FFmpeg 内建 AES,不引入 OpenSSL。 |
| `ftp` `gopher` `gophers` `httpproxy` `icecast` `ipfs_gateway` `ipns_gateway` `mmsh` `mmst` `rtmp` `rtmps` `rtmpt` `rtmpts` `rtp` `srtp` `udp` `udplite` `unix` `prompeg` | MPVKit 基线的网络协议集合。除已列在 b 类的加密/DTLS 项外,均由 FFmpeg 原生实现;TLS 继续走 SecureTransport。 |

### a) 本步新增:bitstream filter

| 组件 | 理由 |
| --- | --- |
| `apv_metadata` `av1_metadata` `evc_frame_merge` `lcevc_metadata` `h264_metadata` `h264_redundant_pps` `hevc_metadata` `mpeg2_metadata` `opus_metadata` `prores_metadata` `vp9_metadata` `vvc_metadata` | MPVKit 基线的元数据处理/重写 bsf,用于 remux 与格式适配。 |
| `av1_frame_merge` `av1_frame_split` `vp9_raw_reorder` `vp9_superframe` `vp9_superframe_split` `vvc_mp4toannexb` | AV1/VP9/VVC 的分帧与 Annex B 适配。 |
| `chomp` `dts2pts` `dump_extradata` `dv_error_marker` `eac3_core` `filter_units` `hapqa_extract` `imx_dump_header` `media100_to_mjpegb` `mjpeg2jpeg` `mjpega_dump_header` `mov2textsub` `mpeg4_unpack_bframes` `pcm_rechunk` `pgs_frame_merge` `remove_extradata` `text2movsub` `truehd_core` | 码流提取、重排与字幕/PCM/PGS 适配 bsf,均为 FFmpeg 原生实现。 |
| `eia608_to_smpte436m` `smpte436m_to_eia608` | 闭路字幕与 SMPTE 436M 互转。 |
| `setts` `showinfo` `noise` `trace_headers` | 调试/诊断 bsf。`noise` 在 MPVKit 基线里;仅做码流扰动,不引入依赖。 |

### b) 需要外部库,留待 D4 后续步骤

| 组件 | 外部依赖 / 原因 | 后续处理 |
| --- | --- | --- |
| `dash` demuxer | `configure:3868` 要求 `libxml2` | 后续单独评估 libxml2(连同许可/体积)。 |
| `libdav1d` decoder | `configure:3768` 要求 `libdav1d` | AV1 软解单独成步;原生 `av1` decoder 已保留。 |
| `libuavs3d` decoder | `configure:3820` 要求 `libuavs3d` | 需要外部 AVS3 解码库,单独评估。 |
| `ffrtmpcrypt` protocol | `configure:4017` 要求 `gcrypt`/`gmp`/`openssl`/`mbedtls` 之一 | 与 RTMP 加密一起后续评估。 |
| `rtmpe` protocol | select `ffrtmpcrypt` | 依赖上一项;本轮不开。 |
| `rtmpte` protocol | select `ffrtmpcrypt` + `ffrtmphttp` | 依赖上一项;本轮不开。 |
| `dtls` protocol | `configure:4057` 要求 OpenSSL/SChannel/GnuTLS/mbedTLS | 与 D3 TLS 方案一起评估。 |

### c) 有意不要 / 当前版本不可用

| 组件 | 类别 | 理由 |
| --- | --- | --- |
| `data` demuxer | 有意不要 | MPVKit 符号表里的调试/数据通道 demuxer,不对应正常媒体文件;正常文件由各容器 demuxer 处理。 |
| `dvd_nav` parser | 有意不要 | DVD 导航解析不属于文件播放/MPVKit 的流媒体覆盖;保留 `dvdsub` 字幕解码,不引入 DVD 菜单路径。 |
| `rdt` demuxer | 当前版本不可用 | FFmpeg 8.1.3 的 `configure --list-demuxers` 没有 `rdt`;无法用同名组件补齐。 |
| `rtp_parse_set_dynamic` protocol | 当前版本不可用 | 这不是 FFmpeg 8.1.3 的 protocol 名(MPVKit 符号表里的内部/派生名);RTP 由 `rtp` 协议覆盖。 |
| `init_cabac` `init_range` `vpx_init_range` decoder | 当前版本不可用 | 它们是 MPVKit 符号表里的初始化辅助符号,不是 8.1.3 可启用的 decoder;对应能力由 H.264/VP8/VP9 解码器本身提供。 |

### 本轮新增后的 parser 与 decoder

parser/decoder 的逐项理由见下文 D4 小节;两者按同一 a/b/c 口径处理。`mlp` parser、`webp` parser 虽不在
MPVKit 符号表,但已在 FFmpeg 中存在;`truehd` 会自动 select `mlp` parser,`webp` 会自动 select `vp8` decoder。

---

## demuxer

| 组件 | 为什么在名单上 |
| --- | --- |
| `matroska` | F0 的输入格式。mkv/webm 解封装是本地 remux 的起点,也是 `lux/test/read_mkv.c` 的验证对象。 |
| `mov` | 读 mp4/mov(含 fMP4 分片)。本地 remux 的产物要能被自己的播放器再读回来,以及直接播放服务器给的 mp4。 |
| `mpegts` | HLS 的 ts 分片与 IPTV 源;也是 `h264/hevc_mp4toannexb` 那一路 bsf 的使用场景。 |

## muxer

| 组件 | 为什么在名单上 |
| --- | --- |
| `mov` | mov/mp4 复用器本体。本地 remux 写 fMP4 分片(`-movflags frag_keyframe+empty_moov`)靠它。 |
| `mp4` | `ff_mp4_muxer`,同一个 movenc 的注册名;显式写清楚,避免以后只开 `mov` 时 `-f mp4` 找不到封装器。 |

## parser

| 组件 | 为什么在名单上 |
| --- | --- |
| `h264` | mpegts / annexb 输入在 `av_read_frame` 时需要按 NAL 切帧;SPS/PPS 解析也靠它。 |
| `hevc` | 同上,HEVC 版本。 |
| `aac` | ADTS 流需要按 ADTS 头切帧,并把 profile/samplerate 补进 codecpar。 |
| `ac3` | AC-3 帧边界靠它(也顺带满足 `mov_muxer_select` 对 `ac3_parser` 的依赖)。 |
| `opus` | Opus 在 mkv 里是带 `CodecPrivate` 的;parser 用于帧边界与 `opus_metadata` 相关处理。 |
| `vorbis` | mkv 里的 Vorbis 需要解析 extradata 才能拿到 codecpar;不开 parser 时 `avformat_find_stream_info` 会退回逐帧探测。 |

## decoder

全部是**软解**组件。开了 `h264`/`hevc` 才能让 `h264_videotoolbox`/`hevc_videotoolbox` 这两个
hwaccel 有对应的 codec 上下文(configure 里 hwaccel 会 `select` decoder)。

| 组件 | 为什么在名单上 |
| --- | --- |
| `h264` | 视频主格式;无硬解 / 硬解失败时的回落。 |
| `hevc` | 同上,4K/HDR 内容常用。 |
| `aac` | 最常见的音频编码,也是 `aac_at` 不可用时的回落。 |
| `ac3` | 5.1 内容最普遍的音频。 |
| `eac3` | 流媒体常见的 E-AC-3;与 `ac3` 共用 `ac3dsp`。 |
| `dca` | DTS / DTS-HD 的核心层解码(mpv 的 `dca_core` 路径)。 |
| `truehd` | TrueHD(含 Atmos 的容器层)。 |
| `mlp` | TrueHD 的底层编码族,`truehd` 解码器依赖它。 |
| `flac` | 无损音轨。 |
| `opus` | 有损低码率音轨(webm/mkv)。 |
| `vorbis` | 老 webm/anime 内容。 |
| `pgssub` | 蓝光 PGS 字幕。 |
| `subrip` | SRT 字幕(封装成 mkv/mp4 的 text 轨)。 |
| `ass` | ASS/SSA 字幕解码(渲染由外部 libass 负责,F1 才引入)。 |
| `webvtt` | WebVTT 字幕。 |
| `webp` | mkv 的 `image/webp` 封面 attachment(补丁 0007 把 mime 映射到它);客户端列表/详情页的封面图。 |
| `mjpeg` | mkv/mp4 里最常见的封面格式(`image/jpeg`),同样是 attachment 解码。 |

## encoder

| 组件 | 为什么在名单上 |
| --- | --- |
| `aac` | FFmpeg 原生 AAC 编码器(LGPL),音频转码的兜底。 |
| `aac_at` | Apple AudioToolbox AAC 编码器(系统框架,不引入第三方许可),CPU 占用低;需要 `--enable-audiotoolbox`。已确认在 8.1.3 里存在且能编进产物(见 verify 输出的 encoder 对账)。 |

## bsf

| 组件 | 为什么在名单上 |
| --- | --- |
| `h264_mp4toannexb` | mp4/mkv 的 AVCC 长度前缀 → Annex B,写 mpegts 或喂给某些解码器时必需。 |
| `hevc_mp4toannexb` | 同上,HEVC。 |
| `aac_adtstoasc` | ADTS → AudioSpecificConfig,ADTS 源写进 mp4 必需(mov_muxer 也会自动 select)。 |
| `dca_core` | 从 DTS-HD 里抽 DTS 核心层,fMP4 remux 时让不支持的设备也能出声。 |
| `dovi_rpu` | Dolby Vision RPU 在 hevc→mp4 时的处理(jellyfin 补丁的价值之一)。 |
| `extract_extradata` | 从码流里提取 extradata,remux 时补 codecpar。 |
| `null` | 空操作 bsf,用来做链路测试(也给 `run.sh` 这类脚本一个"只过一遍"的选项)。 |
| ~~`trim`~~ | **8.1.3 里不存在**(见下面「版本差异」),已从白名单移除。 |

## protocol

| 组件 | 为什么在名单上 |
| --- | --- |
| `file` | 只读本地文件。F0 不联网,`--disable-network` 一起关掉了所有 socket 协议。 |

## hwaccel(F0 附加项)

| 组件 | 为什么在名单上 |
| --- | --- |
| `h264_videotoolbox` | 任务书白名单外,但 libmpv 的底层必须有硬解;只开解码侧,不开编码侧。 |
| `hevc_videotoolbox` | 同上,HEVC。 |

> 这两个是 F0 唯一"超额"的项。它们不吃外部库(只用系统 VideoToolbox.framework),
> 不改变许可结论,但确实让 configure 多编译几个文件;如果 F0 只想要绝对最小,
> 删掉这两个 `--enable-hwaccel` 即可,其余检查不受影响。

---

## 明确不开的东西

| 不开 | 理由 |
| --- | --- |
| `--enable-gpl` / `--enable-nonfree` | 硬约束。 |
| `--enable-version3` | 会把许可抬到 LGPL-3.0-or-later。D2 决定维持 **LGPL-2.1+**,理由见下面「许可决定」一节。 |
| libx264 / libx265 / libfdk-aac / libxvid / libvidstab / libmp3lame / libvpx / libdav1d / libass / libfreetype | 外部库 + GPL/额外依赖。F0 不联网、不下载依赖,一个都不要。 |
| `libavfilter` | `--disable-avfilter`。jellyfin 补丁里的 GPL 滤镜文件正因为关了它才不会被编进去。 |
| `libswscale` | `--disable-swscale`。F0 不做像素格式转换;硬解输出 CVPixelBuffer,软解交给 mpv 的 GPU 链。 |
| `libavdevice` | `--disable-avdevice`。不做采集。 |
| `libpostproc` | FFmpeg 8.0 起已从源码树移除,没有这个库,也没有 `--disable-postproc` 选项。 |
| 网络协议 / TLS | `--disable-network`,F0 只读本地文件。 |
| `matroska` muxer | F0 的产物方向是 fMP4;写 mkv 用不到,不开。 |
| av1/vp9/prores 等解码器 | 名单外。以后要支持再加,加之前先看它的 `_select` 拉进来什么。 |

## 许可决定:不加 `--enable-version3`(D2,2026-11-10)

- **决定**:本构建的许可目标是 **LGPL-2.1-or-later**。所有者已确认 D2(计划 §8「能降就降」),
  与 MPVKit / mpv / libplacebo 的许可下限一致,并缩小与 App Store 条款的张力。`ffmpeg-ios.conf`
  因此**不写** `--enable-version3`,只保留 `--disable-gpl --disable-nonfree`。
- **依据**:P0-4 探针(`2026-11-10-p0-4-version3-finding.md`)在同一份白名单上对比了「有/无
  `--enable-version3`」两次 configure + make:启用的组件集合逐项相同,`config.h` 的 `CONFIG_*`
  行排序后只有两个许可宏不同(`CONFIG_VERSION3` 1→0、`CONFIG_LGPLV3` 1→0);configure 的许可行
  从 `License: LGPL version 3 or later` 变成 `License: LGPL version 2.1 or later`。
- **什么情况会被迫加回来**(届时必须重新评估 D2):启用 `EXTERNAL_LIBRARY_VERSION3_LIST` 里的库
  (gmp、libaribb24、liblensfun、libopencore-amr、mbedtls、rkmpp 等)、`libsmbclient`、
  以 OpenSSL ≥ 3.0 作 TLS 后端,或引入任何 GPLv3-only 代码。当前白名单一个都不涉及;TLS 走
  `--enable-securetransport`,configure 里与 OpenSSL 互斥。
- **守护**:`verify-license.sh` 硬性要求 `CONFIG_VERSION3 0`、`CONFIG_LGPLV3 0`,且 configure
  日志的 `License:` 必须是 `LGPL version 2.1 or later`;`build-ffmpeg.sh` 只接受以 `License: LGPL`
  开头的许可行。把 version3 加回来会让 verify 直接 FAIL。
- **随包许可文本**是仓库根的 `COPYING.LGPLv2.1`,不是 `COPYING.LGPLv3`。

## filter(F2 起)

| 组件 | 为什么在名单上 |
| --- | --- |
| `scale_vt` | VT 上做缩放与 NV12↔P010 转换(补丁 0010 给它加了 `format` 选项),HDR/10-bit 内容不必先落回 CPU 再上屏。 |
| `transpose_vt` | 旋转/镜像走 CoreImage(补丁 0011),避开 VT 旋转对格式的限制。 |
| `format` | 任何滤镜图的第一跳:协商像素格式与色彩属性。 |
| `scale` | swscale 软缩放;`format`/`scale` 是组图与以后 libmpv 的底座。 |
| `null` | 空滤镜,做基准图与"只测链路"用。 |
| `hwupload` / `hwdownload` | 软件帧 ↔ VideoToolbox 帧(带了 0002 的 device derive 才能在没有显式 device 时工作)。 |
| `tonemap_videotoolbox`(Metal) | HDR→SDR 的 Metal 实现;不在 `LUX_FILTERS` 里,需要 Metal Toolchain 才启用(`LUX_FILTERS_METAL`)。 |
| `overlay_videotoolbox`(Metal) | 字幕/水印叠加,Metal 实现。 |
| `bwdif_videotoolbox` / `yadif_videotoolbox`(Metal) | 硬件去隔行。 |

Metal 三项没有 Metal Toolchain 时会被 configure 关掉,`verify-license.sh` 会打 `[warn]` 而不是
`[FAIL]`;装上 toolchain 后自动变成硬性检查。

## configure 自动带入的组件(不在白名单里,但不是我们主动开的)

`verify-license.sh` 会把它们打成 `[warn]`,方便对账:

| 组件 | 谁拉的 |
| --- | --- |
| `mlp` parser | `truehd_decoder_select="mlp_parser"`(configure:3286) |
| `vp9_superframe` bsf | `mov_muxer_select="… vp9_superframe_bsf …"`(configure:3910) |
| `vp8` decoder | `webp_decoder_select="vp8_decoder"`(configure:3313);webp 封面里的有损部分是 VP8 关键帧 |

三条都是 LGPL,体积极小(加起来 < 300 KB),保留。

## 版本差异 / 名字不存在(如实记录)

| 名字 | 情况 | 处理 |
| --- | --- | --- |
| `trim`(bsf) | FFmpeg 8.1.3 的 `libavcodec/bsf/` 下没有 `trim.c`,`bitstream_filters.c` 里也没有注册。`--enable-bsf=trim` 会被当成一个未知组件名**静默忽略**(不会报错,但 `config_components.h` 里不会出现 `CONFIG_TRIM_BSF`,也不会编译任何东西)。 | 从白名单删除,记录在此。需要按时间裁剪时用 `--ss`/`-t` 或应用层丢包。 |
| `--disable-postproc` | FFmpeg 8.0 移除了 libpostproc,**这个选项不存在**,而 8.1.3 的 configure 对未知 `--disable-xxx` 选项会直接 `die`(我们就是这么撞上的)。 | 从参数里删掉。 |
| `--disable-libxml2` / `--disable-opencl` | 这两个在 8.1.3 里只有 `--enable-` 形式(默认关),写 `--disable-` 会触发同样的 `die`。 | 删掉;它们本来就是关的。 |
| `aac_at` | 存在,且 `--enable-encoders=aac_at` + `--enable-audiotoolbox` 后确实编进了产物。 | 保留。 |

## 与许可相关的两个上游文件(F0 的意外发现)

`--disable-gpl` 不等于"没有 GPL 代码被编译":FFmpeg 8.1.3 里有 **两个没有被 `CONFIG_GPL`
守卫的 GPL 源文件**,而它们在 aarch64 上是无条件参与构建的:

| 文件 | 谁在编它 | 处理 |
| --- | --- | --- |
| `libavcodec/aarch64/ac3dsp_init_aarch64.c` + `libavcodec/aarch64/ac3dsp_neon.S` | `libavcodec/aarch64/Makefile` 的 `OBJS-/NEON-OBJS-$(CONFIG_AC3DSP)`,只要开 AC-3/E-AC-3 解码就会编 | 加 `ifeq ($(CONFIG_GPL),yes)` 守卫 + 在 `libavcodec/ac3dsp.c` 里把调用也限定在 GPL 构建。LGPL 构建退回 C 实现的 AC3 DSP。详见 README「对上游源码的补丁」。 |
| `libavutil/aarch64/crc.S` | `libavutil/aarch64/Makefile` 的 `ARMV8-OBJS += aarch64/crc.o`(无条件) | 加 `ifeq ($(CONFIG_GPL),yes)` 守卫 + configure 加 `--disable-arm-crc`(否则 `HAVE_ARM_CRC=1` 时 `crc.h` 的内联还会引用 `ff_crc32_aarch64`,链接会缺符号)。LGPL 构建走 `libavutil/crc.c` 的 C 实现。 |

`verify-license.sh` 的第 4 项检查就是干这个的:它用 `*.d` 依赖文件反查每个 `.o` 的源文件,
扫源码头里的许可标记;一旦有 GPL 源文件被编进去就**非零退出**。这两个文件就是被它抓出来的。

## F2-1 网络与 TLS(libmpv 播放远程地址所需)

| 项 | 开关 | 理由 | 许可 |
|---|---|---|---|
| 网络 | `--enable-network` | `http`/`https`/`tls` 协议的前提。F1 的 `--disable-network` 会让远程 URL 在 libmpv 里直接失败 | 随 FFmpeg(LGPL) |
| 协议 `http` `https` `tcp` `tls` | `--enable-protocol=...`(经 `LUX_PROTOCOLS`) | libmpv 的 `http-header-fields` 注入头与远程播放地址都走这些协议 | 随 FFmpeg(LGPL) |
| TLS 后端 | `--enable-securetransport` | 使用 Apple 系统 Security 框架的 SecureTransport,信任根是系统的,iOS 上无需随包 CA、无第三方库。代价:TLS 1.2 上限、Apple 标记为弃用 API。与 openssl/gnutls/mbedtls/libtls 在 configure 中互斥(`configure:4051`) | 随 FFmpeg(LGPL) + 系统框架 |

**未开启(留给后续判断)**

- `zlib`:仍 `--disable-zlib`。是否需要由 F2-3 的 libmpv 链接/运行结果决定;没有证据之前不开。
- `avdevice`:仍 `--disable-avdevice`。Homebrew 的 mpv.pc 把 libavdevice 列入 Requires.private,但那是 Homebrew 构建的特性集合,不能证明 mpv 0.41 在 MPVKit 式的最小配置下必须它。**UNVERIFIED**,由 F2-3 第一天用 mpv 的 meson feature 表确认。
- `libdav1d`:仍被 `ffmpeg-ios.conf` 禁止。AV1 首版使用 FFmpeg 原生解码器。
