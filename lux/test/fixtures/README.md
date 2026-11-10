# lux/test/fixtures — 入库的测试资产

这里的文件**入库**(体积小、许可无争议),供 `lux/test/run.sh` 直接做解码实测。
运行时不下载、不依赖宿主编码器;`lux/.build/fixtures/` 只是运行期的工作副本。

| 文件 | 用途 | 大小 | sha256 |
| --- | --- | --- | --- |
| `lux-av1-fixture.mkv` | AV1 软解实测(`av1_probe`,run.sh 第 8 段) | 111580 B | `b506fa47ca778f0146668404eaaa673166b192afad56707b00c9b5967fb6c098` |

`SHA256SUMS` 是唯一校验源;`run.sh` 每次都会校验,不匹配直接 FAIL(防止夹具被误改)。

## lux-av1-fixture.mkv

- 容器:Matroska;视频:AV1(Main profile,8-bit 4:2:0),**320x240 / 25fps / 100 帧**,GOP 25。
- 内容来源:`ffmpeg` 的 `lavfi testsrc2` 合成测试图,无第三方素材,可自由分发。
- 编码器:SVT-AV1 4.2.0(`libsvtav1`,BSD-3-Clause);只用于离线造样片,不链接进任何产物。

### 重新生成

需要带 `libsvtav1` 的 ffmpeg(例如 Homebrew 的 `brew install ffmpeg`)。**不要**直接覆盖
正在使用的夹具:先写到 `.part`,校验/确认后再改名,失败就把 `.part` 删掉。之后同步
`SHA256SUMS` 与本文件的 sha256 列。

```sh
cd lux/test/fixtures
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x240:rate=25:duration=4" \
    -c:v libsvtav1 -preset 8 -crf 40 -pix_fmt yuv420p -g 25 \
    -f matroska lux-av1-fixture.mkv.part
ffprobe -hide_banner -loglevel error -count_frames \
    -show_entries stream=codec_name,width,height,pix_fmt,nb_read_frames \
    -of default=nw=1 lux-av1-fixture.mkv.part   # 期望:av1 / 320x240 / yuv420p / 100
mv lux-av1-fixture.mkv.part lux-av1-fixture.mkv
shasum -a 256 lux-av1-fixture.mkv            # 把新值写回 SHA256SUMS 和本文件
```

历史:该样片最初在 D4 的 AV1 实测任务里由宿主 ffmpeg 的 libsvtav1 现场合成
(见 `lux/.build/delegate/av1-fixture.json`),后来按评审意见改为入库资产,
避免 CI/开发机缺少 libsvtav1 时整套 `run.sh` 失败。
