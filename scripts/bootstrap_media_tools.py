#!/usr/bin/env python3
"""Build pinned, self-contained arm64 media helpers without global packages.

Build caches and logs stay on APFS. Only runtime binaries, the Whisper base
model, notices, and a verified manifest are copied into Vendor/tools.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path.home() / "Library/Caches/SiliconPlayer/media-tools"
TOOLS = ROOT / "Vendor/tools"
FFMPEG = {
    "version": "9.0.1",
    "url": "https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz",
    "sha256": "cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635",
}
WHISPER = {
    "version": "1.9.4",
    "url": "https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v1.9.4",
    "sha256": "57e280cee375ab02425b806ad5146b99f6eb9357e3c2b31357c8a6af2e2e44ae",
    "release": "https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.4",
}
MODEL = {
    "name": "ggml-base.bin", "type": "base multilingual",
    "revision": "5359861c739e955e79d9a303bcbc70fb988958b1",
    "url": "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin",
    "sha256": "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
    "size": 147951465,
    "hash_source": "https://huggingface.co/api/models/ggerganov/whisper.cpp?blobs=true",
}
CMAKE = {
    "version": "4.4.3",
    "filename": "cmake-4.4.3-py3-none-macosx_10_10_universal2.whl",
    "url": "https://files.pythonhosted.org/packages/da/2e/78cc0dab93ad407e4b126ab6a3c8a6fc3df89011b49e910c5a5e9bda78a6/cmake-4.4.3-py3-none-macosx_10_10_universal2.whl",
    "sha256": "6c95b37116bb5c714656e4f76931ebdcb739209a1aee91cf51408ccfe137694e",
}


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def download(info, name):
    path = CACHE / name
    if path.exists() and sha(path) == info["sha256"]:
        return path
    partial = path.with_name(path.name + ".part")
    for attempt in range(3):
        try:
            print("Downloading", name, flush=True)
            req = urllib.request.Request(info["url"], headers={"User-Agent": "SiliconPlayer-build/1"})
            with urllib.request.urlopen(req, timeout=90) as source, partial.open("wb") as target:
                copied, last = 0, 0
                while True:
                    chunk = source.read(1024 * 1024)
                    if not chunk:
                        break
                    target.write(chunk)
                    copied += len(chunk)
                    if copied - last >= 16 * 1024 * 1024:
                        print(f"  {name}: {copied // 1024 // 1024} MiB", flush=True)
                        last = copied
            if sha(partial) != info["sha256"]:
                raise RuntimeError("SHA256 mismatch: " + name)
            partial.replace(path)
            return path
        except Exception:
            partial.unlink(missing_ok=True)
            if attempt == 2:
                raise
            time.sleep(2)


def unpack(archive, folder):
    destination = CACHE / folder
    if (destination / ".unpacked").exists():
        return destination
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    with tarfile.open(archive) as tf:
        for member in tf.getmembers():
            pieces = Path(member.name).parts
            if len(pieces) <= 1:
                continue
            member.name = str(Path(*pieces[1:]))
            resolved = (destination / member.name).resolve()
            if destination.resolve() not in resolved.parents:
                raise RuntimeError("Unsafe archive path")
            if member.issym() or member.islnk():
                # The pinned upstream source archives need no escaping symlinks.
                linked = (resolved.parent / member.linkname).resolve()
                if destination.resolve() not in linked.parents:
                    raise RuntimeError("Unsafe archive link")
            tf.extract(member, destination)
    (destination / ".unpacked").write_text(sha(archive))
    return destination


def run_logged(args, cwd, label):
    log = CACHE / (label + ".log")
    print(label, "(log:", str(log) + ")", flush=True)
    with log.open("a") as f:
        f.write("\n" + repr(args) + "\n")
        f.flush()
        result = subprocess.run(args, cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(label + " failed:\n" + log.read_text(errors="replace")[-6000:])


def build_ffmpeg():
    source = unpack(download(FFMPEG, "ffmpeg-9.0.1.tar.xz"), "ffmpeg-9.0.1")
    build = CACHE / "ffmpeg-build"
    build.mkdir(exist_ok=True)
    args = [str(source / "configure"), "--arch=arm64", "--target-os=darwin",
            "--cc=clang", "--cxx=clang++", "--disable-doc", "--disable-debug",
            "--disable-autodetect", "--disable-shared", "--enable-static",
            "--enable-videotoolbox", "--enable-audiotoolbox", "--enable-securetransport",
            "--enable-ffmpeg", "--enable-ffprobe", "--disable-ffplay",
            "--extra-cflags=-arch arm64 -mmacosx-version-min=14.0",
            "--extra-ldflags=-arch arm64 -mmacosx-version-min=14.0"]
    if not (build / "config.mak").exists():
        run_logged(args, build, "ffmpeg-configure")
    run_logged(["make", "-j4", "ffmpeg", "ffprobe"], build, "ffmpeg-build")
    return source, build, args


def build_whisper():
    source = unpack(download(WHISPER, "whisper.cpp-v1.9.4.tar.gz"), "whisper.cpp-1.9.4")
    cmake_wheel = download(CMAKE, CMAKE["filename"])
    venv = CACHE / "cmake-venv"
    if not (venv / "bin/python").exists():
        subprocess.run(["python3", "-m", "venv", str(venv)], check=True)
    cmake = venv / "bin/cmake"
    if not cmake.exists():
        run_logged([str(venv / "bin/python"), "-m", "pip", "install", "--no-deps", str(cmake_wheel)], CACHE, "cmake-install")
    build = CACHE / "whisper-build"
    args = [str(cmake), "-S", str(source), "-B", str(build), "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
            "-DBUILD_SHARED_LIBS=OFF", "-DGGML_BACKEND_DL=OFF", "-DGGML_NATIVE=OFF",
            "-DGGML_METAL=OFF", "-DGGML_ACCELERATE=ON", "-DWHISPER_BUILD_TESTS=OFF",
            "-DWHISPER_BUILD_EXAMPLES=ON", "-DWHISPER_BUILD_SERVER=OFF"]
    run_logged(args, CACHE, "whisper-configure")
    run_logged([str(cmake), "--build", str(build), "--target", "whisper-cli", "-j4"], CACHE, "whisper-build")
    return source, build, args


def copy_file(source, target, executable=False):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    if executable:
        target.chmod(0o755)
        subprocess.run(["strip", "-S", str(target)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(target)], check=True)


def verify():
    manifest = json.loads((TOOLS / "manifest.json").read_text())
    for item in manifest["files"]:
        path = TOOLS / item["path"]
        if not path.is_file() or sha(path) != item["sha256"]:
            raise RuntimeError("Invalid runtime file: " + item["path"])
        if item.get("executable"):
            arch = subprocess.check_output(["lipo", "-archs", str(path)], text=True).strip()
            if arch != "arm64":
                raise RuntimeError("Unexpected architecture: " + arch)
            linked = subprocess.check_output(["otool", "-L", str(path)], text=True)
            for line in linked.splitlines()[1:]:
                dependency = line.strip().split(" (", 1)[0]
                if not dependency.startswith(("/usr/lib/", "/System/Library/")):
                    raise RuntimeError("Non-system helper dependency: " + dependency)
    print("Media tools manifest, hashes, arm64 architecture, system-only dependencies verified.", flush=True)


def smoke():
    directory = TOOLS / "validation"
    directory.mkdir(exist_ok=True)
    aiff = directory / "chinese-speech.aiff"
    wav = directory / "chinese-speech.wav"
    sentence = "你好，这是苹果电脑播放器的字幕测试。现在我们正在检查中文语音识别和字幕时间。"
    subprocess.run(["say", "-v", "Tingting", "-r", "145", "-o", str(aiff), sentence], check=True)
    ffmpeg = str(TOOLS / "ffmpeg")
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(aiff),
                    "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(wav)], check=True)
    start = time.monotonic()
    result = subprocess.run([str(TOOLS / "whisper-cli"), "-m", str(TOOLS / "ggml-base.bin"),
                             "-f", str(wav), "-l", "zh", "-t", "4", "-ng", "-osrt", "-of", str(directory / "chinese-speech")],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
    asr_elapsed = time.monotonic() - start
    (directory / "whisper.log").write_text(result.stdout + "\n" + result.stderr)
    if result.returncode:
        raise RuntimeError("Whisper smoke failed: " + result.stderr[-4000:])
    srt = directory / "chinese-speech.srt"
    text = srt.read_text()
    if "-->" not in text or not any("\u4e00" <= c <= "\u9fff" for c in text):
        raise RuntimeError("Whisper did not produce timed Chinese subtitle text")
    probe = json.loads(subprocess.check_output([str(TOOLS / "ffprobe"), "-v", "error", "-show_format", "-show_streams", "-of", "json", str(wav)], text=True))
    # A real arm64 hardware-encode clip, PCM extraction, and remuxed recording.
    video = directory / "generated-video.mp4"
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
                    "-i", str(wav), "-t", "5", "-c:v", "h264_videotoolbox", "-b:v", "600k", "-c:a", "aac", str(video)], check=True)
    clip = directory / "exported-clip.mp4"
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-ss", "1", "-i", str(video), "-t", "2",
                    "-c:v", "h264_videotoolbox", "-b:v", "600k", "-c:a", "aac", str(clip)], check=True)
    audio = directory / "extracted-audio.wav"
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(video), "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(audio)], check=True)
    recording = directory / "remuxed-recording.mkv"
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-re", "-i", str(video), "-c", "copy", str(recording)], check=True)
    validation = {
        "generated_input": "macOS say / Tingting", "sentence": sentence,
        "input_duration": float(probe["format"]["duration"]), "asr_seconds": round(asr_elapsed, 3),
        "model": "base multilingual", "backend": "CPU + Accelerate (Metal build tools unavailable)",
        "subtitle": text, "clips": {},
    }
    for path in (video, clip, audio, recording):
        p = json.loads(subprocess.check_output([str(TOOLS / "ffprobe"), "-v", "error", "-show_format", "-show_streams", "-of", "json", str(path)], text=True))
        validation["clips"][path.name] = {"duration": float(p["format"]["duration"]), "bytes": path.stat().st_size,
                                          "codecs": [s["codec_name"] for s in p["streams"]]}
        if path.stat().st_size < 1000:
            raise RuntimeError("Empty generated output")
    (directory / "report.json").write_text(json.dumps(validation, ensure_ascii=False, indent=2))
    print("Chinese ASR, hardware encoding, clip export, audio extraction, stream remux smoke passed.", flush=True)


def api_smoke():
    directory = TOOLS / "validation"
    harness = ROOT / "Tests/Integration/MediaToolsChecks.swift"
    if not harness.is_file():
        raise RuntimeError("Missing repository MediaTools API checks: " + str(harness))
    binary = CACHE / "media-tools-harness"
    subprocess.run(["swiftc", "-parse-as-library", "-O", "-target", "arm64-apple-macosx14.0",
                    str(ROOT / "Sources/SiliconPlayer/MediaTools.swift"), str(harness), "-o", str(binary)], check=True)
    result = subprocess.run([str(binary), str(directory)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
    (directory / "api-smoke.log").write_text(result.stdout + "\n" + result.stderr)
    if result.returncode:
        raise RuntimeError("MediaTools API smoke failed:\n" + result.stdout + result.stderr)
    print(result.stdout, end="", flush=True)
    report = {"checks": [line for line in result.stdout.splitlines() if line.startswith("API ")], "passed": True, "outputs": {}}
    for name in ("api-clip.mp4", "api-copy.mkv", "api-audio.wav", "api-stopped-recording.mkv"):
        path = directory / name
        info = json.loads(subprocess.check_output([str(TOOLS / "ffprobe"), "-v", "error", "-show_format", "-show_streams", "-of", "json", str(path)], text=True))
        report["outputs"][name] = {"bytes": path.stat().st_size, "duration": float(info["format"]["duration"]), "codecs": [s["codec_name"] for s in info["streams"]]}
    (directory / "api-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--api-smoke", action="store_true", help="Compile and exercise the actual MediaTools process API; also runs CLI smoke fixtures")
    args = parser.parse_args()
    if platform.machine() != "arm64" or platform.system() != "Darwin":
        raise SystemExit("This build requires an Apple Silicon Mac.")
    CACHE.mkdir(parents=True, exist_ok=True)
    if args.verify:
        verify()
        if args.smoke or args.api_smoke:
            smoke()
        if args.api_smoke:
            api_smoke()
        return
    TOOLS.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=3) as workers:
        ff = workers.submit(build_ffmpeg)
        wh = workers.submit(build_whisper)
        model = workers.submit(download, MODEL, MODEL["name"])
        ffsource, ffbuild, ffargs = ff.result()
        whsource, whbuild, whargs = wh.result()
        modelpath = model.result()
    copy_file(ffbuild / "ffmpeg", TOOLS / "ffmpeg", True)
    copy_file(ffbuild / "ffprobe", TOOLS / "ffprobe", True)
    copy_file(whbuild / "bin/whisper-cli", TOOLS / "whisper-cli", True)
    copy_file(modelpath, TOOLS / "ggml-base.bin")
    for name in ("LICENSE.md", "COPYING.LGPLv2.1", "COPYING.LGPLv3"):
        copy_file(ffsource / name, TOOLS / "licenses" / ("FFmpeg-" + name))
    copy_file(whsource / "LICENSE", TOOLS / "licenses/whisper.cpp-MIT.txt")
    # Whisper converted models retain the original Whisper MIT license.
    openai_license = urllib.request.urlopen("https://raw.githubusercontent.com/openai/whisper/v20250625/LICENSE").read()
    (TOOLS / "licenses/Whisper-model-MIT.txt").write_bytes(openai_license)
    files = []
    for path in sorted(TOOLS.rglob("*")):
        if path.is_file() and not path.name.startswith("._") and "validation" not in path.parts and path.name != "manifest.json":
            files.append({"path": str(path.relative_to(TOOLS)), "sha256": sha(path), "bytes": path.stat().st_size,
                          "executable": path.name in ("ffmpeg", "ffprobe", "whisper-cli")})
    manifest = {"schema": 1, "architecture": "arm64", "minimum_macos": "14.0", "ffmpeg": FFMPEG,
                "whisper_cpp": WHISPER, "model": MODEL, "build_cmake": CMAKE,
                "ffmpeg_configure": ffargs, "whisper_configure": whargs, "backend": "CPU + Accelerate",
                "metal": False, "metal_reason": "No metal compiler in the installed Command Line Tools",
                "files": files, "source_archive_hashes": "Pinned after direct official TLS download; model hash verified against Hugging Face LFS metadata",
                "corresponding_sources": [FFMPEG["url"], WHISPER["url"]]}
    (TOOLS / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    verify()
    if args.smoke or args.api_smoke:
        smoke()
    if args.api_smoke:
        api_smoke()


if __name__ == "__main__":
    main()
