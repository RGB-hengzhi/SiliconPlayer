#!/usr/bin/env python3
"""Compile current production sources and run independent document/network/capture boundaries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('report_directory', nargs='?', default='Tests/Integration/Reports/module-boundaries')
options = parser.parse_args()
report = Path(options.report_directory)
if not report.is_absolute():
    report = root / report
report.mkdir(parents=True, exist_ok=True)
if platform.system() != 'Darwin' or platform.machine() != 'arm64':
    raise SystemExit('These checks require an Apple Silicon Mac running macOS 14 or later.')

sources = sorted((root / 'Sources/PlayerCore').glob('[A-Z]*.swift'))
watched = sources + [root / 'Sources/SiliconPlayer/NetworkMediaService.swift', root / 'Sources/SiliconPlayer/CaptureController.swift']
metadata = {
    'started_at': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
    'platform': platform.platform(), 'architecture': platform.machine(),
    'swift_version': subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True).strip(),
    'source_sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched},
    'results': {},
    'limits': 'No player app, physical keys, public network, real ScreenCaptureKit stream, camera, microphone or privacy permission APIs invoked.'
}


def run(command, output):
    started = time.monotonic()
    try:
        result = subprocess.run([str(arg) for arg in command], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
        content = result.stdout
        exit_code = result.returncode
    except subprocess.TimeoutExpired as error:
        content = error.stdout or ''
        if isinstance(content, bytes):
            content = content.decode('utf-8', errors='replace')
        content += '\nFAIL harness exceeded the 120-second process deadline\n'
        exit_code = 124
    output.write_text(content, encoding='utf-8')
    print(content, end='', flush=True)
    return {'exit_code': exit_code, 'elapsed_seconds': round(time.monotonic() - started, 3)}


with tempfile.TemporaryDirectory(prefix='siliconplayer-boundaries-', dir='/private/tmp') as temp_name:
    temp = Path(temp_name)
    module = temp / 'PlayerCore.swiftmodule'
    core = run(['xcrun', 'swiftc', '-emit-library', '-emit-module', '-parse-as-library', '-module-name', 'PlayerCore',
        '-target', 'arm64-apple-macos14.0', *sources, '-emit-module-path', module, '-o', temp / 'libPlayerCore.dylib'], report / 'boundary-compile-core.txt')
    metadata['results']['compile_core'] = core
    if core['exit_code'] == 0:
        shared = ['xcrun', 'swiftc', '-parse-as-library', '-target', 'arm64-apple-macos14.0', '-I', temp, '-L', temp,
                  '-lPlayerCore', '-Xlinker', '-rpath', '-Xlinker', temp]
        documents = run([*shared, root / 'Tests/Integration/DocumentBoundaryChecks.swift', '-o', temp / 'DocumentBoundaryChecks'], report / 'boundary-compile-documents.txt')
        metadata['results']['compile_documents'] = documents
        if documents['exit_code'] == 0:
            metadata['results']['documents'] = run([temp / 'DocumentBoundaryChecks'], report / 'document-boundary-results.txt')
        network = run([*shared, root / 'Sources/SiliconPlayer/NetworkMediaService.swift', root / 'Tests/Integration/NetworkBoundaryChecks.swift',
                       '-o', temp / 'NetworkBoundaryChecks'], report / 'boundary-compile-network.txt')
        metadata['results']['compile_network'] = network
        if network['exit_code'] == 0:
            fixture_log = (report / 'boundary-http-fixture.txt').open('w')
            fixture = subprocess.Popen(['python3', str(root / 'Tests/Integration/network_boundary_fixture.py'), '--port-file', str(temp / 'port')],
                                       cwd=root, stdout=fixture_log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 10
                while not (temp / 'port').exists() and fixture.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                if not (temp / 'port').exists():
                    raise RuntimeError('Boundary loopback server did not start.')
                metadata['results']['network'] = run([temp / 'NetworkBoundaryChecks', temp / 'port'], report / 'network-boundary-results.txt')
            finally:
                fixture.terminate()
                try:
                    fixture.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    fixture.kill()
                    fixture.wait()
                fixture_log.close()

    # Reuse the current synthetic sample factories without copying production
    # source or invoking the original harness's @main entry point.
    helper_source = (root / 'Tests/Integration/CaptureEncodingChecks.swift').read_text()
    opening = '@main struct CaptureEncodingChecks {'
    ending = '    @MainActor static func main() async throws {'
    if helper_source.count(opening) != 1 or helper_source.count(ending) != 1:
        raise RuntimeError('Capture synthetic-helper extraction boundary changed.')
    factories = helper_source.split(opening, 1)[1].split(ending, 1)[0]
    combined = ((root / 'Sources/SiliconPlayer/CaptureController.swift').read_text()
                + '\nprivate enum CaptureSampleFactory {' + factories + '\n}\n'
                + (root / 'Tests/Integration/CaptureBoundaryChecks.swift').read_text())
    (temp / 'CaptureBoundaryChecks.swift').write_text(combined)
    capture = run(['xcrun', 'swiftc', '-parse-as-library', '-target', 'arm64-apple-macos14.0', temp / 'CaptureBoundaryChecks.swift',
                   '-o', temp / 'CaptureBoundaryChecks'], report / 'boundary-compile-capture.txt')
    metadata['results']['compile_capture'] = capture
    if capture['exit_code'] == 0:
        metadata['results']['capture'] = run([temp / 'CaptureBoundaryChecks'], report / 'capture-boundary-results.txt')

metadata['finished_at'] = time.strftime('%Y-%m-%dT%H:%M:%S%z')
metadata['passed'] = all(value['exit_code'] == 0 for value in metadata['results'].values())
(report / 'module-boundary-summary.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
raise SystemExit(0 if metadata['passed'] else 1)
