#!/usr/bin/env python3
"""Serial daily-use acceptance of an explicitly pinned, already built app.

Keeps the existing checker assertions unchanged. The outer frozen Owner proves
each checker birth group closes; its inner App processes retain the original
checker's subprocess ownership, which is not a stronger per-App proof.
No builds, downloads, ASR, experimental Metal or SFTP tests are performed here.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import shlex
import stat
import statistics
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'Tests/Fixtures'
OWNER = ROOT / 'Docs/Prototypes/Integration-0.6/source39-current-compiled-linear-companions-actual-binding1/driver/owned_runner.py'
OWNER_SHA = 'a6edaf8e3ec42e489ca6a937d360b30ee6851a33506575419fa3709dd6f04144'
ABI_SOURCE = ROOT / 'Docs/Prototypes/Metal-0.6/owned-waitid-sdk-abi-root-preflight1/waitid-sdk-abi.c'
ABI_SOURCE_SHA = '64e4b38b5ea80caf9e8922b05bbd3e2242bd53ea76047822baa2443909030dd4'
NATIVE = ('h264', 'hevc', 'mkv', 'http', 'playlist', 'rapid', 'imported',
          'chapters', 'system', 'navigation', 'failure-recovery', 'switch-stress',
          'multi-track', 'screenshots', 'queue-batch', 'frame-navigation', 'user-filters')
AUDIO = ('flac', 'wav', 'aac', 'mp3')
HIGHRES = ('bbb_sunflower_2160p_60fps_normal-controls',
           'bbb_sunflower_2160p_60fps_normal-60s',
           'apple-tv-trailer_hevc-main10_sdr_4k24-controls',
           'apple-tv-trailer_hevc-main10_sdr_4k24-60s', 'bbb-4k60-600s')
BUDGETS = {'maxStablePhysicalFootprintBytes': 1024**3,
           'maxPeakResidentBytes': 1536 * 1024**2,
           'maxSoakMedianGrowthBytes': 64 * 1024**2, 'maxMeanCPUPercent': 150.0}


def require(value, reason):
    if not value:
        raise RuntimeError(reason)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def save(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    with temporary.open('w', encoding='utf8') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
    temporary.replace(path)


def json_file(path):
    return json.loads(Path(path).read_text(encoding='utf8'))


def source_inputs():
    files = []
    for folder in ('Sources', 'Tests', 'scripts'):
        for base, directories, names in os.walk(ROOT / folder):
            directories[:] = sorted(d for d in directories if d not in ('Fixtures', 'Reports', '__pycache__') and not d.startswith('._'))
            files += [Path(base) / name for name in names if not name.startswith('._') and Path(name).suffix in
                      ('.swift', '.py', '.sh', '.c', '.m', '.mm', '.h', '.modulemap')]
    files += [ROOT / 'Package.swift', ROOT / 'Resources/Info.plist']
    return {str(p.relative_to(ROOT)): digest(p) for p in sorted(files)}


def inventory(directory):
    result = {}
    for path in sorted(directory.rglob('*')):
        if any(part.startswith('._') for part in path.relative_to(directory).parts):
            continue
        info = path.lstat(); relative = str(path.relative_to(directory))
        if stat.S_ISLNK(info.st_mode):
            require(path.resolve().is_relative_to(directory.resolve()), 'App symlink escapes bundle: ' + relative)
            result[relative] = {'link': os.readlink(path)}
        elif stat.S_ISREG(info.st_mode):
            result[relative] = {'bytes': info.st_size, 'sha256': digest(path), 'mode': stat.S_IMODE(info.st_mode)}
        else:
            require(stat.S_ISDIR(info.st_mode), 'App special file: ' + relative)
    return result


def fixtures():
    paths = [FIXTURES / name for codec in ('H264', 'HEVC', 'MKV')
             for name in (f'中文 测试 {codec}' + ('.mkv' if codec == 'MKV' else '.mp4'),
                          f'中文 测试 {codec}.srt', f'中文 测试 {codec}.ass')]
    paths += [FIXTURES / name for name in ('中文 列表.m3u8', '中文 章节.mp4',
              'FullTest/多音轨双字幕.mkv', 'FullTest/English.srt', 'extended/manifest.json',
              'extended/format-validation.srt', 'HighResolution/manifest.json')]
    extended = json_file(FIXTURES / 'extended/manifest.json')
    for row in extended['cases']:
        if row['id'] in (*AUDIO, 'h264-720p', 'hevc-720p'):
            path = ROOT / row['path']; require(digest(path) == row['sha256'], 'Extended fixture changed: ' + row['id']); paths.append(path)
    high = json_file(FIXTURES / 'HighResolution/manifest.json')
    for row in high['assets']:
        if row['file'] in ('bbb_sunflower_2160p_60fps_normal.mp4', 'apple-tv-trailer_hevc-main10_sdr_4k24.mp4'):
            path = ROOT / row['path']; require(digest(path) == row['sha256'], 'High-resolution fixture changed: ' + row['file']); paths.append(path)
    require({row['file'] for row in high['assets']} >= {'bbb_sunflower_2160p_60fps_normal.mp4', 'apple-tv-trailer_hevc-main10_sdr_4k24.mp4'}, 'High-resolution inputs missing')
    return {str(p): digest(p) for p in sorted(set(paths))}


def abi_check(receipt, expected):
    require(digest(OWNER) == OWNER_SHA and digest(ABI_SOURCE) == ABI_SOURCE_SHA, 'Frozen Owner/C ABI source differs')
    require(digest(receipt) == expected, 'Explicit Root ABI receipt pin differs')
    value = json_file(receipt)
    require(value['status'] == 'passed-independent-sdk-abi-preflight' and value['allNaturalExitZero'] is True
            and value['ctypesOwnerUsed'] is False and value['groupSignalsIssued'] == []
            and value['forcedCleanup'] is False and value['ownedSurvivors'] == []
            and type(value['AppGroups']) is int and value['AppGroups'] == 0, 'Independent natural Root ABI proof missing')
    require(value['actualStdout'] == value['expectedStdout'] == '104 12 20 1 4 1 32\n'
            and value['sourceAndSDKInputsUnchanged'] is True
            and value['CSourceSHA256'] == value['CSourceSHA256End'] == ABI_SOURCE_SHA, 'Actual C ABI output/source differs')
    require(value['sdkInputSHA256Before'] == value['sdkInputSHA256End'], 'SDK changed during ABI probe')
    sdk = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk')
    require(set(value['sdkInputSHA256Before']) == {str(sdk / 'usr/include/sys' / name) for name in ('wait.h', 'signal.h')}, 'Only exact wait/signal SDK headers permitted')
    for path, wanted in value['sdkInputSHA256Before'].items():
        require(digest(path) == wanted, 'Current SDK header differs: ' + path)
    require(Path(value['executable']).is_file() and digest(value['executable']) == value['executableSHA256'], 'Actual ABI executable missing/different after restart')
    executable = str(Path(value['executable']))
    expected_commands = [['/bin/mkdir', str(Path(executable).parent)],
                         ['/usr/bin/clang', '-arch', 'arm64', '-mmacosx-version-min=14.0', '-isysroot', str(sdk), '-Wl,-undefined,error', str(ABI_SOURCE), '-o', executable],
                         ['/usr/bin/codesign', '--force', '--sign', '-', executable],
                         ['/usr/bin/codesign', '--verify', '--strict', executable], [executable]]
    require(len(value['commands']) == 5 and len({r['pid'] for r in value['commands']}) == 5
            and all(type(r['pid']) is int and r['pid'] > 0 for r in value['commands'])
            and [r['argv'] for r in value['commands']] == expected_commands, 'Five exact actual Root commands required')
    for index, row in enumerate(value['commands']):
        require(row['exit'] == 0 and row['naturalExit'] is True and row['exactChildWaitCompleted'] is True, 'ABI command not naturally exited')
        for stream in ('stdout', 'stderr'):
            require(digest(receipt.parent / f'command-{index}.{stream}') == row[stream + 'SHA256'], 'Actual ABI log differs')
    require((receipt.parent / 'command-4.stdout').read_bytes() == value['actualStdout'].encode('ascii')
            and (receipt.parent / 'command-4.stderr').read_bytes() == b'', 'Actual ABI run log differs')
    return value


def plan(app, app_hash, reports):
    script = lambda name: str(ROOT / 'scripts' / name)
    py = sys.executable
    pin = ['--app', str(app), '--expected-app-sha256', app_hash]
    steps = [('core', ['/bin/bash', script('test_core.sh')], 600),
             ('queue', ['/bin/bash', script('test_queue.sh'), str(reports / 'modules/queue')], 600),
             ('input', ['/bin/bash', script('test_input.sh'), str(reports / 'modules')], 600),
             ('network', ['/bin/bash', script('test_network.sh'), str(reports / 'modules')], 600),
             ('media-preferences', ['/bin/bash', script('test_media_preferences.sh'), str(reports / 'modules/media-preferences')], 600),
             ('screenshot-publication', ['/bin/bash', script('test_screenshot_publication.sh'), str(reports / 'modules/screenshot-publication.txt')], 120),
             ('screenshot-preferences', ['/bin/bash', script('test_screenshot_preferences.sh')], 120),
             ('user-video-filters', ['/bin/bash', script('test_user_video_filters.sh'), str(reports / 'modules')], 300)]
    steps += [('native-common', [py, script('verify_playback.py'), *NATIVE, *pin, '--report-directory', str(reports / 'native')], 1200),
              ('lifecycle', [py, script('verify_lifecycle.py'), *pin, '--report-directory', str(reports / 'lifecycle')], 240),
              ('audio-formats', [py, script('verify_formats.py'), *AUDIO, '--mode', 'controls', *pin, '--summary', str(reports / 'audio/summary.json')], 360),
              ('async-screenshots', [py, script('verify_async_screenshots.py'), *pin, '--fixture', str(FIXTURES / 'HighResolution/apple-tv-trailer_hevc-main10_sdr_4k24.mp4'), '--report-directory', str(reports / 'async-screenshots')], 540),
              ('high-resolution', [py, script('verify_high_resolution.py'), *pin, '--manifest', str(FIXTURES / 'HighResolution/manifest.json'), '--only', *HIGHRES, '--report-directory', str(reports / 'high-resolution')], 1100)]
    return steps


def resource_check(reports):
    summary = json_file(reports / 'high-resolution/summary.json')
    require({r['id'] for r in summary['results']} == set(HIGHRES) and summary['failed'] == 0, 'Exact native high-resolution cases not all passed')
    results = []
    for row in summary['results']:
        if row['mode'] != 'benchmark':
            continue
        require(row['quality']['meetsTarget'] is True, 'Original frame/drop/AV-sync target failed')
        samples = [s for s in row['player']['samples'] if s['wallSeconds'] >= 3]
        process = [s for s in row['processSamples'] if s['wallSeconds'] >= 3]
        require(len(samples) >= 10 and len(process) >= 10, 'Insufficient actual resource samples')
        footprint = max(s['physicalFootprintBytes'] for s in samples)
        rss = row['peakResidentBytes']; mean_cpu = statistics.mean(s['cpuPercent'] for s in process)
        growth = row['quality']['medianFootprintGrowthBytes']
        require(all(math.isfinite(x) for x in (footprint, rss, mean_cpu, growth)), 'Nonfinite resources')
        checks = {'stableFootprint': 0 < footprint <= BUDGETS['maxStablePhysicalFootprintBytes'],
                  'peakRSS': 0 < rss <= BUDGETS['maxPeakResidentBytes'],
                  'meanCPU': 0 <= mean_cpu <= BUDGETS['maxMeanCPUPercent'],
                  'soakGrowth': row['id'] != 'bbb-4k60-600s' or growth <= BUDGETS['maxSoakMedianGrowthBytes']}
        results.append({'case': row['id'], 'actualStableSampleCount': len(samples), 'actualProcessSampleCount': len(process),
                        'maxStablePhysicalFootprintBytes': footprint, 'peakResidentBytes': rss,
                        'meanCPUPercent': mean_cpu, 'medianFootprintGrowthBytes': growth, 'checks': checks})
    receipt = {'budgetsChosenBeforeExecution': BUDGETS, 'results': results,
               'status': 'passed' if all(all(r['checks'].values()) for r in results) else 'failed',
               'limits': ['Current Mac/windowed desktop workload only.', 'CPU percent is process CPU across cores; 100 percent is approximately one core.',
                          'RSS includes shared mappings; physical footprint is separately measured.', 'Whole-system swap changes are recorded, not attributed solely to the player.',
                          'These gates cover playing native SDR H2644K60 and HEVCMain10 4K24; idle/pause CPU and native UI require Root additional verification.']}
    save(reports / 'resource-acceptance.json', receipt)
    require(receipt['status'] == 'passed', 'Prospective everyday resource budget exceeded; actual measurements retained')
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--expected-app-sha256', required=True)
    parser.add_argument('--report-directory', type=Path, required=True)
    parser.add_argument('--owner-preflight', type=Path, required=True)
    parser.add_argument('--owner-preflight-sha256', required=True)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64' and __debug__ and not sys.flags.optimize, 'Apple Silicon macOS / active original assertions required')
    app = args.app.expanduser().resolve(); require(app.suffix == '.app', 'Explicit App bundle required')
    exe = app / 'Contents/MacOS/SiliconPlayer'; require(digest(exe) == args.expected_app_sha256, 'Selected executable pin differs')
    reports = args.report_directory.expanduser().resolve(); require(not reports.exists(), 'Fresh evidence directory required')
    steps = plan(app, args.expected_app_sha256, reports)
    for name, command, seconds in steps:
        require(Path(command[1]).is_file(), 'Checker missing: ' + name)
        print(f'{name} ({seconds}s ceiling): {shlex.join(command)}', flush=True)
    print('Prospective resource budgets: ' + json.dumps(BUDGETS), flush=True)
    abi = abi_check(args.owner_preflight.resolve(), args.owner_preflight_sha256)
    fixture_before = fixtures(); source_before = source_inputs(); app_before = inventory(app)
    provenance = json_file(app / 'Contents/Resources/build-provenance.json')
    require(provenance['inputFilesUnchanged'] is True and provenance['inputFiles'], 'Fresh compile source map missing')
    for name, wanted in provenance['inputFiles'].items():
        require(digest(ROOT / name) == wanted, 'Current compiled input differs: ' + name)
    if args.check_only:
        print('PASS read-only preflight; no tests/compiler/download/App launches or output writes.', flush=True)
        return 0
    running = subprocess.run(['/usr/bin/pgrep', '-x', 'SiliconPlayer'], capture_output=True)
    require(running.returncode == 1, 'Existing player must be closed before serial acceptance; no unrelated process killed')
    reports.mkdir(parents=True, exist_ok=False); (reports / 'modules').mkdir()
    summary = {'schema': 1, 'startedUTC': datetime.now(timezone.utc).isoformat(), 'status': 'running',
               'scope': 'Daily-use core acceptance; no full PotPlayer parity claim.', 'app': str(app), 'appSHA256': args.expected_app_sha256,
               'selectedNativeCases': NATIVE, 'selectedAudioCases': AUDIO, 'selectedHighResolutionCases': HIGHRES,
               'ownerSHA256': OWNER_SHA, 'ownerABIReceipt': str(args.owner_preflight.resolve()), 'ownerABIReceiptSHA256': args.owner_preflight_sha256,
               'resourceBudgetsBeforeExecution': BUDGETS, 'steps': [],
               'ownershipLimit': 'Frozen outer checker leader is held unreaped until its whole birth group has no live members. Inner App wrappers remain unchanged, not independently certified strong owners.',
               'deferred': ['Full native UI: Root CUA common flow separately', 'Idle/pause resource measurement: Root separately',
                            'ASR and language models', 'experimental Metal and HDR fidelity', 'SFTP/SMB', 'advanced capture/transcoding', 'EPG/optical discs/VR/skins']}
    for name, value in [('source-before', source_before), ('fixtures-before', fixture_before), ('app-before', app_before)]:
        save(reports / (name + '.json'), value)
    save(reports / 'summary.json', summary)
    environment = os.environ.copy()
    for key in list(environment):
        if key.startswith('SILICONPLAYER_VERIFY_') or key in ('PYTHONOPTIMIZE', 'DYLD_LIBRARY_PATH', 'DYLD_INSERT_LIBRARIES'):
            environment.pop(key)
    environment['PYTHONDONTWRITEBYTECODE'] = '1'
    owner = None
    try:
        spec = importlib.util.spec_from_file_location('core_acceptance_frozen_owner', OWNER)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        owner = module.Owner(reports, environment)
        for name, command, seconds in steps:
            require(digest(exe) == args.expected_app_sha256, 'App changed before ' + name)
            print('RUN ' + name, flush=True)
            owner.run(name, command, timeout=seconds, cwd=ROOT)
            summary['steps'].append({'id': name, 'status': 'passed', 'owner': owner.rows[-1]})
            save(reports / 'summary.json', summary); print('PASS ' + name, flush=True)
        summary['resources'] = resource_check(reports)
        summary['status'] = 'passed'
    except BaseException as error:
        summary.update(status='failed', errorType=type(error).__name__, error=str(error))
    finally:
        if owner is not None:
            summary['actualOwnerRows'] = owner.rows
            summary['ownedCleanup'] = owner.cleanup()
            if summary['ownedCleanup']['cleanupRows'] or summary['ownedCleanup']['unreapedOwnedPIDs']:
                summary.update(status='failed', ownershipFailure='Forced cleanup or unreaped checker group')
        try:
            source_end = source_inputs(); fixture_end = fixtures(); app_end = inventory(app)
            for name, value in [('source-end', source_end), ('fixtures-end', fixture_end), ('app-end', app_end)]:
                save(reports / (name + '.json'), value)
            summary['allPinnedInputsUnchanged'] = source_end == source_before and fixture_end == fixture_before and app_end == app_before
            require(summary['allPinnedInputsUnchanged'], 'Source/fixture/App input drift during acceptance')
            require(abi_check(args.owner_preflight.resolve(), args.owner_preflight_sha256) == abi, 'Root ABI proof drifted')
        except BaseException as error:
            summary.update(status='failed', inputFailure=str(error))
        summary['finishedUTC'] = datetime.now(timezone.utc).isoformat(); save(reports / 'summary.json', summary)
    print(summary['status'].upper() + ': ' + str(reports / 'summary.json'), flush=True)
    return 0 if summary['status'] == 'passed' else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        raise SystemExit('Core acceptance preflight failed: ' + str(error))
