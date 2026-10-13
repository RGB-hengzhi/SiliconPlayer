# SiliconPlayer 许可与版权声明

**SiliconPlayer 原创部分：Copyright © 2026 RGB-hengzhi (SiliconPlayer)。**

版权所有人已确认采用 **GNU General Public License version 3 or later**，项目声明标识为 **`GPL-3.0-or-later`**。完整 GPLv3 原文见 [LICENSE](LICENSE)；“or later”是项目授权声明，不是对 GNU 许可证原文的修改。

SiliconPlayer 原生界面使用 Swift / SwiftUI / AppKit 编写，集成 mpv、FFmpeg、libass、Rubber Band 及其他成熟组件。第三方代码与组件继续保留各自的版权、许可证及适用通知，不因项目整体 GPLv3 发行而把其版权改为 RGB-hengzhi，也不替换它们原有的 ISC / BSD / MIT / LGPL / GPL 等许可。

以下原 mpv API 头文件保持各自 **ISC** 许可及 mpv developers 原版权说明：

- `Sources/CMPV/include/mpv/client.h`
- `Sources/CMPV/include/mpv/render.h`
- `Sources/CMPV/include/mpv/render_gl.h`
- `Sources/MetalRenderBridge/pinned-mpv/include/mpv/client.h`
- `Sources/MetalRenderBridge/pinned-mpv/include/mpv/render.h`
- `Sources/MetalRenderBridge/pinned-mpv/include/mpv/render_mtl.h`

API 头文件的 ISC 许可不把链接的 mpv / FFmpeg / Rubber Band 运行库变成 ISC。播放组合按 GPLv3 兼容路线发行；准确组件版本、来源、补丁、构建脚本及原许可应与实际发行包一起核对。

遵循已有开源许可证的发行条件，不需要另行向上游申请同一 GPL 使用权或购买闭源替代商业许可；必须实际履行对应源码、许可证、版权与修改通知等义务。FFmpeg、Rubber Band 等上游的版权仍归各自作者，SiliconPlayer 不声称拥有它们。[GNU GPLv3](https://www.gnu.org/licenses/gpl-3.0.en.html)、[Rubber Band 官方许可](https://breakfastquay.com/rubberband/license.html)

公共二进制下载处应同时提供 **实际发行构建的完整对应源码**：原创应用源码归档、准确的第三方源码及本地补丁、构建与打包脚本、来源和校验清单。仅公开界面源码或上游首页链接不足以替代这些材料。发行入口：[SiliconPlayer Releases](https://github.com/RGB-hengzhi/SiliconPlayer/releases)。

本项目借鉴 IINA 的 Mac 原生交互，初始播放依赖来源为 IINA 官方发行包；没有将其完整界面或 Sparkle 更新组件复制进本应用。项目与 PotPlayer 官方无关联，也尚未覆盖其全部能力。

公共包若仅更新许可说明、来源文件及代码签名，应保留封存功能基线的测试归属，不把重新签名视为又完成一轮 170 项实际测试。ad-hoc 签名核验与 Apple 公证、App Store 发布许可是不同事项。

This software is based in part on the work of the Independent JPEG Group.

Portions of this software are copyright © 2026 The FreeType Project (https://freetype.org). All rights reserved.
