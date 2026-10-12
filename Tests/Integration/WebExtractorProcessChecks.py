#!/usr/bin/env python3
"""Compile and exercise the real C guardian with an owned, local process tree."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/WebExtractor/main.c"
FAKE_HELPER = r'''#!/usr/bin/python3
import json, os, signal, sys, time
from pathlib import Path
mode, logfile = sys.argv[1:3]
def record(role):
    value = {"role": role, "pid": os.getpid(), "ppid": os.getppid(), "pgid": os.getpgid(0),
             "argv": sys.argv[1:], "temporary": os.environ.get("TMPDIR"), "environment": dict(os.environ)}
    fd = os.open(logfile, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    os.write(fd, (json.dumps(value, ensure_ascii=False) + "\n").encode())
    os.close(fd)
def idle():
    while True: time.sleep(0.1)
if mode in ("tree", "noisy", "normal-tree"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
record("worker")
if mode in ("tree", "noisy", "normal-tree"):
    child = os.fork()
    if child == 0:
        grandchild = os.fork()
        if grandchild == 0:
            record("grandchild"); idle()
        record("child"); idle()
    if mode == "noisy":
        block = b"x" * (1024 * 1024)
        while True: os.write(1, block)
    if mode == "tree": idle()
    if mode == "normal-tree":
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            rows = [json.loads(line) for line in Path(logfile).read_text().splitlines() if line]
            if {"worker", "child", "grandchild"} <= {row["role"] for row in rows}: break
            time.sleep(0.01)
        else: sys.exit(42)
if mode == "symlink":
    base = Path(os.environ["TMPDIR"])
    (base / "nested" / "child").mkdir(parents=True)
    (base / "nested" / "child" / "cache.txt").write_text("owned")
    (base / "external-link").symlink_to(sys.argv[3], target_is_directory=True)
os.write(1, "payload 中文\n".encode())
os.write(2, "diagnostic 中文\n".encode())
sys.exit(37 if mode == "failure" else 0)
'''


def utc() -> str:
    return datetime.now(timezone.utc).isoformat()


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def process_state(pid: int) -> str:
    result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
    return result.stdout.strip()


def records(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def wait_records(path: Path, roles: set[str], timeout: float = 5) -> list[dict]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        rows = records(path)
        if roles <= {row["role"] for row in rows}:
            return rows
        time.sleep(0.02)
    raise AssertionError(f"Missing controlled helper roles: {roles}")


def wait_gone(pids: set[int], timeout: float = 6) -> dict[str, str]:
    deadline = time.monotonic() + timeout
    states: dict[str, str] = {}
    while time.monotonic() < deadline:
        states = {str(pid): state for pid in pids if (state := process_state(pid))}
        if not states:
            return states
        time.sleep(0.03)
    raise AssertionError(f"Owned processes remain (zombies also count): {states}")


def drain_bounded(process: subprocess.Popen, timeout: float = 8) -> tuple[int, int]:
    """Drain output without retaining it, checking the deadline even under heavy writes."""
    deadline = time.monotonic() + timeout
    counts = [0, 0]
    with selectors.DefaultSelector() as selector:
        for index, pipe in enumerate((process.stdout, process.stderr)):
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, index)
        while selector.get_map():
            assert time.monotonic() < deadline, "Controlled helper output exceeded cancellation deadline"
            for event, _ in selector.select(0.05):
                data = os.read(event.fileobj.fileno(), 65536)
                if data: counts[event.data] += len(data)
                else: selector.unregister(event.fileobj)
    process.wait(timeout=max(0.1, deadline - time.monotonic()))
    return counts[0], counts[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report_directory", nargs="?")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("These checks require Apple Silicon macOS")
    cache = Path.home() / "Library/Caches/SiliconPlayer/WebExtractorTests"
    cache.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="guardian-", dir=cache))
    report = Path(args.report_directory).expanduser().resolve() if args.report_directory else work / "report"
    if report.exists() and any(report.iterdir()):
        raise SystemExit("Report directory must be new or empty")
    report.mkdir(parents=True, exist_ok=True)
    result = {"schemaVersion": 1, "startedUTC": utc(), "source": str(SOURCE),
              "sourceSHA256": digest(SOURCE), "architecture": "arm64", "status": "running",
              "scope": "Real compiled guardian and owned fake-helper processes; no app, network, yt-dlp extraction or Deno solver run.",
              "results": [], "passed": 0, "failed": 0,
              "limits": ["Only descendants that remain in the owned worker process group are supervised.",
                         "Darwin reaps direct children here; orphaned grandchildren are reaped by the OS and must actually disappear in these checks.",
                         "Static architecture checks and internal PID/PGID observations are not extra scenario groups."]}
    active: list[subprocess.Popen] = []
    logs: list[Path] = []
    tools = work / "工具 中文: 空格,等号=WebTools"
    tools.mkdir()
    executable = tools / "web-extractor"
    helper = tools / "yt-dlp/yt-dlp_macos"
    helper.parent.mkdir()
    helper.write_text(FAKE_HELPER)
    helper.chmod(0o700)
    compile_command = ["xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=14.0", "-std=c11",
                       "-O2", "-Wall", "-Wextra", "-Werror", str(SOURCE), "-o", str(executable)]
    compiled = subprocess.run(compile_command, capture_output=True, text=True, timeout=60)
    (report / "build.log").write_text(compiled.stdout + compiled.stderr)
    result["compileCommand"] = compile_command
    result["compileExitCode"] = compiled.returncode
    if compiled.returncode != 0:
        result["status"] = "failed_compile"
        (report / "summary.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        return 1
    arches = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).strip()
    assert arches == "arm64", arches
    result["executableSHA256"] = digest(executable)
    result["actualArchitectures"] = arches
    shutil.copy2(executable, report / "compiled-web-extractor")
    shutil.copy2(SOURCE, report / "compiled-source.c")
    shutil.copy2(helper, report / "controlled-helper.py")

    def launch(name: str, mode: str, extras: list[str] | None = None,
               environment: dict[str, str] | None = None, entry: Path | None = None):
        log = report / (name + "-processes.jsonl")
        logs.append(log)
        argv = [str(entry or executable), mode, str(log), *(extras or [])]
        process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        active.append(process)
        return process, log, argv

    def observations(process: subprocess.Popen, log: Path) -> dict:
        rows = records(log)
        workers = [row for row in rows if row["role"] == "worker"]
        pids = {process.pid, *(row["pid"] for row in rows)}
        if workers:
            pids.add(workers[0]["ppid"])
            assert all(row["pgid"] == workers[0]["pid"] for row in rows), "Worker group identity changed"
            assert workers[0]["pid"] != process.pid
        states = wait_gone(pids)
        for worker in workers:
            assert not Path(worker["temporary"]).exists(), "Private temporary directory leaked"
        return {"wrapperPID": process.pid, "guardianPID": workers[0]["ppid"] if workers else None,
                "ownedHelperProcesses": rows, "finalProcessStates": states,
                "actualReturnCode": process.returncode}

    def check(name: str, function):
        started = time.monotonic()
        item = {"id": name, "status": "running"}
        try:
            item.update(function())
            item["status"] = "passed"
            result["passed"] += 1
            print("PASS web-extractor/" + name, flush=True)
        except Exception as error:
            item.update(status="failed", error=str(error))
            result["failed"] += 1
            print("FAIL web-extractor/" + name + ": " + str(error), flush=True)
        item["wallSeconds"] = time.monotonic() - started
        result["results"].append(item)
        (report / "summary.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")

    def completed(name: str, mode: str = "normal", extras=None, environment=None, entry=None, expected=0):
        process, log, argv = launch(name, mode, extras, environment, entry)
        out, err = process.communicate(timeout=12)
        (report / (name + "-stdout.bin")).write_bytes(out)
        (report / (name + "-stderr.bin")).write_bytes(err)
        assert process.returncode == expected, (process.returncode, err.decode(errors="replace"))
        assert out == "payload 中文\n".encode(), out[:200]
        assert err == "diagnostic 中文\n".encode(), err[:200]
        item = observations(process, log)
        if mode == "normal-tree":
            assert {"worker", "child", "grandchild"} <= {row["role"] for row in item["ownedHelperProcesses"]}
        item.update(argv=argv, stdoutSHA256=hashlib.sha256(out).hexdigest(), stderrSHA256=hashlib.sha256(err).hexdigest())
        return item

    def argv_integrity():
        extras = ["--", "中文 空格,=%", "literal$HOME`no-shell`", "https://example.invalid/video?a=1,b=2&c=中文"]
        item = completed("argument_integrity", extras=extras)
        assert item["ownedHelperProcesses"][0]["argv"][2:] == extras
        return item

    def environment_check():
        inherited = os.environ.copy()
        sentinels = {"HTTP_PROXY": "http://example.invalid:1", "HTTPS_PROXY": "http://example.invalid:2",
                     "ALL_PROXY": "http://example.invalid:3", "PYTHONPATH": "/invalid-inherited-python",
                     "PYTHONHOME": "/invalid-inherited-pythonhome", "DYLD_LIBRARY_PATH": "/invalid-inherited-dyld",
                     "NODE_OPTIONS": "--invalid-inherited-node", "DENO_DIR": "/invalid-inherited-deno",
                     "DENO_AUTH_TOKENS": "invalid-inherited-token", "WEB_EXTRACTOR_HELPER": "/invalid-helper-override"}
        inherited.update(sentinels)
        item = completed("minimum_environment", environment=inherited)
        worker = item["ownedHelperProcesses"][0]
        env = worker["environment"]
        for key, value in sentinels.items():
            assert key not in env or env[key] != value, key
        assert env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin"
        assert env["LANG"] == env["LC_ALL"] == "en_US.UTF-8"
        assert env["DENO_DIR"] == worker["temporary"] + "/deno"
        assert env["DENO_NO_UPDATE_CHECK"] == "1"
        assert not any(key.startswith(("PYTHON", "DYLD", "NODE")) for key in env)
        return item

    def missing_helper():
        directory = work / "missing-tools"
        directory.mkdir()
        entry = directory / "web-extractor"
        shutil.copy2(executable, entry)
        process, log, argv = launch("missing_helper", "normal", entry=entry)
        out, err = process.communicate(timeout=5)
        assert process.returncode == 127 and not out and b"missing or not executable" in err
        assert not records(log), "Missing-helper case unexpectedly spawned the helper"
        return {"argv": argv, "wrapperPID": process.pid, "actualReturnCode": process.returncode}

    def cancelled(name: str, requested_signal: int, mode: str = "tree"):
        process, log, argv = launch(name, mode)
        rows = wait_records(log, {"worker", "child", "grandchild"})
        if mode == "noisy": time.sleep(0.1)  # Do not read stdout: force pipe back-pressure.
        started = time.monotonic()
        process.send_signal(requested_signal)
        stdout_bytes, stderr_bytes = drain_bounded(process)
        assert process.returncode == -requested_signal
        item = observations(process, log)
        elapsed = time.monotonic() - started
        assert elapsed < 6, elapsed
        item.update(argv=argv, cancellationSeconds=elapsed, requestedSignal=requested_signal,
                    stdoutBytes=stdout_bytes, stderrBytes=stderr_bytes, rolesObservedBeforeSignal=[r["role"] for r in rows])
        return item

    def temporary_symlink():
        external = work / "protected-external"
        external.mkdir()
        protected = external / "keep.txt"
        protected.write_bytes(b"external destination stays unchanged\n")
        before = digest(protected)
        item = completed("temporary_cleanup_preserves_external_symlink_target", "symlink", [str(external)])
        assert digest(protected) == before
        item["externalTargetSHA256Unchanged"] = before
        return item

    def ascii_alias():
        alias = work / "ascii-alias"
        alias.symlink_to(executable)
        item = completed("realpath_alias_with_unicode_spaces_colon_comma", extras=["中文 参数,等号=冒号:"], entry=alias)
        assert item["ownedHelperProcesses"][0]["argv"][2:] == ["中文 参数,等号=冒号:"]
        item.update(aliasPath=str(alias), actualHelperPath=str(helper))
        return item

    try:
        check("normal_exit_and_descendant_cleanup", lambda: completed("normal_exit_and_descendant_cleanup", "normal-tree"))
        check("argument_integrity", argv_integrity)
        check("minimum_environment", environment_check)
        check("helper_exit_failure", lambda: completed("helper_exit_failure", "failure", expected=37))
        check("missing_helper", missing_helper)
        check("sigterm_wrapper_cleans_descendants", lambda: cancelled("sigterm_wrapper_cleans_descendants", signal.SIGTERM))
        check("sigkill_wrapper_cleans_descendants", lambda: cancelled("sigkill_wrapper_cleans_descendants", signal.SIGKILL))
        check("blocked_output_cancellation_deadline", lambda: cancelled("blocked_output_cancellation_deadline", signal.SIGKILL, "noisy"))
        check("temporary_cleanup_preserves_external_symlink_target", temporary_symlink)
        check("realpath_alias_with_unicode_spaces_colon_comma", ascii_alias)
    finally:
        # Terminate only direct children launched here. Their real guardian owns descendant cleanup.
        for process in active:
            if process.poll() is None:
                process.kill()
                try: drain_bounded(process)
                except subprocess.TimeoutExpired: pass
        # A failed guardian must not leave our controlled idle helpers behind.
        # Check the recorded PID's actual command against its unique log path;
        # never signal a process merely because a historic PID or PGID matches.
        cleanup = []
        for log in logs:
            rows = records(log)
            candidates = {row["pid"] for row in rows}
            candidates.update(row["ppid"] for row in rows if row["role"] == "worker")
            for pid in candidates:
                actual = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout.strip()
                if actual and str(log) in actual:
                    try:
                        os.kill(pid, signal.SIGKILL)
                        cleanup.append({"pid": pid, "log": str(log), "signal": "SIGKILL", "identity": "Recorded PID plus unique controlled-helper log path in actual command"})
                    except ProcessLookupError:
                        pass
        result["failureCleanupSignals"] = cleanup
        result["finishedUTC"] = utc()
        result["status"] = "passed" if result["passed"] == 10 and result["failed"] == 0 else "failed"
        result["uniqueScenarioGroups"] = 10
        result["reportDirectory"] = str(report)
        (report / "summary.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        # Default reports are retained, as are work directories after a failure for owned-process diagnosis.
        if args.report_directory and result["status"] == "passed": shutil.rmtree(work)
    print("Web extractor report: " + str(report), flush=True)
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
