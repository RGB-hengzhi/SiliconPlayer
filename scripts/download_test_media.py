#!/usr/bin/env python3
"""Acquire pinned real 4K test media; never run a player or re-encode media.

The source catalog and small HLS snapshots are versioned. Large media stays in
the ignored Fixtures directory. Existing verified assets are always skipped.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCES = ROOT / "Tests/MediaSources/high-resolution.json"
DEFAULT_OUTPUT = ROOT / "Tests/Fixtures/HighResolution"
PAYLOAD_ALGORITHM = "ffprobe-packet-chain-sha256-v1"


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_catalog(path):
    catalog = json.loads(path.read_text(encoding="utf-8"))
    if catalog.get("schema") != 2 or not catalog.get("assets"):
        raise ValueError("Unsupported or empty source catalog")
    for asset in catalog["assets"]:
        filename = asset["file"]
        if Path(filename).name != filename or filename.startswith("."):
            raise ValueError("Invalid asset filename in catalog")
        if asset.get("bytes", 0) <= 0 or not re.fullmatch(r"[0-9a-f]{64}", asset.get("sha256", "")):
            raise ValueError("Missing recorded size/SHA256: " + filename)
    return catalog


def probe_file(path, ffprobe):
    command = [str(ffprobe), "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError("ffprobe failed: " + result.stderr[-2000:].strip())
    return json.loads(result.stdout)


def compressed_payload(path, ffprobe):
    """Hash compressed packets without decoding, independently of container tags.

    Each per-stream digest is SHA256(domain || repeated uint64-be(packet size)
    || raw packet SHA256). Packet order within each stream, codec configuration,
    packet counts and compressed byte counts are retained; timestamps and stream
    interleaving are deliberately excluded because remuxing can change them.
    """
    command = [str(ffprobe), "-v", "error", "-show_streams", "-show_packets",
               "-show_data_hash", "sha256", "-show_entries",
               "stream=index,codec_type,codec_name,extradata_hash:packet=stream_index,size,data_hash",
               "-of", "json", str(path)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=180)
    if result.returncode:
        raise RuntimeError("Compressed-packet inspection failed: " + result.stderr[-2000:].strip())
    data = json.loads(result.stdout)
    streams = {}
    for stream in data.get("streams", []):
        if stream.get("codec_type") not in ("video", "audio"):
            continue
        streams[stream["index"]] = {
            "codec_type": stream["codec_type"], "codec_name": stream["codec_name"],
            "extradata_sha256": stream.get("extradata_hash", ""),
            "packet_count": 0, "packet_bytes": 0,
            "digest": hashlib.sha256(b"SiliconPlayer compressed packet fingerprint v1\0")}
    for packet in data.get("packets", []):
        stream = streams.get(packet["stream_index"])
        if stream is None:
            continue
        size = int(packet["size"])
        packet_hash = packet.get("data_hash", "")
        if not re.fullmatch(r"SHA256:[0-9a-fA-F]{64}", packet_hash):
            raise ValueError("ffprobe did not return a compressed packet SHA256")
        stream["digest"].update(size.to_bytes(8, "big"))
        stream["digest"].update(bytes.fromhex(packet_hash.split(":", 1)[1]))
        stream["packet_count"] += 1
        stream["packet_bytes"] += size
    fingerprints = []
    for index in sorted(streams):
        stream = streams[index]
        if not stream["packet_count"]:
            raise ValueError("No compressed packets were inspected")
        stream["payload_sha256"] = stream.pop("digest").hexdigest()
        fingerprints.append(stream)
    if not fingerprints:
        raise ValueError("No audio/video streams found")
    return {"algorithm": PAYLOAD_ALGORITHM, "streams": fingerprints}


def verify_media(path, asset, ffprobe, strict_container=False):
    size = path.stat().st_size
    with path.open("rb") as handle:
        if handle.read(8)[4:] != b"ftyp":
            raise ValueError("Not an MP4 file (missing ftyp; possibly an HTML error page)")
    actual_hash = sha256(path)
    exact = size == asset["bytes"] and actual_hash == asset["sha256"]
    info = probe_file(path, ffprobe)
    video = next((stream for stream in info.get("streams", []) if stream.get("codec_type") == "video"), None)
    if video is None:
        raise ValueError("No video stream")
    for key, expected in asset["video"].items():
        if key in ("codec_name", "profile", "width", "height", "avg_frame_rate", "pix_fmt",
                   "color_range", "color_space", "color_transfer", "color_primaries") and expected != "unspecified":
            if video.get(key) != expected:
                raise ValueError(f"{key}: expected {expected!r}, got {video.get(key)!r}")
    audio = [stream for stream in info["streams"] if stream.get("codec_type") == "audio"]
    if len(audio) != len(asset["audio"]):
        raise ValueError("Audio stream count differs from source catalog")
    for actual, expected in zip(audio, asset["audio"]):
        for key in ("codec_name", "sample_rate", "channels"):
            if actual.get(key) != expected.get(key):
                raise ValueError("Audio " + key + " differs from source catalog")
    duration = float(info["format"]["duration"])
    if abs(duration - asset["duration_seconds"]) > 0.1:
        raise ValueError("Duration differs from the complete recorded source")
    verification = "recorded container size/SHA256 and ffprobe"
    if not exact:
        reference = asset.get("compressed_payload")
        if strict_container or reference is None:
            raise ValueError("Recorded container size/SHA256 mismatch")
        if reference.get("algorithm") != PAYLOAD_ALGORITHM or compressed_payload(path, ffprobe) != reference:
            raise ValueError("Container differs and compressed payload fingerprint does not match")
        verification = "equivalent compressed packets; container bytes differ"
    return {"file": asset["file"], "bytes": size, "sha256": actual_hash,
            "recorded_container_match": exact, "verification": verification}, info


def download_archive(source, path):
    expected_size = source["archive_bytes"]
    for attempt in range(3):
        try:
            request = urllib.request.Request(source["download_url"], headers={"User-Agent": "SiliconPlayer-test-media/1"})
            with urllib.request.urlopen(request, timeout=60) as response, path.open("wb") as target:
                if response.headers.get_content_type() in ("text/html", "application/xhtml+xml"):
                    raise ValueError("Download returned HTML instead of the pinned archive")
                total, announced = 0, 0
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > expected_size:
                        raise ValueError("Archive exceeds its recorded size")
                    target.write(chunk)
                    if total - announced >= 64 * 1024 * 1024:
                        print(f"  archive: {total // 1024 // 1024} MiB", flush=True)
                        announced = total
            if total != expected_size or sha256(path) != source["archive_sha256"]:
                raise ValueError("Pinned archive size/SHA256 mismatch")
            return
        except (OSError, ValueError):
            path.unlink(missing_ok=True)
            if attempt == 2:
                raise
            time.sleep(1)


def snapshot_path(catalog_directory, reference):
    path = (catalog_directory / reference["snapshot"]).resolve()
    if catalog_directory.resolve() not in path.parents:
        raise ValueError("Snapshot path escapes source catalog directory")
    if sha256(path) != reference["sha256"]:
        raise ValueError("Versioned source playlist SHA256 mismatch: " + str(path))
    return path


def absolute_playlist(text, origin):
    def absolute(address):
        url = urllib.parse.urljoin(origin, address)
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError("Unsupported URL in pinned HLS snapshot")
        return url
    lines = []
    for line in text.splitlines():
        if line.startswith("#EXT-X-KEY:"):
            raise ValueError("Encrypted playlists are outside this test source catalog")
        if line.startswith("#EXT-X-MAP:"):
            line = re.sub(r'URI="([^"]+)"', lambda match: 'URI="' + absolute(match.group(1)) + '"', line)
        elif line and not line.startswith("#"):
            line = absolute(line.strip())
        lines.append(line)
    if "#EXT-X-ENDLIST" not in lines:
        raise ValueError("Only complete VOD source snapshots can be downloaded")
    return "\n".join(lines) + "\n"


def acquire(asset, catalog_directory, output_directory, ffmpeg, ffprobe, strict_container):
    destination = output_directory / asset["file"]
    with tempfile.TemporaryDirectory(prefix=".test-media-", dir=output_directory) as temporary:
        work = Path(temporary)
        staging = work / asset["file"]
        source = asset["source"]
        if source["kind"] == "original_compressed_movie_download":
            archive = work / "source.zip"
            download_archive(source, archive)
            with zipfile.ZipFile(archive) as zipped:
                entry = zipped.getinfo(asset["file"])
                if entry.is_dir() or entry.file_size != asset["bytes"]:
                    raise ValueError("Pinned ZIP movie entry does not match the source catalog")
                with zipped.open(entry) as original, staging.open("wb") as target:
                    shutil.copyfileobj(original, target, 1024 * 1024)
        elif source["kind"] == "lossless_container_remux_from_official_hls":
            playlists = []
            for kind in ("video", "audio"):
                reference = source["snapshots"][kind]
                original = snapshot_path(catalog_directory, reference).read_text(encoding="utf-8")
                playlist = work / (kind + ".m3u8")
                playlist.write_text(absolute_playlist(original, source[kind + "_playlist"]), encoding="utf-8")
                playlists.append(playlist)
            command = [str(ffmpeg), "-hide_banner", "-loglevel", "warning", "-nostdin", "-y"]
            for playlist in playlists:
                command += ["-protocol_whitelist", "file,https,tcp,tls", "-rw_timeout", "25000000", "-i", str(playlist)]
            command += ["-map", "0:v:0", "-map", "1:a:0", "-c", "copy", "-movflags", "+faststart", str(staging)]
            # The command is constructed here; catalog strings are never shell code.
            subprocess.run(command, check=True, timeout=900)
        else:
            raise ValueError("Unsupported source kind: " + source["kind"])
        report, info = verify_media(staging, asset, ffprobe, strict_container)
        os.replace(staging, destination)  # Same destination filesystem; preserve old files until verified.
    info["format"]["filename"] = str(destination)
    return report, info


def atomic_json(path, value):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=".media-report-", dir=path.parent, delete=False) as handle:
            temporary = Path(handle.name)
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, default=DEFAULT_SOURCES)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--ffmpeg", type=Path, default=ROOT / "Vendor/tools/ffmpeg")
    parser.add_argument("--ffprobe", type=Path, default=ROOT / "Vendor/tools/ffprobe")
    parser.add_argument("--only", action="append", help="Select a catalog filename; repeat for multiple assets")
    parser.add_argument("--check", action="store_true", help="Verify existing files only; never download")
    parser.add_argument("--list", action="store_true", help="List source assets without requiring media helpers")
    parser.add_argument("--strict-container", action="store_true", help="Require exact recorded container size/SHA256, including remuxed Apple files")
    args = parser.parse_args()
    catalog = read_catalog(args.sources)
    selected = set(args.only or [asset["file"] for asset in catalog["assets"]])
    known = {asset["file"] for asset in catalog["assets"]}
    if selected - known:
        parser.error("Unknown source filename: " + ", ".join(sorted(selected - known)))
    assets = [asset for asset in catalog["assets"] if asset["file"] in selected]
    if args.list:
        for asset in assets:
            print(f"{asset['file']}  {asset['bytes']:,} bytes  {asset['source']['license']}")
        return 0
    if not args.ffprobe.is_file() or not os.access(args.ffprobe, os.X_OK):
        parser.error("Missing ffprobe; run scripts/bootstrap_media_tools.py first")
    if not args.check and (not args.ffmpeg.is_file() or not os.access(args.ffmpeg, os.X_OK)):
        parser.error("Missing ffmpeg; run scripts/bootstrap_media_tools.py first")
    # Validate all pinned snapshots before any network operation or publication.
    for asset in assets:
        for reference in asset["source"].get("snapshots", {}).values():
            snapshot_path(args.sources.parent, reference)
    args.output.mkdir(parents=True, exist_ok=True)
    reports, failures = [], []
    for asset in assets:
        destination = args.output / asset["file"]
        try:
            report = info = None
            if destination.is_file():
                try:
                    report, info = verify_media(destination, asset, args.ffprobe, args.strict_container)
                    report["action"] = "skipped_existing"
                    print("SKIP", asset["file"], "—", report["verification"], flush=True)
                except (ValueError, RuntimeError) as error:
                    if args.check:
                        raise
                    print("Existing file failed verification:", error, flush=True)
            if report is None:
                if args.check:
                    raise FileNotFoundError("Media file is missing")
                print("DOWNLOAD", asset["file"], flush=True)
                report, info = acquire(asset, args.sources.parent, args.output, args.ffmpeg, args.ffprobe, args.strict_container)
                report["action"] = "downloaded"
                print("READY", asset["file"], "—", report["verification"], flush=True)
            reports.append(report)
            atomic_json(args.output / (asset["file"] + ".ffprobe.json"), info)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
            failures.append({"file": asset["file"], "error": str(error)})
            print("FAILED", asset["file"], "—", error, file=sys.stderr, flush=True)
    atomic_json(args.output / "acquisition-report.json", {"sources": str(args.sources),
        "source_catalog_sha256": sha256(args.sources), "mode": "check" if args.check else "download",
        "assets": reports, "failures": failures})
    print(f"Verified {len(reports)}/{len(assets)} assets; {len(failures)} failures. No player or encoder was run.")
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Cancelled; any existing destination was preserved.", file=sys.stderr)
        raise SystemExit(130)
