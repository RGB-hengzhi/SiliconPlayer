# 依赖准备边界

播放集成通过 Sources/CMPV 绑定 libmpv，构建脚本从项目 Vendor/lib 读取固定 arm64 动态库与相应头文件。FFmpeg / FFprobe 工具使用 Vendor/tools 下的校验记录。公开仓库只保留小型元数据、许可证与脚本，二进制依赖须自行材料化并验证。

- 最初的播放依赖准备脚本为 scripts/bootstrap_mpv.py，来源为官方 IINA 发行包。最终本地 r3 使用 44 个固定版本的签名动态库，普通 bootstrap 不能保证重现最终包。
- 媒体工具脚本 scripts/bootstrap_media_tools.py 默认还准备 Whisper 与模型，目前没有 core-only 一键安装入口。
- core 打包模式只保留播放与 FFmpeg / FFprobe 工具；ASR、网页解析等可选内容不会随日常版本打包。
- 本 Release 已提供实际 44 个运行库及 FFmpeg / FFprobe 的对应源码、定制补丁、构建材料和逐库校验清单。源码包内提供重建步骤；本轮未重新完成干净机的全链构建，因此普通源码克隆仍需先准备依赖。

保留的许可证见 [NOTICE](../NOTICE.md)。可选语音和网页工具的已有文本也被保留，不能据此推断它们已包含在 core 或完成验收。

## 0.6.0 日常公开版

[依赖对应源码包](https://github.com/RGB-hengzhi/SiliconPlayer/releases/download/v0.6.0-core/SiliconPlayer-0.6.0-core-dependency-source.zip)记录实际 r3 的 mpv v0.41.0-dev-g97179bce7-dirty、libplacebo 7.365.0 等版本、本地补丁、全部 44 个运行库的二进制 SHA256 和来源。

`Vendor/licenses/SCOPE.txt` 是初始 IINA bootstrap 的历史准备状态，随原始源码保留以记录构建输入；它不是当前公开发行包的许可状态。公开包在应用内及 ZIP 外层提供 GPLv3、实际依赖原版权通知与对应源码入口，项目原创部分采用 GPL-3.0-or-later。

## 0.6.1 复用边界

0.6.1 core build 14 r2 重新编译了实际应用源码，并独立完成本次 152 项自动检查。其 44 个播放库与两个媒体工具保留 0.6.0 公共包的完整字节，因此继续引用上方已有依赖源码资产（SHA256 `c866e7f402b08371b79a3a02e7206f3be0bbeb07ac8da3b6e1c863b5a21a7c7d`），无需重复上传同一依赖包。新的 [应用源码](https://github.com/RGB-hengzhi/SiliconPlayer/releases/download/v0.6.1-core/SiliconPlayer-0.6.1-core-application-source.zip) 与 [校验清单](https://github.com/RGB-hengzhi/SiliconPlayer/releases/download/v0.6.1-core/SHA256SUMS.txt) 随本次 Release 提供。
