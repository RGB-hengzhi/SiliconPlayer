#!/usr/bin/env python3
"""Hash-pinned actual application tests of local HTML5/DASH and process cleanup.

No native UI events, user-process cleanup, app builds or fixture mutation.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
MODES = ("web-media", "web-quit-resolver", "web-quit-hook")


def redact_line(line):
    if re.search(r'(?i)\b(authorization|set-cookie|cookies?|x-api-key|api-key|token|signature)\b', line):
        return "[credential-bearing diagnostic omitted]\n"
    # Signed CDN credentials can occur in paths and escaped queries/userinfo.
    # Omit the complete URL token instead of retaining any of its components.
    return re.sub(r'''https?(?::|\\u003a)[^\s"'<>]*''', '[URL omitted]', line, flags=re.IGNORECASE)


def public_evidence(value):
    if isinstance(value, str):
        return redact_line(value).rstrip('\n')
    if isinstance(value, list):
        return [public_evidence(item) for item in value]
    if isinstance(value, dict):
        return {key: public_evidence(item) for key, item in value.items()}
    return value


def write_redacted_stream(stream, log):
    while True:
        line = stream.readline(262145)
        if not line:
            break
        try:
            if len(line) > 262144:
                while line and not line.endswith(b"\n"):
                    line = stream.readline(262145)
                log.write("[overlong diagnostic omitted]\n")
            else:
                log.write(redact_line(line.decode("utf-8", errors="replace")))
            log.flush()
        except (OSError, ValueError):
            # A failed run can close the evidence handle while owned-process
            # cleanup drains its final output. No raw fallback file is written.
            continue


def require(value, message):
    if not value:
        raise RuntimeError(message)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1048576), b""):
            h.update(chunk)
    return h.hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def tree_files(directory):
    return {str(p.relative_to(directory)): {"SHA256": digest(p), "bytes": p.stat().st_size}
            for p in sorted(directory.rglob("*")) if p.is_file() and not any(v.startswith("._") for v in p.relative_to(directory).parts)}


def process_snapshot():
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,pgid=,command="], text=True)
    result = {}
    for line in output.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) == 4:
            result[int(parts[0])] = {"pid": int(parts[0]), "ppid": int(parts[1]), "pgid": int(parts[2]), "command": parts[3]}
    return result


def observed_identity(snapshot, pid, row):
    current = snapshot.get(pid)
    return (current is not None and current["pgid"] == row["pgid"]
            and (current["command"] == row["command"] or "<defunct>" in current["command"]))


def system_uptime():
    # macOS Python 3.9 time.monotonic() has a process-local origin. Darwin's
    # CLOCK_UPTIME_RAW shares the boot-relative clock used by systemUptime.
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


def run_case(app, name, output, fixture_directory, local, public_url=None):
    output.mkdir()
    spec = importlib.util.spec_from_file_location("web_media_fixture", ROOT / "Tests/Integration/web_media_fixture.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    server = module.WebMediaServer(fixture_directory, output / "requests.json")
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f"http://127.0.0.1:{server.server_port}"
    report = output / "verification.json"
    process = None
    seen, observations = {}, []
    failure, data = None, None
    forced_cleanup = []
    remaining_after_cleanup = []
    started = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix="siliconplayer-web-profile-") as profile:
            write(Path(profile) / "preferences.json", {"autoplay": False})
            env = {k: v for k, v in os.environ.items() if not k.startswith("SILICONPLAYER_VERIFY_")}
            env.update(SILICONPLAYER_VERIFY_REPORT=str(report), SILICONPLAYER_VERIFY_MODE=name,
                       SILICONPLAYER_VERIFY_EXIT="1", SILICONPLAYER_VERIFY_STORAGE=profile,
                       SILICONPLAYER_VERIFY_WEB_ORIGIN=origin,
                       SILICONPLAYER_VERIFY_WEB_REQUEST_LOG=str(output / "requests.json"),
                       SILICONPLAYER_VERIFY_WEB_LOCAL=str(local))
            if public_url:
                env["SILICONPLAYER_VERIFY_WEB_PUBLIC"] = public_url
            with (output / "application.log").open("w") as log:
                process = subprocess.Popen([str(app)], stdout=subprocess.PIPE if public_url else log,
                                           stderr=subprocess.STDOUT, env=env, start_new_session=True)
                pump = None
                if public_url:
                    pump = threading.Thread(target=write_redacted_stream, args=(process.stdout, log), daemon=True)
                    pump.start()
                while process.poll() is None:
                    require(time.monotonic() - started < 160, "Application test timeout")
                    snapshot = process_snapshot()
                    owned = {process.pid}
                    while True:
                        children = {pid for pid, row in snapshot.items() if row["ppid"] in owned}
                        if children <= owned:
                            break
                        owned |= children
                    rows = [snapshot[pid] for pid in sorted(owned) if pid in snapshot and pid != process.pid]
                    for row in rows:
                        # Persist only this explicitly spawned application's children.
                        seen[row["pid"]] = row
                    # A known child changing to <defunct> still exists and has
                    # not been reaped. Include that same-PID/PGID transition.
                    survivors = [snapshot[pid] for pid, row in seen.items() if observed_identity(snapshot, pid, row)]
                    observations.append({"elapsedSeconds": time.monotonic() - started, "bootUptimeSeconds": system_uptime(),
                                         "children": rows, "ownedSurvivors": survivors})
                    time.sleep(.075)
                require(process.returncode == 0 and report.is_file(), "App did not exit successfully with report")
                if pump:
                    pump.join(timeout=5)
                    require(not pump.is_alive(), "Public diagnostic pipe did not close")
                data = json.loads(report.read_text())
                require(data.get("webMediaPassed") is True and not data.get("failure"), "App verification failed: " + str(data.get("failure")))
                observed_rows = [child for sample in observations for child in sample["children"]]
                require(any("yt-dlp_macos" in r["command"] for r in observed_rows), "No actual bundled extractor subprocess observed")
                remaining = []
                for _ in range(30):
                    snapshot = process_snapshot()
                    remaining = [snapshot[pid] for pid, row in seen.items() if observed_identity(snapshot, pid, row)]
                    if not remaining:
                        break
                    time.sleep(.1)
                require(not remaining, "Observed application children survived normal AppKit exit")
                for filename in ("queue.json", "history.json", "preferences.json", "web-media-preferences.json"):
                    file = Path(profile) / filename
                    if not public_url and file.is_file():
                        # Only controlled loopback URLs and fixture paths occur here.
                        (output / ("profile-" + filename)).write_bytes(file.read_bytes())
                if name == "web-media":
                    labels = {r["name"] for r in data["webMediaObservations"]}
                    expected = {"real-html-metadata", "unknown-size-auto-video", "progressive-explicit-play", "manual-subtitle-and-original-queue",
                                "paused-format-switch", "rapid-paused-format-replacement", "resume-switched-format", "playing-format-switch",
                                "dash-separate-video-audio", "known-web-url-reopens-from-library-path", "legacy-queue-restores-known-web-preferences", "stop-cancels-hook-without-resurrection",
                                "local-replaces-pending-web", "cancel-preparser-and-resolve-again", "private-mpv-config-directory"}
                    require(labels == expected, "Missing or duplicate web scenario observations")
                    require(len(data["webMediaObservations"]) == len(expected) == data["webMediaObservationCount"],
                            "Web observation counts contain duplicates or disagree")
                    require((output / "web-subtitle.png").is_file(), "Rendered subtitle image missing")
                    stop_row = next(r for r in data["webMediaObservations"] if r["name"] == "stop-cancels-hook-without-resurrection")
                    stop_at = stop_row["stopAtSystemUptime"]
                    slow_children = {r["pid"] for r in observed_rows if "slow-stop/progressive.html" in r["command"]}
                    require(slow_children, "No real hook subprocess observed during Stop case")
                    while True:
                        descendants = {r["pid"] for r in observed_rows if r["ppid"] in slow_children}
                        if descendants <= slow_children:
                            break
                        slow_children |= descendants
                    stable = [r for r in observations if stop_at + 2 <= r["bootUptimeSeconds"] <= stop_at + 6]
                    require(stable and all(not any(c["pid"] in slow_children for c in r["ownedSurvivors"]) for r in stable),
                            "Stop did not promptly reap its observed hook subprocess")
                if name == "web-quit-resolver":
                    require(any(r.get("resolverJobsActive") for r in data["webMediaObservations"]), "Quit lacked active pre-parser")
                if name == "web-quit-hook":
                    require(any(r["name"] == "quit-with-hook-active" and r["isLoading"] and not r["loaded"] for r in data["webMediaObservations"]), "Quit lacked active hook")
                if name == "web-public":
                    require(len(data["webMediaObservations"]) == 1 and (output / "public-video.png").is_file(), "Public real playback/image missing")
    except Exception as error:
        failure = str(error)
    finally:
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=5)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
        if failure:
            # Failed developer tests may be force-closed. Independent resolver
            # groups are cleaned only while an observed child still has the
            # exact recorded command and group; never select user processes.
            snapshot = process_snapshot()
            groups = {row["pgid"] for pid, row in seen.items()
                      if pid in snapshot and snapshot[pid]["command"] == row["command"]
                      and snapshot[pid]["pgid"] == row["pgid"]}
            for group in groups:
                try:
                    os.killpg(group, signal.SIGTERM)
                    forced_cleanup.append(group)
                except ProcessLookupError:
                    pass
            time.sleep(.3)
            snapshot = process_snapshot()
            remaining_groups = {row["pgid"] for pid, row in seen.items()
                                if pid in snapshot and snapshot[pid]["command"] == row["command"]
                                and snapshot[pid]["pgid"] == row["pgid"]}
            for group in remaining_groups:
                try:
                    os.killpg(group, signal.SIGKILL)
                    forced_cleanup.append({"group": group, "signal": "SIGKILL"})
                except ProcessLookupError:
                    pass
            time.sleep(.3)
            snapshot = process_snapshot()
            remaining_after_cleanup = [row for pid, row in seen.items() if pid in snapshot
                                       and snapshot[pid]["command"] == row["command"]
                                       and snapshot[pid]["pgid"] == row["pgid"]]
        server.shutdown()
        server.server_close()
        write(output / "child-process-observations.json", public_evidence(observations) if public_url else observations)
    result = {"name": name, "passed": failure is None, "failure": failure,
              "applicationPID": process.pid if process else None, "exitCode": process.returncode if process else None,
              "elapsedSeconds": time.monotonic() - started, "observedChildren": list(seen.values()),
              "forcedCleanupGroups": forced_cleanup,
              "remainingObservedChildrenAfterFailedRunCleanup": remaining_after_cleanup,
              "observationCount": data.get("webMediaObservationCount") if data else None,
              "scope": "Real application APIs/processes/render frames; no physical/native input-event acceptance"}
    if public_url:
        result = public_evidence(result)
    write(output / "summary.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--expected-app-sha256", required=True)
    parser.add_argument("--report-directory", type=Path, required=True)
    parser.add_argument("--mode", choices=MODES, action="append")
    parser.add_argument("--public-page", action="append", help="Explicit anonymous public page; each is one actual playback group")
    args = parser.parse_args()
    app = args.app.resolve()
    bundle = app if app.suffix == ".app" else app.parents[2]
    if app.suffix == ".app":
        app /= "Contents/MacOS/SiliconPlayer"
    require(re.fullmatch("[0-9a-fA-F]{64}", args.expected_app_sha256), "Expected hash invalid")
    require(app.is_file() and digest(app) == args.expected_app_sha256.lower(), "Candidate SHA mismatch")
    output = args.report_directory.resolve()
    require(not output.exists() or not any(output.iterdir()), "Preserve previous evidence; report directory must be new/empty")
    output.mkdir(parents=True, exist_ok=True)
    fixture_directory = ROOT / "Tests/Fixtures/WebPages"
    local = ROOT / "Tests/Fixtures/中文 测试 H264.mp4"
    before = {"bundle": tree_files(bundle), "sources": tree_files(ROOT / "Sources"),
              "fixtures": tree_files(fixture_directory), "localFixture": digest(local),
              "wrapper": digest(Path(__file__).resolve()),
              "server": digest(ROOT / "Tests/Integration/web_media_fixture.py")}
    write(output / "inputs-before.json", before)
    rows = []
    if args.public_page:
        require(not args.mode, "Choose controlled modes or explicit public pages in separate evidence runs")
        for index, address in enumerate(args.public_page):
            parsed = urlsplit(address)
            require(parsed.scheme in ("http", "https") and parsed.hostname and not parsed.username and not parsed.password,
                    "Public page requires uncredentialed HTTP/HTTPS")
            rows.append(run_case(app, "web-public", output / f"public-{index + 1}", fixture_directory, local, address))
    else:
        rows = [run_case(app, mode, output / mode, fixture_directory, local) for mode in (args.mode or MODES)]
    after = {"bundle": tree_files(bundle), "sources": tree_files(ROOT / "Sources"),
             "fixtures": tree_files(fixture_directory), "localFixture": digest(local),
             "wrapper": digest(Path(__file__).resolve()), "server": digest(ROOT / "Tests/Integration/web_media_fixture.py")}
    write(output / "inputs-after.json", after)
    passed = all(r["passed"] for r in rows) and before == after
    summary = {"recordedUTC": datetime.now(timezone.utc).isoformat(), "passed": passed,
               "scenarioCount": len(rows), "passedScenarios": sum(r["passed"] for r in rows),
               "inputsUnchanged": before == after, "appSHA256": digest(app), "rows": rows}
    write(output / "summary.json", summary)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
