#!/usr/bin/env python3
"""Verify explicit Play independently of autoplay with a hash-pinned real app.

The opt-in app setup queues the first fixture before its real renderer exists.
Ordinary opens, restored Stop/Play, and actual delayed HTTP loads are then
checked using pause state, time-pos and real renderer-frame growth. One app
process is one scenario; internal observations are not additional groups.
No build, fixture generation, native mouse/UI control or user-process cleanup.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import http.server
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
EXPECTED = {
    'pre-render-explicit-play', 'loaded-toggle-pause', 'loaded-toggle-play',
    'stop-clears-media-preserves-selection', 'explicit-play-after-stop-resume',
    'ordinary-open-autoplay-false', 'ordinary-play-selected-autoplay-false',
    'ordinary-queue-open-autoplay-false', 'queue-next-autoplay-false',
    'queue-remove-successor-autoplay-false', 'ordinary-open-autoplay-true',
    'sleep-deadline-pauses-loading-request', 'sleep-deadline-preserved-after-load',
    'loading-play-upgrades-same-request', 'loading-explicit-play-advances',
    'loading-play-before-replacement', 'new-open-invalidates-old-play-intent',
    'loading-play-before-stop', 'stop-invalidates-loading-play-intent',
    'ordinary-open-after-cancellation-remains-paused',
}
SOURCE_PATHS = [
    'Sources/SiliconPlayer/MPVEngine.swift',
    'Sources/SiliconPlayer/PlaybackIntentVerifier.swift',
    'Sources/SiliconPlayer/SessionVerifier.swift',
    'Sources/SiliconPlayer/VideoSurface.swift',
    'Sources/SiliconPlayer/PlayerModelAdvanced.swift',
    'Sources/PlayerCore/PlaybackSettings.swift',
    'Sources/PlayerCore/HistoryStore.swift',
    'scripts/verify_playback_intent.py',
]


def require(value: bool, message: str) -> None:
    if not value:
        raise RuntimeError(message)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open('rb') as source:
        for data in iter(lambda: source.read(1024 * 1024), b''):
            value.update(data)
    return value.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n')


def probe(path: Path) -> dict:
    data = json.loads(subprocess.check_output([
        str(ROOT / 'Vendor/tools/ffprobe'), '-v', 'error', '-show_streams',
        '-show_format', '-of', 'json', str(path),
    ], timeout=30))
    videos = [s for s in data.get('streams', []) if s.get('codec_type') == 'video']
    require(videos and float(data.get('format', {}).get('duration', 0)) > 22,
            f'Fixture must contain seekable video longer than 22 seconds: {path}')
    return data


class SlowMediaServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, fixture: Path, report: Path, delay: float):
        super().__init__(('127.0.0.1', 0), SlowMediaHandler)
        self.fixture = fixture
        self.request_log = report
        self.delay = delay
        self.lock = threading.Lock()
        self.events: list[dict] = []
        self.first_requests: set[str] = set()

    def event(self, case: str, kind: str, **details) -> None:
        with self.lock:
            self.events.append({'case': case, 'event': kind,
                                'monotonicSeconds': time.monotonic(), **details})
            # This is a small, mutable test-server log, not product publication.
            temporary = self.request_log.with_suffix('.writing')
            write_json(temporary, self.events)
            os.replace(temporary, self.request_log)

    def first(self, case: str) -> bool:
        with self.lock:
            if case in self.first_requests:
                return False
            self.first_requests.add(case)
            return True


class SlowMediaHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.serve(body=False)

    def do_GET(self):
        self.serve(body=True)

    def serve(self, *, body: bool):
        case = self.path.removeprefix('/').removesuffix('.mp4')
        if case not in {'upgrade', 'stale', 'stop', 'sleep'}:
            self.send_error(404)
            return
        delayed = self.server.first(case)
        self.server.event(case, 'started', method=self.command,
                          range=self.headers.get('Range', ''), delayed=delayed)
        if delayed:
            time.sleep(3.0 if case == 'sleep' else self.server.delay)  # Background HTTP worker, never MainActor.
        self.server.event(case, 'released', delayed=delayed)
        try:
            size = self.server.fixture.stat().st_size
            start, end = 0, size - 1
            requested = self.headers.get('Range')
            if requested:
                match = re.fullmatch(r'bytes=(\d*)-(\d*)', requested)
                if not match:
                    self.send_error(416)
                    return
                lo, hi = match.groups()
                if lo:
                    start = int(lo)
                    end = min(end, int(hi)) if hi else end
                elif hi:
                    start = max(0, size - int(hi))
                else:
                    self.send_error(416)
                    return
                if start > end or start >= size:
                    self.send_error(416)
                    return
            self.send_response(206 if requested else 200)
            self.send_header('Content-Type', 'video/mp4')
            self.send_header('Content-Length', str(end - start + 1))
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Connection', 'close')
            if requested:
                self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.end_headers()
            if body:
                with self.server.fixture.open('rb') as stream:
                    stream.seek(start)
                    remaining = end - start + 1
                    while remaining:
                        data = stream.read(min(65536, remaining))
                        if not data:
                            break
                        self.wfile.write(data)
                        remaining -= len(data)
            self.server.event(case, 'completed')
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError) as error:
            self.server.event(case, 'client-cancelled', error=type(error).__name__)
        finally:
            self.close_connection = True


def validate(data: dict, requests: list[dict], fixture: Path, second: Path) -> None:
    require(data.get('mode') == 'playback-intent' and data.get('playbackIntentSchemaVersion') == 1,
            'Unexpected verifier mode/schema')
    require(data.get('playbackIntentPassed') is True and not data.get('failure') and not data.get('error'),
            'Application playback intent failed: ' + str(data.get('failure') or data.get('error')))
    require(data.get('settingsAutoplayUnchanged') is True and not data.get('pendingRendererLoad'),
            'Intent altered the preference or left a pending renderer load')
    startup = data['playbackIntentStartup']
    require(startup['rendererPendingBeforePlay'] and startup['rendererPendingAfterPlay']
            and startup['loadingBeforePlay'] and startup['autoplayBefore'] is False
            and startup['autoplayAfterPlay'] is False
            and startup['itemIDBeforePlay'] == startup['itemIDAfterPlay']
            and Path(startup['source']).resolve() == fixture,
            'No real same-request Play before renderer readiness')
    rows = data.get('playbackIntentChecks', [])
    require(len(rows) == len(EXPECTED) and {row.get('name') for row in rows} == EXPECTED,
            'Missing or duplicate internal intent observations')
    by_name = {row['name']: row for row in rows}
    for row in rows:
        require(row.get('passed') is True, 'Failed observation: ' + str(row))
        kind = row['kind']
        if kind in {'playing', 'paused'}:
            require(row['loaded'] and not row['isLoading'] and len(row['samples']) >= 5,
                    'No stable loaded media interval: ' + row['name'])
            time_delta = row['timeDelta']
            require(math.isfinite(time_delta), 'Invalid time delta')
            playing = kind == 'playing'
            require(row['mpvPaused'] is not playing and row['modelPaused'] is not playing,
                    'Pause property/model disagree with expected action')
            for sample in row['samples']:
                require(sample['loaded'] and not sample['isLoading']
                        and sample['mpvPaused'] is not playing and sample['modelPaused'] is not playing,
                        'Pause state was not stable throughout observation')
            if playing:
                require(time_delta >= .25 and row['renderFrameDelta'] >= 2,
                        'Explicit Play only loaded media without real time/render progression')
            else:
                require(abs(time_delta) <= .06 and all(abs(s['time'] - row['timeBefore']) <= .06 for s in row['samples']),
                        'autoplay=false ordinary load advanced actual media time')
        elif kind == 'loading':
            require(row['isLoading'] and not row['loaded'] and row['requestStarted']
                    and row['sameRequestAfterRepeatedPlay'], 'No genuine same-request loading Play')
        elif kind == 'loading-pause':
            require(row['isLoading'] and not row['loaded'] and row['requestStarted']
                    and row['mpvPaused'] and row['sleepDeadlineCleared'], 'No sleep pause during actual loading')
        elif kind == 'cancelled':
            require(not row['loaded'] and not row['isLoading'] and row['idle'] and not row['rendererPending'],
                    'Stopped loading request resumed')
            require(all(not s['loaded'] and not s['isLoading'] and s['idle'] for s in row['samples']),
                    'Cancellation did not remain stable')
        else:
            raise RuntimeError('Unknown observation kind: ' + str(kind))
        require(row['autoplay'] is (row['name'] in {'ordinary-open-autoplay-true',
                'sleep-deadline-pauses-loading-request', 'sleep-deadline-preserved-after-load'}),
                'An explicit action changed the autoplay preference')
    require(by_name['explicit-play-after-stop-resume']['resumeVerified']
            and 8.44 <= by_name['explicit-play-after-stop-resume']['timeBefore'] < 10,
            'Stop/Play lost resume or needed a second Play')
    for name in ['ordinary-open-autoplay-false', 'ordinary-play-selected-autoplay-false',
                 'queue-next-autoplay-false', 'queue-remove-successor-autoplay-false',
                 'new-open-invalidates-old-play-intent', 'ordinary-open-after-cancellation-remains-paused']:
        require(by_name[name]['source'] == second.as_uri(), 'Replacement/queue selected the wrong media')
    require(by_name['sleep-deadline-preserved-after-load']['sleepDeadlineCleared'],
            'Sleep pause was not retained when loaded')
    for case in ('upgrade', 'stale', 'stop', 'sleep'):
        starts = [event for event in requests if event['case'] == case and event['event'] == 'started' and event['delayed']]
        releases = [event for event in requests if event['case'] == case and event['event'] == 'released' and event['delayed']]
        require(len(starts) == len(releases) == 1 and releases[0]['monotonicSeconds'] - starts[0]['monotonicSeconds'] >= (2.9 if case == 'sleep' else 1.4),
                'HTTP loading race did not use a genuinely delayed request: ' + case)


def stop_owned(process: subprocess.Popen | None) -> None:
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=3)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'dist/SiliconPlayer-0.3.1.app',
                        help='Candidate bundle/executable; never overwritten or built')
    parser.add_argument('--expected-app-sha256', '--app-sha256', dest='app_sha256', required=True)
    parser.add_argument('--fixture', type=Path, required=True, help='Existing local seekable video >22 seconds')
    parser.add_argument('--second-fixture', type=Path, required=True, help='Different local seekable video >22 seconds')
    parser.add_argument('--report-directory', type=Path, required=True, help='New or empty directory; old evidence refused')
    parser.add_argument('--check-only', action='store_true', help='Check files/hashes without starting app or media tools')
    parser.add_argument('--timeout', type=float, default=150)
    options = parser.parse_args()
    require(re.fullmatch(r'[0-9a-fA-F]{64}', options.app_sha256) is not None, 'Expected app SHA must have 64 hex digits')
    require(math.isfinite(options.timeout) and options.timeout >= 60, 'Timeout must be at least 60 seconds')
    app = options.app.expanduser().resolve()
    if app.suffix == '.app':
        app = app / 'Contents/MacOS/SiliconPlayer'
    fixture = options.fixture.expanduser().resolve()
    second = options.second_fixture.expanduser().resolve()
    reports = options.report_directory.expanduser().resolve()
    require(app.is_file() and os.access(app, os.X_OK), 'Candidate app executable missing')
    require(fixture.is_file() and second.is_file() and fixture != second, 'Two different existing local fixtures are required')
    require(not reports.exists() or reports.is_dir() and not any(reports.iterdir()), 'Report directory must be new or empty')
    expected = options.app_sha256.lower()
    require(digest(app) == expected, 'Application does not match supplied builder hash')
    initial_sources = {path: digest(ROOT / path) for path in SOURCE_PATHS}
    inputs = {str(path): {'SHA256': digest(path), 'bytes': path.stat().st_size} for path in (fixture, second)}
    if options.check_only:
        print(json.dumps({'status': 'preflight-passed', 'appSHA256': expected, 'inputs': inputs,
                          'productionSHA256': initial_sources, 'appStarted': False, 'mediaToolsExecuted': False},
                         ensure_ascii=False, indent=2))
        return
    # Probe only after explicit execution. Preflight never spawns media tools.
    for path in (fixture, second):
        inputs[str(path)]['ffprobe'] = probe(path)
    reports.mkdir(parents=True, exist_ok=True)
    report = reports / 'verification-playback-intent.json'
    requests_path = reports / 'slow-http-requests.json'
    write_json(requests_path, [])
    metadata = {'recordedUTC': datetime.now(timezone.utc).isoformat(), 'scenarioCount': 1,
                'app': str(app), 'appSHA256Begin': expected, 'inputs': inputs,
                'productionSHA256Begin': initial_sources,
                'initialPreferences': {'autoplay': False},
                'scope': 'Real APIs/time/renderer; init fixture setup exercises renderer-pending branch. No physical mouse or media-device acceptance.'}
    write_json(reports / 'run-metadata.json', metadata)
    server = SlowMediaServer(fixture, requests_path, delay=1.5)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    origin = f'http://127.0.0.1:{server.server_port}'
    process = None
    failure = None
    data = None
    started = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix='siliconplayer-playback-intent-') as profile:
            profile_path = Path(profile)
            write_json(profile_path / 'preferences.json', {'autoplay': False})
            env = {k: v for k, v in os.environ.items() if not k.startswith('SILICONPLAYER_VERIFY_')}
            env.update(SILICONPLAYER_VERIFY_REPORT=str(report), SILICONPLAYER_VERIFY_MODE='playback-intent',
                       SILICONPLAYER_VERIFY_EXIT='1', SILICONPLAYER_VERIFY_STORAGE=profile,
                       SILICONPLAYER_VERIFY_INTENT_FIRST=str(fixture), SILICONPLAYER_VERIFY_SECOND=str(second),
                       SILICONPLAYER_VERIFY_INTENT_SLOW=origin + '/upgrade.mp4',
                       SILICONPLAYER_VERIFY_INTENT_STALE=origin + '/stale.mp4',
                       SILICONPLAYER_VERIFY_INTENT_STOP=origin + '/stop.mp4',
                       SILICONPLAYER_VERIFY_INTENT_SLEEP=origin + '/sleep.mp4',
                       SILICONPLAYER_VERIFY_INTENT_REQUEST_LOG=str(requests_path))
            try:
                with (reports / 'verification-playback-intent.log').open('w') as log:
                    # No media arguments: the opt-in init hook owns the pending
                    # renderer fixture. AppDelegate must not replace that request.
                    process = subprocess.Popen([str(app)], env=env, stdout=log,
                                               stderr=subprocess.STDOUT, start_new_session=True)
                    metadata['ownedTestPID'] = process.pid
                    write_json(reports / 'run-metadata.json', metadata)
                    process.wait(timeout=options.timeout)
                require(process.returncode == 0 and report.is_file(), 'App exit/report failed')
                data = json.loads(report.read_text())
                # Keep pristine app JSON; script publication is a separate summary.
                validate(data, json.loads(requests_path.read_text()), fixture, second)
                preferences = json.loads((profile_path / 'preferences.json').read_text())
                require(preferences.get('autoplay') is False, 'Explicit Play persisted autoplay=true')
            finally:
                stop_owned(process)
                saved = reports / 'profile-after-exit'
                saved.mkdir(exist_ok=True)
                for name in ('preferences.json', 'history.json', 'queue.json'):
                    path = profile_path / name
                    if path.is_file():
                        shutil.copy2(path, saved / name)
    except Exception as error:
        failure = str(error)
    finally:
        stop_owned(process)
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
    final_sources = {path: digest(ROOT / path) for path in SOURCE_PATHS}
    final_app = digest(app)
    final_inputs = {str(path): digest(path) for path in (fixture, second)}
    if final_app != expected or final_sources != initial_sources or any(final_inputs[path] != value['SHA256'] for path, value in inputs.items()):
        failure = 'Application, source, script or fixture changed during verification'
    summary = metadata | {'status': 'failed' if failure else 'passed', 'exitCode': process.returncode if process else None,
                          'wallSeconds': time.monotonic() - started, 'appSHA256End': final_app,
                          'productionSHA256End': final_sources, 'inputSHA256End': final_inputs,
                          'internalObservations': len(data.get('playbackIntentChecks', [])) if data else 0,
                          'rawReport': report.name, 'requestLog': requests_path.name,
                          'testProcessExited': process is None or process.poll() is not None}
    if failure:
        summary['failure'] = failure
    write_json(reports / 'summary.json', summary)
    require(not failure, 'Playback intent verification failed: ' + str(failure))
    print(f'PASS playback-intent: 1 actual-app scenario, {len(EXPECTED)} internal observations; app {expected}')


if __name__ == '__main__':
    main()
