#!/usr/bin/env python3
"""Verify a valid saved crop's real initialization failure and media fallback."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
def require(value, message):
    if not value: raise RuntimeError(message)
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report-directory', type=Path, default=ROOT/'Docs/IncrementalTest-2026-10-04/runtime-filter')
    parser.add_argument('--app', type=Path, default=ROOT/'dist/SiliconPlayer-development.app/Contents/MacOS/SiliconPlayer', help='App bundle or executable path')
    parser.add_argument('--expected-app-sha256', type=str.lower, help='Optional externally pinned executable; otherwise pin its hash for this run')
    args = parser.parse_args()
    app = args.app.expanduser().resolve()
    if app.suffix.lower() == '.app': app = app / 'Contents/MacOS/SiliconPlayer'
    app_hash = digest(app)
    if args.expected_app_sha256:
        require(app_hash == args.expected_app_sha256, 'Application hash differs')
    source = ROOT/'Tests/Fixtures/RuntimeFilters/one-pixel-rgb-ffv1.mkv'
    if not source.exists():
        source.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(ROOT/'Vendor/tools/ffmpeg'), '-v', 'error', '-nostdin', '-f', 'lavfi', '-i', 'testsrc=size=1x1:rate=25:duration=30', '-c:v', 'ffv1', '-level', '3', '-pix_fmt', 'bgr0', '-an', str(source)], check=True)
    probe = json.loads(subprocess.check_output([str(ROOT/'Vendor/tools/ffprobe'), '-v', 'error', '-show_streams', '-of', 'json', str(source)]))['streams'][0]
    require(probe['width'] == probe['height'] == 1 and probe['codec_name'] == 'ffv1', 'Failure fixture dimensions/codec differ')
    folder = args.report_directory.resolve(); folder.mkdir(parents=True, exist_ok=True)
    report = folder/'app.json'
    settings = {'version': 1, 'filters': [{'id': str(uuid.uuid4()), 'kind':'crop', 'enabled': True, 'values': {'width': .9, 'height': .9, 'x': .5, 'y': .5}}]}
    environment = {key: value for key, value in os.environ.items() if not key.startswith('SILICONPLAYER_VERIFY_')}
    with tempfile.TemporaryDirectory(prefix='siliconplayer-runtime-fallback-') as profile:
        preferences = Path(profile)/'user-video-filters.json'
        preferences.write_text(json.dumps(settings))
        previous = preferences.read_bytes()
        environment.update(SILICONPLAYER_VERIFY_REPORT=str(report), SILICONPLAYER_VERIFY_EXIT='1', SILICONPLAYER_VERIFY_MODE='benchmark', SILICONPLAYER_VERIFY_SECONDS='18', SILICONPLAYER_VERIFY_STORAGE=profile)
        require(digest(app) == app_hash, 'Application changed before launch')
        with (folder/'app.log').open('w') as log:
            subprocess.run([str(app), str(source)], env=environment, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=50)
        require(preferences.read_bytes() == previous, 'Rejected runtime chain changed the saved configuration')
        (folder/'saved-chain.json').write_bytes(previous)
    require(digest(app) == app_hash, 'Application changed during verification')
    result = json.loads(report.read_text())
    logs = (folder/'app.log').read_text()
    require(result['loaded'] and not result['error'] and not result.get('failure'), 'Fallback did not leave playable media')
    require(not result['videoFilters'] and result['frames'] >= 400, 'Failed filter remained effective or video did not advance')
    require('Invalid too big or non positive size' in logs and ('Disabling filter' in logs or 'Failed to configure' in logs), 'Genuine crop initialization failure not observed')
    png = report.with_suffix('.png').read_bytes()
    require(png[:8] == b'\x89PNG\r\n\x1a\n' and int.from_bytes(png[16:20], 'big') == 1 and int.from_bytes(png[20:24], 'big') == 1, 'Fallback frame was not a 1x1 PNG')
    result.update(app=str(app), appSHA256=app_hash, inputSHA256=digest(source), passed=True, savedChainPreserved=True, scope='Real saved-chain runtime initialization failure and fallback; not a user-edit GUI test')
    report.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
    print('PASS runtime crop failure, playable unfiltered fallback and saved document protection')
if __name__ == '__main__': main()
