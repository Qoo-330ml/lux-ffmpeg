# jellyfin-ffmpeg 补丁分诊(106 个)

`debian/patches/` 是 jellyfin-ffmpeg `v8.1.3-2` 的 Debian 补丁系列(服务端构建用,`--target-os=linux`)。
本仓库的产物是 **iOS/macOS 客户端库**,所以这些补丁要按"会不会被编译、iOS 上能不能用、会不会破坏
LGPL 边界"三条标准重新分诊。本文记录结论;已经落地的部分见 `lux/README.md` §6.2。

## 判定标准

1. **会被编译吗**:补丁改的组件在 `lux/config/ffmpeg-ios.conf` 白名单里吗?平台开关(`cuda`/`qsv`/
   `vaapi`/`d3d11`/`metal`/`coreimage`…)打开了吗?`--disable-programs` 下 `fftools/` 一律不算。
2. **iOS 上可用吗**:依赖的框架(iOS 没有 VAAPI/QSV/D3D11/OpenCL 桌面版)和 API 是否存在。
3. **许可/ABI 风险**:是否引入 GPL 代码、是否改公开头文件/结构体、是否只动内部实现。

## 总量

| 类别 | 数量 | 处置 |
| --- | --- | --- |
| 硬件转码(CUDA/QSV/VAAPI/D3D11/OpenCL/Vulkan/AMF/RK3588/MF) | 59 | 不移植 |
| Apple VideoToolbox | 15 | 移植 4 个解码类,其余见下 |
| fftools(CLI) | 11 | 不移植(`--disable-programs`) |
| 容器/BSF/流媒体(segment/id3v2/dovi→HLS/ass/trim) | 7 | 暂不移植 |
| 音频(AC-4/DTS:X/libopus) | 3 | 暂不移植 |
| 杂项/通用修复 | 11 | 移植 2 个(0090、0088 待定) |

## 第一档:已移植(`lux/patches/`)

jellyfin 0048、0049、0055、0057(解码)、0090(通用)、0062(AudioToolbox)。逐条说明见
`lux/README.md` §6.2。验证:`lux/test/run.sh` 里的 `patch_probe`(0001/0005/0006)和
`hevc12_probe`(0004,断言 12-bit 4:2:0 的 `get_format` 候选里出现 VideoToolbox)。

其中 0057 做了实质改造:原补丁只给 `YUV422P12`/`YUV444P12` 加 VT 候选,漏掉了最常见的
Main12 4:2:0(`YUV420P12`)。lux 版把它并进 `YUV444P10`/`YUV420P12`/`YUV444P12` 共用的 case 块,
并去掉重复候选;在本机 macOS 上实测 12-bit 4:2:0 已经走 `videotoolbox_vld` 硬解。

## 第二档:可做,但要先定产品口径

| 补丁 | 内容 | 前置条件 |
| --- | --- | --- |
| 0088 | matroska 里 `image/webp` 封面 | 要真解出封面还得把 `webp`/`png`/`mjpeg` 解码器加进白名单 |
| 0087 | DTS:X / DTS-HD HRA profile 识别 | 往 `defs.h` 加公开 profile 枚举;收益只是信息显示正确 |
| 0027 | Dolby Vision side data 传给 muxer | 只保留 `movenc`/`matroskaenc` 部分;`hlsenc`/`mpegtsenc` 是服务端 HLS 链,删掉 |

## 第三档:F2(libmpv / avfilter)再评估

| 补丁 | 依赖 | 说明 |
| --- | --- | --- |
| 0043 | avfilter + videotoolbox | `scale_vt` 加 `format` 选项(NV12↔P010),转 SDR 时清 HDR 元数据 |
| 0046 | metal + corevideo | `tonemap_videotoolbox`(Metal shader) |
| 0056 | metal + corevideo | `bwdif`/`yadif_videotoolbox` 去隔行 |
| 0044 | metal + corevideo + coreimage | `overlay_videotoolbox` |
| 0045 | coreimage | `transpose_vt` 改成 CoreImage 实现 |
| 0053 | avfilter + swscale | `tonemapx` 的 aarch64 NEON(10k 行;只有不用 GPU tonemap 时才值得) |

改造点:

- `--enable-avfilter --enable-swscale --enable-metal --enable-coreimage`;
- **Metal 交叉编译**:`configure` 默认 `--metalcc="xcrun -sdk macosx metal"`,iOS 目标必须换成
  `xcrun -sdk iphoneos metal` / `xcrun -sdk iphonesimulator metal`(`metallib` 同理),否则
  `test_cmd $metalcc -v` 会直接 disable metal;
- 新增 `.m`/`.metal` 源文件要进 `verify-license.sh` 的 `.d` 源审计;
- 体积与首帧延迟要重新量。

## 不移植:看起来能用但实际有害的三个

| 补丁 | 不移植的理由 |
| --- | --- |
| 0073 | 把"没有解码出帧"的 `AVERROR_EXTERNAL` 改成 `return 0`,frame 已被 unref → 客户端会拿到"成功但空"的帧,比报错更难查。服务端为了让流不断才这么做。 |
| 0104 | 本质是 **DXVA2** 帧线程竞争修复;`videotoolbox.c` 那处只是把回调改名成 `hwaccel_priv_post_process`。对 iOS 零收益,还要动内部结构体 `FrameDecodeData`。 |
| 0063 | 删掉 `kCVPixelBufferOpenGLESCompatibilityKey`,走 GLES 零拷贝的渲染路径可能拿不到 IOSurface-backed texture。等 lux-client 的渲染后端确定后再谈。 |

其余:59 个硬件转码补丁所依赖的 configure 开关在 darwin 上恒为 0,打上也是死代码;11 个
fftools 补丁在 `--disable-programs` 下不编译;segment/id3v2/ass/trim/HLS-dovi 属于服务端封装链;
AC-4、libopus 编码器不在白名单(AC-4 还涉及专利)。

## 附着新补丁的步骤

```sh
# 1. 从 debian/patches 取出原补丁,允许它一次性漂移(-C1),之后重生成
git apply -C1 debian/patches/00XX-*.patch
# 2. 按需要改造(扩格式、剪掉未编译平台的分支),只动该补丁涉及的文件
# 3. 生成到 lux/patches/,头部写清来源/改造点/许可判断
git diff -- <files> > lux/patches/00NN-<name>.patch
git checkout -- <files>
# 4. 登记 + 全量校验 + 重建
$EDITOR lux/config/patches.txt
./lux/build/apply-patches.sh check
./lux/build/build-ffmpeg.sh macos-arm64 && ./lux/build/verify-license.sh
```

补丁头部的固定格式:

```
# lux patch — 由 debian/patches/<原补丁> 刷新而来(上游 FFmpeg 8.1.3 树,上下文已重生成)
# 改造点:...
# 许可:只改 LGPL 组件,不引入 GPL/nonfree 代码。
```
