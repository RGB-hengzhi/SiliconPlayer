# 可复现的高分辨率测试媒体来源

`high-resolution.json` 与 `snapshots/` 是版本化的小型来源记录；约 1.18 GiB 的四份真实媒体保存在已忽略的 `Tests/Fixtures/HighResolution/`，不加入源码仓库或应用安装包。

在项目目录执行：

```sh
python3 scripts/download_test_media.py --list
python3 scripts/download_test_media.py --check
python3 scripts/download_test_media.py
```

下载需要先准备 `Vendor/tools/ffmpeg` 与 `ffprobe`，可运行 `scripts/bootstrap_media_tools.py`。脚本只下载、ZIP 解包和 `-c copy` 封装，不启动播放器，不缩放、补帧、循环或重新编码。已有媒体经过大小、SHA256 和 ffprobe 验证后跳过；`--only 文件名` 可只取得指定样片，`--output 目录` 可选择目的地。失败与取消保留现有目的文件。

BBB 为 H.264 High / 3840×2160 / 60 fps，来自 [Blender 官方下载页](https://peach.blender.org/download/)链接的下载目录。作者为 Blender Foundation（2008）与 Sunflower 作者 Janus Bager Kristensen（2013），依据[官方 CC-BY 3.0 说明](https://peach.blender.org/about/)保留署名及片尾。其原始 ZIP 和解包 MP4 都锁定大小与 SHA256。

Apple Developer [Streaming Examples](https://developer.apple.com/streaming/examples/)提供 4K23.976 的 HEVC Main10 SDR、HEVC PQ/BT.2020 HDR 与 AV1 10-bit SDR 预告片。本目录只记录官方来源及请求，素材仅用于本地测试，未确认开放再分发许可；不能随应用或源码分发。HDR10+ 名称来自官方 rendition，仍需另测动态元数据和真实 HDR 输出。

Apple 下载使用保存的完整 VOD 子清单，解析其中的原始 segment URL。整文件 SHA256 首选；没有再次远程下载验证容器字节稳定性，也不会猜测新的容器哈希。若 FFmpeg 封装元数据导致容器大小或哈希不同，默认要求每轨压缩 packet 指纹、codec/extradata、分辨率、位深、帧率、颜色、音轨与时长全部匹配，再在 `acquisition-report.json` 记录实际容器哈希。`--strict-container` 可要求全部媒体的容器字节与最初取得的版本完全相同。指纹算法与原始复制命令写在 JSON 中。

本批没有原生 HEVC 4K60 或 VP9 4K，不把已有 `testsrc2` 合成样片当作电影内容。仅凭下载和 ffprobe 成功不能证明播放器性能、音画同步、HDR 色彩准确性或长期稳定性。
