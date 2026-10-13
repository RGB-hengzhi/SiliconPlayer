# 开发说明

当前公开仓库保存 Swift / SwiftUI / AppKit 界面、播放集成、测试与构建脚本。公开 Release 同时提供安装包、源码与开发文档；开发构建需要 Apple Silicon Mac、Apple Command Line Tools、Python 3 以及已材料化和校验的播放库与媒体工具。

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

因此，当前说明提供的是**受控依赖已就绪后的构建入口**，尚未承诺新克隆可以完全自动复现最终成品。公开安装包与对应源码在 [v0.6.1-core Release](https://github.com/RGB-hengzhi/SiliconPlayer/releases/tag/v0.6.1-core) 同页提供。

## 测试

日常版回归入口是 `scripts/run_core_acceptance.py`。它需要明确的应用、输出目录、私有设置、素材和进程所有权前置验证，实际参数由本轮准备与冻结记录提供。先使用脚本的 `--help` 查看接口，不应把修改后的源码或新编译应用标为已经通过旧结果。

模块测试与实际应用测试分别留证，普通界面操作也有单独结果。最终 r3 的测试范围、资源数据和产物校验见 [测试摘要](TESTING.md)。

## 第三方许可

成熟播放能力来自 mpv、FFmpeg、libass 及其依赖。初始许可证文本和来源记录已保存，并随本机成品保留；实际 44 库的对应源码、必要补丁、构建记录与完整许可证另在本 Release 的依赖源码包提供。原创应用代码已由版权所有人确认采用 GPL-3.0-or-later，第三方文件保留各自许可。第三方源码保留其原有许可证与版权信息，对应材料按实际发行库版本归档，并与公开安装包提供下载。本次采用 GPLv3 组合发行路线；未宣称获得 App Store 发布许可或完成 Apple 公证。

## GPL 公开发行材料

本项目原创部分采用 GPL-3.0-or-later，第三方文件保留原许可。公开 Release 同页提供应用与实际依赖对应源码、定制补丁、构建与打包控制材料。下载两个源码资产后先阅读其中 README / REBUILD，再准备受控依赖。记录式重放器已做语法与计划检查，尚未重跑从零全链构建；新工具链编译的结果需要重新验证。

公开安装包的许可资源注入、外层签名和 ZIP 往返校验控制脚本见 [repack_public_bundle.py](../scripts/repack_public_bundle.py)。该步骤不重新编译功能代码；其输出校验值与旧封存 ZIP 不同。完整应用源码资产另含原302构建输入和成品构建控制器。

## 0.6.1 日常版构建步骤

`scripts/build_app.sh` 的 core 输出是初始编译产物，仍使用已锁定的 IINA bootstrap 依赖。正式成品须继续执行对应源码包中的构建控制步骤：复制实际 44 个兼容运行库与 FFmpeg / FFprobe，逐个核对 `Resources/PublicLicenses/runtime-to-source.json`，写入真实来源记录，再签名和核验完整应用。不能把初始产物或普通 bootstrap 当作已经通过实际运行库验收的发行版。

新版本的 GPL 原文和 134 项法律资源纳入构建输入校验；缺失资源时构建会停止。成品构建与运行测试分别记录，旧版本通过的测试不计作新版的结果。
