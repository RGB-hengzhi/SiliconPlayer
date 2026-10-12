# 依赖准备边界

播放集成通过 Sources/CMPV 绑定 libmpv，构建脚本从项目 Vendor/lib 读取固定 arm64 动态库与相应头文件。FFmpeg / FFprobe 工具使用 Vendor/tools 下的校验记录。公开仓库只保留小型元数据、许可证与脚本，二进制依赖须自行材料化并验证。

- 最初的播放依赖准备脚本为 scripts/bootstrap_mpv.py，来源为官方 IINA 发行包。最终本地 r3 使用 44 个固定版本的签名动态库，普通 bootstrap 不能保证重现最终包。
- 媒体工具脚本 scripts/bootstrap_media_tools.py 默认还准备 Whisper 与模型，目前没有 core-only 一键安装入口。
- core 打包模式只保留播放与 FFmpeg / FFprobe 工具；ASR、网页解析等可选内容不会随日常版本打包。
- 完整新机依赖准备、第三方对应源码和补丁归档是后续发布工作。当前不要将源码克隆描述为开箱即用的二进制重建链路。

保留的许可证见 [NOTICE](../NOTICE.md)。可选语音和网页工具的已有文本也被保留，不能据此推断它们已包含在 core 或完成验收。
