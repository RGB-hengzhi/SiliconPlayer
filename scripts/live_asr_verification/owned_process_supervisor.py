#!/usr/bin/env python3
"""Preparation source only: execution needs root's separate standalone GPU authorization.

Compiles exactly the frozen offscreen math source, never a player/application target.
Preserves verified source and executable copies in a new project Docs directory.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time

FROZEN_MANIFEST_SHA = 'f5aeaf8c5ce8f6695ce219e8658483ddc647491c9ec01fed44707b8a27eb3836'
REVIEW_SHA = '5d8a4646da655a63f67a404d23f1427a66098d2015cd622c068a8ca2f6fede34'
EIGHT_INPUT_NAMES = {
    'ColorKernel.metal', 'ColorReference.swift', 'OffscreenColorRunner.swift', 'README.md',
    'input-manifest.json', 'primary-source-notes.md', 'run_after_authorization.sh', 'static-review.json',
}
EXPECTED_BATCHES = {'full-sdr', 'full-pq', 'full-hlg', 'limited-sdr', 'limited-pq', 'limited-hlg'}
EXPECTED_THRESHOLDS = {
    'matrixAbsolute': 5e-6, 'float32Absolute': 2e-5, 'float32Relative': 3e-4,
    'rgba16FloatAbsolute': 6e-5, 'rgba16FloatRelative': 9e-4,
    'rule': 'absError <= absolute + relative * abs(reference)',
}
MAX_SMALL_TEXT = 16 * 1024 * 1024
MAX_OWN_BINARY = 32 * 1024 * 1024


def require(condition, reason):
    if not condition:
        raise RuntimeError(reason)


def bounded_bytes(path, maximum=MAX_SMALL_TEXT):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_size <= maximum, 'not a bounded regular file: ' + str(path))
        parts, count = [], 0
        while True:
            part = os.read(fd, 65536)
            if not part:
                break
            parts.append(part)
            count += len(part)
            require(count <= maximum, 'file grew beyond byte bound: ' + str(path))
        end = os.fstat(fd)
        require(end.st_size == count == info.st_size, 'file size changed during read: ' + str(path))
        return b''.join(parts)
    finally:
        os.close(fd)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def reject_duplicates(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'duplicate JSON member')
        value[key] = item
    return value


def document(data):
    return json.loads(data.decode('utf-8'), object_pairs_hook=reject_duplicates,
                      parse_constant=lambda value: (_ for _ in ()).throw(RuntimeError('non-finite JSON: ' + value)))


def durable_write(path, data, mode=0o600):
    # Exclusive materialized writes; no symlink/rename overwrite or APFS-only publish primitive.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            require(written > 0, 'short write: ' + str(path))
            view = view[written:]
        os.fsync(fd)
    finally:
        os.close(fd)


def save_json(path, value):
    durable_write(path, (json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n').encode('utf-8'))


def pin(path, maximum=MAX_SMALL_TEXT):
    data = bounded_bytes(path, maximum)
    return {'path': str(path), 'bytes': len(data), 'sha256': sha(data)}


def frozen_inputs(folder):
    manifest_bytes = bounded_bytes(folder / 'artifact-manifest.json')
    require(sha(manifest_bytes) == FROZEN_MANIFEST_SHA, 'frozen eight-input manifest SHA differs')
    manifest = document(manifest_bytes)
    records = manifest.get('files')
    require(isinstance(records, list) and len(records) == 8, 'frozen manifest must contain exactly eight inputs')
    require({record['path'] for record in records} == EIGHT_INPUT_NAMES, 'frozen input names differ/duplicate')
    payloads = {'artifact-manifest.json': manifest_bytes}
    pins = []
    for record in records:
        name = record['path']
        require(Path(name).name == name and not name.startswith('._'), 'input path is not an owned data basename')
        data = bounded_bytes(folder / name)
        require(len(data) == record['bytes'] and sha(data) == record['sha256'], 'frozen input bytes/SHA differ: ' + name)
        payloads[name] = data
        pins.append({'path': name, 'bytes': len(data), 'sha256': sha(data)})
    return payloads, sorted(pins, key=lambda record: record['path'])


def verify_materialized(folder, payloads):
    records = []
    for name, expected in sorted(payloads.items()):
        data = bounded_bytes(folder / name)
        require(data == expected, 'materialized input bytes differ: ' + str(folder / name))
        records.append({'path': name, 'bytes': len(data), 'sha256': sha(data)})
    return records


def owned_group_snapshot(pgid, environment):
    # Inspect only PID/PPID/PGID/state; retain only this owned group. No process
    # names, arguments or unrelated process rows are saved in public evidence.
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,stat='],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=1, env=environment, check=False)
    require(result.returncode == 0, 'owned group inspection failed')
    members = []
    for line in result.stdout.splitlines():
        fields = line.split()
        require(len(fields) == 4, 'owned group inspection row malformed')
        pid, ppid, group = (int(x) for x in fields[:3])
        if group == pgid:
            members.append({'pid': pid, 'ppid': ppid, 'pgid': group, 'state': fields[3]})
    require(len({item['pid'] for item in members}) == len(members), 'owned group inspection duplicated PID')
    return sorted(members, key=lambda item: item['pid'])


def terminate_timed_out_group(process, environment):
    # wait(timeout) raised while the child remained unreaped. Keep that leader
    # unreaped throughout TERM/grace/KILL, so its PID/PGID cannot be recycled.
    pgid, began, events, errors = process.pid, time.monotonic(), [], []
    last_members = None
    def snapshot(label):
        nonlocal last_members
        try:
            last_members = owned_group_snapshot(pgid, environment)
            events.append({'event': label, 'elapsedSeconds': time.monotonic() - began,
                           'members': last_members})
            return last_members
        except Exception as error:
            errors.append({'event': label, 'errorType': type(error).__name__,
                           'reason': 'owned process-group inspection unavailable'})
            last_members = None
            return None
    def live(members):
        return members is not None and any(not item['state'].startswith('Z') for item in members)
    def send(sig, label, members):
        # Never signal an uninspected/recycled PGID. The original child is still
        # held unreaped and must be present in this exact group snapshot.
        anchored = (process.returncode is None and members is not None
                    and any(item['pid'] == process.pid and item['pgid'] == pgid for item in members))
        if not anchored:
            errors.append({'event': label, 'reason': 'unreaped owned leader/group anchor unconfirmed'})
            return
        try:
            os.killpg(pgid, sig)
            events.append({'event': label, 'signal': int(sig), 'elapsedSeconds': time.monotonic() - began})
        except ProcessLookupError:
            # May have exited between snapshot and signal. The next snapshot is
            # still necessary; ESRCH alone is never the cleanup success proof.
            events.append({'event': label, 'signal': int(sig), 'result': 'ESRCH'})
        except Exception as error:
            errors.append({'event': label, 'errorType': type(error).__name__, 'reason': 'owned group signal failed'})
    members = snapshot('before-TERM')
    if live(members):
        send(signal.SIGTERM, 'TERM', members)
    grace_until = time.monotonic() + 2
    while members is not None and live(members) and time.monotonic() < grace_until:
        time.sleep(0.1)
        members = snapshot('TERM-grace')
    # This gate depends on the whole group's actual members, not whether the
    # leader has exited. In particular, TERM-resistant workers still get KILL.
    if live(members):
        send(signal.SIGKILL, 'KILL-surviving-group', members)
    kill_until = time.monotonic() + 3
    while members is not None and live(members) and time.monotonic() < kill_until:
        time.sleep(0.1)
        members = snapshot('KILL-confirmation')
    # Reap only after the group escalation/inspection phase has ended.
    leader_reaped = False
    try:
        process.wait(timeout=1)
        leader_reaped = True
    except subprocess.TimeoutExpired:
        errors.append({'event': 'reap', 'reason': 'owned leader still alive after group cleanup'})
        try:
            process.kill()  # Own unreaped direct child only; not an unknown PGID.
            process.wait(timeout=1)
            leader_reaped = True
        except Exception as error:
            errors.append({'event': 'reap-own-child', 'errorType': type(error).__name__, 'reason': 'owned direct child could not be reaped'})
    except Exception as error:
        errors.append({'event': 'reap', 'errorType': type(error).__name__, 'reason': 'owned direct child reap failed'})
    members = snapshot('after-leader-reap')
    # Bound orphan-zombie reaping as well. A residual or unknown group is saved
    # as unconfirmed cleanup, never hidden by the leader's wait return code.
    final_until = time.monotonic() + 1
    while members is not None and members and time.monotonic() < final_until:
        time.sleep(0.1)
        members = snapshot('final-group-confirmation')
    return {'ownedPGID': pgid, 'leaderHeldUnreapedThroughEscalation': True,
            'leaderReaped': leader_reaped, 'actualLeaderExitCode': process.returncode,
            'groupInspectionConfirmed': members is not None,
            'remainingOwnedGroupMembers': members,
            'liveOwnedGroupSurvivors': None if members is None else [x for x in members if not x['state'].startswith('Z')],
            'cleanupSucceeded': leader_reaped and members == [] and not errors,
            'events': events, 'errors': errors, 'elapsedSeconds': time.monotonic() - began,
            'scope': 'Original unreaped leader plus its inspected owned process group; escaped new-session descendants are not claimed.'}


def run_owned(command, folder, stem, timeout, environment):
    save_json(folder / (stem + '-command.json'), {'argv': command, 'timeoutSeconds': timeout,
                                               'cwd': str(folder), 'usesShell': False,
                                               'environment': environment})
    began = time.monotonic()
    forced, timed_out, cleanup = False, False, None
    with (folder / (stem + '.stdout.txt')).open('xb') as stdout, (folder / (stem + '.stderr.txt')).open('xb') as stderr:
        process = subprocess.Popen(command, cwd=folder, stdout=stdout, stderr=stderr,
                                   start_new_session=True, env=environment, close_fds=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out, forced = True, True
            cleanup = terminate_timed_out_group(process, environment)
            code = 124
        stdout.flush()
        stderr.flush()
        os.fsync(stdout.fileno())
        os.fsync(stderr.fileno())
    observation = {'argv': command, 'pid': process.pid, 'ownedPGID': process.pid, 'exitCode': code,
                   'actualProcessExitCode': process.returncode, 'timedOut': timed_out, 'forcedCleanup': forced,
                   'timeoutCleanup': cleanup, 'environment': environment,
                   'elapsedSeconds': time.monotonic() - began,
                   'naturalExit': not timed_out and not forced and code >= 0}
    save_json(folder / (stem + '-observation.json'), observation)
    durable_write(folder / (stem + '.exit.txt'), (str(code) + '\n').encode('ascii'))
    return observation


def require_natural_zero(observation, name):
    require(observation['exitCode'] == 0 and observation['naturalExit'] is True
            and observation['timedOut'] is False and observation['forcedCleanup'] is False,
            name + ' did not return natural exit0; preserve logs and create a new reviewed attempt')


def executable_pin(path):
    data = bounded_bytes(path, MAX_OWN_BINARY)
    require(len(data) >= 32, 'compiled executable is too short')
    magic, cpu = struct.unpack('<II', data[:8])
    require(magic == 0xFEEDFACF and cpu == 0x0100000C, 'compiled executable is not thin arm64 Mach-O')
    require(os.access(path, os.X_OK), 'compiled artifact is not executable')
    return data, {'path': str(path), 'bytes': len(data), 'sha256': sha(data), 'architecture': 'thin-arm64'}


def verify_result(folder, source_pins):
    data = bounded_bytes(folder / 'result.json')
    value = document(data)
    require(value.get('status') == 'passed' and value.get('scope') == 'offscreen-color-math-only', 'math result failed/incomplete/wrong scope')
    require(value.get('releaseGroupsAdded') == 0 and value.get('rendererAcceptance') is False
            and value.get('physicalHDRAcceptance') is False, 'result improperly claims application/physical HDR acceptance')
    require(value.get('thresholdsDeclaredBeforeRun') == EXPECTED_THRESHOLDS, 'preset thresholds differ')
    require(value.get('CPUReferenceAnchorFailures') == [] and value.get('shaderFastMathEnabled') is False
            and value.get('MSLLanguageVersion') == '2.3', 'reference/compiler policy differs')
    by_name = {record['path']: record for record in source_pins}
    expected_sources = {name: {key: by_name[name][key] for key in ('bytes', 'sha256')}
                        for name in ('ColorKernel.metal', 'ColorReference.swift', 'OffscreenColorRunner.swift')}
    reported = value.get('sourcePins')
    require(isinstance(reported, list) and len(reported) == 3, 'runner source pin list missing')
    require({record['file']: {key: record[key] for key in ('bytes', 'sha256')} for record in reported} == expected_sources,
            'runner final source pins differ from frozen compiled inputs')
    batches = value.get('batches')
    require(isinstance(batches, list) and len(batches) == 6
            and {batch.get('id') for batch in batches} == EXPECTED_BATCHES, 'six complete unique batches missing')
    artifacts = []
    for batch in batches:
        require(batch.get('status') == 'passed' and batch.get('sampleCount') == 1038
                and batch.get('failures') == [] and batch.get('checks')
                and all(check.get('passed') is True for check in batch['checks']), 'batch did not meet frozen assertions')
        raw = batch.get('rawArtifacts')
        require(isinstance(raw, list) and len(raw) == 4, 'batch raw readback inventory missing')
        for record in raw:
            name = record.get('file')
            require(isinstance(name, str) and Path(name).name == name and not name.startswith('._'), 'unowned raw artifact path')
            payload = bounded_bytes(folder / name)
            require(len(payload) == record.get('bytes') and sha(payload) == record.get('sha256'), 'actual readback artifact bytes/SHA differ')
            artifacts.append({'path': name, 'bytes': len(payload), 'sha256': sha(payload)})
        name = batch.get('readbackFile')
        require(isinstance(name, str) and Path(name).name == name, 'unowned per-sample readback path')
        rows = document(bounded_bytes(folder / name)).get('rows')
        require(isinstance(rows, list) and len(rows) == 1038
                and len({row['sample'] for row in rows}) == 1038
                and all(row.get('failures') == [] for row in rows), 'complete unique per-sample readback missing')
        artifacts.append(pin(folder / name))
    require(len({record['path'] for record in artifacts}) == 30, 'readback artifact names duplicate')
    return {'resultPin': {'bytes': len(data), 'sha256': sha(data)}, 'batchCount': 6,
            'samplesPerBatch': 1038, 'actualReadbackPins': artifacts}


def main():
    parser = argparse.ArgumentParser(description='Not-run preparation; execute only after root standalone authorization')
    parser.add_argument('--execute-after-root-authorization', action='store_true', required=True)
    parser.add_argument('--expected-wrapper-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True, help='New exclusive directory inside this project Docs/Prototypes/Metal-0.6')
    args = parser.parse_args()
    own_path = Path(__file__).absolute()
    own_bytes = bounded_bytes(own_path)
    require(sha(own_bytes) == args.expected_wrapper_sha256, 'wrapper SHA does not match root-reviewed invocation')
    require(sys.platform == 'darwin' and platform.machine() == 'arm64', 'native arm64 macOS is required')
    metal_root = own_path.parent.parent.resolve(strict=True)
    output_parent = args.output.parent.resolve(strict=True)
    require(args.output.is_absolute() and output_parent == metal_root, 'output must be a new direct child of project Docs/Prototypes/Metal-0.6')
    output = output_parent / args.output.name
    require(output.name not in ('.', '..'), 'invalid output name')
    output.mkdir(mode=0o700, exist_ok=False) # exFAT-compatible exclusive reservation; no atomic tree claim.
    stage, failures, work, durable_inputs_verified = 'freeze-verification', [], None, False
    payloads, before, binary_before, durable_binary_before, result_check = None, None, None, None, None
    observations = {}
    try:
        durable_write(output / 'reviewed-wrapper.py', own_bytes)
        save_json(output / 'request.json', {'recordedUTC': datetime.now(timezone.utc).isoformat(),
                   'argv': sys.argv, 'wrapperSHA256': sha(own_bytes), 'frozenDraftManifestSHA256': FROZEN_MANIFEST_SHA,
                   'reviewSHA256': REVIEW_SHA, 'scope': 'standalone offscreen color math only',
                   'applicationGroupsAdded': 0, 'nativeMetalRendererComplete': False, 'physicalHDRValidated': False})
        original = metal_root / 'offscreen-color-draft'
        payloads, before = frozen_inputs(original)
        review = bounded_bytes(metal_root / 'offscreen-color-readonly-review' / 'review.json')
        require(sha(review) == REVIEW_SHA, 'independent frozen draft review SHA differs')
        durable_write(output / 'frozen-draft-review.json', review)
        save_json(output / 'original-input-pins-before.json', before)
        source_copy = output / 'frozen-inputs'
        source_copy.mkdir()
        for name, data in payloads.items():
            durable_write(source_copy / name, data)
        save_json(output / 'durable-input-pins-before.json', verify_materialized(source_copy, payloads))
        durable_inputs_verified = True
        work = Path(tempfile.mkdtemp(prefix='siliconplayer-metal-durable-', dir='/private/tmp'))
        work_inputs = work / 'inputs'
        work_inputs.mkdir()
        for name, data in payloads.items():
            durable_write(work_inputs / name, data)
        durable_write(output / 'APFS_WORK_DIRECTORY.txt', (str(work) + '\n').encode('utf-8'))
        save_json(output / 'compile-input-pins-before.json', verify_materialized(work_inputs, payloads))
        # Fixed private environment: never inherit PATH/proxy/DYLD/SWIFT/NODE
        # settings or use the user's HOME/cache during this standalone compile.
        private_home, private_tmp = work / 'home', work / 'tmp'
        private_home.mkdir(mode=0o700)
        private_tmp.mkdir(mode=0o700)
        environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'en_US.UTF-8',
                       'LC_ALL': 'en_US.UTF-8', 'HOME': str(private_home),
                       'TMPDIR': str(private_tmp) + '/'}
        save_json(output / 'fixed-environment.json', environment)
        stage = 'compiler-version'
        observations['compilerVersion'] = run_owned(['/usr/bin/xcrun', 'swiftc', '--version'], output, 'compiler-version', 15, environment)
        require_natural_zero(observations['compilerVersion'], stage)
        stage = 'standalone-Swift-compile'
        binary = work / 'color-probe'
        command = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                   '-target', 'arm64-apple-macos14.0', str(work_inputs / 'ColorReference.swift'),
                   str(work_inputs / 'OffscreenColorRunner.swift'), '-framework', 'Metal',
                   '-framework', 'Foundation', '-o', str(binary)]
        observations['compile'] = run_owned(command, output, 'compile', 120, environment)
        require_natural_zero(observations['compile'], stage)
        save_json(output / 'compile-input-pins-after.json', verify_materialized(work_inputs, payloads))
        binary_bytes, binary_before = executable_pin(binary)
        artifacts = output / 'artifacts'
        artifacts.mkdir()
        durable_write(artifacts / 'color-probe', binary_bytes, mode=0o700)
        copied_bytes, durable_binary_before = executable_pin(artifacts / 'color-probe')
        require(copied_bytes == binary_bytes, 'durable executable copy bytes differ')
        save_json(output / 'executable-pins-before-run.json', {'APFS': binary_before, 'durable': durable_binary_before})
        save_json(output / 'pre-GPU-input-pins.json', {'original': frozen_inputs(original)[1],
                  'compileCopies': verify_materialized(work_inputs, payloads),
                  'durableCopies': verify_materialized(source_copy, payloads)})
        stage = 'standalone-Metal-compute'
        command = [str(binary), '--allow-gpu-execution', '--shader', str(work_inputs / 'ColorKernel.metal'),
                   '--output', str(output / 'gpu-readback')]
        observations['run'] = run_owned(command, output, 'run', 120, environment)
        require_natural_zero(observations['run'], stage)
        stage = 'actual-result-validation'
        result_check = verify_result(output / 'gpu-readback', before)
        save_json(output / 'result-validation.json', result_check)
    except Exception as error:
        failures.append({'stage': stage, 'errorType': type(error).__name__, 'reason': str(error)})
    finally:
        # A failed compiler may still leave an output. Preserve its bytes as unaccepted
        # forensic evidence; never execute it or call it a valid built executable.
        if work is not None and (work / 'color-probe').exists() and not (output / 'artifacts' / 'color-probe').exists():
            try:
                partial = bounded_bytes(work / 'color-probe', MAX_OWN_BINARY)
                (output / 'artifacts').mkdir(exist_ok=True)
                durable_write(output / 'artifacts' / 'unaccepted-compiler-output', partial)
                save_json(output / 'unaccepted-compiler-output-pin.json',
                          {'bytes': len(partial), 'sha256': sha(partial), 'acceptedExecutable': False})
            except Exception as error:
                failures.append({'stage': 'preserve-unaccepted-compiler-output', 'errorType': type(error).__name__, 'reason': str(error)})
        # Verify source/binary ownership even after compile/GPU failures; do not hide primary errors.
        if payloads is not None:
            try:
                original_after = frozen_inputs(metal_root / 'offscreen-color-draft')[1]
                require(original_after == before, 'original eight inputs changed')
                end = {'original': original_after,
                       'durableCopies': verify_materialized(output / 'frozen-inputs', payloads)}
                if work is not None:
                    end['compileCopies'] = verify_materialized(work / 'inputs', payloads)
                save_json(output / 'all-input-pins-after.json', end)
                require(sha(bounded_bytes(own_path)) == sha(own_bytes), 'reviewed wrapper changed during execution')
                if binary_before is not None:
                    _, binary_after = executable_pin(work / 'color-probe')
                    _, durable_after = executable_pin(output / 'artifacts' / 'color-probe')
                    require(binary_after == binary_before and durable_after == durable_binary_before, 'executable changed during GPU run')
                    save_json(output / 'executable-pins-after-run.json', {'APFS': binary_after, 'durable': durable_after})
            except Exception as error:
                failures.append({'stage': 'post-run-pins', 'errorType': type(error).__name__, 'reason': str(error)})
        passed = not failures and result_check is not None
        summary = {'schemaVersion': 1, 'status': 'offscreen-math-passed' if passed else 'failed',
                   'recordedUTC': datetime.now(timezone.utc).isoformat(), 'observations': observations,
                   'failures': failures, 'APFSWorkDirectoryPreserved': str(work) if work else None,
                   'durableProjectEvidenceDirectory': str(output), 'frozenEightSourceInputsCopiedAndVerified': durable_inputs_verified,
                   'wrapperSHA256': sha(own_bytes), 'frozenDraftManifestSHA256': FROZEN_MANIFEST_SHA,
                   'resultValidation': result_check, 'applicationGroupsAdded': 0, 'releaseGroupsAdded': 0,
                   'nativeMetalRendererComplete': False, 'physicalHDRValidated': False,
                   'directoryTreeAtomicallyPublished': False,
                   'durabilityScope': 'Project Docs retains materialized sources/executable/logs with file fsync. No exFAT atomic-tree or power-loss directory-metadata guarantee.'}
        save_json(output / 'wrapper-summary.json', summary)
        # Last-written completion marker is explicit successful/failed status, never presence alone.
        save_json(output / 'COMPLETION.json', {'status': summary['status'], 'allChecksPassed': passed,
                  'summarySHA256': sha(bounded_bytes(output / 'wrapper-summary.json')),
                  'sourceManifestSHA256': FROZEN_MANIFEST_SHA, 'wrapperSHA256': sha(own_bytes),
                  'releaseGroupsAdded': 0, 'directoryTreeAtomicallyPublished': False, 'lastWritten': True})
        print(json.dumps({'status': summary['status'], 'output': str(output), 'releaseGroupsAdded': 0}))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
