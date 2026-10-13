#!/usr/bin/env python3
"""Real two-launch profile persistence and damaged profile recovery, isolated from daily data."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--report-directory', type=Path, default=ROOT / 'Docs/FullTest-2026-10-04/lifecycle')
parser.add_argument('--app', type=Path, default=ROOT / 'dist/SiliconPlayer-development.app/Contents/MacOS/SiliconPlayer', help='App bundle or executable path')
parser.add_argument('--expected-app-sha256', type=str.lower, help='Refuse a different executable before writing reports or launching')
args = parser.parse_args()
app = args.app.expanduser().resolve()
if app.suffix.lower() == '.app': app = app / 'Contents/MacOS/SiliconPlayer'
app_hash = hashlib.sha256(app.read_bytes()).hexdigest()
if args.expected_app_sha256 and app_hash != args.expected_app_sha256:
    parser.error('Selected executable does not match --expected-app-sha256')
reports = args.report_directory.resolve()
reports.mkdir(parents=True, exist_ok=True)
first = ROOT / 'Tests/Fixtures/extended/h264-720p.mp4'
second = ROOT / 'Tests/Fixtures/extended/hevc-720p.mp4'

def expect(condition, message):
    if not condition:
        raise RuntimeError(message)

def run(mode, profile, paths=()):
    expect(hashlib.sha256(app.read_bytes()).hexdigest() == app_hash, 'Application changed before launch')
    report = reports / (mode + '.json')
    report.unlink(missing_ok=True)
    env = os.environ.copy()
    for key in list(env):
        if key.startswith('SILICONPLAYER_VERIFY_'):
            env.pop(key)
    env.update(SILICONPLAYER_VERIFY_REPORT=str(report), SILICONPLAYER_VERIFY_EXIT='1', SILICONPLAYER_VERIFY_MODE=mode,
               SILICONPLAYER_VERIFY_STORAGE=profile, SILICONPLAYER_VERIFY_SECOND=str(first))
    with report.with_suffix('.log').open('w') as log:
        subprocess.run([str(app), *map(str, paths)], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=40, check=True)
    expect(hashlib.sha256(app.read_bytes()).hexdigest() == app_hash, 'Application changed during tests')
    data = json.loads(report.read_text())
    data['appSHA256'] = app_hash
    data['app'] = str(app)
    report.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    expect(data['loaded'] and not data.get('error') and not data.get('failure'), repr(data))
    return data

with tempfile.TemporaryDirectory(prefix='siliconplayer-lifecycle-') as profile:
    written = run('persistence-write', profile, [first, second])
    expect(written['persistenceWritten'] and abs(written['savedPosition'] - 8) < .1, 'Write phase did not save expected position')
    print('PASS actual settings/queue/bookmark/favorite/named-list/history write and graceful exit', flush=True)
    read = run('persistence-read', profile)
    expect(all(read[key] for key in ['queueRestoredWithoutAutoplay', 'preferencesRestored', 'libraryRestored', 'profilePlayable']), repr(read))
    expect(8 <= read['resumePosition'] < 11 and read['restoredEqualizerFilters'], repr(read))
    expect(all(read[key] for key in ['restoredWelcomeAvailable', 'restoredSessionIdle', 'restoredSelectedSecondItem',
                                    'continueConsumedRestoreMarker', 'continuePreservedSelection',
                                    'continuePlayingWithoutChangingAutoplay']), repr(read))
    expect(abs(read['restoredHistoryTarget'] - 8) < .1, repr(read))
    print('PASS second-launch restored welcome/selected item and explicit Continue resume with autoplay disabled', flush=True)
with tempfile.TemporaryDirectory(prefix='siliconplayer-damaged-profile-') as profile:
    for name in ['preferences.json', 'queue.json', 'history.json', 'library.json']:
        (Path(profile) / name).write_bytes(b'{ intentionally corrupt JSON')
    read = run('corrupt-profile', profile)
    expect(all(read[key] for key in ['corruptSettingsDefaulted', 'corruptQueueEmpty', 'corruptLibraryReported', 'corruptHistoryReported', 'profilePlayable']), repr(read))
    expect(read['corruptWelcomeNotRestored'], repr(read))
    print('PASS actual corrupted profile defaults, visible store errors and successful media recovery', flush=True)
print('3 lifecycle integration groups passed', flush=True)
