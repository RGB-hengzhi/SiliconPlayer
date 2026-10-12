#!/usr/bin/env python3
"""One hash-pinned actual-app diagnostic privacy group against owned Range HTTP.

Only the caller launches this helper/app. Synthetic path/query/password markers
are not private user data. No physical input, public network or existing-app cleanup.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import threading
import time
import urllib.parse

ROOT = Path(__file__).resolve().parent.parent
MARKERS = ('DIAG_PRIVATE_PATH_6F43', 'DIAG_PRIVATE_QUERY_8A72', 'DIAG_PRIVATE_PASSWORD_3C91')
CHECKS = {
    'private-original-url-retained-in-memory', 'real-video-audio-load',
    'real-render-frame-time-growth', 'exact-seek-advances-renderer',
    'bad-media-rejected-with-category', 'recovery-original-url-retained',
    'recovery-codec-and-frame-growth', 'stopped-before-normal-quit',
}
REQUIRED_APP_INPUTS = (
    'Sources/SiliconPlayer/DiagnosticPrivacyVerifier.swift',
    'Sources/SiliconPlayer/MPVEngine.swift', 'Sources/SiliconPlayer/SessionVerifier.swift',
    'Sources/PlayerCore/MediaDiagnosticRedactor.swift',
)


def require(value, message):
    if not value:
        raise RuntimeError(message)


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')


def bundle_inventory(app):
    files = {}
    for path in sorted(app.rglob('*')):
        if path.name.startswith('._'):
            continue
        require(not path.is_symlink(), 'Bundle contains an unpinned symbolic link')
        if path.is_file():
            files[str(path.relative_to(app))] = digest(path)
    require(files, 'Bundle inventory is empty')
    return files


def pin_inputs(app):
    provenance = json.loads((app / 'Contents/Resources/build-provenance.json').read_text())
    require(provenance.get('inputFilesUnchanged') is True, 'Build inputs changed during compilation')
    inputs = dict(provenance['inputFiles'])
    require(all(name in inputs for name in REQUIRED_APP_INPUTS), 'App omits diagnostic production inputs')
    for name, sha in inputs.items():
        relative = Path(name)
        require(not relative.is_absolute() and '..' not in relative.parts and re.fullmatch(r'[a-f0-9]{64}', sha),
                'Invalid build input binding')
        require(digest(ROOT / relative) == sha, 'App does not match frozen build inputs')
    # No imported project helper. The standalone server/harness binds its own bytes.
    inputs['scripts/verify_diagnostic_privacy.py'] = digest(Path(__file__))
    return inputs


class FixtureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, fixture):
        require(0 < fixture.stat().st_size <= 8 * 1024 * 1024, 'Diagnostic media fixture exceeds 8 MiB')
        super().__init__(('127.0.0.1', 0), Handler)
        self.media = fixture.read_bytes()
        self.events, self.lock = [], threading.Lock()

    def event(self, **value):
        with self.lock:
            self.events.append({'uptime': time.clock_gettime(time.CLOCK_UPTIME_RAW), **value})

    def snapshot(self):
        with self.lock:
            return list(self.events)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.serve(False)

    def do_GET(self):
        self.serve(True)

    def serve(self, body):
        parts = urllib.parse.urlsplit(self.path)
        route = 'good' if parts.path == '/' + MARKERS[0] + '/good.mp4' else 'bad' if parts.path == '/' + MARKERS[0] + '/bad.mp4' else 'unknown'
        query = urllib.parse.parse_qs(parts.query, keep_blank_values=True)
        markers_present = query == {'token': [MARKERS[1]], 'password': [MARKERS[2]]}
        if route == 'unknown' or not markers_present:
            self.server.event(route=route, event='rejected', method=self.command, markersPresent=markers_present)
            self.send_error(404)
            return
        data = self.server.media if route == 'good' else b'NOT_A_MEDIA_FILE\n' * 40
        total = len(data)
        requested = self.headers.get('Range')
        start, end = 0, total - 1
        if requested is not None:
            match = re.fullmatch(r'bytes=(\d*)-(\d*)', requested.strip())
            valid = match is not None and bool(match[1] or match[2])
            if valid:
                if match[1]:
                    start = int(match[1]); end = min(int(match[2]), end) if match[2] else end
                    valid = 0 <= start <= end < total
                else:
                    suffix = int(match[2]); valid = suffix > 0
                    start = max(0, total - suffix)
            if not valid:
                self.server.event(route=route, event='range-rejected', method=self.command, markersPresent=True, status=416)
                self.send_response(416)
                self.send_header('Content-Range', 'bytes */' + str(total))
                self.send_header('Content-Length', '0'); self.send_header('Connection', 'close')
                self.end_headers()
                return
        status = 206 if requested is not None else 200
        self.server.event(route=route, event='started', method=self.command, markersPresent=True,
                          status=status, start=start, end=end, total=total,
                          authPresent=bool(self.headers.get('Authorization')), cookiePresent=bool(self.headers.get('Cookie')))
        self.send_response(status)
        self.send_header('Content-Type', 'video/mp4'); self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1)); self.send_header('Connection', 'close')
        if requested is not None:
            self.send_header('Content-Range', 'bytes ' + str(start) + '-' + str(end) + '/' + str(total))
        self.end_headers()
        if not body:
            return
        try:
            self.wfile.write(data[start:end + 1]); self.wfile.flush()
            self.server.event(route=route, event='completed', method=self.command)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            self.server.event(route=route, event='client_closed', method=self.command)


def verify_safe_artifact(data):
    # Test markers are ASCII; their ordinary/JSON escaping cannot conceal a leak.
    require(all(marker.encode() not in data for marker in MARKERS), 'Sensitive fixture marker reached diagnostic artifact')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--expected-app-sha256', required=True)
    parser.add_argument('--report-directory', type=Path, required=True)
    args = parser.parse_args()
    require(__debug__, 'Run without Python -O')
    require(re.fullmatch(r'[a-f0-9]{64}', args.expected_app_sha256), 'Expected SHA256 must be explicit')
    app, out = args.app.resolve(), args.report_directory.resolve()
    executable = app / 'Contents/MacOS/SiliconPlayer'
    require(app.suffix == '.app' and digest(executable) == args.expected_app_sha256, 'Unexpected actual app bytes')
    require(not out.exists(), 'Refusing to overwrite evidence')
    pins, bundle = pin_inputs(app), bundle_inventory(app)
    fixture = ROOT / 'Tests/Fixtures/\u4e2d\u6587 \u6d4b\u8bd5 H264.mp4'
    fixture_sha = digest(fixture)
    out.mkdir(parents=True, exist_ok=False)
    write(out / 'inputs.json', {'app': str(app), 'appSHA256': args.expected_app_sha256,
                              'buildAndHelperInputs': pins, 'bundleFiles': bundle,
                              'fixtures': {str(fixture.relative_to(ROOT)): fixture_sha},
                              'scope': 'One actual app/API/renderer diagnostic group. Synthetic owned-loopback markers only.'})
    summary = {'status': 'running', 'startedUTC': datetime.now(timezone.utc).isoformat(),
               'appSHA256': args.expected_app_sha256, 'results': [], 'physicalNativeUIAcceptance': False}
    server, thread, process = None, None, None
    forced = False
    report, log_path = out / 'diagnostic-privacy.json', out / 'diagnostic-privacy.log'
    try:
        server = FixtureServer(fixture)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        with tempfile.TemporaryDirectory(prefix='siliconplayer-diagnostic-') as storage, log_path.open('wb') as log:
            env = {k: v for k, v in os.environ.items() if not k.startswith('SILICONPLAYER_VERIFY_')}
            env.update(SILICONPLAYER_VERIFY_MODE='diagnostic-privacy', SILICONPLAYER_VERIFY_REPORT=str(report),
                       SILICONPLAYER_VERIFY_STORAGE=storage, SILICONPLAYER_VERIFY_EXIT='1',
                       SILICONPLAYER_VERIFY_DIAGNOSTIC_ORIGIN='http://127.0.0.1:' + str(server.server_port))
            process = subprocess.Popen([str(executable)], env=env, stdout=log, stderr=subprocess.STDOUT)
            started = time.clock_gettime(time.CLOCK_UPTIME_RAW)
            exit_code = process.wait(timeout=70)
            exited = time.clock_gettime(time.CLOCK_UPTIME_RAW)
            require(exit_code == 0 and report.is_file(), 'Actual application did not finish naturally with a report')
            values = json.loads(report.read_text())
            require(values.get('mode') == 'diagnostic-privacy' and values.get('diagnosticPassed') is True and not values.get('failure'),
                    'Actual diagnostic renderer or recovery checks failed')
            checks = values['diagnosticChecks']
            require(len(checks) == len(CHECKS) and {v['id'] for v in checks} == CHECKS
                    and all(v.get('passed') is True for v in checks), 'Diagnostic observations missing, duplicated or failed')
            verify_safe_artifact(report.read_bytes())
            log.flush()
            actual_log = log_path.read_bytes()
            verify_safe_artifact(actual_log)
            text = actual_log.decode('utf-8', errors='replace')
            require(re.search(r'Selected decoder:\s*h264\b', text, re.I) and re.search(r'Selected decoder:\s*aac\b', text, re.I),
                    'Useful actual codec diagnostics were lost')
            require(re.search(r'(Failed to recognize file format|unrecognized file format|unknown format)', text, re.I),
                    'Useful actual bad-media diagnostic category was lost')
            require('[URL omitted]' in text or '[credential-bearing diagnostic omitted]' in text,
                    'Actual address-bearing diagnostics were not observed as redacted')
            require(values.get('diagnosticBadMediaError') and 'omitted' not in values['diagnosticBadMediaError'],
                    'Bad-media structured error category was lost')
            events = server.snapshot()
            starts = [v for v in events if v['event'] == 'started']
            require(any(v['route'] == 'good' and v['status'] == 206 for v in starts)
                    and any(v['route'] == 'bad' for v in starts) and all(v['markersPresent'] for v in starts),
                    'Actual private-route Range and bad-media HTTP requests missing')
            require(all(not v['authPresent'] and not v['cookiePresent'] for v in starts), 'Unexpected loopback credentials or cookies')
            values.update(appSHA256=args.expected_app_sha256, appPID=process.pid, appExitCode=exit_code,
                          appStartedUptime=started, appExitedUptime=exited, forcedCleanup=False,
                          actualLogSHA256=digest(log_path), addressMarkersAbsent=True,
                          actualCodecDiagnosticsRetained=True, actualErrorDiagnosticsRetained=True)
            write(report, values)
        require(bundle_inventory(app) == bundle and digest(executable) == args.expected_app_sha256, 'App changed during verification')
        require(all(digest(ROOT / name) == sha for name, sha in pins.items()), 'Build/helper inputs changed during verification')
        require(digest(fixture) == fixture_sha, 'Fixture changed during verification')
        summary.update(status='passed', passed=1, failed=0, inputsUnchanged=True, bundleUnchanged=True,
                       results=[{'id': 'diagnostic-privacy', 'status': 'passed', 'observationCount': len(CHECKS),
                                 'report': report.name, 'forcedCleanup': False}])
    except Exception as error:
        summary.update(status='failed', passed=0, failed=1, error=str(error))
        raise
    finally:
        if process is not None and process.poll() is None:
            forced = True; process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=3)
        if server is not None:
            server.shutdown(); server.server_close()
        if thread is not None:
            thread.join(timeout=2)
        if server is not None:
            write(out / 'http-events.json', server.snapshot())
        write(out / 'process.json', {'appPID': process.pid if process is not None else None,
                                   'appExitCode': process.returncode if process is not None else None,
                                   'forcedCleanup': forced, 'serverThreadStopped': thread is None or not thread.is_alive()})
        summary['finishedUTC'] = datetime.now(timezone.utc).isoformat()
        write(out / 'summary.json', summary)
    print('PASS 1 actual diagnostic privacy application group; 8 internal observations add no groups')


if __name__ == '__main__':
    main()
