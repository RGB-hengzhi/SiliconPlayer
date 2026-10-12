#!/usr/bin/env python3
"""Prepared two serial real-App external-WAV groups, not an executed result."""
import argparse, hashlib, importlib.util, json, os, plistlib, shutil, signal, struct, subprocess, sys, tempfile, time, wave
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent.parent
MODES=('live-asr-external-wav-replay','live-asr-external-wav-identity')
COMMON={'isolated-storage-valid','main-video-loaded','main-longer-than-external','native-initial-seek-settled','external-add-accepted','selected-external-wav-row','external-pair-start-accepted','initial-paused-speed-ack','external-held-source-proof','actual-native-resume-ack','external-current-chinese-partial','matching-real-chinese-overlay','real-external-chinese-window-png','final-owned-cleanup','daily-shortcuts-unchanged'}
EXTRA={MODES[0]:{'external-source-completed-before-main-eof','external-natural-close-exact','external-final-cues-in-source-clock','external-final-visible-tail','replay-native-seek-settled','replay-new-owned-pair','replay-paused-native-ack','replay-resumed-native-ack','replay-current-chinese-prefix','replay-source-natural-complete','replay-close-and-source-cues','replay-real-srt-reparse'},MODES[1]:{'selected-track-change-cancels-old-pair','old-track-close-exact','original-external-reselected-and-settled','external-restart-accepted','identity-restart-paused-ack','same-path-external-identity-replaced','replaced-path-old-pair-retired','replaced-source-close-exact','replacement-cannot-reuse-original-attachment'}}
def require(value,message):
    if not value:raise RuntimeError(message)
def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda:f.read(1048576),b''):h.update(block)
    return h.hexdigest()
def write(path,value):Path(path).write_text(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n')
def inventory(app):return {str(p.relative_to(app)):digest(p) for p in sorted(app.rglob('*')) if p.is_file() and not any(x.startswith('._') for x in p.relative_to(app).parts)}
def strong(close):return isinstance(close,dict) and all(close.get(k) is True for k in ('confirmed','resourcesReleased','ownedReaped','decoderStdoutEOF','recognizerStdoutEOF')) and close.get('forced') is False and all(close.get(k)==0 for k in ('decoderExit','recognizerExit','decoderContexts','recognizerStreams','recognizers'))

def service_rows(backend):
    require(isinstance(backend,dict) and backend.get('captureEnabled') is True,'Actual bounded backend capture required')
    return [json.loads(line,parse_constant=lambda value: (_ for _ in ()).throw(RuntimeError('Nonfinite service JSON'))) for line in backend.get('serviceJSONLines',[])]

def validate_held_start(receipt,backend):
    require(isinstance(receipt,dict),'Held startup receipt missing')
    events=backend.get('decoderEvents',[]);headers=backend.get('pcmHeaders',[])
    indices=[receipt.get(n) for n in ('firstPauseEventOrdinal','firstBlockEventOrdinal','secondPauseEventOrdinal')]
    require(all(type(i) is int and 0<=i<len(events) for i in indices) and indices[0]<indices[1]<indices[2],'Actual held-start event ordering invalid')
    a,b,c=indices
    require(events[a].get('event')=='paused' and events[b].get('event')=='first_block_waiting' and events[c].get('event')=='paused','Held birth/post-block native pause ACKs absent')
    require(any(r.get('event')=='resumed' for r in events[a+1:b]) and any(r.get('event')=='pcm' for r in events[a+1:b]),'No actual first resume/complete PCM before held gate')
    names={'paused','resumed','speed_changed','epoch_changed','cancel_acknowledged','control_rejected'}
    first=sum(r.get('event') in names for r in events[:a+1]);second=sum(r.get('event') in names for r in events[:c+1])
    require(receipt.get('firstPauseObservedControlSerial')==first and receipt.get('secondPauseObservedControlSerial')==second and 0<first<second,'Held ACK serials not derived from distinct actual events')
    header=receipt.get('firstRealHeader');require(isinstance(header,dict) and header in headers,'Held header not from actual parsed SPCM')
    gate=events[b];require(header.get('epoch')==gate.get('epoch')==receipt.get('epoch') and header.get('sequence')==gate.get('sequence')==receipt.get('sequence') and header.get('item')==gate.get('item') and header.get('segment')==gate.get('segment'),'Held SPCM ticket differs from actual C gate')
    require(header.get('streamIndex')==0 and header.get('pcmPTS')==0 and header.get('sourceBestEffortTimestamp')==0 and type(header.get('flags')) is int and header['flags']&1==1 and gate.get('header_bytes')==112 and gate.get('samples')==header.get('samples') and gate.get('record_bytes')==112+4*header['samples'],'Held first block PTS/record bounds differ')
    require(any(r.get('event')=='first_block_pause_confirmed' and r.get('epoch')==receipt['epoch'] for r in events[c+1:]),'Actual post-record pause confirmation absent')

def validate_edges(value,mode):
    edges=value.get('asrEdgeReceipts',[]);expected={'short-80-samples-held-eof-backseek-cancel'}|({'zero-prefix-beyond-source-end'} if mode==MODES[0] else set())
    require(len(edges)==len(expected) and {r.get('kind') for r in edges}==expected,'Mandatory edge receipt missing/duplicate/extra')
    mapped={r['kind']:r for r in edges}
    if mode==MODES[0]:
        row=mapped['zero-prefix-beyond-source-end'];controller=row['controllerActual'];backend=row['actualBackend'];close=controller.get('close',{});events=service_rows(backend)
        require(row.get('expectedFailureObserved') is True and controller.get('state')=='failed' and controller.get('grantedSamples')==0 and not controller.get('finalCues'),'Real zero-prefix failure was hidden or fabricated final')
        require(controller.get('binding') and controller['binding']==row.get('before',{}).get('binding') and controller['processID']!=row['before']['processID'],'Zero-prefix attempt lacks fresh exact primary binding')
        require(row['snapshot'].get('eof') is False and row['snapshot'].get('paused') is False and row['snapshot'].get('overlayOwner')=='','Main EOF or stale OSD replaced source failure')
        require(backend.get('decoderMediaEOF') is True and any(e.get('event')=='media_eof' and e.get('epoch')==backend['actualEpoch'] for e in backend.get('decoderEvents',[])),'Zero-prefix did not reach real source EOF')
        pause=row['initialPausedACK'];resume=row['actualResumedACK'];minimum=row['resumeBaselineSerial'];epoch=controller.get('epoch')
        require(type(minimum) is int and minimum>0 and resume.get('minimumSerial')==minimum,'Zero-prefix RESUME baseline not captured before Core unpause')
        for detail,name,paused in ((pause,'speed_changed',True),(resume,'resumed',False)):
            ack=detail['actualDecoderACK'];actual=detail['actualBackend'];host=detail['snapshot'];observed=host['controllerActual']
            require(ack in actual.get('controlReceipts',[]) and ack.get('event')==name and ack.get('epoch')==epoch==actual.get('actualEpoch')==actual.get('desiredEpoch')==observed.get('epoch'),'Zero-prefix real native ACK/epoch missing')
            require(actual.get('processID')==observed.get('processID')==controller['processID'] and observed.get('binding')==controller['binding'] and actual.get('decoderPaused') is paused and host.get('paused') is paused,'Zero-prefix native ACK/current main/pair differ')
        ack=resume['actualDecoderACK'];require(type(ack.get('serial')) is int and ack['serial']>minimum,'Zero-prefix stale RESUME ACK')
        controls={'paused','resumed','speed_changed','epoch_changed','cancel_acknowledged','control_rejected'};serial=0;resume_ordinal=None;eof_ordinal=None
        for ordinal,event in enumerate(backend.get('decoderEvents',[])):
            if event.get('event') in controls:
                serial+=1
                if serial==ack['serial'] and event.get('event')=='resumed' and event.get('epoch')==epoch:resume_ordinal=ordinal
            if event.get('event')=='media_eof' and event.get('epoch')==epoch:eof_ordinal=ordinal
        require(resume_ordinal is not None and eof_ordinal is not None and resume_ordinal<eof_ordinal,'Zero-prefix actual source EOF did not follow the fresh native RESUME')
        require(any(e.get('event')=='error' and e.get('reason')=='no_actual_PCM_input' for e in events) and not any(e.get('event')=='eof_final' for e in events),'Exact service empty-input failure missing')
        require(close.get('confirmed') is False and all(close.get(k) is True for k in ('resourcesReleased','ownedReaped','decoderStdoutEOF','recognizerStdoutEOF')) and close.get('forced') is False and close.get('decoderExit')==0 and close.get('recognizerExit')==1 and all(close.get(k)==0 for k in ('decoderContexts','recognizerStreams','recognizers')),'Expected failure resources were not actually released')
        require('lastError' in backend and backend['lastError'] is not None,'Expected empty-prefix error was erased')
    row=mapped['short-80-samples-held-eof-backseek-cancel'];before=row['before'];complete=row['completion'];replay=row['backseek'];cancelled=row['cancelled'];completed_backend=row['completedBackend'];cancelled_backend=row['cancelledBackend']
    require(row.get('sourceSamples')==80 and row.get('sourceRate')==16000 and row.get('semanticRecognitionClaim') is False and row.get('expectedFailureObserved') is False,'Short source scope invalid')
    validate_held_start(row['heldStart'],row['pause']['actualBackend']);validate_held_start(row['backseekHeldStart'],row['backseekBackend'])
    require(row['heldStart']['firstRealHeader']['samples']==80 and row['heldStart']['firstRealHeader']['inputRate']==16000,'Short source did not use real 80 samples')
    for detail,event,paused in ((row['pause'],'speed_changed',True),(row['resume'],'resumed',False),(row['backseekPausedACK'],'speed_changed',True)):
        ack=detail['actualDecoderACK'];backend=detail['actualBackend'];host=detail['snapshot'];controller=host['controllerActual']
        require(ack.get('event')==event and type(ack.get('serial')) is int and ack['serial']>detail.get('minimumSerial',0) and ack.get('epoch')==backend.get('actualEpoch')==backend.get('desiredEpoch')==controller.get('epoch'),'Short actual ACK/epoch missing')
        require(backend.get('decoderPaused') is paused and host.get('paused') is paused and backend.get('processID')==controller.get('processID'),'Short native pause intent/process differs')
    require(row['pause']['snapshot']['corePosition'] is not None and 0<=row['pause']['snapshot']['corePosition']<=.001 and before.get('grantedSamples')==0,'Short pair did not start actually paused at zero')
    events=service_rows(completed_backend);final=[e for e in events if e.get('event')=='eof_final']
    require(complete.get('state')=='sourceCompleted' and complete.get('grantedSamples')==80 and strong(complete.get('close')) and len(final)==1 and final[0].get('accepted_samples')==80 and final[0].get('padding_samples')==16000 and not any(e.get('event')=='error' for e in events),'Short natural source final not exactly real 80 samples')
    ticket=complete.get('ticket',{});require(ticket and all(final[0].get(a)==ticket.get(b) for a,b in [('epoch','epoch'),('timing_segment','timingSegment'),('item','itemSerial'),('stream_index','streamIndex')]),'Short final wrong actual source ticket')
    prefix=[h for h in completed_backend.get('pcmHeaders',[]) if h.get('epoch')==ticket.get('epoch') and h.get('item')==ticket.get('itemSerial') and final[0]['first_input_sequence']<=h['sequence']<=final[0]['last_input_sequence']]
    require(sum(h['samples'] for h in prefix)==80 and prefix and prefix[0]['sequence']==final[0]['first_input_sequence'] and prefix[-1]['sequence']==final[0]['last_input_sequence'],'Short service prefix/padding confused')
    fresh_header=row['backseekHeldStart']['firstRealHeader'];require(replay['processID']!=before['processID'] and replay['owner']!=before['owner'] and replay.get('binding')==complete.get('binding') and fresh_header['item']>ticket['itemSerial'] and replay.get('grantedSamples')==0,'Short backward seek reused old pair/ticket or forwarded paused PCM')
    cancel_events=service_rows(cancelled_backend);require(strong(cancelled.get('close')) and cancelled.get('grantedSamples')==0 and 'lastError' in cancelled_backend and cancelled_backend['lastError'] is None and any(e.get('event')=='cancel_acknowledged' for e in cancel_events) and any(e.get('event')=='closed' and e.get('ok') is True and e.get('cancelled') is True for e in cancel_events) and not any(e.get('event')=='error' for e in cancel_events),'Short replay cancellation was converted into empty-input EOF')
    return [{'kind':r['kind'],'status':'passed','scope':'mandatory receipts within the same original App group; not extra group/check IDs'} for r in edges]

def run(helper,exe,mode,out,storage,tmp,main,wav_source,duration,daily,bundle_id):
    report=out/(mode+'.json');known={};identity=None;proc=None;samples=[];forced=False
    fixtures=storage/'fixtures';fixtures.mkdir();wav=fixtures/'外置:中文，speech.wav';shutil.copyfile(wav_source,wav)
    short=fixtures/'首块:外置，80samples.wav'
    with wave.open(str(wav_source),'rb') as original:
        require(original.getnchannels()==1 and original.getsampwidth()==2 and original.getframerate()==16000,'Real source WAV must be PCM16 mono 16000 for short-prefix proof')
        prefix=original.readframes(80);require(len(prefix)==160,'Real short prefix must contain 80 source samples')
    with wave.open(str(short),'wb') as output:
        output.setnchannels(1);output.setsampwidth(2);output.setframerate(16000);output.writeframes(prefix)
    short_before={'path':str(short),'sha256':digest(short),'samples':80,'rate':16000,'derivedFromRealSpeechSHA256':digest(wav_source),'generatedAudioOrSilence':False}
    write(out/(mode+'-short-wave-before.json'),short_before)
    before=wav.stat();write(out/(mode+'-private-wave-before.json'),{'path':str(wav),'sha256':digest(wav),'device':before.st_dev,'inode':before.st_ino,'mtimeNanoseconds':before.st_mtime_ns,'bytes':before.st_size})
    env={k:v for k,v in os.environ.items() if not k.startswith('SILICONPLAYER_VERIFY_')}
    env.update(SILICONPLAYER_VERIFY_MODE=mode,SILICONPLAYER_VERIFY_REPORT=str(report),SILICONPLAYER_VERIFY_STORAGE=str(storage),SILICONPLAYER_VERIFY_EXIT='1',SILICONPLAYER_VERIFY_EXTERNAL_WAV=str(wav),SILICONPLAYER_VERIFY_SHORT_WAV=str(short),SILICONPLAYER_VERIFY_EXTERNAL_WAV_DURATION=repr(duration),TMPDIR=str(tmp)+'/')
    write(out/(mode+'-command.json'),{'argv':[str(exe),str(main)],'verificationEnvironment':{k:v for k,v in env.items() if k.startswith('SILICONPLAYER_VERIFY_') or k=='TMPDIR'},'homeInheritedUnchanged':env.get('HOME')==os.environ.get('HOME')})
    try:
        with (out/(mode+'.log')).open('x') as log:
            proc=subprocess.Popen([str(exe),str(main)],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            deadline=time.monotonic()+120
            while proc.poll() is None:
                require(time.monotonic()<deadline,'Actual external WAV App timeout')
                table=helper.process_table()
                if identity is None and proc.pid in table:identity=table[proc.pid]
                helper.collect_owned(table,proc.pid,identity,known)
                samples.append({'uptime':time.clock_gettime(time.CLOCK_UPTIME_RAW),'owned':helper.survivors(table,known)})
                time.sleep(.05)
        require(proc.returncode==0 and report.is_file(),'Actual App did not exit naturally with report')
        require(not helper.survivors(helper.process_table(),known),'Owned process survived')
        value=json.loads(helper.bounded_regular_bytes(report,24*1024*1024));checks=value.get('asrChecks',[]);ids=[r.get('id') for r in checks]
        require(value.get('mode')==mode and value.get('succeeded') is True and len(ids)==len(set(ids)) and set(ids)==COMMON|EXTRA[mode] and all(r.get('passed') is True for r in checks),'Missing/duplicate/failed/extraneous actual WAV checks')
        by_id={r['id']:r['detail'] for r in checks}
        require(by_id['native-initial-seek-settled']['snapshot']['paused'] is True and 0<=by_id['native-initial-seek-settled']['snapshot']['corePosition']<=.001,'Actual video main initial paused-zero missing')
        validate_held_start(by_id['external-held-source-proof']['heldStart'],by_id['external-held-source-proof']['actualBackend'])
        edge_results=validate_edges(value,mode)
        require(digest(short)==short_before['sha256'],'Owned short prefix changed during App checks')
        proof=by_id['external-held-source-proof']['actual']['sourceProof']
        require(proof.get('sourceKind')=='externalPCM_WAV' and proof.get('ffIndex')==0 and proof.get('rawOriginNumerator')==0 and proof.get('inode')==before.st_ino and proof.get('device')==before.st_dev and proof.get('bytes')==before.st_size,'Actual independent external fingerprint/clock proof absent')
        for name in ['initial-paused-speed-ack','actual-native-resume-ack']+(['replay-paused-native-ack','replay-resumed-native-ack'] if mode==MODES[0] else ['identity-restart-paused-ack']):
            detail=by_id[name];ack=detail.get('actualDecoderACK',{});actual=detail.get('actualBackend',{});snapshot=detail.get('snapshot',{});controller=snapshot.get('controllerActual',{})
            expected_event='resumed' if 'resume' in name else 'speed_changed'
            require(ack.get('event')==expected_event and type(ack.get('serial')) is int and ack['serial']>0 and ack.get('epoch')==actual.get('actualEpoch')==actual.get('desiredEpoch')==controller.get('epoch') and actual.get('processID')==controller.get('processID'),'Actual native C ACK/process/epoch missing')
            if 'resume' in name:require(type(detail.get('minimumSerial')) is int and ack['serial']>detail['minimumSerial'] and actual.get('decoderPaused') is False,'Stale or paused resume ACK')
        overlay=by_id['matching-real-chinese-overlay']['snapshot']
        require(bool(overlay.get('overlayOwner')) and overlay['overlayOwner']==overlay.get('controllerActual',{}).get('owner') and any(0x3400<=ord(c)<=0x9fff for c in overlay.get('overlayPayload','')),'Matching Chinese OSD missing')
        png=report.with_suffix('.external-asr-window.png');raw=helper.bounded_regular_bytes(png,64*1024*1024)
        require(len(raw)>5000 and raw[:8]==b'\x89PNG\r\n\x1a\n' and raw[12:16]==b'IHDR','Actual screenshot missing')
        width,height=struct.unpack('>II',raw[16:24]);require(0<width<=16384 and 0<height<=16384,'PNG dimensions invalid')
        close_names=['external-natural-close-exact','replay-close-and-source-cues'] if mode==MODES[0] else ['old-track-close-exact','replaced-source-close-exact']
        for name in close_names:require(strong(by_id[name]['snapshot']['controllerActual'].get('close')),'Actual exact external pair close missing')
        if mode==MODES[0]:
            require(by_id['external-source-completed-before-main-eof']['snapshot']['eof'] is False and by_id['replay-source-natural-complete']['snapshot']['eof'] is False,'External EOF substituted with main EOF')
            old=by_id['external-natural-close-exact']['snapshot']['controllerActual'];new=by_id['replay-new-owned-pair']['snapshot']['controllerActual']
            require(old.get('processID')!=new.get('processID') and old.get('owner')!=new.get('owner') and old.get('binding')==new.get('binding'),'Replay did not allocate a fresh pair under same primary binding')
            require((report.with_suffix('.srt')).is_file(),'Actual exported SRT missing')
        else:
            replacement=by_id['same-path-external-identity-replaced'];require(replacement.get('beforeInode')==before.st_ino and replacement.get('afterInode')!=before.st_ino,'Private replacement did not change identity')
        termination=report.with_suffix('.asr-termination.json');t=json.loads(helper.bounded_regular_bytes(termination,16*1024*1024));backend=t.get('backendActual')
        require(t.get('succeeded') is True and t.get('asrStopped') is True and t.get('ownedJobs') is False and t.get('overlayOwner')=='','Actual shutdown/OSD cleanup failed')
        require(isinstance(backend,dict) and 'lastError' in backend and backend['lastError'] is None,'Final backend diagnostic missing or not clean')
        require(t.get('after',{}).get('close',{}).get('resourcesReleased') is True and t['after']['close'].get('forced') is False,'Final resource receipt missing')
        barrier=helper.termination_barrier(report,storage,mode);require(helper.daily_shortcut_key(bundle_id)==daily,'Daily shortcut changed')
        after=wav.stat();write(out/(mode+'-private-wave-after.json'),{'sha256':digest(wav),'inode':after.st_ino,'mtimeNanoseconds':after.st_mtime_ns,'bytes':after.st_size})
        return {'id':mode,'status':'passed','appPID':proc.pid,'appExit':proc.returncode,'reportSHA256':digest(report),'ASRTerminationSHA256':digest(termination),'PNG':{'path':str(png),'sha256':digest(png),'width':width,'height':height},'observationCount':len(checks),'ownedSurvivors':[],'forcedCleanup':False,'terminationBarrier':barrier,'edgeReceipts':edge_results,'scope':'Selected sole local PCM WAV; real short80-sample transport/EOF/replay/cancel, not semantic recognition/network/natural-speech quality/word-end claim'}
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
            current=helper.process_table().get(old['pid'])
            if current and helper.same_process(current,old,allow_zombie=False):
                forced=True
                try:os.kill(current['pid'],signal.SIGKILL)
                except ProcessLookupError:pass
        write(out/(mode+'-process.json'),{'pid':proc.pid if proc else None,'exit':proc.returncode if proc else None,'knownOwned':list(known.values()),'samples':samples,'forcedCleanup':forced,'ownedSurvivors':helper.survivors(helper.process_table(),known)})

def main():
    global ROOT
    parser=argparse.ArgumentParser();parser.add_argument('--project-root',type=Path,required=True);parser.add_argument('--app',type=Path,required=True);parser.add_argument('--expected-app-sha256',required=True);parser.add_argument('--expected-runtime-manifest-sha256',required=True);parser.add_argument('--expected-pcm-source-sha256',required=True);parser.add_argument('--report-directory',type=Path,required=True);parser.add_argument('--main-fixture',type=Path,required=True);parser.add_argument('--speech-wav',type=Path,required=True);args=parser.parse_args()
    ROOT=args.project_root.resolve(strict=True);app=args.app.resolve(strict=True);exe=app/'Contents/MacOS/SiliconPlayer';out=args.report_directory.resolve();main=args.main_fixture.resolve(strict=True);wav=args.speech_wav.resolve(strict=True)
    require(app.suffix=='.app' and digest(exe)==args.expected_app_sha256,'Exact pinned App required');require(not out.exists(),'Fresh reports required');out.mkdir(parents=True)
    spec=importlib.util.spec_from_file_location('owned_app_helpers',ROOT/'scripts/verify_native_audio_queue.py');helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
    with wave.open(str(wav),'rb') as f:require(f.getcomptype()=='NONE' and f.getnchannels()==1 and f.getsampwidth()==2,'Known sole PCM16 mono fixture required');duration=f.getnframes()/f.getframerate()
    require(5<=duration<=15,'Chinese positive fixture must be a finite 5-15s WAV; short80 prefix is a distinct non-semantic boundary')
    provenance=json.loads((app/'Contents/Resources/build-provenance.json').read_text());require(provenance.get('inputFilesUnchanged') is True,'Actual build input drift');inputs=provenance['inputFiles'];require('Sources/SiliconPlayer/ExternalWAVASRVerifier.swift' in inputs and all(digest(ROOT/n)==h for n,h in inputs.items()),'Compiled actual external verifier/current input pins required')
    runtime_path=app/'Contents/Resources/LiveASR/runtime-manifest.json';require(digest(runtime_path)==args.expected_runtime_manifest_sha256,'Exact compiled runtime manifest required')
    runtime=json.loads(helper.bounded_regular_bytes(runtime_path,2*1024*1024));require(runtime.get('pcmHelperSourceSHA256')==args.expected_pcm_source_sha256==inputs.get('Sources/MediaPCMPTS/main.c'),'Compiled PCM source/runtime binding mismatch')
    require(all(runtime.get('features',{}).get(name,{}).get('verified') is True for name in ('gracefulInputLimit','firstRealBlockHold')),'Actual signed helper handshake/limit capabilities missing')
    before=inventory(app);fixtures={str(main):digest(main),str(wav):digest(wav)};bundle_id=plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleIdentifier'];daily=helper.daily_shortcut_key(bundle_id)
    write(out/'inputs-before.json',{'app':str(app),'appSHA256':args.expected_app_sha256,'buildInputs':inputs,'bundle':before,'fixtures':fixtures,'driverSHA256':digest(Path(__file__)),'runtimeManifestSHA256':args.expected_runtime_manifest_sha256,'pcmSourceSHA256':args.expected_pcm_source_sha256,'dailyShortcut':daily})
    summary={'status':'running','expectedGroups':list(MODES),'expectedOriginalObservations':[27,24],'mandatoryEdgeReceiptsPerMode':[2,1],'edgeReceiptsDoNotAddGroups':True,'appSHA256':args.expected_app_sha256,'runtimeManifestSHA256':args.expected_runtime_manifest_sha256,'pcmSourceSHA256':args.expected_pcm_source_sha256,'results':[]}
    try:
        with tempfile.TemporaryDirectory(prefix='siliconplayer-external-asr-',dir='/private/tmp') as raw:
            work=Path(raw).resolve()
            for mode in MODES:
                storage=work/mode;storage.mkdir();tmp=storage/'tmp';tmp.mkdir()
                summary['results'].append(run(helper,exe,mode,out,storage,tmp,main,wav,duration,daily,bundle_id));write(out/'summary.json',summary)
        require(inventory(app)==before and all(digest(ROOT/n)==h for n,h in inputs.items()) and all(digest(Path(n))==h for n,h in fixtures.items()) and helper.daily_shortcut_key(bundle_id)==daily,'Inputs/bundle/daily data drift')
        summary.update(status='passed',passed=2,failed=0,inputsUnchanged=True,bundleUnchanged=True)
    except BaseException as error:summary.update(status='failed',passed=len(summary['results']),error=str(error));raise
    finally:write(out/'inputs-end.json',{'bundle':inventory(app),'buildInputs':{n:digest(ROOT/n) for n in inputs},'fixtures':{n:digest(Path(n)) for n in fixtures},'dailyShortcut':helper.daily_shortcut_key(bundle_id)});write(out/'summary.json',summary)
if __name__=='__main__':main()
