#!/usr/bin/env python3
"""Four serial actual-App ASR groups; use an explicitly pinned new bundle."""
import argparse, struct, hashlib, importlib.util, json, os, plistlib, shutil, signal, subprocess, tempfile, time, sys
sys.dont_write_bytecode = True
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
MODES=('live-asr-follow','live-asr-pause-seek','live-asr-reload','live-asr-quit')
def require(v,m):
    if not v: raise RuntimeError(m)
def digest(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()
def write(p,v):Path(p).write_text(json.dumps(v,ensure_ascii=False,indent=2,allow_nan=False)+'\n')
def inventory(p):return {str(x.relative_to(p)):digest(x) for x in sorted(p.rglob('*')) if x.is_file() and not any(y.startswith('._') for y in x.relative_to(p).parts)}
def run(helper,exe,mode,out,storage,tmp,fixture,daily,bundle_id):
    report=out/(mode+'.json');known={};identity=None;samples=[];forced=False;proc=None
    env={k:v for k,v in os.environ.items() if not k.startswith('SILICONPLAYER_VERIFY_')}
    env.update(SILICONPLAYER_VERIFY_MODE=mode,SILICONPLAYER_VERIFY_REPORT=str(report),SILICONPLAYER_VERIFY_STORAGE=str(storage),SILICONPLAYER_VERIFY_EXIT='1',TMPDIR=str(tmp)+'/')
    write(out/(mode+'-command.json'),{'argv':[str(exe),str(fixture)],'environment':{k:env[k] for k in ('SILICONPLAYER_VERIFY_MODE','SILICONPLAYER_VERIFY_REPORT','SILICONPLAYER_VERIFY_STORAGE','SILICONPLAYER_VERIFY_EXIT','TMPDIR','HOME') if k in env},'homeInheritedUnchanged':env.get('HOME')==os.environ.get('HOME')})
    try:
        with (out/(mode+'.log')).open('x') as log:
            proc=subprocess.Popen([str(exe),str(fixture)],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            deadline=time.monotonic()+75
            while proc.poll() is None:
                require(time.monotonic()<deadline,'Actual App timeout: '+mode)
                table=helper.process_table()
                if identity is None and proc.pid in table:identity=table[proc.pid]
                helper.collect_owned(table,proc.pid,identity,known)
                samples.append({'uptime':time.clock_gettime(time.CLOCK_UPTIME_RAW),'owned':helper.survivors(table,known)})
                time.sleep(.05)
        require(proc.returncode==0 and report.is_file(),'App did not exit naturally with actual report')
        remaining=helper.survivors(helper.process_table(),known);require(not remaining,'Actual owned child survived')
        value=json.loads(helper.bounded_regular_bytes(report,24*1024*1024))
        require(value.get('mode')==mode and value.get('succeeded') is True,'ASR App assertions failed: '+str(value.get('asrScope')))
        checks=value.get('asrChecks',[]);ids=[x.get('id') for x in checks]
        require(len(ids)==len(set(ids)) and checks and all(x.get('passed') is True for x in checks),'Duplicate/missing/failed ASR checks')
        expected={'real-media-loaded','real-native-seek-settled','actual-pair-start-accepted','actual-transition-ack'}
        if mode=='live-asr-quit':expected.add('live-owned-pair-at-quit')
        else:expected|={'actual-chinese-partial','real-chinese-overlay-command','real-asr-window-screenshot','partial-before-actual-player-eof','owned-registry-empty','real-overlay-owner-cleared','daily-shortcuts-unchanged'}
        if mode=='live-asr-reload':expected|={'same-url-reload-new-binding','old-partial-invalidated-synchronously','retired-owned-pair-released'}
        elif mode!='live-asr-quit':expected|={'actual-eof-finalization','actual-chinese-final-cues','cues-in-actual-source-clock','real-srt-export-reparse'}
        if mode=='live-asr-pause-seek':expected|={'pause-control-observed','actual-clock-stayed-paused','seek-retired-old-partial-before-yield','new-native-seek-and-restart','post-seek-native-resume-ack','post-seek-new-epoch-chinese-partial'}
        require(set(ids)==expected,'ASR check set differs')
        if mode != 'live-asr-quit':
            overlay = next(x['detail']['snapshot'] for x in checks if x['id']=='real-chinese-overlay-command')
            require(bool(overlay.get('overlayOwner')) and overlay['overlayOwner']==overlay.get('controllerActual',{}).get('owner')
                and any(0x3400 <= ord(c) <= 0x9fff for c in overlay.get('overlayPayload','')), 'Actual matching Chinese OSD overlay receipt missing')
            png = report.with_suffix('.asr-window.png')
            require(value.get('asrScreenshotResult')==str(png) and png.is_file(), 'Actual window screenshot reply/path missing')
            image = helper.bounded_regular_bytes(png,64*1024*1024)
            require(len(image)>5000 and image[:8]==b'\x89PNG\r\n\x1a\n' and image[12:16]==b'IHDR', 'Actual screenshot PNG header missing')
            width,height=struct.unpack('>II',image[16:24]);require(0<width<=16384 and 0<height<=16384, 'Actual screenshot dimensions invalid')
            write(out/(mode+'-actual-window-screenshot.json'), {'path':str(png),'sha256':digest(png),'bytes':len(image),'width':width,'height':height,'scope':'Actual mpv window screenshot; visible Chinese text must be separately reviewed from the image, not inferred from metadata/OSD receipt.'})
        for identifier,event in [('actual-transition-ack','speed_changed')] + ([('pause-control-observed','paused'),('post-seek-native-resume-ack','resumed')] if mode=='live-asr-pause-seek' else []):
            detail=next(x['detail'] for x in checks if x['id']==identifier)
            ack=detail.get('actualDecoderACK',{});require(ack.get('event')==event and isinstance(ack.get('serial'),int) and ack['serial']>0 and ack.get('epoch')==detail.get('actualEpoch') and ack['epoch']>0,'Actual decoder ACK absent')
        if mode == 'live-asr-pause-seek':
            resumed = next(x['detail'] for x in checks if x['id']=='post-seek-native-resume-ack')
            ack = resumed['actualDecoderACK']; epoch = resumed.get('actualEpoch')
            previous_epoch = resumed.get('previousEpoch'); minimum_serial = resumed.get('minimumControlSerial')
            resume_snapshot = resumed.get('snapshot',{}); resume_actual = resume_snapshot.get('controllerActual',{})
            require(type(epoch) is int and type(previous_epoch) is int and epoch > previous_epoch > 0
                and type(minimum_serial) is int and minimum_serial > 0 and ack['serial'] > minimum_serial
                and resumed.get('actualDesiredEpoch') == epoch and resumed.get('actualDecoderPaused') is False
                and resume_actual.get('epoch') == epoch and resume_snapshot.get('controllerState') == 'following'
                and resume_snapshot.get('paused') is False and resume_snapshot.get('seeking') is False
                and resume_snapshot.get('settledSeekGeneration') == resume_snapshot.get('seekGeneration'),
                'Post-seek actual resumed ACK/epoch/following state missing')
            partial = next(x['detail']['snapshot'] for x in checks if x['id']=='post-seek-new-epoch-chinese-partial')
            actual_partial = partial.get('controllerActual',{}); ticket = actual_partial.get('ticket',{})
            first = actual_partial.get('firstGrantedSequence'); last = actual_partial.get('lastGrantedSequence')
            require(actual_partial.get('epoch') == epoch and ticket.get('epoch') == epoch
                and type(actual_partial.get('streamGeneration')) is int and actual_partial['streamGeneration'] > 0
                and type(actual_partial.get('grantedSamples')) is int and actual_partial['grantedSamples'] > 0
                and type(first) is int and type(last) is int and 0 < first <= last
                and type(partial.get('ffIndex')) is int and partial['ffIndex'] >= 0
                and ticket.get('streamIndex') == partial['ffIndex'] and partial.get('controllerState') == 'following'
                and actual_partial.get('partial') == partial.get('partial')
                and any(0x3400 <= ord(c) <= 0x9fff for c in partial.get('partial','')),
                'Post-seek accepted current-epoch/stream Chinese partial missing')
        if mode in ('live-asr-follow','live-asr-pause-seek'):
            actual=value.get('asrSnapshot',{}).get('controllerActual',{}).get('close',{})
            require(actual.get('confirmed') is True and actual.get('resourcesReleased') is True and actual.get('forced') is False and actual.get('ownedReaped') is True,'Actual EOF pair close receipt absent')

        termination=report.with_suffix('.asr-termination.json');t=json.loads(helper.bounded_regular_bytes(termination,16*1024*1024))
        require(t.get('succeeded') is True and t.get('asrStopped') is True and t.get('ownedJobs') is False and t.get('overlayOwner')=='','Actual ASR shutdown failed')
        if mode == 'live-asr-quit':
            backend = t.get('backendActual')
            require(isinstance(backend,dict) and 'lastError' in backend and backend['lastError'] is None,
                'Actual quit backend diagnostic missing or not clean')
        close=t.get('after',{}).get('close',{})
        require(close.get('confirmed') is True and close.get('resourcesReleased') is True and close.get('forced') is False,'No exact actual pair close receipt')
        barrier=helper.termination_barrier(report,storage,mode)
        require(helper.daily_shortcut_key(bundle_id)==daily,'Daily shortcuts changed')
        return {'id':mode,'status':'passed','appPID':proc.pid,'appExit':proc.returncode,'reportSHA256':digest(report),'ASRTerminationSHA256':digest(termination),'observationCount':len(checks),'ownedSurvivors':remaining,'forcedCleanup':False,'terminationBarrier':barrier,'realUIAutomationVerified':False,'wordEndAlignmentVerified':False}
    finally:
        if proc and proc.poll() is None:
            forced=True;proc.terminate()
            try:proc.wait(timeout=3)
            except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=3)
        remaining=helper.survivors(helper.process_table(),known)
        for old in remaining:
            current=helper.process_table().get(old['pid'])
            if current and helper.same_process(current,old,allow_zombie=False):
                forced=True
                try:os.kill(current['pid'],signal.SIGTERM)
                except ProcessLookupError:pass
        if remaining:time.sleep(.3)
        for old in helper.survivors(helper.process_table(),known):
            if not old['stat'].startswith('Z'):
                try:os.kill(old['pid'],signal.SIGKILL)
                except ProcessLookupError:pass
        write(out/(mode+'-process.json'),{'pid':proc.pid if proc else None,'exit':proc.returncode if proc else None,'knownOwned':list(known.values()),'samples':samples,'forcedCleanup':forced,'ownedSurvivors':helper.survivors(helper.process_table(),known)})
def main():
    a=argparse.ArgumentParser();a.add_argument('--app',type=Path,required=True);a.add_argument('--expected-app-sha256',required=True);a.add_argument('--report-directory',type=Path,required=True);a.add_argument('--fixture-root',type=Path,required=True);args=a.parse_args()
    app=args.app.resolve(strict=True);exe=app/'Contents/MacOS/SiliconPlayer';out=args.report_directory.resolve()
    require(app.suffix=='.app' and digest(exe)==args.expected_app_sha256,'Exact App required');require(not out.exists(),'Fresh reports required');out.mkdir(parents=True)
    spec=importlib.util.spec_from_file_location('owned_app_helpers',ROOT/'scripts/verify_native_audio_queue.py');helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
    provenance=json.loads((app/'Contents/Resources/build-provenance.json').read_text());inputs=provenance['inputFiles'];require(provenance['inputFilesUnchanged'] is True and 'Sources/SiliconPlayer/LiveASRVerifier.swift' in inputs,'Actual compiled verifier required')
    require(all(digest(ROOT/n)==h for n,h in inputs.items()),'Current build inputs differ');before=inventory(app)
    fixture_root=args.fixture_root.resolve(strict=True);follow=fixture_root/'follow 中文 实时字幕.mov';controls=fixture_root/'controls 中文 实时字幕.mov';fixtures={str(x):digest(x) for x in (follow,controls)}
    bundle_id=plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleIdentifier'];daily=helper.daily_shortcut_key(bundle_id)
    write(out/'inputs-before.json',{'app':str(app),'appSHA256':args.expected_app_sha256,'buildInputs':inputs,'bundle':before,'fixtures':fixtures,'driverSHA256':digest(Path(__file__)),'dailyShortcut':daily})
    summary={'status':'running','expectedGroups':list(MODES),'results':[]}
    try:
        with tempfile.TemporaryDirectory(prefix='siliconplayer-asr-app-',dir='/private/tmp') as raw:
            work=Path(raw).resolve()
            for mode in MODES:
                storage=work/mode;storage.mkdir();tmp=storage/'tmp';tmp.mkdir()
                summary['results'].append(run(helper,exe,mode,out,storage,tmp,controls if mode=='live-asr-pause-seek' else follow,daily,bundle_id));write(out/'summary.json',summary)
                for name in ('history.json','queue.json','preferences.json','media-preferences.json'):
                    if (storage/name).is_file():shutil.copyfile(storage/name,out/(mode+'-'+name))
        require(inventory(app)==before and all(digest(ROOT/n)==h for n,h in inputs.items()) and all(digest(Path(n))==h for n,h in fixtures.items()),'Actual inputs drift')
        require(helper.daily_shortcut_key(bundle_id)==daily,'Daily shortcut drift');summary.update(status='passed',passed=4,failed=0,inputsUnchanged=True,bundleUnchanged=True)
    except BaseException as e:summary.update(status='failed',passed=len(summary['results']),error=str(e));raise
    finally:
        write(out/'inputs-end.json',{'bundle':inventory(app),'buildInputs':{n:digest(ROOT/n) for n in inputs},'fixtures':{n:digest(Path(n)) for n in fixtures},'dailyShortcut':helper.daily_shortcut_key(bundle_id)});write(out/'summary.json',summary)
if __name__=='__main__':main()
