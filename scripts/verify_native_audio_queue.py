#!/usr/bin/env python3
"""Four actual-App local-audio groups against an explicitly pinned build.

After review/migration run from scripts/ against an explicitly hash-pinned App.
No build, network, daily preference writes, synthesized physical input, or
physical output-continuity claim. Each mode is one group; observations are not.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import signal
import stat
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
COMMON = {'private-profile-and-default-off-opt-in', 'owned-inspector-job-registry-empty', 'daily-shortcut-key-unchanged'}
CHECKS = {
 'native-audio-continuation': {
  'initial-a-real-audio-progress', 'natural-b-real-audio-progress', 'natural-c-real-audio-progress',
  'actual-natural-a-b-c-preserves-native-session', 'ninth-item-ordinary-boundary-next-controlled-window',
  'ninth-item-actual-audio-progress', 'nonloop-tail-never-reloads-initial-uuid',
  'terminal-eof-explicit-play-restarts-same-uuid-real-audio'},
 'native-audio-intent-lifecycle': {
  'autoplay-false-native-assembly-stays-paused', 'paused-append-reorder-delete-keeps-current-and-latest-uuids',
  'paused-queue-mutations-do-not-start-audio', 'explicit-play-overrides-initial-autoplay-false',
  'manual-next-keeps-real-playing-intent', 'manual-previous-keeps-real-pause-intent',
  'stop-retires-session-without-late-resurrection', 'stop-then-explicit-play-actually-rebuilds-and-advances',
  'stop-play-new-session-same-logical-uuid'},
 'native-audio-history-preferences': {
  'b-loaded-while-real-old-a-eof-held', 'actual-real-eof-copied-and-held',
  'stop-settles-all-loaded-own-duration-not-successor-duration', 'same-original-reload-new-session-real-progress',
  'copied-real-late-eof-dispatched', 'old-real-eof-does-not-overwrite-newer-original-url-history',
  'typed-owned-saved-preference-installed', 'saved-pref-boundary-uses-ordinary-load-without-dropping-overlay',
  'successor-resume-boundary-restores-position-and-base', 'ordinary-boundaries-still-play-real-audio'},
 'native-audio-loops-disable': {
  'actual-list-loop-wrap-preserves-entry-and-new-cycle', 'actual-file-loop-keeps-original-uuid',
  'actual-a-only-mark-is-not-complete-ab', 'actual-a-only-clears-after-different-native-media',
  'actual-complete-ab-keeps-current-media', 'actual-unexpected-ab-successor-fails-closed',
  'disable-mode-resets-native-list-loop-preserving-current', 'ordinary-next-again-obeys-autoplay-false',
  'ordinary-load-after-disable-cannot-inherit-native-loop'},
}

def require(value, message):
    if not value: raise RuntimeError(message)

def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for data in iter(lambda: stream.read(4 * 1024 * 1024), b''): h.update(data)
    return h.hexdigest()

def write(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False)+'\n', encoding='utf-8')

def inventory(app):
    return {str(path.relative_to(app)): digest(path) for path in sorted(app.rglob('*'))
            if path.is_file() and not path.name.startswith('._')}

def pins(app):
    provenance = json.loads((app/'Contents/Resources/build-provenance.json').read_text())
    require(provenance['inputFilesUnchanged'] is True, 'Compilation input drift')
    result = dict(provenance['inputFiles'])
    result['scripts/verify_native_audio_queue.py'] = digest(ROOT/'scripts/verify_native_audio_queue.py')
    require(all(digest(ROOT/name) == sha for name,sha in result.items()), 'Current inputs differ from App provenance')
    require('Sources/SiliconPlayer/NativeAudioQueueVerifier.swift' in result, 'Verifier not bound to actual App build')
    return result

def bounded_regular_bytes(path, limit=1_048_576):
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        information = os.fstat(fd)
        require(stat.S_ISREG(information.st_mode) and 0 <= information.st_size <= limit, 'Not a bounded regular file')
        result = bytearray()
        while len(result) <= limit:
            data = os.read(fd, min(65536, limit+1-len(result)))
            if not data: break
            result.extend(data)
        require(len(result) <= limit, 'Regular file grew past bound')
        return bytes(result)
    finally: os.close(fd)

def daily_shortcut_key(bundle_id):
    path = Path.home()/'Library/Preferences'/(bundle_id+'.plist')
    try: value = plistlib.loads(bounded_regular_bytes(path)).get('SiliconPlayer.shortcuts.v1')
    except FileNotFoundError: return 'missing'
    if value is None: return 'missing'
    return hashlib.sha256(plistlib.dumps({'value':value}, fmt=plistlib.FMT_BINARY, sort_keys=True)).hexdigest()

def suite_state(path):
    try: raw = bounded_regular_bytes(path)
    except FileNotFoundError: return {'state':'absent', 'cleared':True}
    except (OSError, RuntimeError) as error: return {'state':'unreadable-or-unbounded', 'cleared':False, 'errorType':type(error).__name__}
    try:
        value = plistlib.loads(raw); empty = isinstance(value, dict) and not value
        return {'state':'empty' if empty else 'nonempty', 'cleared':empty, 'bytes':len(raw),
                'sha256':hashlib.sha256(raw).hexdigest(), 'keyCount':len(value) if isinstance(value,dict) else None}
    except (ValueError, plistlib.InvalidFileException) as error:
        return {'state':'invalid-plist', 'cleared':False, 'bytes':len(raw), 'errorType':type(error).__name__}

def readonly_suite_clear(path, evidence_path):
    started = time.monotonic(); before = suite_state(path); after = before; polls = 1
    while not after['cleared'] and time.monotonic()-started < 3.0:
        time.sleep(min(.05, max(0, 3.0-(time.monotonic()-started))))
        after = suite_state(path); polls += 1
    value = {'domainPlist':str(path), 'timeoutSeconds':3.0, 'waitDurationSeconds':time.monotonic()-started,
             'pollCount':polls, 'before':before, 'after':after, 'cleared':after['cleared'],
             'scope':'Read-only exact verification suite after natural exit; no domain/plist deletion or daemon termination.'}
    write(evidence_path,value); require(after['cleared'], 'Private verification suite survived natural exit')
    return value

def termination_barrier(report, storage, mode):
    suite = 'local.siliconplayer.verification.'+hashlib.sha256((str(report)+'\0'+str(storage)).encode()).hexdigest()
    path = report.with_suffix('.suite-termination.json')
    value = json.loads(bounded_regular_bytes(path))
    require(value.get('suite')==suite and value.get('mode')==mode, 'Foreign termination identity')
    require(all(value.get(key) is True for key in ['sameBoundInstance','writesClosed','synchronizeSucceeded',
                'memoryDomainEmpty','succeeded','terminationAllowed']) and value.get('afterKeys')==[]
            and value.get('phase') in ['before-terminateNow','before-reply-true'], 'Actual termination barrier failed')
    began, ended = value.get('startedUptime'), value.get('finishedUptime')
    numeric = lambda x: isinstance(x,(int,float)) and not isinstance(x,bool) and math.isfinite(x) and x >= 0
    require(numeric(began) and numeric(ended) and ended>=began and isinstance(value.get('invocation'),int)
            and value['invocation']>=1, 'Invalid termination order')
    disk = value.get('diskBarrier',{}); plist = Path.home()/'Library/Preferences'/(suite+'.plist')
    start, finish, elapsed = (disk.get(key) for key in ['startedUptime','finishedUptime','waitDurationSeconds'])
    require(disk.get('domainPlist')==str(plist) and disk.get('diskDomainEmpty') is True
            and disk.get('timeoutSeconds')==15.0 and isinstance(disk.get('pollCount'),int)
            and not isinstance(disk['pollCount'],bool) and disk['pollCount']>=1, 'Foreign/incomplete pre-exit disk barrier')
    require(all(numeric(x) for x in [start,finish,elapsed]) and finish>=start>=began and ended==finish
            and abs((finish-start)-elapsed)<.001 and elapsed<=15.5, 'Invalid disk barrier timing')
    after = disk.get('after',{})
    require(after.get('state') in ['absent','empty'] and after.get('cleared') is True
            and (after['state']=='absent' or after.get('keyCount')==0), 'Pre-exit private domain not empty')
    external = readonly_suite_clear(plist,report.with_name(mode+'-suite-cleanup.json'))
    return {'file':path.name,'sha256':digest(path),'evidence':value,'externalReadonlyCleanup':external}

def process_table():
    value = subprocess.run(['ps','-axo','pid=,ppid=,pgid=,stat=,lstart=,command='], capture_output=True,text=True,check=True)
    rows = {}
    for line in value.stdout.splitlines():
        fields = line.strip().split(None,9)
        if len(fields)==10:
            pid,ppid,pgid = map(int,fields[:3])
            rows[pid] = {'pid':pid,'ppid':ppid,'pgid':pgid,'stat':fields[3],
                         'start':' '.join(fields[4:9]),'command':fields[9]}
    return rows

def same_process(current, previous, allow_zombie=True):
    return all(current[key]==previous[key] for key in ['pid','pgid','start']) and (
        current['command']==previous['command'] or (allow_zombie and current['stat'].startswith('Z')))

def collect_owned(table, pid, root_identity, known):
    parents = {pid} if pid in table and (root_identity is None or same_process(table[pid],root_identity)) else set()
    parents.update(key for key,row in known.items() if key in table and same_process(table[key],row))
    changed = True
    while changed:
        changed = False
        for child,row in table.items():
            if row['ppid'] in parents and child not in parents:
                parents.add(child); changed = True
                if child != pid: known.setdefault(child,row)

def survivors(table, known):
    return [row for pid,row in table.items() if pid in known and same_process(row,known[pid])]

def create_fixtures(work, ffmpeg, ffprobe, out):
    folder = work/'fixtures'; folder.mkdir(); files = []; rows = []
    durations = [12,18,12,40,12,12,12,12,12,12]
    for index,duration in enumerate(durations):
        codec = 'pcm_s24le' if index%2==0 else 'flac'
        path = folder/('track-%04d 中文 空格.%s'%(index,'wav' if index%2==0 else 'flac'))
        args = [str(ffmpeg),'-nostdin','-v','error','-f','lavfi','-i','sine=frequency=%d:sample_rate=48000'%(400+index*25),
                '-t',str(duration),'-ac','2','-ar','48000','-channel_layout','stereo','-c:a',codec]
        if codec=='flac': args += ['-sample_fmt','s32','-bits_per_raw_sample','24']
        args += [str(path)]
        completed = subprocess.run(args,capture_output=True,text=True,timeout=60)
        require(completed.returncode==0,'Owned real audio generation failed: '+completed.stderr[:2048])
        probe_args = [str(ffprobe),'-v','error','-show_streams','-show_format','-of','json',str(path)]
        probe = subprocess.run(probe_args,capture_output=True,text=True,timeout=5,check=True)
        metadata = json.loads(probe.stdout); streams = metadata.get('streams',[])
        require(len(streams)==1 and streams[0].get('codec_type')=='audio'
                and streams[0].get('codec_name')==codec and streams[0].get('sample_rate')=='48000'
                and streams[0].get('channels')==2 and streams[0].get('channel_layout')=='stereo'
                and abs(float(metadata['format']['duration'])-duration)<.02,'Unexpected actual fixture stream')
        files.append(str(path.resolve(strict=True)))
        rows.append({'path':files[-1],'sha256':digest(path),'durationSeconds':duration,'generationArguments':args,
                     'probeArguments':probe_args,'actualMetadata':metadata})
    write(folder/'manifest.json',{'version':1,'files':files})
    write(out/'fixtures-inputs.json',{'root':str(folder.resolve()),'manifestSHA256':digest(folder/'manifest.json'),
            'ffmpegSHA256':digest(ffmpeg),'ffprobeSHA256':digest(ffprobe),'rows':rows})
    return folder.resolve(strict=True), rows

def run_mode(executable, app_sha, out, mode, storage, fixture_root, daily_before, bundle_id):
    report = out/(mode+'.json'); log = out/(mode+'.log'); process = None
    known = {}; process_samples = []; root_identity = None; forced = False
    env = {key:value for key,value in os.environ.items() if not key.startswith('SILICONPLAYER_VERIFY_')}
    env.update(SILICONPLAYER_VERIFY_MODE=mode, SILICONPLAYER_VERIFY_REPORT=str(report),
               SILICONPLAYER_VERIFY_STORAGE=str(storage), SILICONPLAYER_VERIFY_EXIT='1',
               SILICONPLAYER_VERIFY_NATIVE_AUDIO_ROOT=str(fixture_root))
    try:
        with log.open('w') as stream:
            process = subprocess.Popen([str(executable)],env=env,stdout=stream,stderr=subprocess.STDOUT)
            deadline = time.monotonic()+240
            while process.poll() is None:
                require(time.monotonic()<deadline,'Actual App deadline exceeded: '+mode)
                table = process_table()
                if root_identity is None and process.pid in table: root_identity = table[process.pid]
                collect_owned(table,process.pid,root_identity,known)
                process_samples.append({'bootUptimeSeconds':time.clock_gettime(time.CLOCK_UPTIME_RAW),
                                        'ownedChildren':survivors(table,known)})
                time.sleep(.05)
        require(process.returncode==0 and report.is_file(),'App did not exit naturally with report')
        deadline = time.monotonic()+2
        while survivors(process_table(),known) and time.monotonic()<deadline: time.sleep(.05)
        remaining = survivors(process_table(),known)
        require(not remaining,'Owned descendants/orphans/defunct survived natural App exit')
        value = json.loads(bounded_regular_bytes(report,16*1024*1024)); actual = value.get('nativeAudioVerification',{})
        require(value.get('mode')==mode and actual.get('mode')==mode and actual.get('passed') is True
                and not actual.get('failure') and actual.get('physicalGaplessVerified') is False
                and actual.get('heldRealEOFStillPending') is False,'Actual native-audio assertions failed: '+str(actual.get('failure')))
        observations = actual.get('observations',[]); ids = [row.get('id') for row in observations]
        require(len(ids)==len(set(ids)) and set(ids)==CHECKS[mode]|COMMON
                and actual.get('observationCount')==len(ids) and all(row.get('passed') is True for row in observations),
                'Missing/duplicate/failed actual observation')
        require(all(isinstance(row.get('snapshot'),dict) for row in observations), 'Missing actual per-check state')
        require(daily_shortcut_key(bundle_id)==daily_before,'Daily shortcut key changed')
        barrier = termination_barrier(report,storage,mode)
        # Keep the App-produced JSON immutable. Wrapper acceptance is a separate
        # file whose hashes bind original report, real log and termination sidecar.
        return {'id':mode,'status':'passed','appSHA256':app_sha,'appPID':process.pid,'appExitCode':0,
                'report':report.name,'reportSHA256':digest(report),'log':log.name,'logSHA256':digest(log),
                'observationCount':len(ids),'forcedCleanup':False,'ownedSurvivors':remaining,
                'terminationBarrier':barrier,'physicalGaplessVerified':False,'physicalNativeUIAcceptance':False}
    finally:
        if process is not None and process.poll() is None:
            forced = True; process.terminate()
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=3)
        remaining = survivors(process_table(),known)
        if remaining:
            forced = True
            for previous in remaining:
                current = process_table().get(previous['pid'])
                if current and same_process(current,previous,allow_zombie=False):
                    try: os.kill(current['pid'],signal.SIGTERM)
                    except ProcessLookupError: pass
            time.sleep(.3)
            for previous in remaining:
                current = process_table().get(previous['pid'])
                if current and same_process(current,previous,allow_zombie=False):
                    try: os.kill(current['pid'],signal.SIGKILL)
                    except ProcessLookupError: pass
        write(out/(mode+'-process.json'),{'appPID':process.pid if process else None,
             'appExitCode':process.returncode if process else None,'forcedCleanup':forced,
             'knownOwnedChildren':list(known.values()),'samples':process_samples,
             'ownedSurvivors':survivors(process_table(),known)})

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True); parser.add_argument('--expected-app-sha256',required=True)
    parser.add_argument('--report-directory',type=Path,required=True); options = parser.parse_args()
    require(__debug__,'Run without Python -O')
    require((ROOT/'Sources/SiliconPlayer/NativeAudioQueueVerifier.swift').is_file(), 'Migrate reviewed source/helper to production before use')
    app = options.app.resolve(strict=True); out = options.report_directory.resolve(); executable = app/'Contents/MacOS/SiliconPlayer'
    require(app.suffix=='.app' and digest(executable)==options.expected_app_sha256,'Unexpected actual App bytes')
    require(not out.exists(),'Refuse existing report directory'); out.mkdir(parents=True,exist_ok=False)
    ffmpeg,ffprobe = (app/'Contents/Resources/Tools'/name for name in ['ffmpeg','ffprobe'])
    require(all(path.is_file() and os.access(path,os.X_OK) for path in [ffmpeg,ffprobe]),'Packaged real helpers missing')
    bundle = inventory(app); inputs = pins(app)
    bundle_id = plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
    daily_before = daily_shortcut_key(bundle_id)
    write(out/'inputs-before.json',{'app':str(app),'appSHA256':options.expected_app_sha256,
          'buildAndHelperInputs':inputs,'bundleFiles':bundle,'dailyShortcutKeySHA256Before':daily_before})
    summary = {'status':'running','startedUTC':datetime.now(timezone.utc).isoformat(),'appSHA256':options.expected_app_sha256,
               'expectedGroups':list(CHECKS),'results':[],'scope':'Four actual API-driven App groups; observations add no groups. Natural A→B→C only in first group; subsequent seeks accelerate correctness checks. No physical output-continuity or synthesized-input acceptance.'}
    fixture_rows = []
    try:
        with tempfile.TemporaryDirectory(prefix='siliconplayer-native-audio-',dir='/private/tmp') as raw:
            work = Path(raw).resolve(strict=True); folder,fixture_rows = create_fixtures(work,ffmpeg,ffprobe,out)
            # Save evidence before the first App, so an App failure cannot erase
            # the original generated inputs when the owned APFS scope closes.
            retained = out/'fixtures'; shutil.copytree(folder,retained)
            require(all(digest(retained/Path(row['path']).name)==row['sha256'] for row in fixture_rows),'Initial retained fixture differs')
            for mode in CHECKS:
                storage = work/mode; storage.mkdir()
                summary['results'].append(run_mode(executable,options.expected_app_sha256,out,mode,storage.resolve(),folder,daily_before,bundle_id))
                write(out/'summary.json',summary)
                for name in ['history.json','queue.json','preferences.json','media-preferences.json']:
                    source = storage/name
                    if source.is_file(): shutil.copyfile(source,out/(mode+'-'+name))
            require(all(digest(row['path'])==row['sha256'] for row in fixture_rows),'Owned fixture contents changed')
            # Retain generated media as exact evidence copies while APFS playback
            # paths remain in raw metadata. These are newly generated local data.
            require(all(digest(retained/Path(row['path']).name)==row['sha256'] for row in fixture_rows),'Retained fixture differs')
        require(inventory(app)==bundle and digest(executable)==options.expected_app_sha256,'App bundle changed')
        require(all(digest(ROOT/name)==sha for name,sha in inputs.items()),'Build/helper inputs changed')
        require(daily_shortcut_key(bundle_id)==daily_before,'Daily shortcut key changed after natural exits')
        require(len(summary['results'])==4 and {row['id'] for row in summary['results']}==set(CHECKS),'Wrong whole-group count')
        summary.update(status='passed',passed=4,failed=0,inputsUnchanged=True,bundleUnchanged=True,dailyShortcutKeyUnchanged=True)
    except Exception as error:
        summary.update(status='failed',passed=len(summary['results']),
                       failed=1 if len(summary['results'])<4 else 0,notRun=max(0,3-len(summary['results'])),
                       integrityFailed=len(summary['results'])==4,error=str(error)); raise
    finally:
        write(out/'inputs-after.json',{'appSHA256':digest(executable),'bundleFiles':inventory(app),
             'buildAndHelperInputs':{name:digest(ROOT/name) if (ROOT/name).is_file() else None for name in inputs},
             'dailyShortcutKeySHA256After':daily_shortcut_key(bundle_id)})
        summary['finishedUTC'] = datetime.now(timezone.utc).isoformat(); write(out/'summary.json',summary)
    print('INFO 4 actual native-audio App groups passed; no physical output-continuity claim')

if __name__=='__main__': main()
