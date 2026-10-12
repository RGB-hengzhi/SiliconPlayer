#!/usr/bin/env python3
"""Four pinned actual-app system PiP groups. Root alone launches GUI runs.

Uses existing native 4K fixtures, the original mpv core/view, actual callback
diagnostics and async window screenshots. No downloads, builds, AX or CGEvent.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from verify_async_screenshots import decode_images

ROOT = Path(__file__).resolve().parent.parent
MODES = ('system-pip', 'system-pip-race', 'system-pip-quit-enter', 'system-pip-quit-active')
CHECKS = {
    'system-pip': {
        'h264-native-4k-load', 'original-surface-and-single-core', 'h264-native-panel-active',
        'active-host-recreation-rejected', 'h264-pip-clock-frames-audio', 'h264-pip-window-png', 'h264-normal-close-restores-host',
        'hevc-main10-native-4k-load', 'hevc-native-panel-active', 'hevc-pip-clock-frames-window-png',
        'hevc-normal-close-restores-host', 'paused-enter-preserves-state',
        'paused-small-resize-redraw-png', 'paused-large-resize-redraw-png',
        'paused-normal-close-restores-host', 'all-cycles-normal-no-forced-detach',
    },
    'system-pip-race': {
        'race-h264-native-4k-load', 'stop-intervenes-while-entering', 'stop-normal-close-restores-surface',
        'stop-post-close-stability', 'race-reopen-original-core', 'race-reopen-real-render-progress',
        'switch-intervenes-while-entering', 'switch-new-file-id-same-core', 'switch-normal-close-restores-surface',
        'switch-post-close-stability', 'switch-hevc-real-render-progress', 'race-reenter-native-panel', 'race-final-normal-close',
    },
    'system-pip-quit-enter': {'quit-native-4k-load', 'quit-during-real-entering', 'normal-appkit-quit-requested-with-attachment'},
    'system-pip-quit-active': {'quit-native-4k-load', 'quit-native-panel-active', 'quit-active-clock-frame-progress',
                               'normal-appkit-quit-requested-with-attachment'},
}
IMAGES = {'h264-playing-pip', 'hevc-playing-pip', 'paused-small-pip', 'paused-large-pip'}
READINESS = {
    'system-pip': {'h264-native-4k-load-ready', 'hevc-main10-native-4k-load-ready'},
    'system-pip-race': {'race-h264-native-4k-load-ready', 'race-reopen-original-core-ready'},
    'system-pip-quit-enter': {'quit-native-4k-load-ready'},
    'system-pip-quit-active': {'quit-native-4k-load-ready'},
}


def require(value, message):
    if not value:
        raise RuntimeError(message)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            result.update(data)
    return result.hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')


def inventory(app):
    values = {}
    for path in sorted(app.rglob('*')):
        if path.name.startswith('._'):
            continue
        require(not path.is_symlink(), 'Bundle contains an unbound symlink')
        if path.is_file():
            values[str(path.relative_to(app))] = digest(path)
    require(values, 'Bundle is empty')
    return values


def pin_inputs(app):
    value = json.loads((app / 'Contents/Resources/build-provenance.json').read_text())
    require(value.get('inputFilesUnchanged') is True, 'Build inputs changed')
    pins = dict(value['inputFiles'])
    required = [
        'Sources/SiliconPlayer/SystemPiPVerifier.swift', 'Sources/SiliconPlayer/SystemPiPController.swift',
        'Sources/SystemPiPBridge/SystemPiPBridge.m', 'Sources/SystemPiPBridge/include/SystemPiPBridge.h',
        'Sources/PlayerCore/SystemPiPLifecycle.swift', 'Sources/SiliconPlayer/MPVEngine.swift',
        'Sources/SiliconPlayer/VideoSurface.swift', 'Sources/SiliconPlayer/ScreenshotActions.swift',
        'Sources/SiliconPlayer/SiliconPlayerApp.swift', 'Sources/SiliconPlayer/SessionVerifier.swift',
    ]
    require(all(name in pins for name in required), 'Actual app omits PiP/renderer/lifecycle inputs')
    for name, sha in pins.items():
        relative = Path(name)
        require(not relative.is_absolute() and '..' not in relative.parts and re.fullmatch(r'[a-f0-9]{64}', sha), 'Invalid input binding')
        require(digest(ROOT / relative) == sha, 'App does not match current frozen inputs')
    for name in ['scripts/verify_system_pip.py', 'scripts/verify_async_screenshots.py',
                 'Tests/Integration/ImageMetrics.swift', 'Vendor/tools/ffprobe']:
        pins[name] = digest(ROOT / name)
    return pins


def probe(path, codec):
    value = json.loads(subprocess.check_output([str(ROOT / 'Vendor/tools/ffprobe'), '-v', 'error', '-show_streams',
                                               '-show_format', '-of', 'json', str(path)], timeout=35))
    videos = [v for v in value['streams'] if v.get('codec_type') == 'video']
    require(len(videos) == 1 and videos[0]['codec_name'] == codec and videos[0]['width'] >= 3840 and videos[0]['height'] >= 2160,
            'Fixture must be actual native 4K expected codec')
    require(float(value['format']['duration']) > 15 and any(v.get('codec_type') == 'audio' for v in value['streams']), 'Fixture lacks duration/audio')
    if codec == 'hevc':
        require(videos[0].get('profile') == 'Main 10' and '10' in videos[0].get('pix_fmt', ''), 'HEVC fixture is not Main10')
    return value


def validate_report(value, mode):
    require(value.get('mode') == mode and value.get('systemPiPPassed') is True and not value.get('failure'), 'Actual PiP checks failed')
    rows = value['systemPiPChecks']
    require(len(rows) == len(CHECKS[mode]) and {v['id'] for v in rows} == CHECKS[mode]
            and all(v.get('passed') is True for v in rows), 'Missing/duplicate/failed PiP observation')
    require(value.get('physicalNativeUIAcceptance') is False and value.get('systemChromeControlsAcceptance') is False,
            'Internal APIs cannot claim physical system chrome acceptance')
    final = value['systemPiPFinal']
    require(final['forcedDetachCount'] == 0, 'Forced detach is not native normal close')
    samples = value['systemPiPSamples']
    require(samples and all(v['sameCoreAndVideoIdentity'] is True for v in samples), 'Core/video identity changed')
    ready = [v for v in samples if v['stage'].endswith('-ready')]
    require(len(ready) == len(READINESS[mode]) and {v['stage'] for v in ready} == READINESS[mode],
            'Real pre-enter renderer readiness evidence missing')
    for sample in ready:
        require(sample['mainSurfaceReady'] is True and sample['originWindowVisible'] is True
                and sample['surfaceMountedInOriginalHost'] is True
                and sample['minimumNewRenderedFrames'] == 24
                and sample['loadRenderFramesAfter'] - sample['loadRenderFramesBefore'] >= 24
                and sample['minimumTimeAdvanceSeconds'] >= .35
                and sample['loadPositionAfter'] >= sample['loadPositionBefore'] + .35,
                'FILE_LOADED alone is not a ready visible renderer')
    if mode in {'system-pip', 'system-pip-race'}:
        require(final['normalCloseCount'] == 3 and final['closedCallbacks'] == 3 and final['safeToReleaseVideoView'] is True
                and final['videoInOriginalHost'] is True and final['generation'] is None and not final['hasPendingJobs'],
                'Native close/restore lifecycle incomplete')
        require(final['willCloseCallbacks'] >= 3 and final['startedCallbacks'] >= (3 if mode == 'system-pip' else 1)
                and 'PIPPanel' in final['observedSystemWindowClass'], 'Real native start/willClose callback evidence missing')
    image_rows = value['systemPiPImages']
    if mode == 'system-pip':
        ownership = [v for v in samples if v['stage'] == 'active-host-recreation-rejected']
        require(len(ownership) == 1 and ownership[0]['replacementHostRejected'] is True
                and ownership[0]['originalRegistrationRetained'] is True,
                'Active host recreation was not rejected with original registration retained')
        require(len(image_rows) == len(IMAGES) and {v['id'] for v in image_rows} == IMAGES, 'Missing real mpv window PNG')
        paused = [v for v in image_rows if v['id'].startswith('paused-')]
        require(all(v['paused'] is True for v in paused) and abs(paused[0]['position'] - paused[1]['position']) < .03,
                'Paused resize advanced playback')
        require(abs(paused[0]['expectedBackingWidth'] - paused[1]['expectedBackingWidth']) > 8,
                'No two actual paused PiP sizes were observed')
    else:
        require(not image_rows, 'Unexpected image scope in race/quit scenario')
    return image_rows


def validate_shutdown(value, shutdown, mode, exited):
    require(value.get('systemPiPQuitFromSwiftTask') is False and value.get('systemPiPQuitOnMainThread') is True,
            'Normal AppKit quit must originate from the main run loop outside a Swift task')
    require(value.get('systemPiPShutdownEvidenceRequired') is True and value.get('systemPiPJobsActiveAtQuit') is True,
            'No real pending PiP attachment at quit')
    require(0 <= exited - value['systemPiPQuitRequestedUptime'] <= 3, 'PiP app did not naturally quit within three seconds')
    require(shutdown.get('succeeded') is True and shutdown.get('mode') == mode, 'Actual termination gate did not confirm cleanup')
    before, after = shutdown['before'], shutdown['after']
    expected = 'entering' if mode.endswith('-enter') else 'active'
    require(before['state'] == expected and before['hasPendingJobs'] is True and before['ownershipTicket'] is not None,
            'AppDelegate did not observe requested busy PiP state')
    require(before['forcedDetachCount'] == 0 and after['forcedDetachCount'] == 0
            and after['closedCallbacks'] == before['closedCallbacks'] + 1
            and after['normalCloseCount'] == before['normalCloseCount'] + 1
            and after['willCloseCallbacks'] >= before['willCloseCallbacks'] + 1,
            'Native didClose evidence missing or replaced by forced detach')
    require(after['terminal'] is True and after['generation'] is None and after['ownershipTicket'] is None
            and after['nativeDetached'] is True and after['hasPendingJobs'] is False
            and after['safeToReleaseVideoView'] is True and after['videoInOriginalHost'] is True,
            'Actual PiP view ownership survived termination gate')
    require(0 <= shutdown['finishedUptime'] - shutdown['requestedUptime'] <= 3,
            'Actual PiP shutdown exceeded gate deadline')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--expected-app-sha256', required=True)
    parser.add_argument('--report-directory', type=Path, required=True)
    parser.add_argument('--first', type=Path, default=ROOT / 'Tests/Fixtures/HighResolution/bbb_sunflower_2160p_60fps_normal.mp4')
    parser.add_argument('--second', type=Path, default=ROOT / 'Tests/Fixtures/HighResolution/apple-tv-trailer_hevc-main10_sdr_4k24.mp4')
    args = parser.parse_args()
    require(__debug__ and re.fullmatch(r'[a-f0-9]{64}', args.expected_app_sha256), 'Explicit SHA and non-optimized Python required')
    app, out, first, second = args.app.resolve(), args.report_directory.resolve(), args.first.resolve(), args.second.resolve()
    executable = app / 'Contents/MacOS/SiliconPlayer'
    require(app.suffix == '.app' and digest(executable) == args.expected_app_sha256, 'Unexpected actual app bytes')
    require(not out.exists(), 'Refusing to overwrite evidence')
    pins, bundle = pin_inputs(app), inventory(app)
    fixtures = {str(p): digest(p) for p in [first, second]}
    metadata = {'first': probe(first, 'h264'), 'second': probe(second, 'hevc')}
    out.mkdir(parents=True, exist_ok=False)
    write(out / 'inputs.json', {'app': str(app), 'appSHA256': args.expected_app_sha256, 'buildAndHelperInputs': pins,
                              'bundleFiles': bundle, 'fixtures': fixtures, 'fixtureMetadata': metadata,
                              'scope': 'Four owned actual application groups; private installed-framework interface on tested OS only.'})
    summary = {'status': 'running', 'startedUTC': datetime.now(timezone.utc).isoformat(), 'appSHA256': args.expected_app_sha256,
               'results': [], 'physicalNativeUIAcceptance': False, 'systemChromeControlsAcceptance': False}
    try:
        for mode in MODES:
            report, shutdown = out / (mode + '.json'), out / (mode + '-shutdown.json')
            process, forced = None, False
            try:
                with tempfile.TemporaryDirectory(prefix='siliconplayer-system-pip-') as storage, (out / (mode + '.log')).open('wb') as log:
                    env = {k: v for k, v in os.environ.items() if not k.startswith('SILICONPLAYER_VERIFY_')}
                    env.update(SILICONPLAYER_VERIFY_MODE=mode, SILICONPLAYER_VERIFY_REPORT=str(report), SILICONPLAYER_VERIFY_STORAGE=storage,
                               SILICONPLAYER_VERIFY_EXIT='1', SILICONPLAYER_VERIFY_PIP_FIRST=str(first), SILICONPLAYER_VERIFY_PIP_SECOND=str(second),
                               SILICONPLAYER_VERIFY_PIP_SHUTDOWN_REPORT=str(shutdown))
                    process = subprocess.Popen([str(executable)], env=env, stdout=log, stderr=subprocess.STDOUT)
                    started = time.clock_gettime(time.CLOCK_UPTIME_RAW)
                    code = process.wait(timeout=105 if mode in {'system-pip', 'system-pip-race'} else 35)
                    exited = time.clock_gettime(time.CLOCK_UPTIME_RAW)
                    require(code == 0 and report.is_file(), 'Actual PiP app did not naturally finish: ' + mode)
                    value = json.loads(report.read_text())
                    image_rows = validate_report(value, mode)
                    if mode.startswith('system-pip-quit-'):
                        require(shutdown.is_file(), 'AppDelegate omitted actual PiP cleanup evidence')
                        validate_shutdown(value, json.loads(shutdown.read_text()), mode, exited)
                    decoded = decode_images([Path(v['path']) for v in image_rows])
                    for expected, actual in zip(image_rows, decoded):
                        require(expected['actualCommandReply'] is True and expected['imageIOOffMain'] is True
                                and expected['renderCaptureMode'] == 'window', 'Not production async window capture')
                        metrics = actual['ImageIO']
                        require(metrics['width'] == expected['width'] and metrics['height'] == expected['height']
                                and abs(metrics['width'] - expected['expectedBackingWidth']) <= 2
                                and abs(metrics['height'] - expected['expectedBackingHeight']) <= 2,
                                'PNG pixels do not match actual PiP video backing bounds')
                    value.update(appSHA256=args.expected_app_sha256, appPID=process.pid, appExitCode=code,
                                 processStartedUptime=started, processExitedUptime=exited, forcedCleanup=False, decodedImages=decoded)
                    write(report, value)
                summary['results'].append({'id': mode, 'status': 'passed', 'observationCount': len(CHECKS[mode]),
                                           'report': report.name, 'appPID': process.pid, 'forcedCleanup': False})
            finally:
                if process is not None and process.poll() is None:
                    forced = True; process.terminate()
                    try: process.wait(timeout=3)
                    except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=3)
                write(out / (mode + '-process.json'), {'appPID': process.pid if process is not None else None,
                      'appExitCode': process.returncode if process is not None else None, 'forcedCleanup': forced})
        require(inventory(app) == bundle and digest(executable) == args.expected_app_sha256, 'App changed during verification')
        require(all(digest(ROOT / name) == sha for name, sha in pins.items()), 'Build/helper inputs changed')
        require(all(digest(Path(name)) == sha for name, sha in fixtures.items()), 'PiP media fixtures changed')
        summary.update(status='passed', passed=4, failed=0, inputsUnchanged=True, bundleUnchanged=True,
                       internalObservationCount=sum(len(CHECKS[m]) for m in MODES))
    except Exception as error:
        summary.update(status='failed', passed=len(summary['results']), failed=1, error=str(error))
        raise
    finally:
        summary['finishedUTC'] = datetime.now(timezone.utc).isoformat(); write(out / 'summary.json', summary)
    print('PASS 4 actual system PiP application groups; 36 internal observations/PNG decode add no groups')


if __name__ == '__main__':
    main()
