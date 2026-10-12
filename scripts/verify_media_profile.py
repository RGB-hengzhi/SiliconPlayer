#!/usr/bin/env python3
"""Four hash-pinned actual-app media/profile groups against owned local copies.

No build, network, physical input synthesis, or daily shortcut writes. Recovery
uses actual coordinator fault injection and a second application startup; it is
not a power-loss durability test. Internal observations add no scenario groups.
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
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
COMMON = {'private-shortcut-suite-selected', 'daily-standard-shortcut-key-unmodified'}
CHECKS = {
 'media-preferences': {
  'actual-external-audio-dual-subtitle-save', 'saved-original-source-and-no-runtime-id',
  'unrelated-edit-persists-base-without-restored-geometry', 'reordered-runtime-ids-match-original-descriptors',
  'fuzzy-and-explicit-same-source-rows-remain-inspectable', 'real-local-zh-en-inference-and-file-url-missing-language',
  'actual-restoration-deduplicates-same-source-stream', 'actual-inferred-language-track-selection-saved',
  'different-embedded-stream-indices-retained', 'duplicate-original-stream-not-used-as-second-subtitle',
  'saved-inferred-language-restores-file-url-without-language',
  'manual-existing-original-subtitle-does-not-add-third-copy',
  'dual-delays-geometry-and-projection-restored', 'restored-settings-real-time-and-frames',
  'replacement-inherits-global-not-previous-media', 'replacement-real-time-and-frames'},
 'media-profile-backup': {
  'export-actual-base-not-media-overlay', 'valid-preview-cancel-zero-store-and-runtime-change',
  'invalid-backup-zero-write', 'actual-complete-profile-commit',
  'one-runtime-adoption-with-all-typed-stores', 'committed-profile-real-time-and-frames'},
 'media-profile-journal-prepare': {
  'real-coordinator-prepared-journal-after-failed-rollback', 'pending-recovery-blocks-natural-exit-persistence'},
 'media-profile-recovery': {
  'second-process-startup-restores-all-original-bytes', 'stored-let-partial-filter-memory-replaced-after-recovery',
  'restored-documents-use-real-playback', 'recovered-profile-real-time-and-frames'},
 'media-profile-malformed-startup': {
  'malformed-startup-preserves-original-bytes-before-defaults',
  'normal-publication-repairs-store-preserved-copy-remains', 'malformed-fallback-real-time-and-frames'},
 'media-profile-lifecycle': {
  'missing-external-is-pending-before-user-selection', 'late-track-can-match-saved-description',
  'manual-track-selection-wins-over-late-restore', 'manual-track-real-time-and-frames',
  'stop-request-during-pending-restore', 'stop-discards-restoration-without-resurrection',
  'replacement-discards-old-delays-geometry-and-track-ids', 'replacement-after-cancel-real-time-and-frames',
  'global-reset-retains-loaded-media-edit-context', 'post-reset-media-edit-does-not-persist-global-geometry',
  'stop-reopen-after-global-reset-restores-default-geometry', 'post-reset-reopen-real-time-and-frames'},
}
GROUPS = [
 ('media-preferences', ['media-preferences']),
 ('media-profile-backup', ['media-profile-backup']),
 ('media-profile-recovery', ['media-profile-journal-prepare', 'media-profile-recovery', 'media-profile-malformed-startup']),
 ('media-profile-lifecycle', ['media-profile-lifecycle']),
]

def require(value, message):
    if not value: raise RuntimeError(message)

def canonical_fixture(path, folder):
    path, folder = Path(path), Path(folder)
    require(path.is_absolute() and folder.is_absolute(), 'Absolute fixture paths required')
    root = folder.resolve(strict=True)
    resolved = path.resolve(strict=True)
    require(root.is_dir() and root in resolved.parents and resolved.is_file(), 'Owned regular fixture required')
    return resolved

def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for data in iter(lambda: stream.read(4 * 1024 * 1024), b''): h.update(data)
    return h.hexdigest()

def write(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False)+'\n', encoding='utf-8')

def inventory(app):
    return {str(path.relative_to(app)): digest(path) for path in sorted(app.rglob('*')) if path.is_file() and not path.name.startswith('._')}

def pins(app):
    provenance = json.loads((app/'Contents/Resources/build-provenance.json').read_text())
    require(provenance['inputFilesUnchanged'], 'Compilation input drift')
    result = dict(provenance['inputFiles'])
    for name in ['scripts/verify_media_profile.py', 'scripts/verify_async_screenshots.py', 'Tests/Integration/ImageMetrics.swift']:
        result[name] = digest(ROOT/name)
    require(all(digest(ROOT/name) == sha for name,sha in result.items()), 'App does not match frozen current inputs')
    return result

def daily_shortcut_key(bundle_id):
    path = Path.home()/'Library/Preferences'/(bundle_id+'.plist')
    if not path.exists(): return 'missing'
    value = plistlib.loads(path.read_bytes()).get('SiliconPlayer.shortcuts.v1')
    if value is None: return 'missing'
    return hashlib.sha256(plistlib.dumps({'value':value}, fmt=plistlib.FMT_BINARY, sort_keys=True)).hexdigest()

def verification_suite_state(path):
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return {'state':'absent','cleared':True}
    except OSError as error:
        return {'state':'unreadable','cleared':False,'errorType':type(error).__name__}
    try:
        value = plistlib.loads(raw)
        empty = isinstance(value, dict) and not value
        return {'state':'empty' if empty else 'nonempty','cleared':empty,'bytes':len(raw),
                'sha256':hashlib.sha256(raw).hexdigest(),'keyCount':len(value) if isinstance(value,dict) else None}
    except (ValueError, plistlib.InvalidFileException) as error:
        return {'state':'invalid-plist','cleared':False,'bytes':len(raw),'errorType':type(error).__name__}

def wait_verification_suite_clear(path, evidence_path, timeout=3.0):
    # Observe only this run's unique domain. CFPreferences publication after a
    # natural exit can be asynchronous; no defaults/domain deletion is performed.
    started = time.monotonic(); before = verification_suite_state(path); after = before
    polls = 1
    while not after['cleared'] and time.monotonic()-started < timeout:
        time.sleep(min(.05, max(0, timeout-(time.monotonic()-started))))
        after = verification_suite_state(path); polls += 1
    evidence = {'domainPlist':str(path),'timeoutSeconds':timeout,'waitDurationSeconds':time.monotonic()-started,
                'pollCount':polls,'before':before,'after':after,'cleared':after['cleared'],
                'scope':'Read-only wait after natural app exit for this verification-only domain; never removes or edits preferences.'}
    write(evidence_path,evidence)
    return evidence

def process_table():
    result = subprocess.run(['ps','-axo','pid=,ppid=,pgid=,stat=,lstart=,command='], capture_output=True, text=True, check=True)
    rows = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 9)
        if len(parts) == 10:
            pid, ppid, pgid = map(int, parts[:3])
            rows[pid] = {'pid':pid,'ppid':ppid,'pgid':pgid,'stat':parts[3], 'start':' '.join(parts[4:9]),'command':parts[9]}
    return rows

def identity(row):
    return (row['pid'],row['pgid'],row['start'],row['command'])

def collect_owned(table, process, known):
    descendants = {process.pid} | set(known)
    changed = True
    while changed:
        changed = False
        for pid,row in table.items():
            if row['ppid'] in descendants and pid not in descendants:
                descendants.add(pid); changed=True
    for pid in descendants:
        if pid != process.pid and pid in table: known.setdefault(pid,table[pid])

def survivors(table, known):
    # Defunct and reparented members still count as surviving owned processes.
    return [row for pid,row in table.items() if pid in known and identity(row)==identity(known[pid])]

def copy_fixtures(work):
    folder = work/'fixtures'; folder.mkdir()
    inputs = {
     'source': ROOT/'Tests/Fixtures/FullTest/多音轨双字幕.mkv',
     'alternate': ROOT/'Tests/Fixtures/中文 测试 H264.mp4',
     'audio': ROOT/'Tests/Fixtures/extended/wav.wav',
     'primary': ROOT/'Tests/Fixtures/中文 测试 H264.srt',
     'secondary': ROOT/'Tests/Fixtures/FullTest/English.srt',
    }
    names = {'source':'同源:多音\\轨，中文.mkv', 'alternate':'切换后中文 H264.mp4',
             'audio':'外置:音轨\\中文，audio.wav', 'primary':'同源:多音\\轨，中文.zh.srt',
             'secondary':'同源:多音\\轨，中文.en.srt'}
    paths = {}
    for key,path in inputs.items():
        destination = folder/names[key]; shutil.copyfile(path,destination)
        require(digest(path)==digest(destination), 'Copy differs from source fixture')
        paths[key] = canonical_fixture(destination, folder)
    return folder.resolve(strict=True), paths, {str(path.relative_to(ROOT)):digest(path) for path in inputs.values()}

def run_mode(executable, app_sha, output, mode, storage, folder, fixtures, daily_before, bundle_id):
    report = output/(mode+'.json'); log = output/(mode+'.log')
    require(Path(storage).is_absolute(), 'Absolute private storage required')
    storage = Path(storage).resolve(strict=True)
    require(storage.is_dir(), 'Private storage directory required')
    fixtures = {key:canonical_fixture(path, folder) for key,path in fixtures.items()}
    folder = Path(folder).resolve(strict=True)
    env = {key:value for key,value in os.environ.items() if not key.startswith('SILICONPLAYER_VERIFY_')}
    env.update(SILICONPLAYER_VERIFY_MODE=mode,SILICONPLAYER_VERIFY_REPORT=str(report),
               SILICONPLAYER_VERIFY_STORAGE=str(storage),SILICONPLAYER_VERIFY_EXIT='1',
               SILICONPLAYER_VERIFY_MEDIA_PROFILE_ROOT=str(folder))
    for key,path in fixtures.items(): env['SILICONPLAYER_VERIFY_MEDIA_PROFILE_'+key.upper()] = str(path)
    known, samples, process, forced = {}, [], None, False
    try:
        with log.open('w') as stream:
            process = subprocess.Popen([str(executable)], env=env, stdout=stream, stderr=subprocess.STDOUT)
            deadline = time.monotonic()+90
            while process.poll() is None:
                require(time.monotonic()<deadline, 'Actual app timeout: '+mode)
                table = process_table(); collect_owned(table,process,known)
                samples.append({'uptime':time.clock_gettime(time.CLOCK_UPTIME_RAW), 'ownedChildren':survivors(table,known)})
                time.sleep(.05)
        require(process.returncode==0 and report.exists(), 'App failed or omitted report: '+mode)
        end = time.monotonic()+2
        while survivors(process_table(),known) and time.monotonic()<end: time.sleep(.05)
        remaining = survivors(process_table(),known)
        require(not remaining,'Owned descendants/orphans/defunct survived app exit: '+mode)
        value = json.loads(report.read_text())
        require(value.get('mode')==mode and value.get('mediaProfilePassed') is True and not value.get('failure'), 'Actual app assertions failed: '+str(value.get('failure')))
        observations = value.get('mediaProfileChecks',[]); ids = [row['id'] for row in observations]
        require(len(ids)==len(set(ids)) and set(ids)==CHECKS[mode]|COMMON and all(row.get('passed') is True for row in observations), 'Wrong/duplicate/failed observations: '+mode)
        require(daily_shortcut_key(bundle_id)==daily_before, 'Daily persisted shortcut key changed')
        suite='local.siliconplayer.verification.'+hashlib.sha256((str(report)+'\0'+str(storage)).encode()).hexdigest()
        sidecar = report.with_suffix('.suite-termination.json')
        require(sidecar.is_file(), 'Missing actual verification termination barrier: '+mode)
        barrier = json.loads(sidecar.read_text())
        require(barrier.get('suite')==suite and barrier.get('mode')==mode, 'Termination barrier has another verification identity')
        require(all(barrier.get(key) is True for key in ['sameBoundInstance','writesClosed','synchronizeSucceeded','memoryDomainEmpty','succeeded','terminationAllowed'])
                and barrier.get('afterKeys')==[] and barrier.get('phase') in ['before-terminateNow','before-reply-true'], 'Actual termination barrier failed: '+mode)
        started,finished=barrier.get('startedUptime'),barrier.get('finishedUptime')
        require(all(isinstance(item,(int,float)) and not isinstance(item,bool) and math.isfinite(item) and item>=0 for item in [started,finished])
                and finished>=started and isinstance(barrier.get('invocation'),int) and barrier['invocation']>=1, 'Invalid termination barrier order')
        disk_barrier=barrier.get('diskBarrier',{})
        expected_domain=str(Path.home()/'Library/Preferences'/(suite+'.plist'))
        require(disk_barrier.get('domainPlist')==expected_domain and disk_barrier.get('diskDomainEmpty') is True
                and disk_barrier.get('timeoutSeconds')==15.0 and isinstance(disk_barrier.get('pollCount'),int)
                and not isinstance(disk_barrier['pollCount'],bool) and disk_barrier['pollCount']>=1,
                'Missing/foreign actual pre-exit private-domain disk barrier: '+mode)
        disk_started,disk_finished,disk_wait=(disk_barrier.get(key) for key in ['startedUptime','finishedUptime','waitDurationSeconds'])
        require(all(isinstance(item,(int,float)) and not isinstance(item,bool) and math.isfinite(item) and item>=0
                    for item in [disk_started,disk_finished,disk_wait]) and disk_finished>=disk_started>=started
                and finished==disk_finished and abs((disk_finished-disk_started)-disk_wait)<.001 and disk_wait<=15.5,
                'Invalid pre-exit disk barrier timing: '+mode)
        before_disk,after_disk=disk_barrier.get('before',{}),disk_barrier.get('after',{})
        require(before_disk.get('state') in ['absent','empty','nonempty','unreadable','nonregular','oversize','invalid']
                and after_disk.get('state') in ['absent','empty'] and after_disk.get('cleared') is True
                and (after_disk['state']=='absent' or after_disk.get('keyCount')==0),
                'Actual pre-exit private-domain file was not empty: '+mode)
        value['verificationSuiteTerminationBarrier']={'file':sidecar.name,'sha256':digest(sidecar),'evidence':barrier}
        images = [Path(path) for path in value.get('mediaProfileImages',[])]
        require(all(path.is_file() and path.parent==output for path in images), 'PNG not owned by report directory')
        if images:
            from verify_async_screenshots import decode_images
            value['decodedImages'] = decode_images(images)
        value.update(appSHA256=app_sha,appPID=process.pid,appExitCode=process.returncode,
                     ownedDescendantsAtExit=remaining, forcedCleanup=False,physicalNativeUIAcceptance=False)
        suite_path=Path.home()/'Library/Preferences'/(suite+'.plist')
        cleanup = wait_verification_suite_clear(suite_path, output/(mode+'-suite-cleanup.json'))
        require(cleanup['cleared'], 'Verification preference suite survived natural quit after bounded wait')
        value['verificationSuiteCleared']=True
        value['verificationSuiteCleanupObservation']=cleanup
        write(report,value)
        return {'mode':mode,'status':'passed','report':report.name,'appSHA256':app_sha,'appExitCode':0,
                'observationCount':len(ids),'reportSHA256':digest(report),'forcedCleanup':False,
                'terminationSidecar':sidecar.name,'terminationSidecarSHA256':digest(sidecar)}
    finally:
        if process is not None and process.poll() is None:
            forced = True; process.terminate()
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=3)
        table = process_table()
        remaining = survivors(table,known)
        if remaining:
            forced = True
            for row in remaining:
                current=process_table().get(row['pid'])
                if current and identity(current)==identity(row):
                    try: os.kill(row['pid'],signal.SIGTERM)
                    except ProcessLookupError: pass
            time.sleep(.3)
            for row in survivors(process_table(),known):
                current=process_table().get(row['pid'])
                if current and identity(current)==identity(row):
                    try: os.kill(row['pid'],signal.SIGKILL)
                    except ProcessLookupError: pass
        write(output/(mode+'-process.json'),{'appPID':process.pid if process else None,'appExitCode':process.returncode if process else None,
              'forcedCleanup':forced,'knownOwnedChildren':list(known.values()),'samples':samples,'ownedSurvivors':survivors(process_table(),known)})

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True);parser.add_argument('--expected-app-sha256',required=True)
    parser.add_argument('--report-directory',type=Path,required=True);options=parser.parse_args()
    require(__debug__,'Run without Python -O')
    app=options.app.resolve();out=options.report_directory.resolve();executable=app/'Contents/MacOS/SiliconPlayer'
    require(app.suffix=='.app' and digest(executable)==options.expected_app_sha256,'Unexpected app bytes')
    require(not out.exists(),'Refuse existing report directory');out.mkdir(parents=True,exist_ok=False)
    bundle=inventory(app);inputs=pins(app)
    bundle_id=plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
    daily_before=daily_shortcut_key(bundle_id)
    write(out/'inputs-before.json',{'app':str(app),'appSHA256':options.expected_app_sha256,'buildAndHelperInputs':inputs,
          'bundleFiles':bundle,'dailyShortcutKeySHA256Before':daily_before})
    summary={'status':'running','startedUTC':datetime.now(timezone.utc).isoformat(),'appSHA256':options.expected_app_sha256,
             'results':[],'scope':'Four actual app groups. Six natural application processes: journal producer/recovery/malformed are one recovery group. API-driven actions, not physical native input acceptance.'}
    fixture_pins={}
    try:
        for group,modes in GROUPS:
            with tempfile.TemporaryDirectory(prefix='siliconplayer-media-profile-',dir='/private/tmp') as raw:
                work=Path(raw);storage=work/'profile';storage.mkdir()
                folder,fixtures,current=copy_fixtures(work);fixture_pins.update(current)
                copy_pins={str(path):digest(path) for path in fixtures.values()}
                write(out/(group+'-inputs.json'),{'originalFixtures':current,'ownedCopies':copy_pins,'privateStorage':str(storage)})
                entries=[]
                for mode in modes:
                    if mode=='media-profile-malformed-startup':
                        # Separate startup subcase after completed journal recovery.
                        storage=work/'malformed-profile';storage.mkdir()
                        original=folder/'malformed-global-original.json';original.write_bytes(b'{"brightness": malformed\xff')
                        shutil.copyfile(original,storage/'preferences.json')
                    entries.append(run_mode(executable,options.expected_app_sha256,out,mode,storage,folder,fixtures,daily_before,bundle_id))
                    if mode=='media-profile-journal-prepare': require((storage/'profile-import-journal.json').is_file(),'Normal exit erased prepared journal')
                    if mode=='media-profile-recovery': require(not (storage/'profile-import-journal.json').exists(),'Recovered journal still present')
                    if mode=='media-profile-malformed-startup':
                        preserved=list((storage/'PreservedPreferences').rglob('preferences.json'))
                        require(any(digest(path)==digest(original) for path in preserved),'Original malformed data absent after normal quit')
                        require(json.loads((storage/'preferences.json').read_text())['brightness']==9,'Current global file not repaired')
                require(all(digest(path)==sha for path,sha in copy_pins.items()),'Owned original copy contents changed')
                # Copies retain only synthetic fixture paths/values; no daily user stores.
                for name in ['preferences.json','user-video-filters.json','media-preferences.json','profile-import-journal.json']:
                    path=storage/name
                    if path.is_file(): shutil.copyfile(path,out/(group+'-'+name))
                summary['results'].append({'id':group,'status':'passed','appSHA256':options.expected_app_sha256,'modes':entries,'modeCount':len(entries)})
                write(out/'summary.json',summary)
        require(inventory(app)==bundle,'App bundle changed during verification')
        require(all(digest(ROOT/name)==sha for name,sha in inputs.items()),'Build/helper inputs changed')
        require(all(digest(ROOT/name)==sha for name,sha in fixture_pins.items()),'Input fixture changed')
        require(daily_shortcut_key(bundle_id)==daily_before,'Daily persisted shortcut key changed after quit')
        write(out/'inputs.json',{'app':str(app),'appSHA256':options.expected_app_sha256,'buildAndHelperInputs':inputs,
            'bundleFiles':bundle,'fixtures':fixture_pins,'dailyShortcutKeySHA256Before':daily_before,'dailyShortcutKeyUnchanged':True})
        summary.update(status='passed',passed=4,failed=0,inputsUnchanged=True,bundleUnchanged=True,dailyShortcutKeyUnchanged=True)
    except Exception as error:
        summary.update(status='failed',error=str(error));raise
    finally:
        write(out/'inputs-after.json',{'buildAndHelperInputs':{name:digest(ROOT/name) if (ROOT/name).is_file() else None for name in inputs},
              'bundleFiles':inventory(app),'appSHA256':digest(executable),'dailyShortcutKeySHA256After':daily_shortcut_key(bundle_id)})
        summary['finishedUTC']=datetime.now(timezone.utc).isoformat();write(out/'summary.json',summary)
    print('INFO 4 actual media/profile application groups passed; internal observations add no groups')

if __name__=='__main__': main()
