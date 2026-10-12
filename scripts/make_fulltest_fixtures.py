#!/usr/bin/env python3
"""Create the local two-audio/two-subtitle input used by multi-track regression.

No network or player is used. Existing inputs are checked and reused unless
--force is explicit. --check never writes fixtures or reports without --report.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Tests/Fixtures/中文 测试 H264.mp4"
CHINESE = SOURCE.with_suffix(".ass")
DESTINATION = ROOT / "Tests/Fixtures/FullTest"
NAME = "多音轨双字幕.mkv"
ENGLISH = "1\n00:00:00,000 --> 00:00:11,900\nEnglish alternate subtitle\n"


def sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def probe(path: Path, ffprobe: Path) -> dict:
    output = subprocess.check_output([str(ffprobe), "-v", "error", "-show_streams",
                                      "-show_format", "-of", "json", str(path)], timeout=30)
    return json.loads(output)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def check_fixture(path: Path, english: Path, duration: float, ffprobe: Path) -> dict:
    require(path.is_file(), f"Missing fixture: {path}")
    require(english.is_file() and english.read_text(encoding="utf-8") == ENGLISH,
            f"English.srt differs from the reproducible input: {english}")
    info = probe(path, ffprobe)
    streams = info["streams"]
    video = [item for item in streams if item.get("codec_type") == "video"]
    audio = [item for item in streams if item.get("codec_type") == "audio"]
    subtitles = [item for item in streams if item.get("codec_type") == "subtitle"]
    require(len(streams) == 5 and len(video) == 1 and video[0]["codec_name"] == "h264",
            "Expected one H.264 video and five total streams")
    require(len(audio) == 2 and all(item["codec_name"] == "aac" for item in audio),
            "Expected two AAC audio tracks")
    require([item["codec_name"] for item in subtitles] == ["ass", "subrip"],
            "Expected Chinese ASS then English SubRip tracks")
    for collection in (audio, subtitles):
        require([item.get("tags", {}).get("language") for item in collection] == ["zho", "eng"],
                "Expected ordered zho/eng track metadata")
        require([item.get("disposition", {}).get("default", 0) for item in collection] == [1, 0],
                "Only the first audio/subtitle track should be default")
    actual_duration = float(info["format"]["duration"])
    require(abs(actual_duration - duration) < 0.25, "Output duration differs from the H.264 source")
    return info


def write_report(path: Path, data: dict) -> None:
    # Exclusive publication prevents a mistyped report path overwriting evidence.
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--chinese-subtitle", type=Path, default=CHINESE)
    parser.add_argument("--output-directory", type=Path, default=DESTINATION)
    parser.add_argument("--ffmpeg", type=Path, default=ROOT / "Vendor/tools/ffmpeg")
    parser.add_argument("--ffprobe", type=Path, default=ROOT / "Vendor/tools/ffprobe")
    parser.add_argument("--check", action="store_true", help="Check existing fixtures only")
    parser.add_argument("--force", action="store_true", help="Explicitly replace these two fixtures")
    parser.add_argument("--report", type=Path, help="Write provenance to a NEW JSON file")
    args = parser.parse_args()
    if args.check and args.force:
        parser.error("--check and --force cannot be combined")
    if args.report and args.report.exists():
        parser.error("--report must name a new file; previous evidence is preserved")
    for path in (args.source, args.chinese_subtitle, args.ffprobe):
        require(path.is_file(), f"Missing prerequisite: {path}; generate the base fixtures first")
    require(os.access(args.ffprobe, os.X_OK), "ffprobe is not executable")
    source_info = probe(args.source, args.ffprobe)
    duration = float(source_info["format"]["duration"])
    require(math.isfinite(duration) and 11.9 <= duration <= 12.1,
            "This regression requires the original 12-second H.264 source")
    require(any(item.get("codec_name") == "h264" for item in source_info["streams"]),
            "Source must contain H.264 video")
    require(any(item.get("codec_type") == "audio" for item in source_info["streams"]),
            "Source must contain audio")
    # Reading as UTF-8 also rejects damaged/misencoded subtitles before encoding.
    require("[Events]" in args.chinese_subtitle.read_text(encoding="utf-8"), "Expected Chinese ASS input")
    output = args.output_directory / NAME
    english = args.output_directory / "English.srt"
    action, command = "checked_existing", []
    if not args.check and not args.force and output.exists() and not english.exists():
        with tempfile.TemporaryDirectory(prefix=".fulltest-", dir=args.output_directory) as temporary:
            staged_subtitle = Path(temporary) / "English.srt"
            staged_subtitle.write_text(ENGLISH, encoding="utf-8")
            # Validate the existing container before completing its missing sidecar.
            check_fixture(output, staged_subtitle, duration, args.ffprobe)
            require(not english.exists(), "English.srt appeared during preparation; refusing to replace it")
            staged_subtitle.replace(english)
        action = "completed_missing_sidecar"
    if not args.check and (args.force or not output.exists()):
        require(args.ffmpeg.is_file() and os.access(args.ffmpeg, os.X_OK), "Missing executable ffmpeg")
        if english.exists() and not args.force:
            require(english.read_text(encoding="utf-8") == ENGLISH,
                    "Existing English.srt differs; refusing to replace it without --force")
        args.output_directory.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".fulltest-", dir=args.output_directory) as temporary:
            staging = Path(temporary)
            staged_subtitle = staging / "English.srt"
            staged_output = staging / NAME
            staged_subtitle.write_text(ENGLISH, encoding="utf-8")
            command = [str(args.ffmpeg), "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                       "-i", str(args.source), "-f", "lavfi", "-i",
                       f"sine=frequency=880:sample_rate=48000:duration={duration:g}",
                       "-i", str(args.chinese_subtitle), "-i", str(staged_subtitle),
                       "-map", "0:v:0", "-map", "0:a:0", "-map", "1:a:0", "-map", "2:s:0", "-map", "3:s:0",
                       "-c:v", "copy", "-c:a", "aac", "-b:a", "128k", "-ac", "1", "-c:s", "copy",
                       "-t", f"{duration:g}", "-metadata:s:a:0", "language=zho", "-metadata:s:a:0", "title=中文声音",
                       "-metadata:s:a:1", "language=eng", "-metadata:s:a:1", "title=English tone",
                       "-metadata:s:s:0", "language=zho", "-metadata:s:s:0", "title=中文字幕",
                       "-metadata:s:s:1", "language=eng", "-metadata:s:s:1", "title=English subtitle",
                       "-disposition:a:0", "default", "-disposition:a:1", "0",
                       "-disposition:s:0", "default", "-disposition:s:1", "0", str(staged_output)]
            subprocess.run(command, check=True, timeout=90)
            check_fixture(staged_output, staged_subtitle, duration, args.ffprobe)
            # Verify before publication; no partially encoded destination appears.
            if not args.force:
                require(not output.exists(), "Destination appeared during generation; refusing to overwrite it")
            staged_output.replace(output)
            if args.force or not english.exists():
                staged_subtitle.replace(english)
        action = "generated"
    info = check_fixture(output, english, duration, args.ffprobe)
    data = {"schema": 1, "action": action, "source": {"path": str(args.source.resolve()), "sha256": sha256(args.source)},
            "sourceDerivationVerified": action == "generated",
            "chineseSubtitle": {"path": str(args.chinese_subtitle.resolve()), "sha256": sha256(args.chinese_subtitle)},
            "englishSubtitle": {"path": str(english.resolve()), "sha256": sha256(english)},
            "fixture": {"path": str(output.resolve()), "bytes": output.stat().st_size, "sha256": sha256(output)},
            "tools": {"ffprobeSHA256": sha256(args.ffprobe)}, "command": command, "ffprobe": info,
            "scope": "Container/stream metadata only. Source derivation is known for this run's generation; reused inputs record the reference source without re-proving derivation. No player, audio quality or subtitle rendering acceptance."}
    if action == "generated":
        data["tools"]["ffmpegSHA256"] = sha256(args.ffmpeg)
    if args.report:
        write_report(args.report, data)
    print(f"PASS {action}: {output}; H.264 + 2 AAC + Chinese ASS + English SRT; {info['format']['duration']}s")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(f"Full-test fixture error: {error}")
