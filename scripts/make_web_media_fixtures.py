#!/usr/bin/env python3
"""Create local HTTP web-player fixtures without altering archived test media."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Tests/Fixtures/WebPages"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if OUT.exists():
        raise SystemExit("Fixture directory already exists; preserve existing evidence")
    OUT.mkdir(parents=True)
    sources = [ROOT / "Tests/Fixtures/中文 测试 H264.mp4",
               ROOT / "Tests/Fixtures/extended/hevc-720p.mp4"]
    copies = [OUT / "h264.mp4", OUT / "hevc.mp4"]
    for source, target in zip(sources, copies):
        shutil.copyfile(source, target)
    (OUT / "中文 人工.vtt").write_text(
        "WEBVTT\n\n00:00:00.000 --> 00:00:11.900\n网页人工字幕：中文标点，清晰度切换。\n", encoding="utf-8")
    (OUT / "progressive.html").write_text('''<!doctype html>
<html lang="zh"><head><meta charset="utf-8"><title>网页视频 中文，格式=选择</title></head>
<body><video id="web-video" controls>
<source src="h264.mp4" type="video/mp4" label="H264 360p">
<source src="hevc.mp4" type="video/mp4" label="HEVC 720p">
<track src="中文 人工.vtt" kind="subtitles" srclang="zh" label="中文人工" default>
</video></body></html>''', encoding="utf-8")
    (OUT / "unknown.html").write_text('''<!doctype html>
<html lang="zh"><head><meta charset="utf-8"><title>未知尺寸 普通网页视频</title></head>
<body><video controls src="h264.mp4"></video></body></html>''', encoding="utf-8")
    dash = OUT / "dash"
    dash.mkdir()
    # Argument arrays preserve literal DASH template dollar signs.
    command = [str(ROOT / "Vendor/tools/ffmpeg"), "-hide_banner", "-loglevel", "error",
               "-i", str(copies[0]), "-map", "0:v:0", "-map", "0:a:0", "-c", "copy",
               "-f", "dash", "-seg_duration", "2", "-use_template", "1", "-use_timeline", "1",
               "-init_seg_name", "init-$RepresentationID$.m4s",
               "-media_seg_name", "chunk-$RepresentationID$-$Number%05d$.m4s",
               str(dash / "manifest.mpd")]
    subprocess.run(command, check=True, timeout=60)
    (OUT / "dash.html").write_text('''<!doctype html>
<html lang="zh"><head><meta charset="utf-8"><title>DASH 分离视频与音频</title></head>
<body><video controls src="dash/manifest.mpd"></video></body></html>''', encoding="utf-8")
    manifest = {"scope": "Controlled local HTML5 and separate DASH HTTP inputs; no public-site certification",
                "sourceInputs": [{"path": str(p), "SHA256": digest(p)} for p in sources],
                "files": [{"path": str(p.relative_to(OUT)), "SHA256": digest(p), "bytes": p.stat().st_size}
                          for p in sorted(OUT.rglob("*")) if p.is_file()],
                "ffmpegCommand": command}
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "created", "directory": str(OUT), "files": len(manifest["files"])}, ensure_ascii=False))


if __name__ == "__main__":
    main()
