#!/usr/bin/env python3
"""Prepared standalone PCM/PTS driver. Never runs from import; no App/ASR/mic."""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import selectors
import signal
import struct
import subprocess
import sys
import tempfile
import time

INPUT_SHA = '24aeb113af71d05f374d8e4dabae0e3006190c20e4d4ee805ed45ae455fa2fd7'
C_SHA = '6763b8e65f1862f62d235d2bbbf967ce6879c88d17e45620eef67d810b316983'
PROTOCOL_SHA = '2a92a61d13a0daa303c0bfd4f5709d0b9f4ecdbc732bfbdf0a915d9cbeaa1582'
SUPERVISOR_SHA = 'f84d9f94e2a759342294441b16b62e2b65d7834eab31d764de44ad54e6d82406'
ABI_READER_SHA = 'b3ad55bd34f6c1ff713129afac56a8d0d6627abcfe8d851b45a46c32b593d429'
NOPTS = -(1 << 63)
BASELINE = ('track-zho', 'track-eng', 'speech-wav', 'resample-wav')
CASES = BASELINE + ('seek-pause', 'track-switch', 'queue-switch', 'speed-pace',
                    'cancel-signal', 'seek-backpressure', 'cancel-backpressure', 'reject-video', 'time-domain')


def require(value, reason):
    if not value:
        raise RuntimeError(reason)


def sha(path):
    require(path.is_file() and not path.is_symlink(), 'Materialized input required')
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(65536), b''):
            digest.update(chunk)
    return digest.hexdigest()


def pairs(items):
    value = {}
    for key, item in items:
        require(key not in value, 'Duplicate JSON key')
        value[key] = item
    return value


def parse(data):
    return json.loads(data, object_pairs_hook=pairs,
                      parse_constant=lambda value: (_ for _ in ()).throw(RuntimeError('Nonfinite JSON')))


def save(path, value):
    with path.open('x', encoding='utf-8') as handle:
        json.dump(value, handle, indent=2, ensure_ascii=False, allow_nan=False)
        handle.write('\n'); handle.flush(); os.fsync(handle.fileno())


def copy(path, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open('xb') as handle:
        handle.write(path.read_bytes()); handle.flush(); os.fsync(handle.fileno())
    target.chmod(path.stat().st_mode & 0o777)
    require(sha(path) == sha(target), 'Durable copy mismatch')


def module(path, expected, name):
    require(sha(path) == expected, 'Helper dependency source changed')
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value


def packets(data):
    cursor, rows = 0, []
    while cursor < len(data):
        require(len(data) - cursor >= 112, 'Truncated SPCM header')
        magic, version, size, total, flags = struct.unpack_from('<4sHHII', data, cursor)
        require(magic == b'SPCM' and version == 1 and size == 112 and flags & ~7 == 0, 'SPCM identity/flags invalid')
        epoch, segment, item = struct.unpack_from('<QQQ', data, cursor + 16)
        stream, numerator, denominator, rate = struct.unpack_from('<IIII', data, cursor + 40)
        source, pts, time_denominator, delay = struct.unpack_from('<qqqq', data, cursor + 56)
        sequence, count, input_rate, ordinal, offset = struct.unpack_from('<QIIII', data, cursor + 88)
        require(1 <= count <= 320 and rate == 16000 and 8000 <= input_rate <= 96000 and numerator > 0 and denominator > 0,
                'SPCM PCM/timebase bounds invalid')
        require(total == 112 + count * 4 and cursor + total <= len(data), 'Truncated SPCM payload')
        waveform = struct.unpack_from('<' + 'f' * count, data, cursor + 112)
        require(all(math.isfinite(x) for x in waveform) and time_denominator == input_rate * 16000, 'Nonfinite PCM/bad clock units')
        require(bool(flags & 1) == (pts != NOPTS) and bool(flags & 2) == (pts != NOPTS and pts < 0), 'False known/negative PTS flag')
        rows.append({'sequence': sequence, 'epoch': epoch, 'segment': segment, 'item': item, 'stream': stream,
                     'source': source, 'pts': pts, 'denominator': time_denominator, 'delay': delay,
                     'samples': count, 'ordinal': ordinal, 'offset': offset, 'flags': flags,
                     'timeBase': [numerator, denominator], 'inputRate': input_rate,
                     'pcmSHA256': hashlib.sha256(data[cursor + 112:cursor + total]).hexdigest()})
        cursor += total
    require([r['sequence'] for r in rows] == list(range(1, len(rows) + 1)), 'SPCM global sequence incomplete')
    return rows


def near_away(numerator, denominator):
    value, remainder = divmod(abs(numerator), denominator)
    if remainder * 2 >= denominator: value += 1
    return -value if numerator < 0 else value


def run_case(name, argv, folder, environment, supervisor):
    folder.mkdir()
    began = time.monotonic(); events, commands, failure = [], [], None
    forced, timeout, cleanup = False, False, None
    pause_at, signal_at, ack_at, blocked_at = None, None, None, None
    process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=environment, cwd=folder, start_new_session=True, close_fds=True)
    selector = selectors.DefaultSelector()
    blocked = name in ('seek-backpressure', 'cancel-backpressure')
    for pipe, kind in ((process.stdout, 'pcm'), (process.stderr, 'json')):
        os.set_blocking(pipe.fileno(), False)
        if not blocked or kind == 'json': selector.register(pipe, selectors.EVENT_READ, kind)
    counts, line = {'pcm': 0, 'json': 0}, b''
    def send(text):
        process.stdin.write(text.encode('ascii')); process.stdin.flush()
        commands.append({'text': text, 'elapsedSeconds': time.monotonic() - began})
    def unblock():
        nonlocal blocked
        if blocked:
            selector.register(process.stdout, selectors.EVENT_READ, 'pcm'); blocked = False
    with (folder / 'stdout.spcm').open('xb') as pcm, (folder / 'stderr.jsonl').open('xb') as trace:
        try:
            while selector.get_map() or blocked:
                require(time.monotonic() - began < 60, 'Case deadline')
                if pause_at is not None and time.monotonic() - pause_at >= 0.15:
                    if name == 'seek-pause': send('SEEK 1 2 3000000\nRESUME 2\n')
                    elif name == 'track-switch': send('TRACK 1 2 2\nSEEK 2 3 2000000\nRESUME 3\n')
                    elif name == 'queue-switch': send('QUEUE 1 2\nRESUME 2\n')
                    pause_at = None
                if blocked_at is not None and time.monotonic() - blocked_at >= 0.2:
                    send('SEEK 1 2 3000000\n' if name == 'seek-backpressure' else 'CANCEL 1\n')
                    blocked_at = None
                for key, _ in selector.select(0.02):
                    data = os.read(key.fileobj.fileno(), 65536)
                    if not data:
                        selector.unregister(key.fileobj); key.fileobj.close(); continue
                    kind = key.data; counts[kind] += len(data)
                    (pcm if kind == 'pcm' else trace).write(data)
                    require(counts[kind] <= 16 * 1024 * 1024, 'Case output bound')
                    if kind != 'json': continue
                    line += data
                    while b'\n' in line:
                        raw, line = line.split(b'\n', 1); row = parse(raw); events.append(row)
                        if row['event'] == 'pcm' and len([r for r in events if r['event'] == 'pcm']) == 1:
                            if name in ('seek-pause', 'track-switch', 'queue-switch'): send('PAUSE 1\n')
                            elif name == 'speed-pace': send('SPEED 1 4\n')
                            elif name == 'cancel-signal':
                                signal_at = time.monotonic(); os.kill(process.pid, signal.SIGTERM)
                            elif name in ('seek-backpressure', 'cancel-backpressure'): blocked_at = time.monotonic()
                        if row['event'] == 'paused': pause_at = time.monotonic()
                        if row['event'] in ('epoch_changed', 'cancel_acknowledged') and blocked: unblock()
                        if row['event'] == 'cancel_acknowledged' and ack_at is None: ack_at = time.monotonic()
                require(len(line) <= 65536, 'JSON line bound')
            require(not line, 'Truncated JSON event')
            code = process.wait(timeout=5)
        except BaseException as error:
            failure = str(error); forced = True; timeout = 'deadline' in failure.lower()
            cleanup = supervisor.terminate_timed_out_group(process, environment); code = 124
        finally:
            selector.close()
            for pipe in (process.stdin, process.stdout, process.stderr):
                if not pipe.closed: pipe.close()
            pcm.flush(); trace.flush(); os.fsync(pcm.fileno()); os.fsync(trace.fileno())
    remaining = supervisor.owned_group_snapshot(process.pid, environment)
    receipt = {'id': name, 'argv': argv, 'pid': process.pid, 'ownedPGID': process.pid,
               'exitCode': code, 'actualProcessExitCode': process.returncode, 'forcedCleanup': forced,
               'timedOut': timeout, 'cleanup': cleanup, 'remainingOwnedProcesses': remaining,
               'commands': commands, 'signalSent': 'SIGTERM' if signal_at else None,
               'cancelAckSeconds': ack_at - signal_at if ack_at and signal_at else None,
               'failure': failure, 'elapsedSeconds': time.monotonic() - began}
    save(folder / 'process.json', receipt)
    require(not forced and not timeout and remaining == [] and code == (1 if name == 'reject-video' else 0), 'Natural process contract failed')
    if name == 'time-domain':
        require(any(r['event'] == 'time_domain_selftest' and r['passed'] is True and r['synthetic_only'] is True for r in events), 'Pure time-domain guard missing')
        return {'id': name, 'scope': 'synthetic-only-not-media', 'process': receipt}
    require(events[-1]['event'] == 'closed' and events[-1]['remaining_owned_contexts'] == 0, 'Decoder resources not closed')
    if name == 'reject-video':
        require(events[-1]['ok'] is False and any(r.get('category') == 'selected_stream_is_not_audio' for r in events), 'Wrong-stream rejection absent')
        return {'id': name, 'scope': 'actual-owned-rejection', 'process': receipt}
    require(events[-1]['ok'] is True and not any(r['event'] == 'error' for r in events), 'Helper API failure')
    records = packets((folder / 'stdout.spcm').read_bytes())
    metadata = [r for r in events if r['event'] == 'pcm']
    require(records and len(records) == len(metadata), 'Actual PCM/metadata pair missing')
    for record, row in zip(records, metadata):
        require(record['sequence'] == row['sequence'] and record['epoch'] == row['epoch'] and record['pts'] == row['pcm_pts']
                and record['source'] == row['source_pts'] and record['samples'] == row['samples'] and record['stream'] == row['stream_index'], 'IPC fields differ from telemetry')
        if record['flags'] & 1 and not record['flags'] & 4:
            scaled = near_away(record['source'] * record['timeBase'][0] * record['denominator'], record['timeBase'][1])
            require(record['pts'] == scaled - record['delay'] + record['offset'] * record['inputRate'],
                    'PCM PTS is not actual decoded source PTS minus measured swr delay plus exact sample offset')
        if not record['flags'] & 1: require(record['pts'] == NOPTS, 'Missing PTS fabricated from samples')
    if name in ('seek-pause', 'track-switch', 'queue-switch'):
        pause_index = next(i for i,r in enumerate(events) if r['event'] == 'paused')
        resume_index = next(i for i,r in enumerate(events) if r['event'] == 'resumed')
        require(not any(r['event'] == 'pcm' for r in events[pause_index+1:resume_index]), 'New PCM published during acknowledged pause')
    target_epoch = 3 if name == 'track-switch' else 2
    if name in ('seek-pause', 'seek-backpressure', 'track-switch', 'queue-switch'):
        new = [r for r in records if r['epoch'] == target_epoch]
        require(new, 'No real frame after requested epoch change')
        require(all(r['item'] == 2 for r in new) if name == 'queue-switch' else True, 'Queue identity not changed')
        require(all(r['stream'] == 2 for r in new) if name == 'track-switch' else True, 'Selected track not applied')
        if name != 'queue-switch':
            target = 2 if name == 'track-switch' else 3
            require(new[0]['flags'] & 1 and target <= new[0]['pts']/new[0]['denominator'] <= target + 0.05, 'Actual post-seek frame not near target')
        ack = next(i for i,r in enumerate(events) if r['event'] in ('epoch_changed','media_opened') and r['epoch'] >= target_epoch)
        require(all(r['epoch'] >= target_epoch or r.get('completed_old_epoch_inflight_record') is True
                    for r in events[ack+1:] if r['event'] == 'pcm'), 'Unmarked stale packet after epoch acknowledged')
    if name in ('cancel-signal','cancel-backpressure'):
        require(events[-1]['cancelled'] is True and ack_at is not None, 'Actual cancel/cleanup missing')
        if name == 'cancel-signal': require(receipt['cancelAckSeconds'] <= 2, 'Owned cancel exceeded candidate bound')
    if name == 'speed-pace': require(any(r['event']=='speed_changed' for r in events), 'Speed control not acknowledged')
    if name == 'resample-wav': require(any(r['inputRate'] != 16000 and r['delay'] > 0 for r in records), 'No actual nonzero resampling delay case')
    save(folder / 'decoded-packet-evidence.json', {'records': records, 'rawSHA256': sha(folder / 'stdout.spcm'),
                                                'traceSHA256': sha(folder / 'stderr.jsonl'), 'applicationGroupsAdded': 0})
    return {'id': name, 'scope': 'actual-owned-decoder-prototype', 'packets': len(records), 'process': receipt}


def execute(args, tracked):
    leaf = Path(__file__).resolve().parent; project = leaf.parents[3]
    pins = parse((leaf / 'input-pins.json').read_bytes()); require(sha(leaf/'input-pins.json') == INPUT_SHA, 'Prepared input manifest drift')
    require(sha(leaf/'media_pcm_pts.c') == C_SHA and sha(leaf/'protocol.json') == PROTOCOL_SHA, 'Reviewed C/IPC contract drift')
    before = {str(Path(__file__)): sha(Path(__file__)), str(leaf/'media_pcm_pts.c'): sha(leaf/'media_pcm_pts.c'),
              str(leaf/'protocol.json'): sha(leaf/'protocol.json'), str(leaf/'input-pins.json'): INPUT_SHA}
    require(sha(project/'Vendor/manifest.json') == pins['VendorManifestSHA256'] and sha(project/'Vendor/tools/manifest.json') == pins['VendorToolsManifestSHA256'], 'Vendor metadata drift')
    before[str(project/'Vendor/manifest.json')]=pins['VendorManifestSHA256'];before[str(project/'Vendor/tools/manifest.json')]=pins['VendorToolsManifestSHA256']
    for row in pins['headers']:
        require(sha(leaf/row['path']) == row['sha256'], 'Pinned materialized header drift'); before[str(leaf/row['path'])] = row['sha256']
    for row in pins['runtimeLibrariesByVendorManifest'] + pins['fixtureReferencesFromFrozenSnapshot'] + [pins['ffprobe']]:
        path = project/row['path']; require(sha(path) == row['sha256'], 'Runtime/fixture/tool payload drift'); before[str(path)] = row['sha256']
    tracked.update(before)
    work = Path(tempfile.mkdtemp(prefix='siliconplayer-media-pcm-pts-', dir='/private/tmp'))
    save(args.output/'APFS-work.json', {'path':str(work),'retained':True})
    filesystem = subprocess.run(['/bin/df','-P',str(work)],capture_output=True,text=True,check=False,timeout=10)
    require(filesystem.returncode == 0 and len(filesystem.stdout.splitlines()) == 2, 'APFS volume lookup failed')
    device = filesystem.stdout.splitlines()[1].split()[0]
    volume = subprocess.run(['/usr/sbin/diskutil','info','-plist',device],capture_output=True,check=False,timeout=10)
    import plistlib
    require(volume.returncode == 0 and plistlib.loads(volume.stdout).get('FilesystemType') == 'apfs', 'APFS work required')
    for directory in ('home','tmp','runtime-libs','headers'): (work/directory).mkdir()
    environment={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LANG':'en_US.UTF-8','LC_ALL':'en_US.UTF-8','HOME':str(work/'home'),'TMPDIR':str(work/'tmp')+'/'}
    save(args.output/'fixed-environment.json',environment)
    copy(leaf/'media_pcm_pts.c',work/'media_pcm_pts.c')
    for row in pins['headers']: copy(leaf/row['path'],work/row['path'])
    for row in pins['runtimeLibrariesByVendorManifest']:
        for destination in (work/'runtime-libs',args.output/'artifacts/runtime-libs'): copy(project/row['path'],destination/Path(row['path']).name)
    supervisor_path=project/'Docs/Prototypes/Metal-0.6/offscreen-color-durable-wrapper-v2/run_durable.py'
    abi_path=project/'Docs/Prototypes/LiveASR-0.6/online-c-api-driver-draft-v1/run_after_authorization.py'
    supervisor=module(supervisor_path,SUPERVISOR_SHA,'owned_supervisor'); abi_reader=module(abi_path,ABI_READER_SHA,'abi_reader')
    for path in (supervisor_path,abi_path): before[str(path)]=sha(path);copy(path,args.output/('reviewed-'+path.parent.name+'.py'))
    binary=work/'media-pcm-pts'; libs=[work/'runtime-libs'/name for name in ('libavformat.63.dylib','libavcodec.63.dylib','libavutil.61.dylib','libswresample.7.dylib')]
    argv=['/usr/bin/xcrun','clang','-std=c11','-O2','-target','arm64-apple-macos14.0','-I',str(work/'headers'),str(work/'media_pcm_pts.c')]+[str(p) for p in libs]+['-Wl,-rpath,@executable_path/runtime-libs','-o',str(binary)]
    version=supervisor.run_owned(['/usr/bin/xcrun','clang','--version'],args.output,'compiler-version',30,environment)
    supervisor.require_natural_zero(version,'compiler version')
    compiled=supervisor.run_owned(argv,args.output,'compile',120,environment)
    if binary.exists(): copy(binary,args.output/'artifacts/media-pcm-pts')
    supervisor.require_natural_zero(compiled,'PCM helper compile')
    abi=[abi_reader.macho(path) for path in [binary]+sorted((work/'runtime-libs').iterdir())]
    by_name={Path(row['path']).name:row for row in pins['runtimeLibrariesByVendorManifest']}
    require(abi[0]['rpaths']==['@executable_path/runtime-libs'], 'Compiled helper rpath differs')
    for row in abi[1:]:
        require(row['loads']==by_name[Path(row['path']).name]['dependencies'], 'Actual library load commands differ from fixed Vendor closure')
    save(args.output/'binary-and-libraries-ABI.json',abi)
    for path in [binary]+sorted((work/'runtime-libs').iterdir())+list((args.output/'artifacts').rglob('*')):
        if path.is_file() and not path.name.startswith('._'):before[str(path)]=sha(path)
    for path in (work/'media_pcm_pts.c',*list((work/'headers').rglob('*.h'))):before[str(path)]=sha(path)
    tracked.update(before)
    save(args.output/'pre-decode-input-pins.json',before)
    fixture={Path(r['path']).name:project/r['path'] for r in pins['fixtureReferencesFromFrozenSnapshot']}
    multi=fixture['多音轨双字幕.mkv'];speech=fixture['UI 手工 07 中文语音.wav'];wav=fixture['wav.wav']
    outcomes=[]
    for name in CASES:
        if name=='time-domain': command=[str(binary),'--time-domain-selftest']
        else:
            path=speech if name=='speech-wav' else wav if name=='resample-wav' else multi
            stream=0 if name in ('speech-wav','resample-wav','reject-video') else 2 if name=='track-eng' else 1
            command=[str(binary),'--input',str(path),'--audio-stream',str(stream),'--epoch','1','--item','1']
            if name not in BASELINE and name not in ('reject-video','seek-backpressure','cancel-backpressure'): command.append('--paced')
            if name=='queue-switch':command+=['--next-input',str(speech),'--next-audio-stream','0','--next-item','2']
        outcomes.append(run_case(name,command,args.output/name,environment,supervisor))
    zho=parse((args.output/'track-zho/decoded-packet-evidence.json').read_bytes())['records']
    eng=parse((args.output/'track-eng/decoded-packet-evidence.json').read_bytes())['records']
    require([r['pcmSHA256'] for r in zho] != [r['pcmSHA256'] for r in eng], 'Different selected tracks produced identical PCM content')
    for name,path,stream in (('track-zho',multi,1),('track-eng',multi,2),('speech-wav',speech,0),('resample-wav',wav,0)):
        ref=supervisor.run_owned([str(project/'Vendor/tools/ffprobe'),'-v','error','-select_streams',str(stream),'-show_frames','-show_entries','frame=stream_index,best_effort_timestamp,pts,nb_samples','-of','json',str(path)],args.output,'reference-'+name,30,environment)
        supervisor.require_natural_zero(ref,'actual decoded frame reference')
        reference=parse((args.output/('reference-'+name+'.stdout.txt')).read_bytes())['frames']
        trace=[parse(line) for line in (args.output/name/'stderr.jsonl').read_bytes().splitlines()]
        frames=[r for r in trace if r['event']=='decoded_frame']
        require(len(frames)==len(reference) and all(a['best_effort_timestamp']==int(b.get('best_effort_timestamp',NOPTS)) and a['input_samples']==int(b['nb_samples']) and a['stream_index']==b['stream_index'] for a,b in zip(frames,reference)), 'Actual frame PTS/count/track differs from pinned ffprobe')
    after={path:sha(Path(path)) for path in before};save(args.output/'input-pins-after.json',after);require(before==after,'Decode inputs changed')
    save(args.output/'summary.json',{'status':'passed-covered-decoder-prototype-cases','cases':outcomes,'prototypeCaseCount':len(outcomes),'applicationGroupsAdded':0,'releaseGroupsAdded':0,'inputsUnchanged':True,'actualNegativeAndMissingPTSFixtureAcceptance':False,'AppClockOrASRWordAlignmentAcceptance':False,'scope':'Local owned source FD decode/resample/IPC only; pure time-domain selftest not actual-media boundary proof'})


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--execute-after-root-authorization',action='store_true',required=True)
    parser.add_argument('--expected-driver-sha256',required=True);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    require(platform.system()=='Darwin' and platform.machine()=='arm64' and sha(Path(__file__))==args.expected_driver_sha256,'Reviewed arm64 macOS launcher required')
    leaf=Path(__file__).resolve().parent
    require(args.output.is_absolute() and args.output.parent==leaf.parent and args.output.name.startswith('media-pcm-pts-actual-') and not args.output.exists() and not args.output.is_symlink(),'Fresh owned output leaf required')
    args.output.mkdir()
    tracked={}
    try:execute(args,tracked)
    except BaseException as error:
        after,missing={},[]
        for path in tracked:
            try:after[path]=sha(Path(path))
            except Exception:missing.append(path)
        save(args.output/'failed-input-pins-after.json',{'before':tracked,'after':after,'unreadablePaths':missing,'inputsUnchanged':bool(tracked) and not missing and tracked==after})
        save(args.output/'failure.json',{'status':'failed-preserved-no-retry','reason':str(error),'applicationGroupsAdded':0,'releaseGroupsAdded':0});raise


if __name__=='__main__':main()
