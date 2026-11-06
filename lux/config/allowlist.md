# F0 白名单 — 每项为什么在名单上

本文件是 `lux/config/ffmpeg-ios.conf` 里那份白名单的说明书。**改配置必须同时改这里**。
组件名以 FFmpeg 8.1.3 的 `configure` 为准(`libavcodec/bitstream_filters.c`、
`libavformat/allformats.c`、`libavcodec/allcodecs.c` 里注册的名字)。

原则:

1. F0 只回答"能不能出一套 LGPL 的最小 iOS 构建",不追求功能完整;
2. 只开**播放本地文件 + 本地 remux(mkv → fMP4)**闭环里真正会被调用到的东西;
3. 任何 `--enable-gpl` / `--enable-nonfree` / 外部 GPL 编码库(x264/x265/fdk-aac/…)一律不开;
4. `--disable-everything` 之后只按本名单打开,名单之外的东西**一个都不开**。

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
| libx264 / libx265 / libfdk-aac / libxvid / libvidstab / libmp3lame / libvpx / libdav1d / libass / libfreetype | 外部库 + GPL/额外依赖。F0 不联网、不下载依赖,一个都不要。 |
| `libavfilter` | `--disable-avfilter`。jellyfin 补丁里的 GPL 滤镜文件正因为关了它才不会被编进去。 |
| `libswscale` | `--disable-swscale`。F0 不做像素格式转换;硬解输出 CVPixelBuffer,软解交给 mpv 的 GPU 链。 |
| `libavdevice` | `--disable-avdevice`。不做采集。 |
| `libpostproc` | FFmpeg 8.0 起已从源码树移除,没有这个库,也没有 `--disable-postproc` 选项。 |
| 网络协议 / TLS | `--disable-network`,F0 只读本地文件。 |
| `matroska` muxer | F0 的产物方向是 fMP4;写 mkv 用不到,不开。 |
| av1/vp9/prores 等解码器 | 名单外。以后要支持再加,加之前先看它的 `_select` 拉进来什么。 |

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
