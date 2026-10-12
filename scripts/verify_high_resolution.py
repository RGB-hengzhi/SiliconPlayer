#!/usr/bin/env python3
"""Serial real-content 4K playback checks and a 10-minute 4K60 soak.

Uses the primary-source manifest from download_test_media.py. Records the exact
app/fixture hashes, screenshots, mpv timeline/drop/AV-sync/footprint/thermal data,
process RSS/CPU and system swap. These are windowed playback measurements on the
current desktop, not calibrated HDR output or isolated power measurements.
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import hashlib
import json
import os
import statistics
import subprocess
import tempfile
import time
import sys
sys.dont_write_bytecode = True
from verify_formats import hardware, system_memory, command_text

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'dist/SiliconPlayer-development.app/Contents/MacOS/SiliconPlayer'
MANIFEST = ROOT / 'Tests/Fixtures/HighResolution/manifest.json'

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(4*1024*1024), b''):
            h.update(block)
    return h.hexdigest()

def save(path, data):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--report-directory', type=Path, default=ROOT / 'Docs/FullTest-2026-10-04/high-resolution')
parser.add_argument('--app', type=Path, default=APP, help='App bundle or executable path')
parser.add_argument('--expected-app-sha256', type=str.lower, help='Refuse a different executable before writing reports or launching')
parser.add_argument('--manifest', type=Path, default=MANIFEST, help='Verified actual container hashes and ffprobe metadata')
parser.add_argument('--skip-soak', action='store_true')
parser.add_argument('--only', nargs='*', help='Optional case IDs')
args = parser.parse_args()
app = args.app.expanduser().resolve()
if app.suffix.lower() == '.app': app = app / 'Contents/MacOS/SiliconPlayer'
app_hash = digest(app)
require(not args.expected_app_sha256 or app_hash == args.expected_app_sha256, 'Selected executable does not match --expected-app-sha256')
reports = args.report_directory.resolve(); reports.mkdir(parents=True, exist_ok=True)
manifest_path = args.manifest.resolve()
manifest = json.loads(manifest_path.read_text())
assets = manifest['assets']
by_file = {item['file']: item for item in assets}
validated = set()
cases = []
for asset in assets:
    name = asset['file'].removesuffix('.mp4')
    cases.extend([(name + '-controls', asset, 'controls', 18, {}), (name + '-60s', asset, 'benchmark', 60, {})])
hevc = by_file['apple-tv-trailer_hevc-main10_sdr_4k24.mp4']
bbb = by_file['bbb_sunflower_2160p_60fps_normal.mp4']
cases += [('hevc-main10-software-30s', hevc, 'benchmark', 30, {'SILICONPLAYER_VERIFY_HWDEC': 'no'}),
          ('hevc-main10-cpu-denoise-30s', hevc, 'benchmark', 30, {'SILICONPLAYER_VERIFY_FILTER': 'denoise'})]
if not args.skip_soak:
    cases.append(('bbb-4k60-600s', bbb, 'benchmark', 600, {}))
if args.only:
    known = {case[0] for case in cases}
    require(not (set(args.only) - known), 'Unknown high-resolution case')
    cases = [case for case in cases if case[0] in args.only]
summary = {'startedUTC': datetime.now(timezone.utc).isoformat(), 'hardware': hardware(), 'appSHA256': app_hash, 'app': str(app),
           'sourceManifest': str(manifest_path), 'results': [],
           'limits': ['Windowed rendering, normal desktop workloads, current Mac only.',
                     'HDR10/PQ input decode is tested; HDR/EDR output, dynamic metadata fidelity and calibrated color are not certified.',
                     'Software decoding and CPU filter runs report measured performance limits; their speed is not assumed.',
                     'No native HEVC4K60/VP9-4K/8K or other M-series performance inferred.',
                     'Full native UI/capture permissions are outside these playback API tests.']}

for name, asset, mode, seconds, extras in cases:
    media = ROOT / asset['path']
    if media not in validated:
        require(media.is_file() and digest(media) == asset['sha256'], 'Fixture SHA mismatch: ' + str(media))
        validated.add(media)
    require(digest(app) == app_hash, 'Application changed during tests')
    report = reports / (name + '.json')
    for stale in (report, report.with_suffix('.png'), report.with_suffix('.progress.json')):
        stale.unlink(missing_ok=True)
    result = {'id': name, 'fixture': asset['path'], 'fixtureSHA256': asset['sha256'], 'mode': mode,
              'requestedSeconds': seconds, 'video': asset['video'], 'status': 'failed', 'metricsBefore': system_memory()}
    env = os.environ.copy()
    for key in list(env):
        if key.startswith('SILICONPLAYER_VERIFY_'): env.pop(key)
    env.update(SILICONPLAYER_VERIFY_REPORT=str(report), SILICONPLAYER_VERIFY_EXIT='1', SILICONPLAYER_VERIFY_MODE=mode,
               SILICONPLAYER_VERIFY_SECONDS=str(seconds), **extras)
    if mode == 'controls':
        env['SILICONPLAYER_VERIFY_SUBTITLE'] = str(ROOT / 'Tests/Fixtures/中文 测试 H264.srt')
    start = time.monotonic(); samples = []
    with tempfile.TemporaryDirectory(prefix='siliconplayer-highres-') as profile, report.with_suffix('.log').open('w') as log:
        env['SILICONPLAYER_VERIFY_STORAGE'] = profile
        process = subprocess.Popen([str(app), str(media)], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            last_update = -60
            while process.poll() is None:
                elapsed = time.monotonic()-start
                if elapsed > seconds + 60: raise TimeoutError('Application exceeded timeout')
                usage = command_text(['ps','-o','rss=,%cpu=','-p',str(process.pid)]).split()
                if len(usage) == 2:
                    samples.append({'wallSeconds': elapsed, 'residentBytes': int(usage[0])*1024, 'cpuPercent': float(usage[1])})
                if elapsed-last_update >= 60:
                    last_update = elapsed
                    print(f'RUN {name}: {elapsed:.0f}s/{seconds}s', flush=True)
                time.sleep(.5)
            require(process.returncode == 0, f'App exit={process.returncode}')
            require(digest(app) == app_hash, 'Application changed during tests')
            require(report.is_file(), 'Application report missing')
            data = json.loads(report.read_text())
            require(data['loaded'] and not data.get('error') and not data.get('failure'), repr(data))
            expected_codec = asset['video']['codec_name']
            require(any(t['codec'] == expected_codec for t in data['tracks']), 'Expected codec missing')
            require(data['screenshotExists'] and report.with_suffix('.png').stat().st_size > 5000, 'GPU screenshot absent')
            require(report.with_suffix('.png').read_bytes()[:8] == b'\x89PNG\r\n\x1a\n', 'Invalid GPU PNG')
            checks = ['real native 3840×2160 input', 'expected codec loaded', 'valid GPU screenshot', 'clean application exit']
            if mode == 'controls':
                require(data['paused'] and abs(data['speed']-1.5)<.01 and abs(data['volume']-43)<.01, 'Playback controls failed')
                require(data['abCleared'] and abs(data['abStart']-2)<.1 and abs(data['abEnd']-3)<.1, 'A–B controls failed')
                require(data['subtitleID'] > 0 and 3 < data['position'] < 3.2, 'Chinese subtitle or frame step failed')
                require(data['decoder'] == 'videotoolbox', 'Requested hardware decode not active')
                checks += ['pause/seek/speed/volume', 'A–B setting/clear', 'Chinese external subtitles', 'one video frame forward', 'actual VideoToolbox decode']
            else:
                require(data['playedWallSeconds'] >= seconds-.1, 'Insufficient real playback duration')
                require(data['frames'] > 0 and data['physicalFootprintBytes'] > 0, 'No real frame advance or footprint data')
                params = data['videoParams']
                require(params.get('w') == 3840 and params.get('h') == 2160, 'Decoded resolution mismatch')
                decoder = '软件解码' if extras.get('SILICONPLAYER_VERIFY_HWDEC') == 'no' else 'videotoolbox-copy' if extras.get('SILICONPLAYER_VERIFY_FILTER') else 'videotoolbox'
                require(data['decoder'] == decoder, f'Actual decoder {data["decoder"]}, expected {decoder}')
                if extras.get('SILICONPLAYER_VERIFY_FILTER'):
                    require('hqdn3d' in json.dumps(data['videoFilters']), 'Actual denoise filter missing')
                stable = [sample for sample in data['samples'] if sample['wallSeconds'] >= 3]
                avsync = max(abs(sample['avsync']) for sample in stable)
                expected_fps = float(asset['video']['avg_frame_rate'].split('/')[0]) / float(asset['video']['avg_frame_rate'].split('/')[1])
                drop_ratio = (data['decoderDrops'] + data['renderDrops']) / max(1, expected_fps*data['playedWallSeconds'])
                footprints = [sample['physicalFootprintBytes'] for sample in stable]
                edge = min(50,len(footprints)//2)
                growth = statistics.median(footprints[-edge:])-statistics.median(footprints[:edge]) if edge else 0
                result['quality'] = {'expectedFPS':expected_fps, 'reportedFPS':data['fps'], 'dropRatio':drop_ratio,
                    'maxStableAVSyncSeconds':avsync, 'medianFootprintGrowthBytes':growth,
                    'target': 'drops ≤1%, stable AV-sync ≤100ms, estimated frames ≥85% of source cadence',
                    'meetsTarget': drop_ratio<=.01 and avsync<=.1 and data['frames'] >= expected_fps*data['playedWallSeconds']*.85}
                if not extras:
                    require(result['quality']['meetsTarget'], 'Normal hardware playback missed frame/drop/sync target')
                checks += [f'actual {decoder}', f'continuous playback ≥{seconds}s', 'per-sample drop/AV-sync/footprint/thermal data']
            result['checks'] = checks
            result['status'] = 'passed'; result['player'] = data
        except Exception as error:
            result['error'] = str(error)
            if report.exists():
                try: result['player'] = json.loads(report.read_text())
                except ValueError: pass
        finally:
            if process.poll() is None: process.kill(); process.wait()
    result['wallSeconds'] = time.monotonic()-start
    result['metricsAfter'] = system_memory(); result['processSamples'] = samples
    if samples:
        result['peakResidentBytes'] = max(sample['residentBytes'] for sample in samples)
        result['peakCPUPercent'] = max(sample['cpuPercent'] for sample in samples)
    summary['results'].append(result)
    summary['passed'] = sum(item['status']=='passed' for item in summary['results'])
    summary['failed'] = sum(item['status']!='passed' for item in summary['results'])
    save(reports/'summary.json',summary)
    print(f'{"PASS" if result["status"]=="passed" else "FAIL"} {name}: {result.get("player",{}).get("decoder","unknown")}' + (' — '+result['error'] if 'error' in result else ''),flush=True)
summary['finishedUTC'] = datetime.now(timezone.utc).isoformat(); save(reports/'summary.json',summary)
print(f'{summary["passed"]} high-resolution cases passed, {summary["failed"]} failed',flush=True)
raise SystemExit(bool(summary['failed']))
