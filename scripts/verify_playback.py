#!/usr/bin/env python3
"""Exercise the real bundled application with offline fixtures and local HTTP."""
from pathlib import Path
import functools
import http.server
import json
import os
import subprocess
import threading
import re
import sys
import tempfile
import hashlib
import argparse
import shutil

if not __debug__:
    raise RuntimeError('Run verification without Python -O/PYTHONOPTIMIZE; assertions must remain active')

root = Path(__file__).resolve().parent.parent
DEFAULT_APP = root / 'dist/SiliconPlayer-development.app/Contents/MacOS/SiliconPlayer'
fixtures = root / 'Tests/Fixtures'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('cases', nargs='*')
parser.add_argument('--report-directory', type=Path, default=root / 'Docs')
parser.add_argument('--app', type=Path, default=DEFAULT_APP, help='App bundle or executable path')
parser.add_argument('--expected-app-sha256', type=str.lower, help='Refuse a different executable before writing reports or launching')
options = parser.parse_args()
app = options.app.expanduser().resolve()
if app.suffix.lower() == '.app': app = app / 'Contents/MacOS/SiliconPlayer'
app_hash = hashlib.sha256(app.read_bytes()).hexdigest()
if options.expected_app_sha256 and app_hash != options.expected_app_sha256:
    parser.error('Selected executable does not match --expected-app-sha256')
reports = options.report_directory.resolve()
reports.mkdir(parents=True, exist_ok=True)
image_tool_dir = tempfile.TemporaryDirectory(prefix='siliconplayer-image-metrics-')
image_tool = Path(image_tool_dir.name) / 'image-metrics'
if not options.cases or set(options.cases).intersection({'screenshots', 'user-filters', 'filter-transition', 'filter-transition-quit'}):
    subprocess.run(['swiftc', '-parse-as-library', str(root / 'Tests/Integration/ImageMetrics.swift'), '-o', str(image_tool)], check=True)
def image_metrics(path):
    return json.loads(subprocess.check_output([str(image_tool), str(path)]))

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_head(self):
        path = Path(self.translate_path(self.path))
        if not path.is_file():
            return super().send_head()
        file = path.open('rb')
        size = path.stat().st_size
        start, end = 0, size - 1
        range_header = self.headers.get('Range')
        if range_header:
            match = re.fullmatch(r'bytes=(\d*)-(\d*)', range_header)
            if not match:
                file.close(); self.send_error(416); return None
            lo, hi = match.groups()
            if lo:
                start = int(lo); end = int(hi) if hi else end
            else:
                start = max(0, size - int(hi))
            end = min(end, size - 1)
            if start > end or start >= size:
                file.close(); self.send_error(416); return None
        self.send_response(206 if range_header else 200)
        self.send_header('Content-Type', self.guess_type(str(path)))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        if range_header:
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.end_headers()
        file.seek(start)
        self.remaining = end - start + 1
        return file

    def copyfile(self, source, outputfile):
        if not hasattr(self, 'remaining'):
            return super().copyfile(source, outputfile)
        while self.remaining > 0:
            data = source.read(min(65536, self.remaining))
            if not data:
                break
            outputfile.write(data)
            self.remaining -= len(data)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=str(fixtures)))
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
from urllib.parse import quote
network = f'http://127.0.0.1:{server.server_port}/' + quote('中文 测试 H264.mp4')
hls = f'http://127.0.0.1:{server.server_port}/HLS/playlist.m3u8'
cases = [
    ('h264', [str(fixtures / '中文 测试 H264.mp4')], '中文 测试 H264.ass', 'controls'),
    ('hevc', [str(fixtures / '中文 测试 HEVC.mp4')], '中文 测试 HEVC.srt', 'controls'),
    ('mkv', [str(fixtures / '中文 测试 MKV.mkv')], '中文 测试 MKV.ass', 'controls'),
    ('http', [network], '中文 测试 H264.srt', 'controls'),
    ('playlist', [str(fixtures / '中文 测试 H264.mp4'), str(fixtures / '中文 测试 HEVC.mp4')], None, 'playlist'),
    ('rapid', [str(fixtures / '中文 测试 H264.mp4')], '中文 测试 H264.ass', 'rapid'),
    ('advanced', [str(fixtures / '中文 测试 H264.mp4')], '中文 测试 H264.ass', 'advanced'),
    ('processing', [str(fixtures / '中文 测试 H264.mp4')], None, 'processing'),
    ('filter-transition', [str(fixtures / '中文 测试 H264.mp4')], None, 'filter-transition'),
    ('filter-transition-quit', [str(fixtures / '中文 测试 H264.mp4')], None, 'filter-transition-quit'),
    ('hls', [hls], '中文 测试 H264.srt', 'controls'),
    ('imported', [str(fixtures / '中文 列表.m3u8')], None, 'playlist'),
    ('chapters', [str(fixtures / '中文 章节.mp4')], '中文 测试 H264.ass', 'chapters'),
    ('system', [str(fixtures / '中文 测试 H264.mp4')], None, 'system'),
    ('shutdown-recording', [str(fixtures / '中文 测试 H264.mp4')], None, 'shutdown-recording'),
    ('navigation', [str(fixtures / '中文 测试 H264.mp4')], None, 'navigation'),
    ('failure-recovery', [str(fixtures / 'fulltest-not-found.mp4')], None, 'failure-recovery'),
    ('switch-stress', [str(fixtures / '中文 测试 H264.mp4')], None, 'switch-stress'),
    ('multi-track', [str(fixtures / 'FullTest' / '多音轨双字幕.mkv')], '中文 测试 H264.srt', 'multi-track'),
    ('screenshots', [str(fixtures / '中文 测试 H264.mp4')], '中文 测试 H264.ass', 'screenshots'),
    ('user-filters', [str(fixtures / '中文 测试 H264.mp4')], None, 'user-filters'),
    ('queue-batch', [str(fixtures / '中文 测试 H264.mp4')], None, 'queue-batch'),
    ('frame-navigation', [str(fixtures / '中文 测试 H264.mp4')], None, 'frame-navigation'),
]
unknown = set(options.cases) - {case[0] for case in cases}
if unknown:
    parser.error('Unknown verification case: ' + ', '.join(sorted(unknown)))
corrupt = fixtures / 'FullTest' / '损坏截断.mp4'
corrupt.parent.mkdir(parents=True, exist_ok=True)
corrupt.write_bytes(b'\x00\x00\x00\x18ftypisom\x00\x00\x00\x00isomiso2' + b'broken fixture' * 100)
try:
    for name, args, subtitle, mode in cases:
        if options.cases and name not in options.cases:
            continue
        report = reports / f'verification-{name}.json'
        report.unlink(missing_ok=True)
        image = report.with_suffix('.png')
        image.unlink(missing_ok=True)
        if mode == 'filter-transition-quit':
            report.with_suffix('.video-termination.json').unlink(missing_ok=True)
            report.with_suffix('.suite-termination.json').unlink(missing_ok=True)
        if mode in ('screenshots', 'user-filters'):
            shutil.rmtree(report.with_suffix('.images'), ignore_errors=True)
        env = os.environ.copy()
        for key in list(env):
            if key.startswith('SILICONPLAYER_VERIFY_'): env.pop(key)
        env.update(SILICONPLAYER_VERIFY_REPORT=str(report), SILICONPLAYER_VERIFY_EXIT='1', SILICONPLAYER_VERIFY_MODE=mode)
        if mode in ('system', 'navigation', 'failure-recovery', 'switch-stress'):
            env['SILICONPLAYER_VERIFY_SECOND'] = str(fixtures / '中文 测试 HEVC.mp4')
        if mode == 'failure-recovery':
            env['SILICONPLAYER_VERIFY_CORRUPT'] = str(corrupt)
        if mode == 'shutdown-recording':
            report.with_suffix('.mkv').unlink(missing_ok=True)
        if subtitle:
            env['SILICONPLAYER_VERIFY_SUBTITLE'] = str(fixtures / subtitle)
        quit_evidence = None
        with tempfile.TemporaryDirectory(prefix='siliconplayer-verification-') as storage, (reports / f'verification-{name}.log').open('w') as log:
            env['SILICONPLAYER_VERIFY_STORAGE'] = storage
            assert hashlib.sha256(app.read_bytes()).hexdigest() == app_hash, 'Application changed during verification'
            completed = subprocess.run([str(app), *args], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=130 if mode == 'user-filters' else 65 if mode == 'switch-stress' else 40, check=True)
            if mode == 'filter-transition-quit':
                sidecar = report.with_suffix('.video-termination.json')
                suite = report.with_suffix('.suite-termination.json')
                quit_evidence = {'sidecar': json.loads(sidecar.read_text()), 'sidecarSHA256': hashlib.sha256(sidecar.read_bytes()).hexdigest(),
                                 'suite': json.loads(suite.read_text()), 'suiteSHA256': hashlib.sha256(suite.read_bytes()).hexdigest(),
                                 'filterStoreSHA256': hashlib.sha256((Path(storage) / 'user-video-filters.json').read_bytes()).hexdigest(),
                                 'processExitCode': completed.returncode, 'processReturnedWithoutTimeoutOrForcedCleanup': True}
        data = json.loads(report.read_text())
        assert hashlib.sha256(app.read_bytes()).hexdigest() == app_hash, 'Application changed during verification'
        data['appSHA256'] = app_hash
        data['app'] = str(app)
        if quit_evidence is not None: data['quitExternalEvidence'] = quit_evidence
        report.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        assert not data['error'] and not data.get('failure'), data
        if mode not in ('screenshots', 'queue-batch', 'frame-navigation'):
            assert data['loaded'], data
            assert data['decoder'] == ('videotoolbox-copy' if mode in ('advanced', 'processing', 'filter-transition', 'filter-transition-quit') else 'videotoolbox'), data
            assert any(t['codec'] == 'aac' for t in data['tracks']), data
        if mode == 'frame-navigation':
            assert 7.05 < data['forwardTwoAfterSeek'] < 7.09 and 1.94 < data['reverseAfterSeek'] < 1.99, data
            assert data['newSeekCancelsQueuedStep'] and data['stopCancelsQueuedStep'], data
        elif mode == 'queue-batch':
            assert all(data[key] for key in ('batchMoveAccepted', 'movePreservesCurrent', 'nonCurrentBatchRemovalPreservesPlayback', 'currentBatchRemovalLoadsSurvivingSuccessor', 'removeAllStopsAndClears', 'emptyQueuePersisted')), data
        elif mode == 'user-filters':
            assert data['invalidCandidatePreservesChainAndDisk'] and data['storeReloadMatches'] and data['clearedChainAndDecoder'] and not data['controllerError'], data
            assert len(data['filters']) == 13, data
            dimensions = {'transpose': (360, 640), 'crop': (576, 324), 'downscale': (320, 180), 'crop-then-transpose': (360, 320), 'transpose-then-crop': (180, 640), 'transpose-disabled': (320, 360)}
            for row in data['filters']:
                assert row['saved'] and row['decoder'] == 'videotoolbox-copy', row
                expected = dimensions.get(row['name'], (640, 360))
                assert (row['output']['w'], row['output']['h']) == expected, row
                metrics = image_metrics(row['path'])
                assert (metrics['width'], metrics['height']) == expected, row
                row['pixelSHA256'] = metrics['pixelSHA256']
                if row['name'] == 'grayscale':
                    assert metrics['maxChannelDifference'] <= 2, 'Grayscale filter did not produce gray pixels'
            report.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        elif mode == 'screenshots':
            assert all(data[key] for key in ('copiedPNGAndTIFF', 'existingDestinationPreserved', 'approvedReplacementWorks', 'writeFailurePreservesParent', 'customDirectoryWorks', 'settingsRoundTrip', 'stoppedCapturePreservesClipboard')), data
            assert set(data['files']) == {'subtitles', 'video', 'window', 'jpg', 'webp'}, data
            decoded = {}
            for kind, path in data['files'].items():
                metrics = image_metrics(path)
                assert metrics['width'] > 0 and metrics['height'] > 0, metrics
                magic = Path(path).read_bytes()
                assert (magic.startswith(b'\xff\xd8\xff') if kind == 'jpg' else magic.startswith(b'RIFF') and magic[8:12] == b'WEBP' if kind == 'webp' else magic.startswith(b'\x89PNG\r\n\x1a\n')), metrics
                decoded[kind] = metrics['pixelSHA256']
            assert decoded['subtitles'] != decoded['video'], 'Subtitles were not visible in the subtitle screenshot'
            data['decodedImageHashes'] = decoded
            report.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        elif mode == 'failure-recovery':
            assert all(data[key] for key in ('missingFileRejected','recoveredFromMissing','corruptFileRejected','stopDuringLoad','recoveredFromCorrupt')), data
        elif mode == 'switch-stress':
            assert data['switchCount'] == 30 and data['finalStateConsistent'], data
        elif mode == 'multi-track':
            assert len(data['initialAudioIDs']) >= 2 and len(data['initialSubtitleIDs']) >= 2, data
            assert data['selectedAudioID'] == data['initialAudioIDs'][-1], data
            assert data['selectedSubtitleID'] == data['initialSubtitleIDs'][0], data
            assert int(data['secondarySubtitleID']) == data['initialSubtitleIDs'][-1], data
            assert data['subtitleCountWithExternal'] >= 3 and data['externalSubtitleSelected'] > 0, data
            assert data['audioDisabled'] and data['subtitleDisabled'] and data['screenshotExists'], data
        elif mode == 'navigation':
            assert abs(data['beforeSeek'] - 2.2) < .08 and abs(data['afterSeek'] - 7.37) < .08, data
            assert abs(data['afterUndo'] - data['beforeSeek']) < .08 and abs(data['afterRedo'] - data['afterSeek']) < .08, data
            assert all(data[key] for key in ('stopClearedState', 'stopClearedEngine', 'stopReleasedSystem', 'stopPreservedQueue', 'restartedAfterStop', 'seekUndoClearedOnSwitch')), data
            assert data['screenshotExists'] and image.stat().st_size > 5000, data
            frames = json.loads(subprocess.check_output([str(root / 'Vendor/tools/ffprobe'), '-v', 'error', '-skip_frame', 'nokey', '-select_streams', 'v:0', '-show_frames', '-show_entries', 'frame=pts_time', '-of', 'json', args[0]]))['frames']
            keyframes = [float(frame['pts_time']) for frame in frames if 'pts_time' in frame]
            assert any(abs(value - data['keyframePosition']) < .08 for value in keyframes), (data['keyframePosition'], keyframes)
        elif mode == 'system':
            assert data['sleepTimerPaused'] and data['sleepAssertionReleased'], data
            assert data['miniMode'] and data['miniFloating'] and data['miniWidth'] <= 480 and data['miniRestored'], data
            assert data['currentTitle'] == '中文 测试 HEVC.mp4' and data['bookmarkRacePosition'] < 3, data
            assert data['nowPlayingTitle'] == data['currentTitle'], data
        elif mode == 'shutdown-recording':
            assert data['recordingAtExit'], data
            recording = report.with_suffix('.mkv')
            assert recording.stat().st_size > 5000
            probe = json.loads(subprocess.check_output([str(root / 'Vendor/tools/ffprobe'), '-v', 'error', '-show_format', '-show_streams', '-of', 'json', str(recording)]))
            assert float(probe['format']['duration']) > 0.5 and any(s['codec_type'] == 'video' for s in probe['streams']), probe
        elif mode == 'processing':
            assert data['stereoWidth'] == 320 and data['stereoHeight'] == 360, data
            assert data['projectionWidth'] == 1280 and data['projectionHeight'] == 720, data
            assert data['deband'] and data['scaler'] == 'lanczos' and data['audioProcessingFilters'], data
            assert report.with_name(report.stem + '-front.png').read_bytes() != image.read_bytes()
        elif mode == 'filter-transition':
            keys = ('transitionImmediateQueued', 'transitionImmediateExecuted', 'transitionPauseAndTargetPreserved',
                    'transitionLatestReplaced', 'transitionLatestAppliedOnce', 'transitionStopCancelled',
                    'transitionStopStayedCleared', 'transitionSameURLReloadCancelled',
                    'transitionReloadStayedDefault', 'transitionPlaying4xPreserved')
            assert all(data.get(key) is True for key in keys), data
            assert data['paused'] and data['speed'] == 1 and data['transitionFinalRenderUpdates'] >= 24, data
            graph = data['transitionLatestGraph']
            assert len(graph) == 1 and graph[0]['name'] == 'lavfi' and 'yaw=90' in graph[0]['params']['graph'], data
            decoded = {}
            for suffix, expected in (('-stereo.png', (320, 360)), ('-projection.png', (1280, 720)), ('.png', (320, 360))):
                path = report.with_name(report.stem + suffix)
                metrics = image_metrics(path)
                assert (metrics['width'], metrics['height']) == expected, metrics
                decoded[suffix] = metrics['pixelSHA256']
            data['transitionImagePixelSHA256'] = decoded
            report.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        elif mode == 'filter-transition-quit':
            keys = ('quitRefreshWindowQueued', 'quitRefreshWindowExecuted', 'quitCandidateExecutedBeforeCancel',
                    'quitReversibleBegin', 'quitClosedGateRejected', 'quitNoLateCommitOrApply',
                    'quitCancelReopenedAcceptance', 'quitSavedChainRuntimeRestored', 'quitAppExitStartedPending')
            assert all(data.get(key) is True for key in keys), data
            external = data['quitExternalEvidence']; sidecar = external['sidecar']; suite = external['suite']
            assert external['processExitCode'] == 0 and external['processReturnedWithoutTimeoutOrForcedCleanup'], external
            assert sidecar['mode'] == mode and all(sidecar.get(k) is True for k in
                ('succeeded', 'nonWeb', 'closedRequestRejected', 'applyCountUnchanged', 'savedFilterBytesUnchanged')), sidecar
            before = sidecar['begin']['before']; after_begin = sidecar['begin']['after']; after = sidecar['afterCleanup']
            assert before['accepting'] and before['candidateApplying'] and before['pendingRequest'] == data['quitPendingRequest'], sidecar
            for snapshot in (after_begin, after):
                assert not snapshot['accepting'] and not snapshot['candidateApplying'] and not snapshot['pendingRequest'] and snapshot['candidateFragments'] == 0, snapshot
                assert snapshot['applyCount'] == data['quitApplyCountBeforeTermination'], snapshot
            assert before['epoch'] != after_begin['epoch'] and after_begin['epoch'] == after['epoch'], sidecar
            assert all(snapshot['filterStoreSHA256'] == data['quitSavedFilterSHA256'] == external['filterStoreSHA256']
                       for snapshot in (before, after_begin, after)), sidecar
            assert suite['mode'] == mode and suite['terminationAllowed'] and suite['succeeded'] and suite['diskBarrier']['diskDomainEmpty'], suite
            metrics = image_metrics(image)
            assert (metrics['width'], metrics['height']) == (640, 360) and data['paused'], metrics
            data['quitScreenshotPixelSHA256'] = metrics['pixelSHA256']
            report.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        elif mode == 'advanced':
            assert data['rotation'] == 180 and data['brightness'] == 15 and data['contrast'] == 10, data
            assert data['subtitleSize'] == 48 and int(data['secondarySubtitleID']) > 0, data
            assert data['filterDecoder'] == 'videotoolbox-copy' and data['videoFilters'] and data['audioFilters'], data
            assert data['screenshotExists'] and data['statistics'] and data['devices'], data
            assert report.with_name(report.stem + '-original.png').read_bytes() != report.with_name(report.stem + '-adjusted.png').read_bytes()
        elif mode == 'playlist':
            assert data['advancedToNext'] and data['currentTitle'] == '中文 测试 HEVC.mp4', data
        else:
            assert data['paused'] and data['speed'] == 1.5 and abs(data['volume'] - 43) < 0.01, data
            assert data['screenshotExists'] and image.stat().st_size > 5000, data
            assert data['subtitleID'] > 0 and data['abCleared'], data
            assert abs(data['abStart'] - 2) < 0.1 and abs(data['abEnd'] - 3) < 0.1, data
            assert 3 < data['position'] < 3.2, data  # One real frame forward after seeking.
            if mode == 'chapters':
                assert data['chapterID'] == 1 and 5.9 <= data['chapterSeekPosition'] <= 6.1, data
                assert data['chapterTitles'] == ['第一章 开始', '第二章 中文章节'], data
        print(f'PASS {name}: {data["decoder"]}, {data["duration"]:.3f}s, screenshot={data["screenshotExists"]}', flush=True)
finally:
    server.shutdown()
    server.server_close()
    image_tool_dir.cleanup()
