#!/usr/bin/env python3
"""Verify real async screenshot UI APIs and shutdown for an explicitly pinned app.

The application's 10 ms RunLoop heartbeat measures MainActor scheduling, not
physical window responsiveness. No fixture generation or app build is performed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
EXPECTED = {
    '4k-png', 'subtitles', 'window', 'jpeg', 'webp', 'copy-png-tiff',
    'existing-target', 'approved-replacement', 'created-before-command-reply',
    'write-failure', 'stop-before-reply', 'switch-save-before-reply',
    'switch-copy-before-reply', 'newer-clipboard-preserved', 'shutdown-waits-for-reply',
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def probe(path: Path) -> dict:
    return json.loads(subprocess.check_output([
        str(ROOT / 'Vendor/tools/ffprobe'), '-v', 'error', '-show_streams',
        '-show_format', '-of', 'json', str(path),
    ], timeout=30))


def decode_images(images: list[Path]) -> list[dict]:
    # This bundled FFmpeg build intentionally has a restricted codec set and
    # does not decode PNG. The existing ImageIO harness draws every pixel into
    # a CGContext and hashes the decoded raster for PNG/JPEG/WebP acceptance.
    # Its 8-bit comparison raster is not an HDR color-fidelity measurement.
    decoded = []
    if not images:
        return decoded
    with tempfile.TemporaryDirectory(prefix='siliconplayer-async-imageio-') as scratch:
        tool = Path(scratch) / 'image-metrics'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-target', 'arm64-apple-macos14.0',
                        str(ROOT / 'Tests/Integration/ImageMetrics.swift'), '-o', str(tool)],
                       timeout=90, check=True)
        for image in images:
            metrics = json.loads(subprocess.check_output([str(tool), str(image)], timeout=40))
            require(metrics.get('width', 0) > 0 and metrics.get('height', 0) > 0
                    and re.fullmatch(r'[0-9a-f]{64}', metrics.get('pixelSHA256', '')) is not None,
                    f'ImageIO did not fully decode image pixels: {image}')
            details = {'path': str(image), 'SHA256': sha256(image), 'ImageIO': metrics}
            if image.name == '4k-video.png':
                with image.open('rb') as source:
                    header = source.read(33)
                require(header[:8] == b'\x89PNG\r\n\x1a\n' and header[12:16] == b'IHDR', 'Invalid real 4K PNG')
                width, height, bit_depth = struct.unpack('>IIB', header[16:25])
                require(width >= 3840 and height >= 2160 and bit_depth == 16, '4K PNG is not high bit depth')
                require(metrics['width'] == width and metrics['height'] == height, 'Decoded PNG dimensions differ from its header')
                details['PNGHeader'] = {'width': width, 'height': height, 'bitDepth': bit_depth}
            decoded.append(details)
    return decoded


def validate_report(data: dict, actual_quit: bool) -> list[Path]:
    require(data.get('mode') == 'async-screenshots', 'App did not run the new async verifier')
    require(data.get('asyncScreenshotPassed') is True and not data.get('failure'),
            f'Async screenshot verification failed: {data.get("failure", data)}')
    require(data.get('pendingScreenshots') == 0 and data.get('screenshotBusy') is False,
            'Screenshot jobs survived completion')
    limit = data.get('mainActorGapLimitSeconds')
    require(isinstance(limit, (float, int)) and 0 < limit <= 0.100, 'Missing strict MainActor threshold')
    diagnostics = data.get('asyncScreenshotDiagnostics', [])
    require(diagnostics, 'Missing actual core reply evidence')
    if actual_quit:
        require(data.get('actualApplicationTermination') is True
                and data.get('quitBeganBeforeReply') is True
                and data.get('tempPresentAtQuitRequest') is True, 'Not an actual pending app termination')
        require(data['maxMainActorGapSeconds'] <= limit and data['apiCallSeconds'] <= limit,
                'Actual application termination blocked MainActor')
        require(len(diagnostics) == 1, 'Unexpected screenshot jobs during quit')
        row = diagnostics[0]
        require(row.get('cancelled') is True and row.get('published') is False
                and row.get('replyAt') is not None and row.get('tempRemoved') is True,
                'Quit lacked real reply, cancellation or cleanup')
        require(row['commandSubmittedAt'] < data['quitRequestedAt'] < row['replyAt']
                <= row['completedAt'] <= data['willTerminateAt'], 'Actual quit ordering was not preserved')
        require(not Path(row['target']).exists() and not Path(row['tempDirectory']).exists(), 'Quit left cancelled files')
        return []
    checks = data.get('asyncScreenshotChecks', [])
    require({row.get('name') for row in checks} == EXPECTED and len(checks) == len(EXPECTED),
            'Required screenshot cases are missing or duplicated')
    files = []
    by_name = {row['name']: row for row in checks}
    require(by_name['4k-png'].get('busyRejectionCompleted') is True, 'Busy refusal did not complete callback')
    require(by_name['4k-png']['heartbeatsWhilePending'] > 0, 'No heartbeat ran during the 4K operation')
    require(by_name['copy-png-tiff'].get('clipboardPNGAndTIFFDecoded') is True, 'Clipboard data was not decoded')
    for row in checks:
        require(row.get('passed') is True and row['apiCallSeconds'] <= limit
                and row['maxMainActorGapSeconds'] <= limit, f'MainActor failure: {row}')
        require(row.get('tempRemoved') is True, f'Temporary files survived: {row}')
        if row.get('commandSubmittedAt') is not None:
            require(row.get('replyAt') is not None and row.get('tempExistedAtReply') is True,
                    f'Missing real COMMAND_REPLY/temporary directory ordering: {row}')
            require(row['commandSubmittedAt'] <= row['replyAt'] <= row['completedAt'], f'Invalid completion order: {row}')
        if row['expectedSuccess']:
            require(row.get('replyStatus') == 0 and row.get('published') is True
                    and row.get('imageIOOffMain') is True, f'No successful real background capture: {row}')
            if row.get('target'):
                files.append(Path(row['target']))
        else:
            require(row.get('published') is False, f'Failed/cancelled screenshot was published: {row}')
        if row.get('tempDirectory'):
            require(not Path(row['tempDirectory']).exists(), f'Temporary directory survived process exit: {row}')
    race = by_name['created-before-command-reply']
    require(race['commandSubmittedAt'] < race['intervenedAt'] < race['replyAt'], 'Same-name race was not exercised')
    require(Path(race['target']).read_bytes() == b'external-owner-content', 'Concurrent target was overwritten')
    for name in ('stop-before-reply', 'switch-save-before-reply', 'switch-copy-before-reply', 'shutdown-waits-for-reply'):
        row = by_name[name]
        require(row.get('cancelled') is True, f'Cancellation not recorded: {row}')
        if row.get('target'):
            require(not Path(row['target']).exists(), f'Cancelled screenshot destination exists: {row}')
    return files


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True, help='.app bundle or its executable; never built by this script')
    parser.add_argument('--expected-app-sha256', '--app-sha256', dest='app_sha256', required=True,
                        help='Expected SHA256 of Contents/MacOS/SiliconPlayer, supplied by builder')
    parser.add_argument('--fixture', type=Path, required=True, help='Existing real 4K (3840x2160+) 10-bit video')
    parser.add_argument('--next-fixture', type=Path, default=ROOT / 'Tests/Fixtures/中文 测试 H264.mp4')
    parser.add_argument('--report-directory', type=Path, required=True, help='New or empty evidence directory')
    parser.add_argument('--case', choices=('all', 'operations', 'quit'), default='all')
    parser.add_argument('--timeout', type=float, default=240)
    options = parser.parse_args()
    require(__debug__, 'Run without Python -O/PYTHONOPTIMIZE')
    require(re.fullmatch(r'[0-9a-fA-F]{64}', options.app_sha256) is not None, '--app-sha256 must contain 64 hex digits')
    app = options.app.expanduser().resolve()
    if app.suffix == '.app':
        app = app / 'Contents/MacOS/SiliconPlayer'
    fixture, next_fixture = options.fixture.expanduser().resolve(), options.next_fixture.expanduser().resolve()
    require(app.is_file() and os.access(app, os.X_OK), f'Missing executable: {app}')
    require(fixture.is_file() and next_fixture.is_file(), 'Both offline fixtures must exist')
    expected_hash = options.app_sha256.lower()
    require(sha256(app) == expected_hash, 'Application does not match the explicitly expected binary hash')
    fixture_probe = probe(fixture)
    video = next((stream for stream in fixture_probe['streams'] if stream.get('codec_type') == 'video'), {})
    fmt = video.get('pix_fmt', '')
    depth = int(video.get('bits_per_raw_sample') or 0)
    match = re.search(r'(10|12|14|16)(?:le|be)?$', fmt)
    if match:
        depth = max(depth, int(match.group(1)))
    require(video.get('width', 0) >= 3840 and video.get('height', 0) >= 2160 and depth >= 10,
            f'Fixture is not real 4K high bit depth video: {video}')
    reports = options.report_directory.expanduser().resolve()
    require(not reports.exists() or not any(reports.iterdir()), 'Evidence directory must be new or empty; previous results are protected')
    reports.mkdir(parents=True, exist_ok=True)
    metadata = {'app': str(app), 'appSHA256': expected_hash, 'fixture': str(fixture),
                'fixtureSHA256': sha256(fixture), 'fixtureFFprobe': fixture_probe,
                'nextFixture': str(next_fixture), 'nextFixtureSHA256': sha256(next_fixture),
                'scope': 'Real async product API/COMMAND_REPLY, MainActor heartbeat and full image decode; physical UI and HDR output are not certified',
                'command': sys.argv}
    (reports / 'inputs.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
    cases = ('operations', 'quit') if options.case == 'all' else (options.case,)
    for case in cases:
        report = reports / f'verification-async-screenshots-{case}.json'
        env = {key: value for key, value in os.environ.items() if not key.startswith('SILICONPLAYER_VERIFY_')}
        env.update(SILICONPLAYER_VERIFY_MODE='async-screenshots', SILICONPLAYER_VERIFY_REPORT=str(report),
                   SILICONPLAYER_VERIFY_EXIT='1', SILICONPLAYER_VERIFY_SECOND=str(next_fixture))
        if case == 'quit':
            env['SILICONPLAYER_VERIFY_ASYNC_QUIT'] = '1'
        require(sha256(app) == expected_hash, 'App changed before launching verification')
        with tempfile.TemporaryDirectory(prefix='siliconplayer-async-screenshot-storage-') as storage, (reports / f'{case}.log').open('w') as log:
            env['SILICONPLAYER_VERIFY_STORAGE'] = storage
            # subprocess owns only this test PID. It never quits a pre-existing
            # user player process, and keeps the isolated storage until exit.
            subprocess.run([str(app), str(fixture)], env=env, stdout=log,
                           stderr=subprocess.STDOUT, timeout=options.timeout, check=True)
        require(sha256(app) == expected_hash, 'App changed during verification')
        require(report.is_file(), f'Application produced no report for {case}')
        data = json.loads(report.read_text())
        data['appSHA256'] = expected_hash
        data['fixtureSHA256'] = metadata['fixtureSHA256']
        report.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        images = validate_report(data, actual_quit=case == 'quit')
        # Full decoding is done only after the player exits, so it cannot
        # perturb the in-app heartbeat. Headers supplement, never replace it.
        data['decodedImages'] = decode_images(images)
        report.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        print(f'PASS {case}: {len(data.get("asyncScreenshotChecks", []))} operation checks; app {expected_hash}')


if __name__ == '__main__':
    main()
