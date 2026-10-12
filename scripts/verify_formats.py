#!/usr/bin/env python3
"""Verify real format controls and playback on this Apple Silicon Mac.

Requires the fixtures from make_extended_fixtures.py and the built arm64 app.
Records input/tool/app hashes, ffprobe metadata, player reports and system/process
memory. A successful codec test is evidence for that fixture, not every profile,
DRM variant, damaged file or high-resolution file sharing the codec name.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time
import tempfile
import shutil

sys.dont_write_bytecode = True
if not __debug__:
    raise RuntimeError('Run verification without Python -O/PYTHONOPTIMIZE; assertions must remain active')
from make_extended_fixtures import ROOT, FOLDER, MANIFEST, CASE_IDS, sha256

DEFAULT_APP = ROOT / 'dist' / 'SiliconPlayer-development.app' / 'Contents' / 'MacOS' / 'SiliconPlayer'
DEFAULT_SUMMARY = ROOT / 'Docs' / 'verification-formats.json'


def write_summary(path: Path, values: dict) -> None:
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(values, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)


def command_text(arguments: list[str]) -> str:
    try:
        return subprocess.check_output(arguments, text=True, timeout=10, stderr=subprocess.DEVNULL).strip()
    except (subprocess.SubprocessError, OSError):
        return ''


def system_memory() -> dict:
    stats = command_text(['vm_stat'])
    size = re.search(r'page size of (\d+) bytes', stats)
    pages = {name.strip(): int(value) for name, value in re.findall(r'^([^\n:]+):\s+(\d+)\.', stats, re.MULTILINE)}
    swap = command_text(['sysctl', 'vm.swapusage'])
    values = {}
    for name, number, unit in re.findall(r'(total|used|free)\s*=\s*([\d.]+)([KMG])', swap):
        values[name + 'Bytes'] = int(float(number) * (1024 ** {'K': 1, 'M': 2, 'G': 3}[unit]))
    return {'pageSizeBytes': int(size.group(1)) if size else None, 'pages': pages, 'swap': values, 'swapRaw': swap}


def hardware() -> dict:
    return {'architecture': platform.machine(), 'model': command_text(['sysctl', '-n', 'hw.model']),
            'chip': command_text(['sysctl', '-n', 'machdep.cpu.brand_string']),
            'physicalMemoryBytes': int(command_text(['sysctl', '-n', 'hw.memsize']) or 0),
            'cpuCount': int(command_text(['sysctl', '-n', 'hw.ncpu']) or 0),
            'macOSVersion': command_text(['sw_vers', '-productVersion']),
            'macOSBuild': command_text(['sw_vers', '-buildVersion'])}


def validate_controls(case: dict, data: dict, image: Path) -> list[str]:
    checks = []
    assert data.get('loaded'), 'Media did not load'
    assert not data.get('error') and not data.get('failure'), data.get('error') or data.get('failure')
    assert data.get('mode') == 'controls', 'App lacks expected controls verification mode'
    assert any(track.get('codec') == case['expected_codec'] for track in data.get('tracks', [])), 'Expected codec track absent'
    assert data.get('paused') and abs(data.get('speed', 0) - 1.5) < 0.01 and abs(data.get('volume', 0) - 43) < 0.01, 'Pause/speed/volume controls failed'
    checks += ['loaded', 'expected codec', 'pause', 'speed 1.5×', 'volume 43']
    assert data.get('abCleared') and abs(data.get('abStart', -1) - 2) < 0.1 and abs(data.get('abEnd', -1) - 3) < 0.1, 'A–B loop failed'
    checks += ['seek 2s', 'A–B 2–3s', 'clear A–B']
    if case['video']:
        assert data.get('frameApplicable', True) and data.get('screenshotApplicable', True), 'Video incorrectly marked audio-only'
        assert data.get('screenshotExists') and image.is_file() and image.stat().st_size > 3000, 'Video screenshot missing or too small'
        assert image.read_bytes()[:8] == b'\x89PNG\r\n\x1a\n', 'Invalid screenshot format'
        assert data.get('subtitleID', 0) > 0, 'External Chinese subtitle not selected'
        assert 3 < data.get('position', 0) < 3.2, 'Frame step after 3s seek failed'
        checks += ['Chinese external subtitle', 'PNG screenshot', 'one frame forward']
    else:
        assert data.get('frameApplicable') is False and data.get('screenshotApplicable') is False, 'Audio-only verification must skip video actions'
        assert abs(data.get('position', -1) - 3) < 0.15, 'Audio seek failed'
        checks += ['audio-only seek', 'video-only controls correctly skipped']
    return checks


def validate_benchmark(case: dict, data: dict) -> list[str]:
    assert data.get('loaded'), 'Benchmark did not load media'
    assert not data.get('error') and not data.get('failure'), data.get('error') or data.get('failure')
    assert data.get('mode') == 'benchmark', 'App lacks benchmark mode; rebuild before running'
    assert data.get('playedWallSeconds', 0) >= 17.1, 'Real playback interval shorter than 18s benchmark'
    assert data.get('frames', 0) > 0, 'No frame advancement during real video playback'
    assert data.get('fps', 0) > 0, 'Missing video FPS'
    assert data.get('physicalFootprintBytes', 0) > 0, 'Missing process physical footprint'
    assert any(track.get('codec') == case['expected_codec'] for track in data.get('tracks', [])), 'Benchmark codec track absent'
    return ['real playback ≥18s (timer tolerance)', 'frame advancement', 'FPS/drop/AV-sync/cache metrics', 'physical footprint']


def run_case(case: dict, mode: str, app: Path, reports: Path, timeout: float) -> dict:
    name = f'{case["id"]}-{mode}'
    report = reports / f'{name}.json'
    image = report.with_suffix('.png')
    for path in (report, image): path.unlink(missing_ok=True)
    log_path = report.with_suffix('.log')
    env = os.environ.copy()
    for key in list(env):
        if key.startswith('SILICONPLAYER_VERIFY_'): env.pop(key)
    env.update(SILICONPLAYER_VERIFY_REPORT=str(report), SILICONPLAYER_VERIFY_MODE=mode,
               SILICONPLAYER_VERIFY_EXIT='1', LC_ALL='C')
    if mode == 'controls' and case['video']:
        env['SILICONPLAYER_VERIFY_SUBTITLE'] = str(FOLDER / 'format-validation.srt')
    storage = tempfile.mkdtemp(prefix='siliconplayer-format-verification-')
    env['SILICONPLAYER_VERIFY_STORAGE'] = storage
    command = [str(app), str(ROOT / case['path'])]
    before = system_memory()
    start = time.monotonic()
    samples = []
    result = {'case': case['id'], 'mode': mode, 'command': command,
              'report': str(report.relative_to(ROOT)) if report.is_relative_to(ROOT) else str(report),
              'log': str(log_path), 'memoryBefore': before, 'status': 'failed'}
    with log_path.open('w') as log:
        process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            while process.poll() is None:
                elapsed = time.monotonic() - start
                if elapsed > timeout:
                    process.kill(); process.wait()
                    raise TimeoutError(f'App exceeded {timeout:g}s timeout')
                usage = command_text(['ps', '-o', 'rss=,%cpu=', '-p', str(process.pid)]).split()
                if len(usage) == 2:
                    samples.append({'wallSeconds': round(elapsed, 3), 'residentBytes': int(usage[0]) * 1024, 'cpuPercent': float(usage[1])})
                time.sleep(0.5)
            assert process.returncode == 0, f'App exit code {process.returncode}; see {log_path}'
            assert report.is_file(), 'App did not write a verification report'
            data = json.loads(report.read_text())
            result['player'] = data
            result['checks'] = validate_controls(case, data, image) if mode == 'controls' else validate_benchmark(case, data)
            result['status'] = 'passed'
        except Exception as error:
            result['error'] = str(error)
            if report.is_file():
                try: result['player'] = json.loads(report.read_text())
                except (ValueError, OSError): pass
        finally:
            if process.poll() is None: process.kill(); process.wait()
            shutil.rmtree(storage)
    result['wallSeconds'] = round(time.monotonic() - start, 3)
    result['memoryAfter'] = system_memory()
    result['processSamples'] = samples
    if samples:
        result['peakResidentBytes'] = max(sample['residentBytes'] for sample in samples)
        result['peakCPUPercent'] = max(sample['cpuPercent'] for sample in samples)
    if image.is_file():
        result['screenshot'] = {'path': str(image), 'bytes': image.stat().st_size, 'sha256': sha256(image)}
    print(f'{"PASS" if result["status"] == "passed" else "FAIL"} {name}: '
          f'{result.get("player", {}).get("decoder", "unknown")}, '
          f'{result["wallSeconds"]:.1f}s' + (f' — {result["error"]}' if 'error' in result else ''), flush=True)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', nargs='*', help='Optional fixture IDs: ' + ', '.join(CASE_IDS))
    parser.add_argument('--mode', choices=['controls', 'benchmark', 'all'], default='all')
    parser.add_argument('--app', type=Path, default=DEFAULT_APP, help='App bundle or executable path')
    parser.add_argument('--expected-app-sha256', type=str.lower, help='Refuse a different executable before writing reports or launching')
    parser.add_argument('--summary', type=Path, default=DEFAULT_SUMMARY)
    parser.add_argument('--timeout', type=float, default=60)
    args = parser.parse_args()
    if set(args.cases) - set(CASE_IDS): parser.error('Unknown fixture ID')
    if not MANIFEST.is_file(): parser.error('Run scripts/make_extended_fixtures.py first')
    app = args.app.expanduser().resolve()
    if app.suffix.lower() == '.app': app = app / 'Contents' / 'MacOS' / 'SiliconPlayer'
    if not app.is_file(): parser.error('Build SiliconPlayer.app first')
    app_hash = sha256(app)
    if args.expected_app_sha256 and app_hash != args.expected_app_sha256:
        parser.error('Selected executable does not match --expected-app-sha256')
    manifest = json.loads(MANIFEST.read_text())
    cases = [case for case in manifest['cases'] if not args.cases or case['id'] in args.cases]
    if not cases: parser.error('No matching fixtures')
    summary = args.summary.resolve()
    summary.parent.mkdir(parents=True, exist_ok=True)
    reports = summary.parent / 'format-reports'
    reports.mkdir(exist_ok=True)
    values = {'schema': 1, 'startedUTC': datetime.now(timezone.utc).isoformat(), 'hardware': hardware(),
              'app': {'path': str(app), 'sha256': app_hash}, 'tools': manifest['tools'], 'fixtures': cases,
              'results': [], 'limitations': [
                  'Measurements describe this 16GB Mac and these fixtures, with other desktop workloads present.',
                  'VP9/AV1 use looped small official FFmpeg FATE vectors; high-resolution coverage is not inferred.',
                  'Frame count is mpv estimated-frame-number advancement; drop counters are reported separately.',
                  'RSS includes shared resident mappings; physicalFootprintBytes is the player-reported physical footprint.',
                  'System swap snapshots include all processes and are not attributed solely to the player.',
                  'No DRM, Blu-ray menu, Dolby Vision, HDR display output or damaged-media coverage is inferred.'
              ]}
    for case in cases:
        path = ROOT / case['path']
        if not path.is_file() or sha256(path) != case['sha256']:
            values['results'].append({'case': case['id'], 'status': 'failed', 'error': 'Fixture hash mismatch'})
            continue
        modes = ['controls', 'benchmark'] if args.mode == 'all' else [args.mode]
        for mode in modes:
            if mode == 'benchmark' and not case['video']: continue
            if mode == 'benchmark' and case['duration_requested'] < 20:
                values['results'].append({'case': case['id'], 'mode': mode, 'status': 'failed', 'error': 'Benchmark requires ≥20s fixture'})
                continue
            if sha256(app) != app_hash:
                raise RuntimeError('App binary changed during verification; rebuild and rerun as one consistent test set')
            values['results'].append(run_case(case, mode, app, reports, args.timeout))
            write_summary(summary, values)
    if sha256(app) != app_hash:
        raise RuntimeError('App binary changed during verification')
    values['finishedUTC'] = datetime.now(timezone.utc).isoformat()
    values['passed'] = sum(result['status'] == 'passed' for result in values['results'])
    values['failed'] = sum(result['status'] != 'passed' for result in values['results'])
    write_summary(summary, values)
    print(f'{values["passed"]} passed, {values["failed"]} failed; summary: {summary}', flush=True)
    return int(values['failed'] > 0)


if __name__ == '__main__':
    raise SystemExit(main())
