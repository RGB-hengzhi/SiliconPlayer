#!/usr/bin/env python3
"""Serial real-app TS exact-seek verification; --check-only never launches an app.

Each TS fixture runs one continuous ts-seek mode, including fourteen directional
seeks, TS/MP4 option restoration, history resume and bookmark loading. Internal
seek points are observations, not separately counted application scenarios.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'dist/SiliconPlayer-development.app/Contents/MacOS/SiliconPlayer'
CATALOG = ROOT / 'Tests/MediaSources/expanded-media.json'
CONTROL_CATALOG = ROOT / 'Tests/Fixtures/extended/manifest.json'
PRODUCTION = ['Sources/SiliconPlayer/MPVEngine.swift', 'Sources/SiliconPlayer/SessionVerifier.swift',
              'Sources/SiliconPlayer/VideoSurface.swift', 'Sources/SiliconPlayer/PlayerModelAdvanced.swift',
              'Sources/PlayerCore/HistoryStore.swift', 'scripts/verify_ts_seek.py']
TARGETS = [0.1, 1.9, 2.0, 2.37, 3.0, 7.37, 23.5]
LIMITATIONS = ['Only the two hash-pinned, 25fps, GOP12 MPEG-2 local TS fixtures are certified.',
               'Network/live TS, long GOP H.264/HEVC TS, discontinuous timestamps and real remote controls are not certified.',
               'RenderProgress records frames flushed by the production renderer; no physical display/camera measurement.',
               'Each continuous application mode is one scenario; individual seeks are not additional scenarios.',
               'Recorded source hashes describe workspace inputs at run time, not independent proof of binary build provenance.']


def require(value, message):
    if not value:
        raise RuntimeError(message)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n')


def stop_process(process):
    if process.poll() is not None:
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


def validate(data, case):
    require(data.get('mode') == 'ts-seek', 'Unexpected application verification mode')
    require(data.get('loaded') and not data.get('error') and not data.get('failure'), 'Application did not finish cleanly')
    require(data.get('tsSeekPassed') and data.get('tsSeekInitialLocal') and data.get('tsSeekInitialSeekable'),
            'Local/seekable TS prerequisite or verifier result failed')
    require(data.get('tsSeekHistorySaved') and data.get('tsSeekBookmarkPendingCleared'), 'History/bookmark path failed')
    require(any(track['type'] == 'video' and track['codec'] == 'mpeg2video' for track in data['tracks']),
            'Final source is not the expected MPEG-2 video')
    rows = data['tsSeekResults']
    require(len(rows) == data['tsSeekPlannedSteps'] == 23, 'Missing or extra internal observations')
    directional = [row for row in rows if row['direction'] in ('forward', 'backward')]
    require(len(directional) == 14, 'Expected seven seeks in each direction')
    for direction, targets in [('forward', TARGETS), ('backward', list(reversed(TARGETS)))]:
        require([row['target'] for row in directional if row['direction'] == direction] == targets,
                'Directional target sequence differs')
    for row in rows:
        require(row['passed'] and row['local'] and row['seekable'] and row['directionMatches'], 'Failed step: ' + row['label'])
        require(not row['seeking'] and row['renderFramesAfter'] > row['renderFramesBefore'] and row['stableSamples'] >= 3,
                'Seek completion/render stability absent: ' + row['label'])
        require(math.isfinite(row['actual']) and abs(row['actual'] - row['target']) <= .06,
                'Position missed 60ms bound: ' + row['label'])
        require(math.isfinite(row['latencySeconds']) and 0 < row['latencySeconds'] <= 10,
                'Seek/load latency exceeded bound: ' + row['label'])
        for key in ('offsetReadback', 'fileLocalOffsetReadback'):
            require(abs(float(row[key]) - row['expectedOffset']) < .00001, 'Offset mismatch: ' + row['label'])
        is_ts = 'mpegts' in [token.strip() for token in row['fileFormat'].split(',')]
        require(is_ts == (row['expectedOffset'] == .5), 'Container/option scope mismatch: ' + row['label'])
    by_name = {row['label']: row for row in rows}
    require(by_name['switch-to-mp4']['expectedOffset'] == by_name['resume-switch-to-mp4']['expectedOffset'] == 0,
            'Missing MP4 restore check')
    require(by_name['return-to-ts']['expectedOffset'] == by_name['history-resume']['expectedOffset'] == .5,
            'Missing TS re-open check')
    require(abs(by_name['history-resume']['actual'] - 7.37) <= .06 and
            abs(by_name['bookmark-after-resume']['actual'] - 2.37) <= .06, 'Resume/bookmark targets differ')
    require(Path(data['tsSeekSource']).resolve() == (ROOT / case['path']).resolve(), 'Verifier used a different TS source')
    latency = sorted(row['latencySeconds'] for row in directional)
    return {'directionalObservations': len(directional), 'totalInternalObservations': len(rows),
            'maxAbsoluteErrorSeconds': max(row['absoluteErrorSeconds'] for row in directional),
            'seekLatencySeconds': {'median': (latency[6] + latency[7]) / 2,
                                  'p95': latency[math.ceil(.95 * len(latency)) - 1], 'max': latency[-1]}}


def run_case(case, control, app, app_hash, source_hashes, reports, timeout):
    report = reports / (case['id'] + '-app.json')
    log_path = report.with_suffix('.log')
    for path in (report, report.with_suffix('.png')):
        path.unlink(missing_ok=True)
    result = {'id': case['id'] + '-ts-seek', 'scenarioCount': 1, 'status': 'failed',
              'fixture': case['path'], 'fixtureSHA256': case['sha256'], 'appSHA256Begin': digest(app),
              'productionSHA256': source_hashes, 'report': str(report), 'log': str(log_path)}
    require(result['appSHA256Begin'] == app_hash, 'Application changed before scenario')
    environment = {key: value for key, value in os.environ.items() if not key.startswith('SILICONPLAYER_VERIFY_')}
    started = time.monotonic()
    process = None
    try:
        with tempfile.TemporaryDirectory(prefix='siliconplayer-ts-seek-') as profile, log_path.open('w') as log:
            environment.update(SILICONPLAYER_VERIFY_REPORT=str(report), SILICONPLAYER_VERIFY_MODE='ts-seek',
                               SILICONPLAYER_VERIFY_EXIT='1', SILICONPLAYER_VERIFY_STORAGE=profile,
                               SILICONPLAYER_VERIFY_SECOND=str(ROOT / control['path']))
            process = subprocess.Popen([str(app), str(ROOT / case['path'])], env=environment,
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                process.wait(timeout=timeout)
                require(process.returncode == 0 and report.is_file(), 'Application exit/report failed')
                data = json.loads(report.read_text())
                result['player'] = data
                result['metrics'] = validate(data, case)
                image = report.with_suffix('.png')
                require(data.get('screenshotExists') and image.is_file(), 'Final TS render screenshot missing')
                header = image.read_bytes()[:24]
                require(header[:8] == b'\x89PNG\r\n\x1a\n' and len(header) == 24, 'Invalid rendered PNG')
                result['screenshot'] = {'sha256': digest(image), 'bytes': image.stat().st_size,
                                        'width': int.from_bytes(header[16:20], 'big'),
                                        'height': int.from_bytes(header[20:24], 'big')}
                history = Path(profile) / 'history.json'
                if history.is_file():
                    result['savedHistory'] = json.loads(history.read_text())
                result['status'] = 'passed'
            finally:
                stop_process(process)
    except Exception as error:
        result['error'] = str(error)
        if report.is_file() and 'player' not in result:
            try:
                result['player'] = json.loads(report.read_text())
            except (OSError, ValueError):
                pass
    finally:
        if process is not None:
            stop_process(process)
        result['wallSeconds'] = time.monotonic() - started
        result['appSHA256End'] = digest(app)
        if result['appSHA256End'] != app_hash:
            result['status'] = 'failed'
            result['error'] = 'Application changed during scenario'
    if report.is_file():
        augmented = result.get('player', {}) | {'appSHA256Begin': result['appSHA256Begin'],
                    'appSHA256End': result['appSHA256End'], 'inputSHA256': case['sha256'],
                    'controlSHA256': control['sha256'], 'productionSHA256': source_hashes,
                    'scenarioCount': 1, 'status': result['status']}
        save(report, augmented)
    print(('PASS ' if result['status'] == 'passed' else 'FAIL ') + result['id'] +
          (': ' + result['error'] if 'error' in result else ''), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=APP)
    parser.add_argument('--expected-app-sha256', help='Refuse a different executable')
    parser.add_argument('--report-directory', type=Path, default=ROOT / 'Docs/IncrementalTest-2026-10-04/ts-seek/application')
    parser.add_argument('--timeout', type=float, default=150)
    parser.add_argument('--only', nargs='+', choices=['mpeg2-ts-mp2', 'mpeg2-anamorphic'])
    parser.add_argument('--check-only', action='store_true', help='Validate fixture/app hashes and write plan.json; never launch app')
    args = parser.parse_args()
    require(math.isfinite(args.timeout) and args.timeout > 0, '--timeout must be positive and finite')
    app = args.app.resolve()
    if app.suffix == '.app':
        app = app / 'Contents/MacOS/SiliconPlayer'
    app_hash = digest(app)
    require(not args.expected_app_sha256 or app_hash == args.expected_app_sha256, 'Executable does not match requested SHA-256')
    cases = [case for case in json.loads(CATALOG.read_text())['cases'] if case['id'] in ('mpeg2-ts-mp2', 'mpeg2-anamorphic')]
    if args.only:
        cases = [case for case in cases if case['id'] in args.only]
    require(len(cases) == (len(set(args.only)) if args.only else 2), 'Catalog is missing requested TS fixtures')
    control = next(case for case in json.loads(CONTROL_CATALOG.read_text())['cases'] if case['id'] == 'h264-720p')
    for case in [*cases, control]:
        require(digest(ROOT / case['path']) == case['sha256'], 'Fixture hash mismatch: ' + case['id'])
    sources = {path: digest(ROOT / path) for path in PRODUCTION}
    reports = args.report_directory.resolve()
    reports.mkdir(parents=True, exist_ok=True)
    summary = {'startedUTC': datetime.now(timezone.utc).isoformat(), 'app': str(app), 'appSHA256Begin': app_hash,
               'productionSHA256': sources, 'catalogSHA256': digest(CATALOG), 'controlCatalogSHA256': digest(CONTROL_CATALOG),
               'fixtures': [{'id': case['id'], 'path': case['path'], 'sha256': case['sha256']} for case in cases],
               'controlFixture': {'id': control['id'], 'path': control['path'], 'sha256': control['sha256']},
               'plannedScenarioCount': len(cases), 'launchedScenarioCount': 0,
               'mode': 'ts-seek', 'toleranceSeconds': .06, 'targets': TARGETS,
               'limitations': LIMITATIONS, 'results': []}
    if args.check_only:
        summary.update(status='inputs-ready', appSHA256End=digest(app))
        require(summary['appSHA256End'] == app_hash, 'Application changed during input check')
        save(reports / 'plan.json', summary)
        print(f'CHECK PASS: {len(cases)} planned app scenarios; 0 launched; fixtures and executable pinned')
        return
    try:
        for case in cases:
            require(digest(app) == app_hash, 'Application changed between scenarios')
            require(all(digest(ROOT / path) == value for path, value in sources.items()), 'Production source changed between scenarios')
            summary['launchedScenarioCount'] += 1
            summary['results'].append(run_case(case, control, app, app_hash, sources, reports, args.timeout))
            save(reports / 'summary.json', summary)
    except Exception as error:
        summary['failure'] = str(error)
    finally:
        summary['appSHA256End'] = digest(app)
        summary['productionSHA256End'] = {path: digest(ROOT / path) for path in PRODUCTION}
        summary['finishedUTC'] = datetime.now(timezone.utc).isoformat()
        summary['passedScenarioCount'] = sum(result['status'] == 'passed' for result in summary['results'])
        summary['status'] = 'passed' if (not summary.get('failure') and summary['appSHA256End'] == app_hash and
            summary['productionSHA256End'] == sources and summary['passedScenarioCount'] == len(cases)) else 'failed'
        save(reports / 'summary.json', summary)
    require(summary['status'] == 'passed', 'TS application verification failed; see ' + str(reports / 'summary.json'))
    print(f'PASS {summary["passedScenarioCount"]} continuous app scenarios (internal seeks are observations)', flush=True)


if __name__ == '__main__':
    main()
