# lux-ffmpeg 白名单 — 每项为什么在名单上

本文件是 `lux/config/ffmpeg-ios.conf` 里那份白名单的说明书。**改配置必须同时改这里**。
组件名以 FFmpeg 8.1.3 的 `configure` 为准(`libavcodec/bitstream_filters.c`、
`libavformat/allformats.c`、`libavcodec/allcodecs.c` 里注册的名字)。

原则:

1. F0 先回答"能不能出一套 LGPL 的最小 iOS 构建";P1 D4 再按 MPVKit 1.0.0 的能力基线补齐原生 LGPL 组件;
2. 只开**播放本地文件 + 本地 remux(mkv → fMP4)**以及 P1 播放链实际会调用到的东西;
3. 任何 `--enable-gpl` / `--enable-nonfree` / 外部 GPL 编码库(x264/x265/fdk-aac/…)一律不开;
4. `--disable-everything` 之后只按本名单打开,名单之外的东西**一个都不开**。

## P1 D4 原生 LGPL 补齐(2026-11-10)

本节按 `capabilities-mpvkit.json` 与 P1 开始时的白名单做差集。D4 的决定是**以 MPVKit 1.0.0 的能力为基线,
默认全部保留**,但本步只加入 FFmpeg 自带、无需新增第三方库的组件。分类口径:

- **a) 原生 LGPL**:当前 FFmpeg 8.1.3 自带,本步加入白名单。
- **b) 需要外部库**:留到 D4 后续步骤,逐条登记在本节 b) 表。
- **c) 有意不要 / 当前版本不可用**:不加,保留理由与替代路径。

最终计数(dav1d 纳入后):demuxer 40、protocol 36、bsf 49、parser 66、decoder 198;相对 P1 起点
分别新增 37、31、42、60、181,合计 351 个组件(dav1d 见「外部依赖:dav1d」一节)。P1 第 5 步再加入 38 个原生滤镜,`LUX_FILTERS`
到 45 项(见「滤镜(P1 第5步)」)。`ffmpeg-ios.conf` 是唯一真相,本文件的表格是逐项理由。

`mlp` 与 `webp` 不在 MPVKit 的导出符号里,但它们**确实存在**于 FFmpeg 8.1.3:
`configure:3194` 有 `mlp_decoder_select="mlp_parser"`, `configure:3313` 有
`webp_decoder_select="vp8_decoder"`;`libavcodec/allcodecs.c` 分别注册 `ff_mlp_decoder` 与 `ff_webp_decoder`。
其中 `mlp` 同时有 decoder 与 parser,`webp` 是 decoder 并会显式带入 `vp8` decoder。两项本来就在
P1 白名单里,因此不是 D4 新增项,也不属于 MPVKit 缺口。

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

### a) 本步新增:外部依赖 dav1d(AV1 软解,2026-11-10 b 类转 a 类)

所有者决定纳入 dav1d。它不属于 FFmpeg 自带代码,因此单列一节,但按 D4 的口径已从 b 类移出。

| 项 | 内容 |
| --- | --- |
| 组件 | `libdav1d` decoder(`--enable-libdav1d` + `--enable-decoder=libdav1d`) |
| 版本 | **1.5.4**(上游最新稳定版;`lux/config/deps.lock` 锁定) |
| 许可 | **BSD-2-Clause**,以上游源码包内 `COPYING` 为准(`Copyright © 2018-2026, VideoLAN and dav1d authors`;两条条款 + 免责声明)。与 LGPL-2.1+ 兼容,不改变本构建的 LGPL 结论。 |
| 来源 | `https://downloads.videolan.org/pub/videolan/dav1d/1.5.4/dav1d-1.5.4.tar.xz`;sha256 `686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5`,与上游随包的 `.sha256` 文件一致。 |
| 形态 | 静态库 `libdav1d.a`,由 `lux/build/build-deps.sh dav1d` 装到 `lux/.build/deps/<target>/install`,链接期并入 `libavcodec`(FFmpeg 的 .a/.dylib 内);**不单独做 `Libdav1d.framework`**(计划 §4.2 允许两种形式,取依赖面更小的一种)。 |
| 理由 | D4 决定「以 MPVKit 基线的编解码覆盖为准,默认全保留」;AV1 是当前片源的主力编码之一,dav1d 是 FFmpeg 之外最成熟的 AV1 软解实现,解码速度与 10-bit/HDR 支持都优于 FFmpeg 原生 `av1` 解码器。原生 `av1` 保留作回退。 |
| 许可检查 | `verify-license.sh` 的禁用符号表不再匹配 `dav1d`(`dav1d_*` / `libdav1d`);其余外部库/GPL 规则不变。 |

构建细节:`build-deps.sh` 用 `deps-target.sh` 生成的 meson cross 文件,`-Denable_tools=false
-Denable_tests=false -Denable_examples=false -Denable_docs=false -Dxxhash_muxer=disabled`,
只出 `libdav1d.a` 与头文件,不构建 CLI/测试,也不探测宿主 xxhash。

验证(2026-11-10):

- 三个 target 的 `libdav1d.a` 都构建成功,`lipo -info` 均为单架构 arm64;`dav1d.pc` 的 Version 为 1.5.4。
- 三个切片的 `build-ffmpeg.sh` 均成功,`config_components.h` 都是 `CONFIG_LIBDAV1D_DECODER 1`
  (原生 `CONFIG_AV1_DECODER 1` 同时保留);`config.h` 的 `CONFIG_GPL`/`CONFIG_NONFREE`/`CONFIG_VERSION3` 均为 0。
- 三个切片的 `verify-license.sh` 均 0 failures、1 warning(唯一 warning 是 Metal Toolchain 未安装)。
- `lux/test/run.sh`: `RESULT: PASS`。运行时枚举 AV1 解码器得到 `libdav1d` 与 `av1` 两个名字,
  说明解码器确实注册进了 libavcodec。
- **AV1 解码未实测**:仓库与 `lux/.build/fixtures` 里没有 AV1 样片(`run.sh` 只合成 H.264/AAC 与
  12-bit HEVC),按任务书要求不临时造样片,因此本步只验证到「编解码器注册 + 构建/许可」层面。
- 链接约定:`libavcodec.a` 里的 `libdav1d` 解码器引用 `dav1d_*` 符号,任何链接本构建静态库的程序
  都要在 `libavcodec.a` 之后追加 `lux/.build/deps/<target>/install/lib/libdav1d.a`
  (`lux/test/run.sh` 已按此修改);动态 framework 构建时由 configure 的 EXTRALIBS 自动带上。

### b) 需要外部库,留待 D4 后续步骤

| 组件 | 外部依赖 / 原因 | 后续处理 |
| --- | --- | --- |
| `dash` demuxer | `configure:3868` 要求 `libxml2` | 后续单独评估 libxml2(连同许可/体积)。 |
| `libuavs3d` decoder | `configure:3820` 要求 `libuavs3d` | 需要外部 AVS3 解码库,单独评估。 |
| `tscc` decoder | `configure:3290` select `inflate_wrapper`,后者 `deps="zlib"` | 当前 `--disable-zlib`;需与 zlib 一起评估。它虽然出现在 `--list-decoders`,实际 configure 会因依赖不满足而关闭。 |
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

### D4 验证口径(2026-11-10,macOS arm64)

- `verify-license.sh macos-arm64`:0 failures、1 warning;唯一 warning 是未安装 Metal Toolchain
  (`CONFIG_METAL=0`),因此 4 个 Metal 滤镜未启用,不是许可失败。
- `config.h`: `CONFIG_GPL 0`、`CONFIG_NONFREE 0`、`CONFIG_VERSION3 0`;并确认 `CONFIG_LGPLV3 0`。
- `lux/test/run.sh`: `RESULT: PASS`。

### a) 本步新增:parser

下表每个名字都是一个独立启用的 parser。`dvd_nav` 是唯一未加入的基线 parser(见 c 类)。

| 组件 | 理由 |
| --- | --- |
| `av1` `avs2` `avs3` `cavsvideo` `dirac` `dnxhd` `dnxuc` `evc` `ffv1` `h261` `h263` `hdr` `ipu` `jpeg2000` `jpegxl` `jpegxs` `lcevc` `mjpeg` `mpeg4video` `mpegvideo` `prores` `prores_raw` `rv34` `vc1` `vp3` `vp8` `vp9` `vvc` `webp` | 视频 elementary stream 的帧边界/参数解析,用于 MPV 对 MPEG-4/VC-1/RV/ProRes/AV1/VP8/VP9/VVC/图像序列等格式的探测与解码。 |
| `apv` `bmp` `gif` `png` `pnm` `qoi` `xbm` `xwd` | 图像/封面类 parser;用于附件和图像 demuxer 的 codecpar 探测。 |
| `cri` `dpx` `dvaudio` | MPVKit 基线中的专业/广播格式 parser;FFmpeg 原生,保留基线覆盖。 |
| `aac_latm` `adx` `amr` `cook` `dca` `dolby_e` `flac` `ftr` `g723_1` `g729` `gsm` `mlp` `mpegaudio` `sbc` `sipr` `tak` `xma` | 音频帧边界与 codecpar 解析。`mlp` 原本由 `truehd` 自动 select,D4 已显式启用;它也是 MPVKit 符号表未列出但本仓库确认存在的 parser。 |
| `dvbsub` `dvdsub` `misc4` | 字幕/辅助流 parser;保留 MPVKit 的 DVB/DVD 字幕能力,但不启用 DVD 导航解析。 |

### a) 本步新增:decoder

本步新增 180 个 decoder;每个名字都在下面某一行的列表里独立启用。`libuavs3d` 与 `tscc` 是两个未加入的
基线 decoder(见 b 类);`libdav1d` 已在 D4 后续步骤纳入(见「外部依赖:dav1d」);`init_cabac`/`init_range`/
`vpx_init_range` 不是 8.1.3 可启用的 decoder(见 c 类)。
`mlp` 与 `webp` 已在 P1 原白名单中,故不重复列出。

| 组件 | 理由 |
| --- | --- |
| `aac_at` `ac3_at` `adpcm_ima_qt_at` `alac_at` `amr_nb_at` `eac3_at` `gsm_ms_at` `ilbc_at` `mp1_at` `mp2_at` `mp3_at` `pcm_alaw_at` `pcm_mulaw_at` `qdm2_at` `qdmc_at` | Apple AudioToolbox 系统解码器,已在 `--enable-audiotoolbox` 下;不引入第三方库。用于系统硬件/低功耗音频路径。 |
| `pcm_alaw` `pcm_bluray` `pcm_dvd` `pcm_f16le` `pcm_f24le` `pcm_f32be` `pcm_f32le` `pcm_f64be` `pcm_f64le` `pcm_lxf` `pcm_mulaw` `pcm_s16be` `pcm_s16be_planar` `pcm_s16le` `pcm_s16le_planar` `pcm_s24be` `pcm_s24daud` `pcm_s24le` `pcm_s24le_planar` `pcm_s32be` `pcm_s32le` `pcm_s32le_planar` `pcm_s64be` `pcm_s64le` `pcm_s8` `pcm_s8_planar` `pcm_sga` `pcm_u16be` `pcm_u16le` `pcm_u24be` `pcm_u24le` `pcm_u32be` `pcm_u32le` `pcm_u8` `pcm_vidc` | MPVKit 基线的 PCM 全格式覆盖,含 Blu-ray/DVD PCM、视频容器里的 PCM 与浮点 PCM。全部是 FFmpeg 原生实现。 |
| `adpcm_4xm` `adpcm_adx` `adpcm_afc` `adpcm_agm` `adpcm_aica` `adpcm_argo` `adpcm_ct` `adpcm_dtk` `adpcm_ea` `adpcm_ea_maxis_xa` `adpcm_ea_r1` `adpcm_ea_r2` `adpcm_ea_r3` `adpcm_ea_xas` `adpcm_g722` `adpcm_g726` `adpcm_g726le` `adpcm_ima_acorn` `adpcm_ima_alp` `adpcm_ima_amv` `adpcm_ima_apc` `adpcm_ima_apm` `adpcm_ima_cunning` `adpcm_ima_dat4` `adpcm_ima_dk3` `adpcm_ima_dk4` `adpcm_ima_ea_eacs` `adpcm_ima_ea_sead` `adpcm_ima_iss` `adpcm_ima_moflex` `adpcm_ima_mtf` `adpcm_ima_oki` `adpcm_ima_qt` `adpcm_ima_rad` `adpcm_ima_smjpeg` `adpcm_ima_ssi` `adpcm_ima_wav` `adpcm_ima_ws` `adpcm_ima_xbox` `adpcm_ms` `adpcm_mtaf` `adpcm_psx` `adpcm_sanyo` `adpcm_sbpro_2` `adpcm_sbpro_3` `adpcm_sbpro_4` `adpcm_swf` `adpcm_thp` `adpcm_thp_le` `adpcm_vima` `adpcm_xa` `adpcm_xmd` `adpcm_yamaha` `adpcm_zork` | MPVKit 基线的游戏/相机/广播 ADPCM 族。主要出现在 AVI、MOV、MKV 的老片源与游戏录像;FFmpeg 原生,无外部库。 |
| `mp1` `mp1float` `mp2` `mp2float` `mp3` `mp3adu` `mp3adufloat` `mp3float` `mp3on4` `mp3on4float` | MP1/MP2/MP3 及其浮点/ADU/MP3on4 变体。覆盖老旧音频与 MP4 中的 MP3 轨道。 |
| `av1` `dxv` `ffv1` `ffvhuff` `flv` `h263` `h263i` `h263p` `hap` `huffyuv` `indeo5` `ipu` `media100` `mjpegb` `mpeg1video` `mpeg2video` `mpeg4` `mpegvideo` `msmpeg4v1` `msmpeg4v2` `msmpeg4v3` `mts2` `prores` `rv10` `rv20` `rv30` `rv40` `snow` `sonic` `svq3` `vc1` `vp6` `vp6a` `vp6f` `vp7` `vp8` `vp9` `wmv1` `wmv2` `wmv3` | MPVKit 基线的视频解码覆盖:AV1 原生软解、Motion JPEG/ProRes/VC-1/WMV/RV/VP6-9/MPEG-1/2/4 等。D4 决定默认保留;AV1 同时有原生 `av1` 与 `libdav1d` 两条软解路径,`libuavs3d`/`tscc` 见 b 类。 |
| `aac_fixed` `aac_latm` `ac3_fixed` | AAC/AC-3 的定点与 LATM 变体;与主 decoder 共享 DSP,用于低功耗与广播流。 |
| `alac` `amrnb` `amrwb` `ape` `cook` `dolby_e` `tta` `wmalossless` `wmapro` `wmav1` `wmav2` `wmavoice` `xma1` `xma2` | MPVKit 基线的无损/语音/WMA/XMA 音频族,覆盖 ALAC、APE、RealAudio Cook、Dolby E、TTA、WMA 与 Xbox XMA。 |
| `ccaption` `dvbsub` `dvdsub` `movtext` `mpl2` `srt` `ssa` `xsub` | MPVKit 基线的字幕解码:CEA-608、DVB/DVD 字幕、mov_text、MPL2、SubRip/SSA、XSUB。渲染仍由外部 libass 负责。 |
| `txd` | MPVKit 基线的 RenderWare TXD 纹理 decoder;原生实现,用于老游戏/视频纹理封面。 |

下面是 F0 立项时的最小集合与逐项理由,保留作历史依据。P1 D4 之后最终名单以上方 D4 表和
`ffmpeg-ios.conf` 为准(当前计数见本节开头);这些旧小节若与 D4 表冲突,以后两者为准。

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

## protocol(F0 起点)

| 组件 | 为什么在名单上 |
| --- | --- |
| `file` | 只读本地文件。F0 起点只有它;P1 F2-1 已加入 `http`/`https`/`tcp`/`tls`,P1 D4 再扩展到上方 protocol 表。 |

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
| libx264 / libx265 / libfdk-aac / libxvid / libvidstab / libmp3lame / libvpx / libass / libfreetype | 外部库/额外依赖;当前构建不下载、不引入,需要时单独评估许可与体积。 |
| `libuavs3d` / `tscc` | D4 b 类:分别需要 libuavs3d,或 zlib(`tscc` 经 `inflate_wrapper`);留到后续步骤。 |
| `zlib`(全局) | 当前 `--disable-zlib`;D4 只有 `tscc` 需要它,不为一个 decoder 打开全局依赖。 |
| `dash` demuxer | 需要 libxml2,留到后续步骤;现有 HLS/`webm_dash_manifest` 不受影响。 |
| `ffrtmpcrypt` / `rtmpe` / `rtmpte` / `dtls` | 需要 gcrypt/gmp/OpenSSL/mbedTLS 等加密后端;基础 RTMP/RTMPS/RTMPT 仍可用。 |
| `libavdevice` | `--disable-avdevice`。不做采集。 |
| `libpostproc` | FFmpeg 8.0 起已从源码树移除,没有这个库,也没有 `--disable-postproc` 选项。 |
| `matroska` muxer | F0 的产物方向是 fMP4;写 mkv 用不到,不开。 |
| `data` demuxer / `dvd_nav` parser | 有意不要:前者是调试数据通道,后者是 DVD 导航;理由见 D4 c 类。 |

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

## 滤镜(P1 第5步,2026-11-10)

P1 D4 只补了 demuxer/protocol/decoder/parser/bsf,没有动 filter。本步以 `capabilities-mpvkit.json`
的 59 项 filters 与 P1 起点名单做差集:已在名单里的 5 项(`format` `hwdownload` `hwupload` `null`
`scale`)与 4 个核心内建端点不重复处理,剩余 50 项分成三类:

- **a) 原生、无外部依赖(38 项)**:本步加入 `LUX_FILTERS`。
- **b) 需要外部库或 GPU 工具链(12 项)**:本步不加,逐条登记。
- **c) 核心内建端点(4 项)**:不属于 configure 白名单,只做说明。

`LUX_FILTERS` 最终为 7(原有)+ 38 = **45 项**;`LUX_FILTERS_METAL` 与补丁集未改动。
下表「类别」一列取 **必须** / **可选** / **有意不要** 三档;本步 A 类都是必须或可选,
没有「有意不要」的项(A 类既然要补,就不存在主动放弃的条目)。

### a) 本步新增:音频 af(13)

| 组件 | 类别 | 理由 |
| --- | --- | --- |
| `aformat` | 必须 | 统一采样格式/声道布局/采样率,是 af 链与 AO 之间的协商点;mpv 的 `--af=format` 与内部重配都走它。 |
| `amix` | 可选 | 多路音频混音(双音轨同时出声、评论轨、karaoke),MPVKit 基线能力。 |
| `anull` | 可选 | 空音频滤镜,直通与基准对照(与 vf `null` 对应)。 |
| `aresample` | 必须 | 重采样、声道布局转换与时间基重整;输出设备采样率不匹配、变速与 seek 后的音频都靠它。 |
| `areverse` | 可选 | 片段倒放,短视频/鬼畜类片源。 |
| `asetrate` | 可选 | 直接改采样率实现变速/变调,与 `atempo` 互补。 |
| `atempo` | 必须 | 变速不变调,mpv `speed` 控制的音频侧实现。 |
| `atrim` | 可选 | 按时间裁剪音频,配合 `trim`/`setpts` 做片段处理。 |
| `equalizer` | 可选 | 参量均衡(多段 IIR),音乐播放的 EQ 能力。 |
| `firequalizer` | 可选 | FIR 线性相位均衡,需要陡峭滤波曲线时使用。 |
| `pan` | 必须 | 声道映射/下混(5.1→stereo)与单声道化,mpv `--audio-channels` 的底层。 |
| `superequalizer` | 可选 | 18 段图示均衡,MPVKit 基线里的另一套 EQ。 |
| `volume` | 必须 | 增益/静音,mpv 音量控制的基础。 |

### a) 本步新增:视频 vf(25)

| 组件 | 类别 | 理由 |
| --- | --- | --- |
| `bwdif` | 可选 | 另一种去隔行算法(BWDIF),画质优于 yadif 的可选路径。 |
| `estdif` | 可选 | 边缘导向去隔行,低角度边缘锯齿更少。 |
| `fps` | 可选 | 帧率转换/CFR 化,用于需要固定输出帧率的片源。 |
| `hflip` | 可选 | 水平翻转(镜像),与 `transpose` 的镜像模式互补。 |
| `hwmap` | 可选 | 在硬件帧上下文之间映射(VT ↔ 其它 hwframes),避免下载到 CPU 再上传。 |
| `idet` | 可选 | 隔行/场序探测,诊断并辅助决定是否去隔行。 |
| `lenscorrection` | 可选 | 镜头畸变校正(桶形/枕形),运动相机片源。 |
| `lut` | 可选 | 通用逐像素 LUT(表达式),颜色映射的底座。 |
| `lut1d` | 可选 | 一维 LUT,按通道做 gamma/曲线调整。 |
| `lut2` | 可选 | 双输入 LUT,两路画面的逐像素组合。 |
| `lut3d` | 可选 | 3D LUT(`.cube`),校色/风格化的标准路径。 |
| `lutrgb` | 可选 | 按 RGB 通道的 LUT,表达式形式。 |
| `lutyuv` | 可选 | 按 YUV 通道的 LUT,表达式形式。 |
| `negate` | 可选 | 反色/负片,依赖 `lut`(已同组启用)。 |
| `overlay` | 必须 | 字幕/水印/画中画叠加;mpv 的 `--vf=overlay` 与 OSD 合成路径。 |
| `palettegen` | 可选 | GIF/索引色输出的调色板生成,与 `paletteuse` 配对。 |
| `paletteuse` | 可选 | 用 `palettegen` 的调色板做索引色输出。 |
| `rotate` | 可选 | 任意角度旋转(表达式),补充 `transpose` 的 90° 整数倍。 |
| `scale2ref` | 可选 | 以第二路为参照缩放,画中画/水印对齐。 |
| `setpts` | 必须 | 重写 PTS;变速、`trim`、`fps` 之后的时基修正都依赖它。 |
| `transpose` | 必须 | 90° 旋转/翻转,mpv `--video-rotate` 的软件实现。 |
| `trim` | 可选 | 按时间裁剪视频,配合 `setpts` 做片段处理。 |
| `vflip` | 可选 | 垂直翻转(上下镜像)。 |
| `w3fdif` | 可选 | W3C 去隔行算法,另一种画质取向。 |
| `yadif` | 必须 | mpv 默认去隔行器(`--deinterlace` 的 yadif 路径)。 |

### b) 需要外部库 / GPU 工具链,本步不加(12)

| 组件 | 外部依赖 / 原因 | 后续处理 |
| --- | --- | --- |
| `ass` | `configure:4089` 要求 `libass` | 字幕渲染;播放器侧已由 libass 负责,是否内置到 FFmpeg 单独评估。 |
| `subtitles` | `configure:4220` 要求 `avformat avcodec` + `libass` | 把字幕烧进视频帧;同上,依赖 libass。 |
| `libplacebo` | `configure:4155` 要求 `libplacebo` + `vulkan` | GPU 色调映射/缩放,与现有 Metal/VideoToolbox 路径重叠,后续评估。 |
| `blend_vulkan` | `configure:4095` 要求 `vulkan` + `spirv_library`(shaderc) | Vulkan 计算滤镜;当前 `--disable-vulkan`,GPU 路径由 Metal/VT 承担。 |
| `chromaber_vulkan` | `configure:4103` 同上 | 色差模拟;Vulkan 工具链。 |
| `flip_vulkan` | `configure:4133` 同上 | Vulkan 翻转。 |
| `gblur_vulkan` | `configure:4142` 同上 | Vulkan 高斯模糊。 |
| `hflip_vulkan` | `configure:4143` 同上 | Vulkan 水平翻转。 |
| `nlmeans_vulkan` | `configure:4167` 同上 | Vulkan 非局部均值降噪。 |
| `overlay_vulkan` | `configure:4182` 同上 | Vulkan 叠加。 |
| `vflip_vulkan` | `configure:4236` 同上 | Vulkan 垂直翻转。 |
| `xfade_vulkan` | `configure:4250` 同上 | Vulkan 转场。 |

### c) 核心内建端点(4,不加)

| 端点 | 说明 |
| --- | --- |
| `asrc:abuffer` / `asink:abuffer` | 音频滤镜图的输入/输出端点,由 libavfilter 核心无条件注册(见 `configure` 的 `print_enabled_components`,filter_list 固定追加 4 个 buffer 端点),没有 `CONFIG_*_FILTER` 开关。 |
| `vsrc:buffer` / `vsink:buffer` | 视频滤镜图的输入/输出端点,同上。 |

它们不是 `--enable-filter=` 能打开的名字,因此不写入 `LUX_FILTERS`,也不参与 45 项的计数。

### 本步验证口径(2026-11-10)

- `configure --list-filters` 中 A 类 38 项全部存在(另 5 项原有滤镜也在);`verify-license.sh` 的
  filter 对账为 45 项全部生效,且没有「额外启用(configure 自动 select)」警告。
- `macos-arm64`、`ios-arm64`、`ios-sim-arm64` 三切片:`verify-license.sh` = 0 failures、1 warning
  (仅 Metal Toolchain 未安装,`CONFIG_METAL=0`)。
- 体积:`libavfilter.a` 相对 76944df 的基线(315208 / 312136 / 315296 字节)增至
  925800 / 907072 / 925816 字节(macos-arm64 / ios-arm64 / ios-sim-arm64),即 +193.7% / +190.6% / +193.6%;
  增量远超 +10%,是本步新增 38 个滤镜代码与静态表的预期代价,不是阻塞项。

## configure 自动 select:历史与口径

P1 D4 之前,`mlp` parser、`vp9_superframe` bsf、`vp8` decoder 会由 `_select` 自动带入,
`verify-license.sh` 会打 `[warn]` 方便对账。D4 已把这三项显式写入白名单;`av1`/`flac`/`mpegaudio`
等 parser 也改为显式启用。当前构建不再产生「额外启用(configure 自动 select)」警告。

若后续改动再次产生自动 select,必须逐项登记来源;它们也必须是 LGPL 组件,否则回退该组。

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
- `libdav1d`:已不再禁止。P1 D4 后续步骤按所有者决定纳入(静态并入 libavcodec),见「外部依赖:dav1d」;
  AV1 同时保留 FFmpeg 原生 `av1` 解码器作为回退。
