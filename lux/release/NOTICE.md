# 草稿 — 待法务确认

> 本文件由 `lux/build/make-license-bundle.sh` 生成,只整理源码包、构建产物和链接关系中的事实,不是法律意见,也不对许可适用作结论。标注“待法务确认”的条目需 D5/G4 法务审阅。

## 1. 生成范围与源码身份

- 清单范围:FFmpeg 六库 + libmpv 栈(Libmpv/Libplacebo/Libfribidi/Libuchardet)及其非系统依赖
- 生成脚本:`lux/build/make-license-bundle.sh`
- 仓库:lux-ffmpeg
- 源码 HEAD(最近一次触及源码的提交,排除本清单生成物):`e8c09615cf18bb3c8c3ae4bf8809f2c97fd20e71`
- 分支:`p1-allowlist`
- 提交时间:`2026-11-10T15:12:43+08:00`
- 提交标题:lux: neutralize libmpv embedded install paths
- 补丁集:`lux/config/patches.txt` 13 条,sha256 `9f532c1b8144fb212e5bc3bb6c3bfe5f193ca97ada07c64a951bc84de28a056e`
- apply-patches digest:`45aeb1df8deddd7abd5d011e32379428536dffb61fb9d63702ed26a224839c52`
- 构建配置:`lux/config/ffmpeg-ios.conf`,sha256 `8a563b8b79d4b70c0dc541b3cee863b2211dac4365c786ca36d552633a8f4c2e`
- 路径占位符:`$BUILD` = `lux/.build`;`$DEPS` = `lux/.build/deps`;`$REPO` = 仓库根目录。

## 2. FFmpeg 六库

| 目标 | 库 | 静态库 | Framework 切片 | 产物许可(草稿) | 状态 |
| --- | --- | --- | --- | --- | --- |
| macos-arm64 | libavcodec | lux/.build/macos-arm64/install/lib/libavcodec.a | lux/.build/xcframeworks/Libavcodec.xcframework/macos-arm64/Libavcodec.framework/Libavcodec | LGPL-2.1-or-later | 已定位(事实记录) |
| macos-arm64 | libavformat | lux/.build/macos-arm64/install/lib/libavformat.a | lux/.build/xcframeworks/Libavformat.xcframework/macos-arm64/Libavformat.framework/Libavformat | LGPL-2.1-or-later | 已定位(事实记录) |
| macos-arm64 | libavfilter | lux/.build/macos-arm64/install/lib/libavfilter.a | lux/.build/xcframeworks/Libavfilter.xcframework/macos-arm64/Libavfilter.framework/Libavfilter | LGPL-2.1-or-later | 已定位(事实记录) |
| macos-arm64 | libswscale | lux/.build/macos-arm64/install/lib/libswscale.a | lux/.build/xcframeworks/Libswscale.xcframework/macos-arm64/Libswscale.framework/Libswscale | LGPL-2.1-or-later | 已定位(事实记录) |
| macos-arm64 | libswresample | lux/.build/macos-arm64/install/lib/libswresample.a | lux/.build/xcframeworks/Libswresample.xcframework/macos-arm64/Libswresample.framework/Libswresample | LGPL-2.1-or-later | 已定位(事实记录) |
| macos-arm64 | libavutil | lux/.build/macos-arm64/install/lib/libavutil.a | lux/.build/xcframeworks/Libavutil.xcframework/macos-arm64/Libavutil.framework/Libavutil | LGPL-2.1-or-later | 已定位(事实记录) |
| ios-arm64 | libavcodec | lux/.build/ios-arm64/install/lib/libavcodec.a | lux/.build/xcframeworks/Libavcodec.xcframework/ios-arm64/Libavcodec.framework/Libavcodec | LGPL-2.1-or-later | 已定位(事实记录) |
| ios-arm64 | libavformat | lux/.build/ios-arm64/install/lib/libavformat.a | lux/.build/xcframeworks/Libavformat.xcframework/ios-arm64/Libavformat.framework/Libavformat | LGPL-2.1-or-later | 已定位(事实记录) |
| ios-arm64 | libavfilter | lux/.build/ios-arm64/install/lib/libavfilter.a | lux/.build/xcframeworks/Libavfilter.xcframework/ios-arm64/Libavfilter.framework/Libavfilter | LGPL-2.1-or-later | 已定位(事实记录) |
| ios-arm64 | libswscale | lux/.build/ios-arm64/install/lib/libswscale.a | lux/.build/xcframeworks/Libswscale.xcframework/ios-arm64/Libswscale.framework/Libswscale | LGPL-2.1-or-later | 已定位(事实记录) |
| ios-arm64 | libswresample | lux/.build/ios-arm64/install/lib/libswresample.a | lux/.build/xcframeworks/Libswresample.xcframework/ios-arm64/Libswresample.framework/Libswresample | LGPL-2.1-or-later | 已定位(事实记录) |
| ios-arm64 | libavutil | lux/.build/ios-arm64/install/lib/libavutil.a | lux/.build/xcframeworks/Libavutil.xcframework/ios-arm64/Libavutil.framework/Libavutil | LGPL-2.1-or-later | 已定位(事实记录) |
| ios-sim-arm64 | libavcodec | lux/.build/ios-sim-arm64/install/lib/libavcodec.a | lux/.build/xcframeworks/Libavcodec.xcframework/ios-arm64-simulator/Libavcodec.framework/Libavcodec | LGPL-2.1-or-later | 已定位(事实记录) |
| ios-sim-arm64 | libavformat | lux/.build/ios-sim-arm64/install/lib/libavformat.a | lux/.build/xcframeworks/Libavformat.xcframework/ios-arm64-simulator/Libavformat.framework/Libavformat | LGPL-2.1-or-later | 已定位(事实记录) |
| ios-sim-arm64 | libavfilter | lux/.build/ios-sim-arm64/install/lib/libavfilter.a | lux/.build/xcframeworks/Libavfilter.xcframework/ios-arm64-simulator/Libavfilter.framework/Libavfilter | LGPL-2.1-or-later | 已定位(事实记录) |
| ios-sim-arm64 | libswscale | lux/.build/ios-sim-arm64/install/lib/libswscale.a | lux/.build/xcframeworks/Libswscale.xcframework/ios-arm64-simulator/Libswscale.framework/Libswscale | LGPL-2.1-or-later | 已定位(事实记录) |
| ios-sim-arm64 | libswresample | lux/.build/ios-sim-arm64/install/lib/libswresample.a | lux/.build/xcframeworks/Libswresample.xcframework/ios-arm64-simulator/Libswresample.framework/Libswresample | LGPL-2.1-or-later | 已定位(事实记录) |
| ios-sim-arm64 | libavutil | lux/.build/ios-sim-arm64/install/lib/libavutil.a | lux/.build/xcframeworks/Libavutil.xcframework/ios-arm64-simulator/Libavutil.framework/Libavutil | LGPL-2.1-or-later | 已定位(事实记录) |

- `macos-arm64`:BUILD-INFO 记录 `LGPL version 2.1 or later`;version3=false;--disable-gpl=true;--disable-nonfree=true。
- `ios-arm64`:BUILD-INFO 记录 `LGPL version 2.1 or later`;version3=false;--disable-gpl=true;--disable-nonfree=true。
- `ios-sim-arm64`:BUILD-INFO 记录 `LGPL version 2.1 or later`;version3=false;--disable-gpl=true;--disable-nonfree=true。

## 3. libmpv 栈 Framework

| 目标 | Framework | 二进制来源 | 许可(源码,草稿) | 状态 |
| --- | --- | --- | --- | --- |
| macos-arm64 | Libmpv | lux/.build/mpv-frameworks/macos-arm64/Libmpv.framework/Libmpv | 待法务确认 | 待法务确认 |
| macos-arm64 | Libplacebo | lux/.build/mpv-frameworks/macos-arm64/Libplacebo.framework/Libplacebo | LGPL-2.1-or-later | 待法务确认 |
| macos-arm64 | Libfribidi | lux/.build/mpv-frameworks/macos-arm64/Libfribidi.framework/Libfribidi | LGPL-2.1-or-later | 已定位(事实记录) |
| macos-arm64 | Libuchardet | lux/.build/mpv-frameworks/macos-arm64/Libuchardet.framework/Libuchardet | MPL-1.1 或 GPL-2.0-or-later 或 LGPL-2.1-or-later(待法务确认) | 待法务确认 |
| ios-arm64 | Libmpv | lux/.build/mpv-frameworks/ios-arm64/Libmpv.framework/Libmpv | 待法务确认 | 待法务确认 |
| ios-arm64 | Libplacebo | lux/.build/mpv-frameworks/ios-arm64/Libplacebo.framework/Libplacebo | LGPL-2.1-or-later | 待法务确认 |
| ios-arm64 | Libfribidi | lux/.build/mpv-frameworks/ios-arm64/Libfribidi.framework/Libfribidi | LGPL-2.1-or-later | 已定位(事实记录) |
| ios-arm64 | Libuchardet | lux/.build/mpv-frameworks/ios-arm64/Libuchardet.framework/Libuchardet | MPL-1.1 或 GPL-2.0-or-later 或 LGPL-2.1-or-later(待法务确认) | 待法务确认 |
| ios-sim-arm64 | Libmpv | lux/.build/mpv-frameworks/ios-sim-arm64/Libmpv.framework/Libmpv | 待法务确认 | 待法务确认 |
| ios-sim-arm64 | Libplacebo | lux/.build/mpv-frameworks/ios-sim-arm64/Libplacebo.framework/Libplacebo | LGPL-2.1-or-later | 待法务确认 |
| ios-sim-arm64 | Libfribidi | lux/.build/mpv-frameworks/ios-sim-arm64/Libfribidi.framework/Libfribidi | LGPL-2.1-or-later | 已定位(事实记录) |
| ios-sim-arm64 | Libuchardet | lux/.build/mpv-frameworks/ios-sim-arm64/Libuchardet.framework/Libuchardet | MPL-1.1 或 GPL-2.0-or-later 或 LGPL-2.1-or-later(待法务确认) | 待法务确认 |

## 4. Libmpv 栈的直接非系统依赖(otool -L)

### macos-arm64

| Framework | 非系统依赖 | deps.lock 来源 |
| --- | --- | --- |
| Libmpv | `@rpath/Libfribidi.framework/Libfribidi` | fribidi |
| Libmpv | `@rpath/Libavcodec.framework/Libavcodec` | ffmpeg |
| Libmpv | `@rpath/Libavfilter.framework/Libavfilter` | ffmpeg |
| Libmpv | `@rpath/Libavformat.framework/Libavformat` | ffmpeg |
| Libmpv | `@rpath/Libavutil.framework/Libavutil` | ffmpeg |
| Libmpv | `@rpath/Libplacebo.framework/Libplacebo` | libplacebo |
| Libmpv | `@rpath/Libswresample.framework/Libswresample` | ffmpeg |
| Libmpv | `@rpath/Libswscale.framework/Libswscale` | ffmpeg |
| Libmpv | `@rpath/Libuchardet.framework/Libuchardet` | uchardet |

- `Libplacebo`:otool -L 只有系统库,没有非系统动态依赖。
- `Libfribidi`:otool -L 只有系统库,没有非系统动态依赖。
- `Libuchardet`:otool -L 只有系统库,没有非系统动态依赖。

### ios-arm64

| Framework | 非系统依赖 | deps.lock 来源 |
| --- | --- | --- |
| Libmpv | `@rpath/Libfribidi.framework/Libfribidi` | fribidi |
| Libmpv | `@rpath/Libavcodec.framework/Libavcodec` | ffmpeg |
| Libmpv | `@rpath/Libavfilter.framework/Libavfilter` | ffmpeg |
| Libmpv | `@rpath/Libavformat.framework/Libavformat` | ffmpeg |
| Libmpv | `@rpath/Libavutil.framework/Libavutil` | ffmpeg |
| Libmpv | `@rpath/Libplacebo.framework/Libplacebo` | libplacebo |
| Libmpv | `@rpath/Libswresample.framework/Libswresample` | ffmpeg |
| Libmpv | `@rpath/Libswscale.framework/Libswscale` | ffmpeg |
| Libmpv | `@rpath/Libuchardet.framework/Libuchardet` | uchardet |

- `Libplacebo`:otool -L 只有系统库,没有非系统动态依赖。
- `Libfribidi`:otool -L 只有系统库,没有非系统动态依赖。
- `Libuchardet`:otool -L 只有系统库,没有非系统动态依赖。

### ios-sim-arm64

| Framework | 非系统依赖 | deps.lock 来源 |
| --- | --- | --- |
| Libmpv | `@rpath/Libfribidi.framework/Libfribidi` | fribidi |
| Libmpv | `@rpath/Libavcodec.framework/Libavcodec` | ffmpeg |
| Libmpv | `@rpath/Libavfilter.framework/Libavfilter` | ffmpeg |
| Libmpv | `@rpath/Libavformat.framework/Libavformat` | ffmpeg |
| Libmpv | `@rpath/Libavutil.framework/Libavutil` | ffmpeg |
| Libmpv | `@rpath/Libplacebo.framework/Libplacebo` | libplacebo |
| Libmpv | `@rpath/Libswresample.framework/Libswresample` | ffmpeg |
| Libmpv | `@rpath/Libswscale.framework/Libswscale` | ffmpeg |
| Libmpv | `@rpath/Libuchardet.framework/Libuchardet` | uchardet |

- `Libplacebo`:otool -L 只有系统库,没有非系统动态依赖。
- `Libfribidi`:otool -L 只有系统库,没有非系统动态依赖。
- `Libuchardet`:otool -L 只有系统库,没有非系统动态依赖。

otool -L 不显示静态并入的组件。以下为依据构建脚本/符号表整理的静态或构建期归属:

| Framework | 组件 | 类型 | 依据 |
| --- | --- | --- | --- |
| Libmpv | libass | static | libass.a 静态链接;nm -gU 可查到 _ass_* 符号 |
| Libmpv | freetype | static | freetype.a 静态链接;nm -gU 可查到 _FT_* 符号 |
| Libmpv | harfbuzz | static | harfbuzz.a 静态链接;nm -gU 可查到 _hb_* 符号 |
| Libmpv | libunibreak | static | libunibreak.a 静态链接;nm -gU 可查到 _init_linebreak 等符号 |
| Libplacebo | lcms2 | static | lcms2.a 静态链接;nm -gU 可查到 _cms* 符号 |
| Libplacebo | moltenvk | static | vulkan.pc 提供 -lMoltenVK;nm -gU 可查到 _vk* 符号 |
| Libplacebo | shaderc | static | shaderc.pc 提供 -lshaderc_combined;二进制内有 shaderc_util 符号 |
| Libplacebo | spirv-cross | static-transitive | MoltenVK ExternalDependencies 的 libSPIRVCross.a |
| Libplacebo | spirv-tools | static-transitive | shaderc_combined 的 SPIRV-Tools 部分 |
| Libplacebo | spirv-tools-mvk | static-transitive | MoltenVK ExternalDependencies 的 libSPIRVTools.a |
| Libplacebo | glslang | static-transitive | shaderc_combined 的 glslang 部分 |
| Libplacebo | spirv-headers | build-time | shaderc 构建期头文件 |
| Libplacebo | spirv-headers-mvk | build-time | MoltenVK/SPIRV-Tools 构建期头文件 |
| Libplacebo | vulkan-headers | build-time | libplacebo/MoltenVK 构建期头文件 |
| Libplacebo | volk | build-time | MoltenVK 构建期 Vulkan 加载器源码/头文件 |
| Libplacebo | cereal | build-time | MoltenVK 构建期头文件 |
| Libplacebo | fast_float | header-only | libplacebo 构建期头文件 |

## 5. 依赖与许可清单(deps.lock)

deps.lock 共 21 项;sha256 校验结果与许可文件如下。

| # | 依赖 | 版本 | 许可(草稿) | 状态 | 链接方式 | sha256 | 许可文件 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | freetype | 2.15.0 | FTL 或 GPL-2.0(二选一,待法务确认) | 待法务确认 | Libmpv 静态 | 一致 | `licenses/freetype/LICENSE.TXT`, `licenses/freetype/docs/FTL.TXT`, `licenses/freetype/docs/GPLv2.TXT` |
| 2 | harfbuzz | 15.0.0 | MIT | 已定位(事实记录) | Libmpv 静态 | 一致 | `licenses/harfbuzz/COPYING`, `licenses/harfbuzz/src/ms-use/COPYING` |
| 3 | fribidi | 1.0.17 | LGPL-2.1-or-later | 已定位(事实记录) | Libmpv 动态、Libfribidi 本体 | 一致 | `licenses/fribidi/COPYING` |
| 4 | libunibreak | 8.0 | Zlib | 已定位(事实记录) | Libmpv 静态 | 一致 | `licenses/libunibreak/LICENCE` |
| 5 | lcms2 | 2.19.1 | MIT | 已定位(事实记录) | Libplacebo 静态 | 一致 | `licenses/lcms2/LICENSE` |
| 6 | uchardet | 0.0.8 | MPL-1.1 或 GPL-2.0-or-later 或 LGPL-2.1-or-later(待法务确认) | 待法务确认 | Libmpv 动态、Libuchardet 本体 | 一致 | `licenses/uchardet/COPYING` |
| 7 | libass | 0.17.5 | ISC | 已定位(事实记录) | Libmpv 静态 | 一致 | `licenses/libass/COPYING` |
| 8 | mpv | 0.41.0 | 待法务确认 | 待法务确认 | Libmpv 本体 | 一致 | `licenses/mpv/Copyright`, `licenses/mpv/LICENSE.GPL`, `licenses/mpv/LICENSE.LGPL` |
| 9 | libplacebo | 7.360.1 | LGPL-2.1-or-later | 已定位(事实记录) | Libmpv 动态、Libplacebo 本体 | 一致 | `licenses/libplacebo/LICENSE` |
| 10 | shaderc | 2025.5 | Apache-2.0 | 已定位(事实记录) | Libplacebo 静态 | 一致 | `licenses/shaderc/LICENSE` |
| 11 | glslang | 7a47e2531cb334982b2a2dd8513dca0a3de4373d | BSD-3-Clause / BSD-2-Clause / MIT / Apache-2.0 / GPL-3.0-with-bison-exception(按文件,待法务确认) | 待法务确认 | Libplacebo 静态(传递) | 一致 | `licenses/glslang/LICENSE.txt` |
| 12 | spirv-tools | 262bdab48146c937467f826699a40da0fdfc0f1a | Apache-2.0 | 已定位(事实记录) | Libplacebo 静态(传递) | 一致 | `licenses/spirv-tools/LICENSE` |
| 13 | spirv-headers | b824a462d4256d720bebb40e78b9eb8f78bbb305 | MIT(部分文档 CC-BY-4.0,待法务确认) | 待法务确认 | 构建期/头文件 | 一致 | `licenses/spirv-headers/LICENSE`, `licenses/spirv-headers/LICENSES/CC-BY-4.0.txt`, `licenses/spirv-headers/LICENSES/MIT.txt` |
| 14 | moltenvk | 1.4.2 | Apache-2.0 | 已定位(事实记录) | Libplacebo 静态 | 一致 | `licenses/moltenvk/LICENSE` |
| 15 | vulkan-headers | e3b1eec08173d6b825cd3ac88c885a63b621504a | Apache-2.0 或 MIT(按文件) | 已定位(事实记录) | 构建期/头文件 | 一致 | `licenses/vulkan-headers/LICENSE.md`, `licenses/vulkan-headers/LICENSES/Apache-2.0.txt`, `licenses/vulkan-headers/LICENSES/MIT.txt` |
| 16 | spirv-cross | 6c09849fe88c48eaed08413aa022aaa136a3a057 | Apache-2.0(部分文件 MIT / Khronos Free Use / CC-BY-4.0,待法务确认) | 待法务确认 | Libplacebo 静态(传递) | 一致 | `licenses/spirv-cross/LICENSE`, `licenses/spirv-cross/LICENSES/Apache-2.0.txt`, `licenses/spirv-cross/LICENSES/CC-BY-4.0.txt` 等 5 份 |
| 17 | spirv-tools-mvk | 0d6fd73ca73830ccab5fa1f00ed5ed40124e2c55 | Apache-2.0 | 已定位(事实记录) | Libplacebo 静态(传递) | 一致 | `licenses/spirv-tools-mvk/LICENSE` |
| 18 | spirv-headers-mvk | 29981f65241605e08b0ede4cfeb999fe3b723c6a | MIT(部分文件 Apache-2.0 / 文档 CC-BY-4.0,待法务确认) | 待法务确认 | 构建期/头文件 | 一致 | `licenses/spirv-headers-mvk/LICENSE`, `licenses/spirv-headers-mvk/LICENSES/CC-BY-4.0.txt`, `licenses/spirv-headers-mvk/LICENSES/MIT.txt` |
| 19 | volk | 776893306c5d3b22b6185b5d4a258b81d94572bf | MIT | 已定位(事实记录) | 构建期/头文件 | 一致 | `licenses/volk/LICENSE.md` |
| 20 | cereal | a56bad8bbb770ee266e930c95d37fff2a5be7fea | BSD-3-Clause(含 zlib 许可的 external 组件) | 已定位(事实记录) | 构建期/头文件 | 一致 | `licenses/cereal/LICENSE`, `licenses/cereal/include/cereal/external/LICENSE` |
| 21 | fast_float | 8.0.2 | MIT 或 Apache-2.0 或 BSL-1.0(三选一,待法务确认) | 待法务确认 | 头文件 | 一致 | `licenses/fast_float/LICENSE-APACHE`, `licenses/fast_float/LICENSE-BOOST`, `licenses/fast_float/LICENSE-MIT` |

## 6. ⚠ GPL/nonfree 需复核

本节按“清单中出现 GPL 文本、GPL 选项或 GPL 默认许可”列出条目并单独标记;是否构成 GPL/nonfree 许可适用,待法务确认。

- <span style="color:red">⚠ GPL/nonfree 需复核</span> — **FFmpeg**:源码树含 `COPYING.GPLv2` / `COPYING.GPLv3`;三个切片均带 `--disable-gpl` / `--disable-nonfree`;iOS 两切片另有 `--enable-version3`。产物许可见第 2 节,待法务确认。
- <span style="color:red">⚠ GPL/nonfree 需复核</span> — **freetype**:源码 LICENSE.TXT 明示 FTL 与 GPL-2.0 二选一;docs/FTL.TXT 与 docs/GPLv2.TXT 均已复制。
- <span style="color:red">⚠ GPL/nonfree 需复核</span> — **uchardet**:COPYING 同时含 MPL-1.1、GPL-2.0、LGPL-2.1 文本;README 明示三选一;lux/build/build-deps.sh 注释写作 LGPL-2.1+,与源码表述不一致。
- <span style="color:red">⚠ GPL/nonfree 需复核</span> — **mpv**:Copyright 明示默认 GPL-2.0+;构建使用 -Dgpl=false;同一文件说明该开关本身不构成 LGPL 授权。
- <span style="color:red">⚠ GPL/nonfree 需复核</span> — **glslang**:LICENSE.txt 按文件列出 3-Clause BSD、2-Clause BSD、MIT、Apache-2.0,并含 “GPL 3 with special bison exception” 一节;未逐文件核对适用范围。
- <span style="color:red">⚠ GPL/nonfree 需复核</span> — **传递关系**:`Libmpv` 静态并入 freetype(FTL/GPL-2.0 二选一);`Libplacebo` 静态并入 glslang(含 GPL-3.0-with-bison-exception 一节)。静态归属见第 4 节,是否适用待法务确认。

## 7. 缺失与待确认

### 缺失

无缺失的源码包、许可文件或 framework 二进制。

### 待法务确认

| 组件 | 许可(草稿) | 说明 |
| --- | --- | --- |
| Libmpv | 待法务确认 | 静态并入含 GPL 文本/选项的组件:freetype |
| Libplacebo | LGPL-2.1-or-later | 静态并入含 GPL 文本/选项的组件:glslang |
| freetype | FTL 或 GPL-2.0(二选一,待法务确认) | 源码 LICENSE.TXT 明示 FTL 与 GPL-2.0 二选一;docs/FTL.TXT 与 docs/GPLv2.TXT 均已复制。 |
| uchardet | MPL-1.1 或 GPL-2.0-or-later 或 LGPL-2.1-or-later(待法务确认) | COPYING 同时含 MPL-1.1、GPL-2.0、LGPL-2.1 文本;README 明示三选一;lux/build/build-deps.sh 注释写作 LGPL-2.1+,与源码表述不一致。 |
| mpv | 待法务确认 | Copyright 明示默认 GPL-2.0+;构建使用 -Dgpl=false;同一文件说明该开关本身不构成 LGPL 授权。 |
| glslang | BSD-3-Clause / BSD-2-Clause / MIT / Apache-2.0 / GPL-3.0-with-bison-exception(按文件,待法务确认) | LICENSE.txt 按文件列出 3-Clause BSD、2-Clause BSD、MIT、Apache-2.0,并含 “GPL 3 with special bison exception” 一节;未逐文件核对适用范围。 |
| spirv-headers | MIT(部分文档 CC-BY-4.0,待法务确认) | LICENSE 按文件列出 MIT;tools/jsoncpp 为 MIT;部分 .md 文档为 CC-BY-4.0。 |
| spirv-cross | Apache-2.0(部分文件 MIT / Khronos Free Use / CC-BY-4.0,待法务确认) | LICENSE 为 Apache-2.0;LICENSES/ 另有 MIT、Khronos Free Use 与 CC-BY-4.0 文本。 |
| spirv-headers-mvk | MIT(部分文件 Apache-2.0 / 文档 CC-BY-4.0,待法务确认) | LICENSE 按文件列出 MIT;LICENSES/ 另有 Apache-2.0;部分文档为 CC-BY-4.0。 |
| fast_float | MIT 或 Apache-2.0 或 BSL-1.0(三选一,待法务确认) | LICENSE-APACHE、LICENSE-MIT、LICENSE-BOOST 三份并存;适用选择待法务确认。 |

### 其它异常

无。

## 8. 许可文件索引

| 组件 | 文件 |
| --- | --- |
| freetype | `licenses/freetype/LICENSE.TXT` |
| freetype | `licenses/freetype/docs/FTL.TXT` |
| freetype | `licenses/freetype/docs/GPLv2.TXT` |
| harfbuzz | `licenses/harfbuzz/COPYING` |
| harfbuzz | `licenses/harfbuzz/src/ms-use/COPYING` |
| fribidi | `licenses/fribidi/COPYING` |
| libunibreak | `licenses/libunibreak/LICENCE` |
| lcms2 | `licenses/lcms2/LICENSE` |
| uchardet | `licenses/uchardet/COPYING` |
| libass | `licenses/libass/COPYING` |
| mpv | `licenses/mpv/Copyright` |
| mpv | `licenses/mpv/LICENSE.GPL` |
| mpv | `licenses/mpv/LICENSE.LGPL` |
| libplacebo | `licenses/libplacebo/LICENSE` |
| shaderc | `licenses/shaderc/LICENSE` |
| glslang | `licenses/glslang/LICENSE.txt` |
| spirv-tools | `licenses/spirv-tools/LICENSE` |
| spirv-headers | `licenses/spirv-headers/LICENSE` |
| spirv-headers | `licenses/spirv-headers/LICENSES/CC-BY-4.0.txt` |
| spirv-headers | `licenses/spirv-headers/LICENSES/MIT.txt` |
| moltenvk | `licenses/moltenvk/LICENSE` |
| vulkan-headers | `licenses/vulkan-headers/LICENSE.md` |
| vulkan-headers | `licenses/vulkan-headers/LICENSES/Apache-2.0.txt` |
| vulkan-headers | `licenses/vulkan-headers/LICENSES/MIT.txt` |
| spirv-cross | `licenses/spirv-cross/LICENSE` |
| spirv-cross | `licenses/spirv-cross/LICENSES/Apache-2.0.txt` |
| spirv-cross | `licenses/spirv-cross/LICENSES/CC-BY-4.0.txt` |
| spirv-cross | `licenses/spirv-cross/LICENSES/LicenseRef-KhronosFreeUse.txt` |
| spirv-cross | `licenses/spirv-cross/LICENSES/MIT.txt` |
| spirv-tools-mvk | `licenses/spirv-tools-mvk/LICENSE` |
| spirv-headers-mvk | `licenses/spirv-headers-mvk/LICENSE` |
| spirv-headers-mvk | `licenses/spirv-headers-mvk/LICENSES/CC-BY-4.0.txt` |
| spirv-headers-mvk | `licenses/spirv-headers-mvk/LICENSES/MIT.txt` |
| volk | `licenses/volk/LICENSE.md` |
| cereal | `licenses/cereal/LICENSE` |
| cereal | `licenses/cereal/include/cereal/external/LICENSE` |
| fast_float | `licenses/fast_float/LICENSE-APACHE` |
| fast_float | `licenses/fast_float/LICENSE-BOOST` |
| fast_float | `licenses/fast_float/LICENSE-MIT` |
| ffmpeg | `licenses/ffmpeg/COPYING.LGPLv2.1` |
| ffmpeg | `licenses/ffmpeg/COPYING.LGPLv3` |
| ffmpeg | `licenses/ffmpeg/COPYING.GPLv2` |
| ffmpeg | `licenses/ffmpeg/COPYING.GPLv3` |
| ffmpeg | `licenses/ffmpeg/LICENSE.md` |

## 9. 复现

```sh
./lux/build/make-license-bundle.sh
# 只处理一个切片:
./lux/build/make-license-bundle.sh --target macos-arm64
```

脚本会重建 `lux/release/licenses/`、`lux/release/source-manifest.json` 与 `lux/release/NOTICE.md`;不修改源码、配置或已有构建脚本。

