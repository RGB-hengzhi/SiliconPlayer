#!/usr/bin/env python3
"""Generate offline HLS, chapter, and playlist integration fixtures."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
fixtures = root / 'Tests/Fixtures'
ffmpeg = root / 'Vendor/tools/ffmpeg'
source = fixtures / '中文 测试 H264.mp4'
hls = fixtures / 'HLS'
hls.mkdir(parents=True, exist_ok=True)
subprocess.run([str(ffmpeg), '-hide_banner', '-loglevel', 'error', '-y', '-i', str(source),
                '-map', '0', '-c', 'copy', '-hls_time', '2', '-hls_list_size', '0',
                '-hls_segment_type', 'fmp4', '-hls_segment_filename', str(hls / 'segment-%03d.m4s'),
                str(hls / 'playlist.m3u8')], check=True)
metadata = fixtures / 'chapters.txt'
metadata.write_text(';FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=6000\ntitle=第一章 开始\n'
                    '[CHAPTER]\nTIMEBASE=1/1000\nSTART=6000\nEND=12000\ntitle=第二章 中文章节\n')
subprocess.run([str(ffmpeg), '-hide_banner', '-loglevel', 'error', '-y', '-i', str(source),
                '-i', str(metadata), '-map_metadata', '1', '-map', '0', '-c', 'copy',
                str(fixtures / '中文 章节.mp4')], check=True)
(fixtures / '中文 列表.m3u8').write_text('#EXTM3U\n#EXTINF:-1,中文H264\n中文 测试 H264.mp4\n'
                                      '#EXTINF:-1,中文HEVC\n中文 测试 HEVC.mp4\n')
print('Generated HLS fMP4, Chinese chapters, and relative M3U8 fixtures')
