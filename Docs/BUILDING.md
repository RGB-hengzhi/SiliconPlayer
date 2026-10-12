# 开发说明

当前公开仓库保存 Swift / SwiftUI / AppKit 界面、播放集成、测试与构建脚本。本轮发布内容为源码与开发文档；开发构建需要 Apple Silicon Mac、Apple Command Line Tools、Python 3 以及已材料化和校验的播放库与媒体工具。

## 构建日常版

在已准备好依赖的项目根目录运行：

```bash
SILICONPLAYER_BUILD_PROFILE=core bash scripts/build_app.sh
```

默认输出为 `dist/SiliconPlayer-core-development.app`。构建缓存默认放在内置盘 APFS；源码可以放在外置盘。需要自定义路径时使用 `SILICONPLAYER_BUILD_CACHE` 与 `SILICONPLAYER_OUTPUT_APP`。已有命名候选与发布包受脚本保护，不应覆盖。

`core` 只打包普通播放与 FFmpeg / FFprobe 工具，不包含 ASR 模型、语音辅助进程、Deno 或 yt-dlp。它在缺少依赖时直接报错，不会自动下载。默认的 `full` 开发配置继续保留，但不是当前日常成品的验收范围。

## 依赖与复现边界

本地构建使用 `Vendor/manifest.json` 与 `Vendor/tools/manifest.json`；公开仓库以 [依赖说明](DEPENDENCIES.md) 记录其准备方式与边界，未上传含本机路径的原始清单。应根据固定来源、架构和 SHA256 校验输入，不以电脑全局安装的库代替受控依赖。

项目最初通过 `scripts/bootstrap_mpv.py` 获取官方 IINA 发行包中的 arm64 libmpv 依赖集合。最终成品还包含本项目开发过程中固定的播放动态库版本与构建来源记录，不能用一次普通 bootstrap 就宣称复现最终发行字节。

`scripts/bootstrap_media_tools.py` 是完整开发依赖准备脚本，默认会同时准备 Whisper 和语音模型；当前没有独立的 core 依赖一键下载流程。仅为构建日常版时，不应把该命令当作轻量依赖安装入口。

因此，当前说明提供的是**受控依赖已就绪后的构建入口**，尚未承诺新克隆可以完全自动复现最终成品。当前仓库不提供公共二进制下载。

## 测试

日常版回归入口是 `scripts/run_core_acceptance.py`。它需要明确的应用、输出目录、私有设置、素材和进程所有权前置验证，实际参数由本轮准备与冻结记录提供。先使用脚本的 `--help` 查看接口，不应把修改后的源码或新编译应用标为已经通过旧结果。

模块测试与实际应用测试分别留证，普通界面操作也有单独结果。最终 r3 的测试范围、资源数据和产物校验见 [测试摘要](TESTING.md)。

## 第三方许可

成熟播放能力来自 mpv、FFmpeg、libass 及其依赖。初始许可证文本和来源记录已保存，并随本机成品保留；它们不是完整的逐库许可审计或对应源码归档。项目整体许可证尚未指定，公开展示源码本身不授予新的许可。第三方源码保留其原有许可证与版权信息，公共二进制发行前需要完成逐库许可、完整对应源码与构建补丁归档。当前没有宣称整体 GPL 兼容、已获 App Store 发布许可或已完成 Apple 公证。
