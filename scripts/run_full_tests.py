#!/usr/bin/env python3
"""Run the repository QA scripts serially into a new evidence directory.

--check-only performs file/platform preflight and prints the plan without
running any tests, downloads, encoders, builds, or player processes. Full runs
open native player windows and include an optional 600-second 4K60 soak.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests/Fixtures"
CATALOG = ROOT / "Tests/MediaSources/high-resolution.json"
APP = ROOT / "dist/SiliconPlayer-development.app"
APP_STAGES = {"app-integration", "lifecycle", "formats", "ts-seek", "async-screenshots",
              "filter-runtime-fallback", "expanded-media", "high-resolution", "web-media", "playback-intent", "epg", "diagnostic-privacy", "system-pip", "media-profile", "native-audio-queue", "live-asr"}
PYTHON = sys.executable
BASE_FILES = [f"中文 测试 {codec}{suffix}" for codec in ("H264", "HEVC", "MKV")
              for suffix in ((".mkv", ".srt", ".ass") if codec == "MKV" else (".mp4", ".srt", ".ass"))]
NETWORK_FILES = ["HLS/playlist.m3u8", "HLS/init.mp4", "中文 章节.mp4", "中文 列表.m3u8"]
EXTENDED_IDS = {"h264-720p", "hevc-720p", "h264-4k", "hevc-4k", "prores", "flac", "wav", "aac", "mp3", "vp9", "av1"}
EXTENDED_FILES = {item: item + ".mp4" for item in ("h264-720p", "hevc-720p", "h264-4k", "hevc-4k")} | {
    "prores": "prores.mov", "flac": "flac.flac", "wav": "wav.wav", "aac": "aac.m4a",
    "mp3": "mp3.mp3", "vp9": "vp9.mkv", "av1": "av1.mkv"}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def save(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def source_inputs() -> dict[str, str]:
    paths = [p for folder in (ROOT / "Sources", ROOT / "Tests", ROOT / "scripts")
             for p in folder.rglob("*") if p.is_file()
             and p.suffix in (".swift", ".py", ".sh", ".c", ".m", ".mm", ".h", ".modulemap")
             and not any(part.startswith("._") or part in ("Fixtures", "__pycache__") for part in p.relative_to(ROOT).parts)]
    paths += [ROOT / "Package.swift", ROOT / "Resources/Info.plist"]
    return {str(p.relative_to(ROOT)): digest(p) for p in sorted(paths)}


def remove_tree_missing_ok(path: Path) -> None:
    # On exFAT, removing a file also removes its AppleDouble companion. Older
    # Python versions may still enumerate that now-missing companion.
    def onerror(function, filename, error):
        if not isinstance(error[1], FileNotFoundError):
            raise error[1]
    shutil.rmtree(path, onerror=onerror)


def app_executable(app: Path) -> Path:
    return app / "Contents/MacOS/SiliconPlayer" if app.suffix.lower() == ".app" else app


def expected_sha256(value: str) -> str:
    if not re.fullmatch(r"[0-9a-fA-F]{64}", value):
        raise argparse.ArgumentTypeError("Expected executable SHA256 must contain 64 hexadecimal digits")
    return value.lower()


def environment(app: Path = APP) -> dict:
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("SILICONPLAYER_VERIFY_") or key in ("PYTHONOPTIMIZE", "SILICONPLAYER_OUTPUT_APP"):
            env.pop(key)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["SILICONPLAYER_OUTPUT_APP"] = str(app)
    return env


def hls_files() -> list[str]:
    playlist = FIXTURES / "HLS/playlist.m3u8"
    if not playlist.is_file():
        return []
    result = []
    for line in playlist.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#"):
            require(Path(line).name == line, "Local HLS fixture must use simple segment filenames")
            result.append("HLS/" + line)
    return result


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def prepare_fixtures() -> None:
    """Run existing fixed-path generators in a temporary mirror; copy only missing files."""
    FIXTURES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="siliconplayer-fixture-prep-", dir="/private/tmp") as name:
        mirror = Path(name)
        local = mirror / "Tests/Fixtures"
        local.mkdir(parents=True)
        (mirror / "scripts").mkdir()
        (mirror / "Vendor").symlink_to(ROOT / "Vendor", target_is_directory=True)
        original_names = [name for name in BASE_FILES if " MKV" not in name]
        if any(not (FIXTURES / name).is_file() for name in original_names):
            generated = mirror / "native"
            subprocess.run(["swift", str(ROOT / "scripts/make_fixtures.swift"), str(generated)], check=True, env=environment())
            for path in generated.iterdir():
                target = FIXTURES / path.name
                if path.is_file() and not target.exists():
                    shutil.copyfile(path, target)
        for name in original_names:
            (local / name).symlink_to(FIXTURES / name)
        for script, needed in (("remux_fixture.py", [name for name in BASE_FILES if " MKV" in name]),
                               ("make_network_fixtures.py", NETWORK_FILES + hls_files())):
            if any(not (FIXTURES / name).is_file() for name in needed):
                copied = mirror / "scripts" / script
                shutil.copyfile(ROOT / "scripts" / script, copied)
                subprocess.run([PYTHON, str(copied)], check=True, env=environment())
                for path in local.rglob("*"):
                    target = FIXTURES / path.relative_to(local)
                    if path.is_file() and not path.is_symlink() and not target.exists():
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(path, target)
    subprocess.run([PYTHON, str(ROOT / "scripts/make_fulltest_fixtures.py")], check=True, env=environment())
    manifest = FIXTURES / "extended/manifest.json"
    current = json.loads(manifest.read_text()) if manifest.is_file() else {}
    existing = {item["id"]: item for item in current.get("cases", [])}
    missing = []
    for identifier in sorted(EXTENDED_IDS):
        path = FIXTURES / "extended" / EXTENDED_FILES[identifier]
        if path.exists():
            recorded = existing.get(identifier)
            require(recorded is not None and recorded.get("path") == str(path.relative_to(ROOT))
                    and recorded.get("duration_requested") == 24 and recorded.get("sha256") == digest(path),
                    f"Existing {path} is unrecorded, changed, or not 24s; preserving it, refusing automatic replacement")
        else:
            missing.append(identifier)
    if missing:
        # Select only missing cases in an APFS mirror. The original generator's
        # -y/hash-repair behavior must never replace existing local evidence.
        with tempfile.TemporaryDirectory(prefix="siliconplayer-extended-prep-", dir="/private/tmp") as name:
            mirror = Path(name)
            (mirror / "scripts").mkdir()
            (mirror / "Vendor").symlink_to(ROOT / "Vendor", target_is_directory=True)
            copied = mirror / "scripts/make_extended_fixtures.py"
            shutil.copyfile(ROOT / "scripts/make_extended_fixtures.py", copied)
            original_sources = FIXTURES / "extended/sources"
            if original_sources.is_dir():
                shutil.copytree(original_sources, mirror / "Tests/Fixtures/extended/sources")
            subprocess.run([PYTHON, str(copied), *missing, "--duration", "24"], check=True, env=environment())
            generated = json.loads((mirror / "Tests/Fixtures/extended/manifest.json").read_text())
            for item in generated["cases"]:
                target = ROOT / item["path"]
                require(not target.exists(), f"Fixture appeared during preparation: {target}")
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(mirror / item["path"], target)
                existing[item["id"]] = item
            original_sources.mkdir(parents=True, exist_ok=True)
            for path in (mirror / "Tests/Fixtures/extended/sources").glob("*"):
                target = original_sources / path.name
                if path.is_file() and not target.exists():
                    shutil.copyfile(path, target)
            save(manifest, {**current, "schema": 1, "tools": current.get("tools", generated["tools"]),
                            "cases": [existing[key] for key in sorted(existing)],
                            "supplement": {"addedIDs": missing, "tools": generated["tools"]}})
    subtitle = FIXTURES / "extended/format-validation.srt"
    if not subtitle.exists():
        with subtitle.open("x", encoding="utf-8") as handle:
            handle.write("1\n00:00:00,000 --> 00:00:24,000\n中文格式覆盖测试 · SiliconPlayer\n")


def verified_highres_manifest(directory: Path) -> Path:
    checked = json.loads((directory / "acquisition-report.json").read_text())
    require(not checked["failures"], "High-resolution acquisition check failed")
    by_file = {item["file"]: item for item in checked["assets"]}
    catalog = json.loads(CATALOG.read_text())
    assets = []
    for asset in catalog["assets"]:
        actual = by_file[asset["file"]]
        info = json.loads((directory / (asset["file"] + ".ffprobe.json")).read_text())
        video = [stream for stream in info["streams"] if stream["codec_type"] == "video"]
        require(len(video) == 1 and video[0]["width"] == 3840 and video[0]["height"] == 2160,
                "Acquired high-resolution input must be native 3840×2160")
        assets.append({**asset, "path": str((FIXTURES / "HighResolution" / asset["file"]).relative_to(ROOT)),
                       "sha256": actual["sha256"], "bytes": actual["bytes"], "video": video[0],
                       "verification": actual["verification"]})
    path = directory / "verified-manifest.json"
    save(path, {"schema": 1, "sourceCatalog": str(CATALOG.relative_to(ROOT)), "sourceCatalogSHA256": digest(CATALOG),
                "scope": "This run's verified compressed media and actual container SHA; not playback acceptance.",
                "assets": assets})
    return path


def plan(args, reports: Path, media_check: Path) -> list[tuple[str, list[str], int]]:
    script = lambda name: str(ROOT / "scripts" / name)
    result = [("verify-mpv", [PYTHON, script("bootstrap_mpv.py"), "--verify"], 180),
              ("verify-media-tools", [PYTHON, script("bootstrap_media_tools.py"), "--verify"], 180),
              ("verify-web-tools", [PYTHON, script("bootstrap_web_tools.py"), "--verify"], 180)]
    if not args.skip_high_resolution:
        command = [PYTHON, script("download_test_media.py"), "--check", "--output", str(media_check)]
        if args.strict_container:
            command.append("--strict-container")
        result.append(("download-check", command, 600))
    if args.prepare_fixtures:
        result.append(("prepare-fixtures", [PYTHON, script("run_full_tests.py"), "--_prepare-fixtures"], 1800))
    if not args.skip_expanded_media:
        if args.prepare_fixtures:
            result.append(("prepare-expanded-media", [PYTHON, script("verify_extended_media.py"), "--prepare"], 1800))
        result.append(("check-expanded-media", [PYTHON, script("verify_extended_media.py"), "--check-only",
                                               "--report-directory", str(reports / "expanded-media")], 300))
    result += [("multi-track-fixture", [PYTHON, script("make_fulltest_fixtures.py"), "--check",
                                        "--report", str(reports / "fixtures/multi-track.json")], 90),
               ("core", ["bash", script("test_core.sh")], 600),
               ("queue-native", ["bash", script("test_queue.sh"), str(reports / "modules/queue-list02")], 600),
               ("module-boundaries", ["bash", script("test_module_boundaries.sh"), str(reports / "module-boundaries")], 600),
               ("media-tools-api", [PYTHON, script("bootstrap_media_tools.py"), "--verify", "--api-smoke"], 600),
               ("audio-signals", ["bash", script("test_audio_signals.sh"), "--library", str(ROOT / "Vendor/lib/libmpv.2.dylib"), "--report-directory", str(reports / "audio-signals"), "--keep-wav"], 600)]
    for name in ("network", "capture_encoding", "input", "thumbnails", "subtitle_translation", "advanced_controls"):
        result.append((name.replace("_", "-"), ["bash", script("test_" + name + ".sh"), str(reports / "modules")], 600))
    result += [("web-media-module", ["bash", script("test_web_media.sh"), str(reports / "modules/web-media")], 600),
               ("mpv-command-options", ["bash", script("test_mpv_command_options.sh")], 120),
               ("web-extractor-processes", ["bash", script("test_web_extractor.sh"), str(reports / "modules/web-extractor")], 180)]
    result += [("epg-module", ["bash", script("test_epg.sh"), str(reports / "modules/epg")], 600),
               ("media-preferences-module", ["bash", script("test_media_preferences.sh"), str(reports / "modules/media-preferences")], 600),
               ("media-preferences-controller", ["bash", script("test_media_preferences_controller.sh"), str(reports / "modules/media-preferences-controller")], 600),
               ("system-pip-lifecycle-module", ["bash", script("test_system_pip_lifecycle.sh"), str(reports / "modules/system-pip-lifecycle")], 600)]
    result.append(("native-audio-queue-module", ["bash", script("test_native_audio_queue.sh"), str(reports / "modules/native-audio-queue")], 600))
    if not args.skip_build:
        result.append(("build", ["bash", script("build_app.sh")], 1800))
    result += [("screenshot-publication", ["bash", script("test_screenshot_publication.sh"), str(reports / "modules/screenshot-publication-results.txt")], 120),
               ("screenshot-preferences", ["bash", script("test_screenshot_preferences.sh")], 120),
               ("user-video-filters", ["bash", script("test_user_video_filters.sh"), str(reports / "modules")], 300),
               ("app-integration", [PYTHON, script("verify_playback.py"), "--report-directory", str(reports / "app")], 1200),
               ("lifecycle", [PYTHON, script("verify_lifecycle.py"), "--report-directory", str(reports / "lifecycle")], 240),
               ("formats", [PYTHON, script("verify_formats.py"), "--mode", "all", "--app", str(args.app),
                            "--summary", str(reports / "formats/summary.json")], 1800)]
    result += [("ts-seek", [PYTHON, script("verify_ts_seek.py"), "--expected-app-sha256", "{APP_EXECUTABLE_SHA256}",
                            "--report-directory", str(reports / "ts-seek")], 300),
               ("async-screenshots", [PYTHON, script("verify_async_screenshots.py"), "--app", str(args.app), "--fixture", str(FIXTURES / "HighResolution/apple-tv-trailer_hevc-main10_sdr_4k24.mp4"), "--expected-app-sha256", "{APP_EXECUTABLE_SHA256}",
                                     "--report-directory", str(reports / "async-screenshots")], 300)]
    result.append(("filter-runtime-fallback", [PYTHON, script("verify_filter_runtime_failure.py"),
                                              "--report-directory", str(reports / "runtime-filter")], 90))
    result += [("web-media", [PYTHON, script("verify_web_media.py"), "--app", str(args.app),
                              "--expected-app-sha256", "{APP_EXECUTABLE_SHA256}",
                              "--report-directory", str(reports / "web-media")], 600),
               ("playback-intent", [PYTHON, script("verify_playback_intent.py"), "--app", str(args.app),
                                    "--expected-app-sha256", "{APP_EXECUTABLE_SHA256}",
                                    "--fixture", str(FIXTURES / "NativeUI/UI 手工 06 长片 H264.mp4"),
                                    "--second-fixture", str(FIXTURES / "extended/hevc-720p.mp4"),
                                    "--report-directory", str(reports / "playback-intent")], 240)]
    result.append(("epg", [PYTHON, script("verify_epg.py"), "--app", str(args.app),
                           "--expected-app-sha256", "{APP_EXECUTABLE_SHA256}",
                           "--report-directory", str(reports / "epg")], 300))
    result.append(("diagnostic-privacy", [PYTHON, script("verify_diagnostic_privacy.py"), "--app", str(args.app),
                          "--expected-app-sha256", "{APP_EXECUTABLE_SHA256}",
                          "--report-directory", str(reports / "diagnostic-privacy")], 180))
    result.append(("system-pip", [PYTHON, script("verify_system_pip.py"), "--app", str(args.app),
                          "--expected-app-sha256", "{APP_EXECUTABLE_SHA256}",
                          "--report-directory", str(reports / "system-pip")], 360))
    result.append(("media-profile", [PYTHON, script("verify_media_profile.py"), "--app", str(args.app),
                          "--expected-app-sha256", "{APP_EXECUTABLE_SHA256}",
                          "--report-directory", str(reports / "media-profile")], 480))
    result += [("native-audio-queue", [PYTHON, script("verify_native_audio_queue.py"), "--app", str(args.app),
                                     "--expected-app-sha256", "{APP_EXECUTABLE_SHA256}",
                                     "--report-directory", str(reports / "native-audio-queue")], 480),
               ("live-asr", [PYTHON, script("verify_live_asr_app.py"), "--app", str(args.app),
                             "--expected-app-sha256", "{APP_EXECUTABLE_SHA256}",
                             "--fixture-root", str(FIXTURES / "LiveASR"),
                             "--report-directory", str(reports / "live-asr")], 360)]
    if not args.skip_expanded_media:
        result.append(("expanded-media", [PYTHON, script("verify_extended_media.py"),
                                           "--report-directory", str(reports / "expanded-media")], 1800))
    if not args.skip_high_resolution:
        command = [PYTHON, script("verify_high_resolution.py"), "--report-directory", str(reports / "high-resolution"),
                   "--manifest", str(reports / "media-check/verified-manifest.json")]
        if args.skip_soak:
            command.append("--skip-soak")
        result.append(("high-resolution", command, 2200))
    # Every actual application stage receives the same explicit target and the
    # same run-wide hash. Helpers must never fall back to the old default app.
    for name, command, _ in result:
        if name in APP_STAGES:
            if "--app" not in command:
                command += ["--app", str(args.app)]
            pin = args.expected_app_sha256 or "{APP_EXECUTABLE_SHA256}"
            if "--expected-app-sha256" in command:
                command[command.index("--expected-app-sha256") + 1] = pin
            else:
                command += ["--expected-app-sha256", pin]
    return result


def preflight(args, reports: Path, media_check: Path) -> list[str]:
    problems = []
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        problems.append("Apple Silicon macOS is required")
    if platform.mac_ver()[0] and int(platform.mac_ver()[0].split(".")[0]) < 14:
        problems.append("macOS 14 or later is required")
    if sys.flags.optimize:
        problems.append("Use Python without -O/-OO; assertions are part of the playback acceptance checks")
    if reports.exists():
        problems.append(f"Report directory already exists; use a NEW path: {reports}")
    for command in ("bash", "swift", "swiftc", "xcrun", "codesign", "lipo", "say"):
        if not shutil.which(command):
            problems.append("Missing command: " + command)
    required = [ROOT / "Vendor/manifest.json", ROOT / "Vendor/lib/libmpv.dylib", ROOT / "Vendor/lib/libmpv.2.dylib",
                ROOT / "Vendor/tools/manifest.json", ROOT / "Vendor/tools/ffmpeg", ROOT / "Vendor/tools/ffprobe",
                ROOT / "Vendor/tools/whisper-cli", ROOT / "Vendor/tools/ggml-base.bin", CATALOG,
                ROOT / "Vendor/WebTools/manifest.json", ROOT / "Vendor/WebTools/yt-dlp/yt-dlp_macos", ROOT / "Vendor/WebTools/deno",
                FIXTURES / "WebPages/manifest.json", FIXTURES / "WebPages/progressive.html", FIXTURES / "WebPages/dash.html",
                FIXTURES / "NativeUI/UI 手工 06 长片 H264.mp4",
                ROOT / "Vendor/LiveASR/manifest.json", ROOT / "Vendor/LiveASRModel/model-manifest.json",
                ROOT / "Resources/live-asr-package-pins.json", FIXTURES / "LiveASR/manifest.json",
                FIXTURES / "LiveASR/follow 中文 实时字幕.mov", FIXTURES / "LiveASR/controls 中文 实时字幕.mov",
                FIXTURES / "中文 测试 H264.png",
                FIXTURES / "HighResolution/apple-tv-trailer_hevc-main10_sdr_4k24.mp4"]
    if args.skip_build:
        required.append(app_executable(args.app))
    if not args.prepare_fixtures:
        required += [FIXTURES / name for name in BASE_FILES + NETWORK_FILES + hls_files()]
        required += [FIXTURES / "FullTest/多音轨双字幕.mkv", FIXTURES / "FullTest/English.srt",
                     FIXTURES / "extended/manifest.json", FIXTURES / "extended/format-validation.srt"]
        manifest = FIXTURES / "extended/manifest.json"
        if manifest.is_file():
            try:
                cases = json.loads(manifest.read_text())["cases"]
                if {item["id"] for item in cases} != EXTENDED_IDS:
                    problems.append("Extended fixtures must include all 11 format IDs")
                required += [ROOT / item["path"] for item in cases]
            except (ValueError, KeyError, TypeError) as error:
                problems.append("Invalid extended fixture manifest: " + str(error))
    if not args.skip_high_resolution and CATALOG.is_file():
        required += [FIXTURES / "HighResolution" / item["file"] for item in json.loads(CATALOG.read_text())["assets"]]
    if not args.skip_expanded_media and not args.prepare_fixtures:
        expanded = FIXTURES / "ExpandedMedia/manifest.json"
        required.append(expanded)
        if expanded.is_file():
            try:
                expanded_cases = json.loads(expanded.read_text())["cases"]
                if len(expanded_cases) != 13 or len({item["id"] for item in expanded_cases}) != 13:
                    problems.append("Expanded media requires all 13 unique fixture IDs")
                required += [ROOT / item["path"] for item in expanded_cases]
            except (ValueError, KeyError, TypeError) as error:
                problems.append("Invalid expanded-media manifest: " + str(error))
    problems += ["Missing prerequisite: " + (str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path))
                 for path in required if not path.is_file()]
    for _, command, _ in plan(args, reports, media_check):
        path = Path(command[1])
        if not path.is_file():
            problems.append("Missing script: " + str(path))
    return problems


def run_step(name: str, command: list[str], seconds: int, reports: Path, app: Path, app_hash: str | None) -> dict:
    if name in APP_STAGES:
        require(app_hash is not None and digest(app_executable(app)) == app_hash,
                "Selected application changed before stage " + name)
    command = [app_hash if value == "{APP_EXECUTABLE_SHA256}" else value for value in command]
    print(f"RUN {name}: {shlex.join(command)}", flush=True)
    log_path = reports / "logs" / (name + ".txt")
    start = time.monotonic()
    result = {"id": name, "command": command, "log": str(log_path.relative_to(reports)), "status": "failed"}
    try:
        with log_path.open("w", encoding="utf-8") as log:
            # A new process group lets cancellation stop the script's child app,
            # local HTTP servers, and encoders rather than leaving them behind.
            process = subprocess.Popen(command, cwd=ROOT, env=environment(app), stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                deadline = time.monotonic() + seconds
                while process.poll() is None:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired(command, seconds)
                    try:
                        process.wait(timeout=min(30, remaining))
                    except subprocess.TimeoutExpired:
                        if time.monotonic() >= deadline:
                            raise
                        print(f"RUN {name}: {time.monotonic() - start:.0f}s; log: {log_path}", flush=True)
            except BaseException:
                import signal
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                raise
        result["exitCode"] = process.returncode
        if process.returncode == 0:
            result["status"] = "passed"
        else:
            result["error"] = f"Script exited {process.returncode}"
        if name in APP_STAGES and digest(app_executable(app)) != app_hash:
            result.update(status="failed", error="Selected application changed during stage " + name)
    except subprocess.TimeoutExpired:
        result["error"] = f"Stage exceeded {seconds}s and its process group was terminated"
    result["wallSeconds"] = round(time.monotonic() - start, 3)
    print(f"{result['status'].upper()} {name}; log: {log_path}", flush=True)
    if result["status"] != "passed":
        print(log_path.read_text(errors="replace")[-5000:], flush=True)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report-directory", type=Path, help="Must be a new directory; default uses UTC timestamp + PID")
    parser.add_argument("--check-only", action="store_true", help="Read-only file/platform preflight and print commands")
    parser.add_argument("--prepare-fixtures", action="store_true", help="Generate missing local fixtures, preserving existing files; first extended run may download pinned small samples")
    parser.add_argument("--skip-high-resolution", action="store_true", help="Skip the four real 4K files' acquisition check and playback tests")
    parser.add_argument("--skip-expanded-media", action="store_true", help="Omit the 13 expanded sources and 26 playback scenarios; this is a partial suite")
    parser.add_argument("--skip-soak", action="store_true", help="Keep real 4K checks, omit the 600-second soak; this is a partial suite")
    parser.add_argument("--strict-container", action="store_true", help="Use acquisition --check --strict-container instead of accepted compressed-packet identity")
    parser.add_argument("--app", type=Path, default=APP, help="Selected .app bundle or executable; default dist/SiliconPlayer-development.app")
    parser.add_argument("--expected-app-sha256", type=expected_sha256, help="Pin the selected executable externally; otherwise its SHA is pinned once for this run")
    parser.add_argument("--skip-build", action="store_true", help="Test the selected existing app without rebuilding it; requires a prebuilt app")
    parser.add_argument("--_prepare-fixtures", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    args.app = args.app.expanduser().resolve()
    if not args.skip_build and args.app.suffix.lower() != ".app":
        parser.error("An executable --app path requires --skip-build; build output must be a .app bundle")
    if args._prepare_fixtures:
        prepare_fixtures()
        return 0
    require(not (args.skip_soak and args.skip_high_resolution), "--skip-soak is unnecessary with --skip-high-resolution")
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    reports = (args.report_directory or ROOT / "Docs/FullTest-Reruns" / f"{timestamp}-{os.getpid()}").resolve()
    # This workspace can be exFAT. Symlinks exist only on APFS, never in Docs.
    media_check = Path("/private/tmp") / f"siliconplayer-media-check-{timestamp}-{os.getpid()}"
    problems = preflight(args, reports, media_check)
    print(f"Evidence directory: {reports}")
    print(f"Selected app: {args.app}")
    if not args.skip_build:
        print(f"Build output (SILICONPLAYER_OUTPUT_APP): {args.app}")
    for name, command, _ in plan(args, reports, media_check):
        print(f"  {name}: {shlex.join(command)}")
    for error in problems:
        print("PRECHECK FAILED: " + error, file=sys.stderr)
    if problems:
        print("See Docs/FullTest-2026-10-04/REPRODUCE.md for dependency/media preparation.", file=sys.stderr)
        return 1
    if args.check_only:
        print("PASS static prerequisites; no hashes, tests, build, network, files or application launches performed.")
        return 0
    app_hash = digest(app_executable(args.app)) if args.skip_build else None
    require(app_hash is None or not args.expected_app_sha256 or app_hash == args.expected_app_sha256,
            "Selected executable does not match --expected-app-sha256")
    running = subprocess.run(["pgrep", "-x", "SiliconPlayer"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(running.returncode == 1, "Close existing SiliconPlayer processes before serial QA; no process was killed")
    reports.mkdir(parents=True, exist_ok=False)
    for name in ("logs", "fixtures", "modules", "module-boundaries", "app", "lifecycle", "formats", "high-resolution", "media-check", "expanded-media", "runtime-filter", "ts-seek", "async-screenshots", "audio-signals"):
        (reports / name).mkdir()
    summary = {"startedUTC": datetime.now(timezone.utc).isoformat(), "options": vars(args) | {"report_directory": str(reports), "app": str(args.app)},
               "app": str(args.app), "appExecutable": str(app_executable(args.app)), "appSHA256": app_hash,
               "results": [], "status": "running", "scope": "Serial repository scripts; omitted stages and module limitations remain explicit.",
               "sourceSHA256": {}}
    try:
        if not args.skip_high_resolution:
            media_check.mkdir(exist_ok=False)
            catalog = json.loads(CATALOG.read_text())
            for asset in catalog["assets"]:
                (media_check / asset["file"]).symlink_to(FIXTURES / "HighResolution" / asset["file"])
        summary["sourceSHA256"] = source_inputs()
        save(reports / "run-summary.json", summary)
        for name, command, seconds in plan(args, reports, media_check):
            if name == "media-tools-api":
                validation = ROOT / "Vendor/tools/validation"
                # Same filesystem rename avoids copying the old evidence and
                # keeps a hard-kill backup outside the application's Tools bundle.
                backup = FIXTURES / f".validation-before-qa-{timestamp}-{os.getpid()}"
                require(not backup.exists(), f"Preserved validation backup already exists: {backup}")
                existed = validation.exists()
                if existed:
                    validation.rename(backup)
                try:
                    result = run_step(name, command, seconds, reports, args.app, app_hash)
                finally:
                    try:
                        if validation.exists():
                            shutil.copytree(validation, reports / "modules/media-tools-output")
                    finally:
                        if validation.exists():
                            remove_tree_missing_ok(validation)
                        if existed:
                            backup.rename(validation)
            else:
                result = run_step(name, command, seconds, reports, args.app, app_hash)
            summary["results"].append(result)
            if name == "download-check":
                # Copy only small metadata; never copy or package the linked media.
                for path in media_check.iterdir():
                    if path.is_file() and not path.is_symlink():
                        shutil.copyfile(path, reports / "media-check" / path.name)
                if result["status"] == "passed":
                    verified_highres_manifest(reports / "media-check")
            if name == "build" and result["status"] == "passed":
                app_hash = digest(app_executable(args.app))
                require(not args.expected_app_sha256 or app_hash == args.expected_app_sha256,
                        "Built executable does not match --expected-app-sha256")
                summary["appSHA256"] = app_hash
            save(reports / "run-summary.json", summary)
            if result["status"] != "passed":
                summary["status"] = "failed"
                break
        else:
            summary["status"] = "passed"
    except KeyboardInterrupt:
        summary["status"] = "cancelled"
    except (OSError, ValueError, RuntimeError) as error:
        summary["status"] = "failed"
        summary["error"] = str(error)
        print("FAILED: " + str(error), file=sys.stderr)
    finally:
        summary["sourceSHA256End"] = source_inputs()
        if summary["sourceSHA256End"] != summary["sourceSHA256"]:
            summary.update(status="failed", error="Source/test/build inputs changed during the full run")
        if app_hash is not None:
            summary["appSHA256End"] = digest(app_executable(args.app)) if app_executable(args.app).is_file() else None
            if summary["appSHA256End"] != app_hash:
                summary.update(status="failed", error="Selected executable changed during the full run")
        if media_check.exists():
            shutil.rmtree(media_check)
        summary["finishedUTC"] = datetime.now(timezone.utc).isoformat()
        save(reports / "run-summary.json", summary)
    print(f"{summary['status'].upper()}: {reports / 'run-summary.json'}")
    return 0 if summary["status"] == "passed" else 130 if summary["status"] == "cancelled" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as error:
        raise SystemExit(f"Full-test runner error: {error}")
