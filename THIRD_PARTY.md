# 第三方组件与对应源码

SiliconPlayer 原创部分采用 `GPL-3.0-or-later`。此文件介绍主要组件和许可边界；完整许可证及版权通知仍以各组件源码中的原文为准。完整逐组件版本/哈希/源码映射由对应源码清单提供，参见 [依赖与对应源码说明](Docs/DEPENDENCIES.md)；不能用本概要替代实际 44 库的清点。

| 组件 | 使用与许可说明 | 官方来源 |
| --- | --- | --- |
| mpv / libmpv | 播放引擎；默认 GPLv2-or-later，本项目实际兼容构建的源码及补丁必须随对应源码提供 | [mpv](https://github.com/mpv-player/mpv)、[v0.41.0 Copyright](https://github.com/mpv-player/mpv/blob/v0.41.0/Copyright) |
| mpv API 头文件 | 六个接口头文件保留原 ISC 许可和 mpv developers 版权，详见 NOTICE | [mpv API](https://github.com/mpv-player/mpv/tree/v0.41.0/include/mpv) |
| FFmpeg 播放库 | 实际运行栈包含启用 GPL 的构建；应以真实 configure、源码、修改记录和依赖映射为准，不能概括为纯 LGPL | [FFmpeg 许可](https://ffmpeg.org/legal.html) |
| FFmpeg / FFprobe 导出工具 | 本项目工具版本 9.0.1；保留其本身适用的 LGPL 许可，提供固定源码与 configure 配置，不因主应用 GPL 改写它们的版权 | [FFmpeg 源码](https://ffmpeg.org/releases/) |
| Rubber Band | 时间伸缩处理；采用其已有 GPLv2-or-later 路线，未采用闭源替代商业许可 | [Rubber Band 许可](https://breakfastquay.com/rubberband/license.html) |
| libass | ASS 字幕渲染；保留原 ISC 许可和 libass contributors 版权声明 | [libass](https://github.com/libass/libass) |
| 其他随包库 | libplacebo、字体、编解码、压缩等实际依赖；逐组件确认真实版本、原许可、源码与本地修改 | 见对应源码资产的完整组件映射 |

GPLv3 授权的是完整组合发行的适用条款；第三方组件原有许可和版权仍然保留。Apple 系统框架与通用编译工具依据 GPL 的系统库/工具排除项处理，不应把随应用分发的非系统库当作系统库。[GNU GPLv3 第1节](https://www.gnu.org/licenses/gpl-3.0.en.html#section1)

## 对应源码资产应包含

- 与封存 0.6.0-core r3 功能构建对应的原创应用源码、接口文件、资源及构建脚本。
- 实际 44 个播放动态库各自对应的源码版本、必要依赖、本地补丁、构建配置与打包步骤；原 Vendor / IINA 清单只是历史起点，不能替代当前映射。
- FFmpeg / FFprobe 9.0.1 的源码和构建 configure，完整版权与许可证通知。
- 若公共副本更新许可资源与签名，应保留原 r3 源码归档，并另给元数据变更与重签名/重打包说明。
- 可免费取得的源码资产、安装包和 SHA256 校验清单，在同一个 Release 清楚列明。

这是一份材料要求与概要说明；对应源码资产尚未生成/上传时，不应把它当作“所有组件已齐备”的证明。使用权来自各组件现有许可证，不是本文件重新向上游申请或授予的权利。

This software is based in part on the work of the Independent JPEG Group.

Portions of this software are copyright © 2026 The FreeType Project (https://freetype.org). All rights reserved.
