# Licenses and attribution for SiliconPlayer 0.6.0 core runtime

The original SiliconPlayer application is GPL-3.0-or-later. Original third-party copyrights and grants are retained in these component directories and in the matching dependency-source archives. This collection contains full original license texts and complete copyright/license comment blocks, omitting executable C code. It accompanies the binary package; it does not replace the corresponding-source assets.

Portions of this software are copyright © 2026 The FreeType Project (https://freetype.org). All rights reserved.

This software is based in part on the work of the Independent JPEG Group.

## Explicit alternatives used for this GPLv3-compatible release

- FreeType 2.14.3: use the FreeType License (FTL). Full `FREETYPE/docs/FTL.TXT` is present. Original `LICENSE.TXT` expressly says FTL is compatible with GPLv3; `docs/GPLv2.TXT` is retained only as the unselected alternative. The archive itself also permits later GPL versions. Original BDF/PCF and hash MIT notices, gzip Zlib notice, and HarfBuzz Old MIT notices are retained. The 2026 attribution year is established by the exact source `include/freetype/freetype.h` copyright, not inferred from the package date.
- UCharDet 0.0.8: choose the LGPL-2.1-or-later branch explicitly permitted in its original MPL/GPL/LGPL headers. Original tri-license notices remain intact.
- Zstandard 1.5.7: use its BSD-3-Clause branch; GPL text in the source distribution is an alternative.
- Rubber Band 4.0.0: use its GPL-2.0-or-later branch. No commercial alternate license is claimed.
- libarchive BLAKE2: use its expressly permitted Apache-2.0 alternative. Both the original choice notice and full Apache text are present. Fontconfig CaseFolding data retains its original Unicode copyright and full Unicode License V3.
- libass 0.17.5 is ISC. libbs2b 3.1.0 is MIT, not LGPL/GPL. These original grants are copied verbatim.

The reviewed shared runtime uses mpv GPL-2.0-or-later, GPL-enabled FFmpeg and compatible LGPL/permissive libraries. No mandatory GPL-2.0-only runtime route was identified in these actual source grants. GPLv3-compatible distribution does not erase or rewrite third-party license texts. The separate ffmpeg/ffprobe tools retain their default-configured LGPL grant. Build-only/header dependencies and optional source components retain their own original notices; included text is not a claim that every source component is linked into the app. This is a bounded source/notice review, not a universal legal certification.

## Runtime project routes

| Project | Actual source version/ref | Selected grant/route |
| --- | --- | --- |
| BROTLI | 1.0.9 | MIT |
| DAV1D | 1.5.3 | BSD-2-Clause (patent grant retained) |
| FFMPEG | 9.0.1 | GPL-2.0-or-later for shared runtime; LGPL-2.1-or-later for default-configured tools |
| FONTCONFIG | 2.18.1 | MIT-style component grants and Unicode data license retained |
| FREETYPE | 2.14.3 | FTL selected, with BDF/PCF/fthash MIT, gzip Zlib and HarfBuzz Old MIT |
| FRIBIDI | 1.0.16 | LGPL-2.1-or-later |
| HARFBUZZ | 14.2.1 | Old MIT and retained component grants |
| JPEG_TURBO | 3.1.4.1 | IJG and BSD-3-Clause; Zlib SIMD notices retained |
| LIBARCHIVE | 3.8.8 | BSD-style component grants and BLAKE2 Apache-2.0 alternative selected; original grants retained |
| LIBASS | 0.17.5 | ISC |
| LIBBLURAY | 1.4.1 | LGPL-2.1-or-later |
| LIBBS2B | 3.1.0 | MIT |
| LIBJXL | 0.11.2 | BSD-3-Clause with selected submodule grants retained |
| LIBOGG | 1.3.6 | BSD-3-Clause |
| LIBPLACEBO_LOCAL | a96296875a067887fc75d7b74a0a4292422c204d; API365; one local source-file change | LGPL-2.1-or-later with build/header component grants retained |
| LIBSOXR | 0.1.3 | LGPL-2.1-or-later with PFFFT UCAR notice retained |
| LIBUDFREAD | 1.2.0 | LGPL-2.1-or-later |
| LIBUNIBREAK | 7.0 | Zlib |
| LIBVORBIS | 1.3.7 | BSD-3-Clause |
| LIBWEBP | 1.6.0 | BSD-3-Clause (patent grant retained) |
| LITTLE_CMS2 | 2.19 | MIT (core library; GPL plugin texts remain in source materials) |
| LUAJIT | 8e6520a7aecd0517e792b359afbbfd7274791f5f | MIT |
| LZ4 | 1.10.0 | BSD-2-Clause (library; GPL command-line tool sources separately retained) |
| MPV_LOCAL | v0.41.0-dev-g97179bce7-dirty; 18 local source-file changes | GPL-2.0-or-later |
| MUJS | 1.3.9 | ISC |
| RUBBERBAND | 4.0.0 | GPL-2.0-or-later (open-source branch) |
| SPEEX | 1.2.1 | BSD-3-Clause |
| SVT_AV1 | 4.2.0 | BSD-3-Clause-Clear and BSD-2-Clause component grants (AOM patent grant retained) |
| UCHARDET | 0.0.8 | LGPL-2.1-or-later selected from original MPL-1.1/GPL-2.0-or-later/LGPL-2.1-or-later tri-license |
| ZIMG | 3.0.6 | WTFPL-2.0 with original notices retained |
| ZSTD | 1.5.7 | BSD-3-Clause selected (GPL alternative not selected) |

Exact library names, binary SHA256 values and source archive hashes are supplied in `runtime-to-source.json` in the dependency-source kit. Full original license text is authoritative.
