#!/usr/bin/env python3
"""Serial actual App continuity/cancellation proof, not held-out ASR quality."""
import argparse, base64, hashlib, importlib.util, json, math, os, plistlib, re, signal, struct, subprocess, sys, tempfile, time
from fractions import Fraction
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent.parent
CASES=(('continuous-pcm25','live-asr-continuous-local','pcm25',5),('continuous-aac7','live-asr-continuous-local','aac7',2),('continuous-bound-cancel','live-asr-continuous-cancel','pcm25',0))
FIXTURES={'pcm25':('recorded-repeat25-pcm16k','1bd288974571591ecb5bc5feb93a5cf88030ca9b36a0bd0c2c65f115f31fa0f2',525.4),
          'aac7':('recorded-repeat7-aac48k','656fce09b6c9d8d4e54fe35ca4f08f0f8ade5e2d994297ead57b859b77ffadc2',147.112)}
def require(v,m):
    if not v: raise ValueError(m)
def digest(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()
def write(p,v):Path(p).write_text(json.dumps(v,ensure_ascii=False,indent=2,allow_nan=False)+'\n')
def inventory(p):return {str(x.relative_to(p)):digest(x) for x in sorted(p.rglob('*')) if x.is_file() and not any(n.startswith('._') for n in x.relative_to(p).parts)}
def expected(mode,pairs):
    ids={'isolated-storage','loaded-real-long-source','native-paused-zero','selected-embedded-audio-initial','initial-pair-accepted','initial-native-paused-ack','initial-chinese-real-prefix','actual-chinese-window-png','daily-shortcut-unchanged'}
    if mode=='live-asr-continuous-local':
        ids|={'real-player-eof-after-final-pair','all-complete-real-pairs','old-and-post-120-source-cues','full-session-srt-reparse','real-eof-cleanup','continuation-native-paused-ack','continuation-buffer-held-over-three-seconds','continuation-real-resume-ack'}
        for i in range(1,pairs):ids|={f'actual-input-bound-{i}',f'new-pair-real-prefix-{i}',f'retained-cues-and-primary-binding-{i}'}
    else:
        for i,action in enumerate(('seek','reload','stop','quit')):
            ids.add('real-bound-before-'+action)
            if i:ids|={'reset-native-'+action,'restart-pair-'+action,'selected-embedded-audio-'+action}
            if action!='quit':ids|={'owned-retired-'+action,'strong-close-no-revival-'+action}
        ids.add('owned-real-bound-at-quit')
    return ids

def ht(h):return (h['epoch'],h['segment'],h['item'],h['streamIndex'])
def et(e):return (e['epoch'],e['timing_segment'],e['item'],e['stream_index'])
def tm(h,offset=0):
    require(h['flags']&1 and h['pcmPTS']!=-(1<<63),'Missing PTS cannot be located')
    return Fraction(h['pcmPTS']+offset*h['inputRate'],h['pcmDenominator'])
def prefix(headers,e):
    r=[h for h in headers if ht(h)==et(e) and e['first_input_sequence']<=h['sequence']<=e['last_input_sequence']]
    require(r and r[0]['sequence']==e['first_input_sequence'] and r[-1]['sequence']==e['last_input_sequence'] and sum(h['samples'] for h in r)==e['accepted_samples'],'Actual service prefix/header mismatch')
    return r

def sample_time(rows,sample):
    require(0<=sample<=sum(h['samples'] for h in rows),'Token in padding/outside actual PCM')
    used=0
    for h in rows:
        if sample<used+h['samples']:return tm(h,sample-used)
        used+=h['samples']
    return tm(rows[-1],rows[-1]['samples'])
def closed(c):
    return isinstance(c,dict) and all(c.get(k) is True for k in ('confirmed','resourcesReleased','ownedReaped','decoderStdoutEOF','recognizerStdoutEOF')) and c.get('forced') is False and all(c.get(k)==0 for k in ('decoderExit','recognizerExit','decoderContexts','recognizerStreams','recognizers'))

def audit_pair(b,proof):
    require(b.get('captureEnabled') is True and 'lastError' in b and b['lastError'] is None,'Required actual pair capture/clean diagnostic missing')
    headers=b['pcmHeaders']; events=b['decoderEvents']; service=[json.loads(x) for x in b['serviceJSONLines']]
    require(headers and all(a['sequence']<z['sequence'] for a,z in zip(headers,headers[1:])),'Header ordering/inventory absent')
    require(sum(h['samples'] for h in headers)==b['parsedRealSamples']<=1920000,'Real helper sample bound/counter differs')
    pcm={e['sequence']:e for e in events if e['event']=='pcm'};require(len(pcm)==sum(e['event']=='pcm' for e in events),'Duplicate C PCM receipt')
    for h in headers:
        require(0<h['samples']<=320 and h['pcmDenominator']==h['inputRate']*16000,'SPCM bounds invalid')
        e=pcm.get(h['sequence']);require(e is not None,'Real C PCM receipt missing')
        for a,z in [('epoch','epoch'),('segment','segment'),('item','item'),('streamIndex','stream_index'),('samples','samples'),('pcmPTS','pcm_pts'),('sourceBestEffortTimestamp','source_pts'),('pcmDenominator','time_denominator'),('delayBefore','delay_units_before_convert'),('frameOrdinal','decoded_frame')]:require(h[a]==e[z],'C/SPCM field mismatch: '+a)
        require(bool(h['flags']&1)==e['pts_known'] and bool(h['flags']&2)==e['negative_pts'] and bool(h['flags']&4)==e['drain_from_last_real_anchor'],'Actual PTS flags differ')
        if h['flags']&1 and not h['flags']&4:
            require(tm(h)==Fraction(h['sourceBestEffortTimestamp']*h['tbNumerator'],h['tbDenominator'])-Fraction(h['delayBefore'],h['pcmDenominator'])+Fraction(h['convertedOffset'],16000),'Source PTS/resampler ledger origin differs')
    fp=[e for e in events if e['event']=='source_fd_fingerprint'];require(fp,'Owned held-FD receipt absent')
    for e in fp:require(e['custom_avio'] is True and e['nofollow'] is True and e['device']==proof['device'] and e['inode']==proof['inode'] and e['bytes']==proof['bytes'] and e['mtime_seconds']*1000000000+e['mtime_nanoseconds']==proof['mtimeNanoseconds'],'Actual pair changed source identity')
    children=b['ownedChildExitDiagnostics'];require(len(children)==3,'Three exact owned child exit receipts required')
    for c in children:require(c['reaped'] is True and c['leaderExitedWNOWAIT'] is True and c['exitCode']==0 and c['stdoutEOF'] is True and c['stderrEOF'] is True and c['forcedSignalIssued'] is False and c['firstIdentityFailureReceipt'] is None,'Owned pair not naturally strongly reaped or has sticky error')
    probe=b['sourceProbe'];require(probe.get('protocol')=='fd' and probe.get('naturalExitCode')==0 and probe.get('reaped') is True and probe.get('forcedTermination') is False and probe.get('metadataValidated') is True,'Actual held-FD ffprobe incomplete')
    dc=[e for e in events if e['event']=='closed'];require(len(dc)==1 and dc[0]['ok'] is True and dc[0]['remaining_owned_contexts']==0,'Decoder natural context close missing')
    require(service and all(a['sequence']<z['sequence'] for a,z in zip(service,service[1:])),'Service event order differs')
    sc=service[-1];require(sc['event']=='closed' and sc['ok'] is True and sc['live_streams']==sc['live_recognizers']==0,'Actual recognizer resource close missing')
    origin=Fraction(proof['rawOriginNumerator'],proof['rawOriginDenominator']); finals={}; final=[]
    streams={e['stream_generation']:et(e) for e in service if e['event']=='stream_created'}
    for e in service:
        if e['event'] not in ('partial','endpoint_final','eof_final'):continue
        require(streams.get(e['stream_generation'])==et(e),'Unknown actual recognizer stream ticket')
        rows=prefix(headers,e);raw=json.loads(e['engine_result_json'])
        require(raw['text']==e['text'] and raw['tokens']==e['tokens'] and raw['segment']==e['engine_segment'] and abs(raw['start_time']-e['engine_start_time_seconds'])<=1e-6,'Actual CAPI JSON differs')
        require(len(raw['timestamps'])==len(e['timestamps']) and all(abs(x-y)<=.0050001 for x,y in zip(raw['timestamps'],e['timestamps'])),'Actual CAPI token starts differ')
        require(0<=e['padding_samples']<=16000,'Padding not bounded/separate')
        first=e['timestamps'][0] if e['timestamps'] else 0
        pos=(e['engine_start_time_seconds']+first)*16000;require(math.isfinite(pos) and 0<=pos<=e['accepted_samples']+1,'Token start in non-source padding')
        start=sample_time(rows,min(e['accepted_samples'],math.floor(pos+.5)))-origin;end=sample_time(rows,e['accepted_samples'])-origin
        if e['final'] and e['text'].strip():finals[(e['epoch'],e['stream_generation'],e['engine_segment'],e['revision'])]=(e['text'],start,end)
        if e['event']=='eof_final':final.append((e,rows))
    require(len(final)==1,'Completed pair lacks exact actual eof_final')
    e,rows=final[0];start=tm(rows[0])-origin;end=tm(rows[-1],rows[-1]['samples'])-origin
    limit=[x for x in events if x['event']=='input_limit_reached']; eof=[x for x in events if x['event']=='media_eof']
    if limit:
        require(len(limit)==1 and not eof and b['decoderInputLimitReached'] is True and b['decoderMediaEOF'] is False,'Input bound falsely treated as media EOF')
        l=limit[0];require(l['max_samples']==1920000 and l['output_samples']==b['parsedRealSamples'] and l['output_samples']+l['next_chunk_samples_not_published']>1920000,'Actual bound receipt differs')
    else:require(eof and b['decoderMediaEOF'] is True and b['decoderInputLimitReached'] is False,'Last pair lacks real source EOF')
    return {'id':b['processID'],'start':start,'end':end,'accepted':e['accepted_samples'],'parsed':b['parsedRealSamples'],'limited':bool(limit),'unpaced':b.get('unpacedContinuation'), 'finals':finals}


def audit_cancelled_preparation(process,receipt,b,proof):
    require(isinstance(process,str) and process and isinstance(b,dict) and b.get('processID')==process,'Exact cancelled warm process wire absent')
    require(receipt.get('processID')==process and receipt.get('kind')=='cancelled_preparation' and receipt.get('confirmed') is True and receipt.get('resourcesReleased') is True and receipt.get('forced') is False and receipt.get('decoderExit')==receipt.get('recognizerExit')==0,'Actual warm cancellation receipt incomplete')
    require(b.get('captureEnabled') is True and 'lastError' in b and b['lastError'] is None and b.get('setupFinished') is True and b.get('recognizerReady') is True,'Actual warm pair capture/setup error')
    require(b.get('servicePCMBytesWritten')==0,'Warm cancellation forwarded PCM')
    children=b.get('ownedChildExitDiagnostics');require(isinstance(children,list) and len(children)==3,'Actual warm three-child inventory missing')
    roles={c.get('role'):c for c in children};require(set(roles)=={'source-probe','decoder','recognizer'} and len({c['pid'] for c in children})==3,'Warm child namespace inventory differs')
    for c in children:
        require(c['pid']>0 and c['reservedPGID']==c['pid'] and c.get('reaped') is True and c.get('leaderExitedWNOWAIT') is True and c.get('exitCode')==0 and c.get('stdoutEOF') is True and c.get('stderrEOF') is True and c.get('forcedSignalIssued') is False and c.get('firstIdentityFailureReceipt') is None,'Warm child lacks exact natural-zero dual-EOF strong reap')
        waits=[x for x in c.get('events',[]) if x.get('event')=='waitpid']
        require(waits and waits[-1].get('return')==c['pid'] and waits[-1].get('status')==0,'Actual warm exact waitpid0 trace absent')
        group=c.get('confirmedQuiescentGroupReceipt');require(isinstance(group,dict) and group.get('reservedPID')==group.get('reservedPGID')==c['pid'] and group.get('complete') is True and group.get('allZombie') is True and group.get('sizeReturn')==group.get('readReturn')==0,'Warm complete retained-group reap proof absent')
        members=group.get('members');require(isinstance(members,list) and members and len({x['pid'] for x in members})==len(members) and any(x['pid']==c['pid'] for x in members) and all(x['pid']>0 and x['pgid']==c['pid'] and x['stat']==5 for x in members),'Warm full all-zombie original leader membership absent')
    require(roles['decoder']['pid']==b.get('decoderPID') and roles['recognizer']['pid']==b.get('servicePID') and roles['source-probe']['pid']==b.get('sourceProbe',{}).get('pid'),'Wrong warm child PID role mapping')
    probe=b['sourceProbe'];require(probe.get('protocol')=='fd' and probe.get('naturalExitCode')==0 and probe.get('reaped') is True and probe.get('forcedTermination') is False and probe.get('metadataValidated') is True,'Warm held-FD probe proof missing')
    events=b['decoderEvents'];closed_events=[e for e in events if e['event']=='closed']
    require(len(closed_events)==1 and closed_events[0].get('ok') is True and closed_events[0].get('cancelled') is True and closed_events[0].get('remaining_owned_contexts')==0,'Warm actual decoder cancellation close missing')
    require(any(e['event']=='cancel_acknowledged' and e.get('epoch')==closed_events[0]['epoch'] for e in events),'Warm actual decoder CANCEL acknowledgement absent')
    require(not any(e['event'] in ('media_eof','input_limit_reached','error') for e in events),'Warm cancellation falsely completed source or has decoder error')
    headers=b['pcmHeaders'];require(sum(h['samples'] for h in headers)==b['parsedRealSamples']==closed_events[0]['output_samples'],'Warm real decoded header count differs')
    pcm={e['sequence']:e for e in events if e['event']=='pcm'};require(len(pcm)==sum(e['event']=='pcm' for e in events),'Duplicate warm PCM event')
    for h in headers:
        require(0<h['samples']<=320 and h['pcmDenominator']==h['inputRate']*16000,'Warm SPCM record bound invalid')
        e=pcm.get(h['sequence']);require(e is not None,'Actual warm SPCM/C event correlation absent')
        for a,z in [('epoch','epoch'),('segment','segment'),('item','item'),('streamIndex','stream_index'),('samples','samples'),('pcmPTS','pcm_pts'),('sourceBestEffortTimestamp','source_pts'),('pcmDenominator','time_denominator'),('delayBefore','delay_units_before_convert'),('frameOrdinal','decoded_frame')]:require(h[a]==e[z],'Warm SPCM/C actual field mismatch: '+a)
    fps=[e for e in events if e['event']=='source_fd_fingerprint'];require(fps,'Warm actual held-FD fingerprint absent')
    for e in fps:require(e.get('custom_avio') is True and e.get('nofollow') is True and e['device']==proof['device'] and e['inode']==proof['inode'] and e['bytes']==proof['bytes'] and e['mtime_seconds']*1000000000+e['mtime_nanoseconds']==proof['mtimeNanoseconds'],'Warm source identity changed')
    service=[json.loads(x) for x in b['serviceJSONLines']]
    require(service and service[0]['event']=='ready' and all(a['sequence']<z['sequence'] for a,z in zip(service,service[1:])),'Warm recognizer ready/event order absent')
    require(all(e.get('accepted_samples')==0 and e.get('padding_samples')==0 for e in service) and not any(e['event'] in ('partial','endpoint_final','eof_final','stream_created','error') for e in service),'Warm recognizer received real or fabricated input')
    require(any(e['event']=='cancel_acknowledged' for e in service) and service[-1]['event']=='closed' and service[-1].get('ok') is True and service[-1].get('cancelled') is True and service[-1].get('live_streams')==service[-1].get('live_recognizers')==0,'Warm actual service cooperative cancel/closed proof absent')
    return {'processID':process,'decoderPID':b['decoderPID'],'recognizerPID':b['servicePID'],'parsedRealSamples':b['parsedRealSamples'],'servicePCMBytesWritten':0,'actualClosedAndReaped':True}

def audit_continuity(value,out,report):
    actual=value['controllerActual'];proof=actual['sourceProof'];raw=value['completedPairWire']
    require(isinstance(raw,dict) and len(raw)==value['expectedPairs'] and actual['completedPairWireOverflow'] is False and closed(actual.get('close')),'Complete owned pair/raw/close inventory absent')
    rows=[]
    for key,b in raw.items():
        require(key==b['processID'],'Wrong pair namespace')
        rows.append(audit_pair(b,proof));write(out/('pair-'+key+'.json'),b)
    rows.sort(key=lambda x:x['start']);require(rows[0]['start']==0 and rows[0]['unpaced'] is False,'Initial actual source/paced baseline absent')
    for before,after in zip(rows,rows[1:]):require(before['limited'] and after['unpaced'] is True and before['end']==after['start'],'Rational gap/overlap/repeated source between actual pairs')
    require(not rows[-1]['limited'],'Final pair must truly reach source EOF')
    prepared=value['preparedPairWire'];require(isinstance(prepared,dict) and value['preparedPairWireBytes']<=8*1048576,'Prepared wire absent/overflow')
    receipt=actual['completedPairs'];require(len(receipt)==len(rows)-1,'Real limit receipt count differs')
    for r,prev,nxt in zip(receipt,rows,rows[1:]):
        require(r['processID']==prev['id'] and r['nextProcessID']==nxt['id'] and Fraction(r['endNumerator'],r['endDenominator'])==prev['end'] and r['acceptedSamples']==prev['accepted'] and r['decodedSamples']==prev['parsed'] and r['confirmed'] is True and r['resourcesReleased'] is True,'Actual receipt seam/process/sample mapping differs')
    for r,following in zip(receipt,rows[1:]):
        p=prepared.get(following['id']);require(isinstance(p,dict) and p.get('processID')==following['id'],'Wrong prepared process namespace')
        require(p.get('captureEnabled') is True and 'lastError' in p and p['lastError'] is None and p.get('setupFinished') is True and p.get('recognizerReady') is True and p.get('decoderPaused') is True,'Prepared pair not actually ready/paused/clean')
        require(p.get('servicePCMBytesWritten')==0 and p.get('actualEpoch')==p.get('desiredEpoch')==1,'Prepared pair accepted PCM or changed epoch before handover')
        require(any(c['event']=='paused' and c['epoch']==1 and c['serial']>0 for c in p['controlReceipts']),'Prepared actual native PAUSE ACK missing')
        wire=[json.loads(x) for x in p['serviceJSONLines']]
        require(len(wire)==1 and wire[0]['event']=='ready' and wire[0]['accepted_samples']==0 and wire[0]['live_streams']==0 and wire[0]['live_recognizers']==1,'Model readiness/zero actual input not backed by service wire')
        for k in ('preparedReservedUptime','preparedReadyUptime','inputLimitObservedUptime','handoverUptime'):require(isinstance(r.get(k),(int,float)) and math.isfinite(r[k]),'Actual preparation timing receipt missing')
        require(r['preparedReservedUptime']<=r['preparedReadyUptime']<=r['inputLimitObservedUptime']<=r['handoverUptime'],'Cold readiness reached after old bound or timestamp ordering invalid')
    maps={r['id']:r['finals'] for r in rows};cues=actual['finalCues'];require(cues,'Actual final captions missing')
    ids=[c['id'] for c in cues];require(len(ids)==len(set(ids)),'Cue identity duplicated across pairs')
    for c in cues:
        r=maps.get(c['processID'],{}).get((c['epoch'],c['streamGeneration'],c['engineSegment'],c['revision']));require(r is not None,'Cue has no current pair/final revision source')
        require((c['text'],Fraction(c['startNumerator'],c['startDenominator']),Fraction(c['endNumerator'],c['endDenominator']))==r,'Caption clock/text changed or padding included')
    text=report.with_suffix('.srt').read_text();blocks=text.strip().split('\n\n');require(len(blocks)==len(cues),'SRT lost old pair captions')
    for i,(block,c) in enumerate(zip(blocks,cues),1):
        lines=block.splitlines();require(len(lines)>=3 and lines[0]==str(i) and '\n'.join(lines[2:])==c['text'],'SRT sequence/text differs')
        clocks=lines[1].split(' --> ');require(len(clocks)==2,'SRT bounds missing')
        for clock,name in zip(clocks,('start','end')):
            m=re.fullmatch(r'(\d+):(\d\d):(\d\d),(\d{3})',clock);require(m is not None,'SRT clock invalid')
            h,mn,s,ms=map(int,m.groups());require(mn<60 and s<60,'SRT clock bounds invalid')
            require(abs((h*3600+mn*60+s)*1000+ms-float(Fraction(c[name+'Numerator'],c[name+'Denominator']))*1000)<=1.01,'SRT rational source coordinate differs')
    return [{'processID':r['id'],'start':[r['start'].numerator,r['start'].denominator],'end':[r['end'].numerator,r['end'].denominator],'acceptedSamples':r['accepted'],'parsedSamples':r['parsed'],'inputBound':r['limited'],'unpacedContinuation':r['unpaced']} for r in rows]

def run(helper,exe,case,fixture,out,storage,tmp,daily,bundle):
    ident,mode,source,pairs=case;report=out/(ident+'.json');known={};identity=None;samples=[];proc=None;forced=False
    env={k:v for k,v in os.environ.items() if not k.startswith('SILICONPLAYER_VERIFY_')}
    env.update(SILICONPLAYER_VERIFY_MODE=mode,SILICONPLAYER_VERIFY_CONTINUOUS_CASE=source,SILICONPLAYER_VERIFY_REPORT=str(report),SILICONPLAYER_VERIFY_STORAGE=str(storage),SILICONPLAYER_VERIFY_EXIT='1',TMPDIR=str(tmp)+'/')
    write(out/(ident+'-command.json'),{'argv':[str(exe),str(fixture)],'verificationEnvironment':{k:v for k,v in env.items() if k.startswith('SILICONPLAYER_VERIFY_') or k=='TMPDIR'},'HOMEInheritedUnchanged':env.get('HOME')==os.environ.get('HOME')})
    try:
        with (out/(ident+'.log')).open('x') as log:
            proc=subprocess.Popen([str(exe),str(fixture)],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True);deadline=time.monotonic()+(400 if pairs!=2 else 140);next_sample=0
            while proc.poll() is None:
                require(time.monotonic()<deadline,'Actual continuity App timed out')
                table=helper.process_table()
                if identity is None and proc.pid in table:identity=table[proc.pid]
                helper.collect_owned(table,proc.pid,identity,known)
                if time.monotonic()>=next_sample:
                    require(len(samples)<2048,'Actual process sampling overflow');samples.append({'uptime':time.clock_gettime(time.CLOCK_UPTIME_RAW),'owned':helper.survivors(table,known)});next_sample=time.monotonic()+.25
                time.sleep(.05)
        require(proc.returncode==0 and report.is_file(),'App must exit naturally0')
        remaining=helper.survivors(helper.process_table(),known);require(not remaining,'Owned child survived')
        value=json.loads(helper.bounded_regular_bytes(report,192*1048576));require(value.get('mode')==mode and value.get('succeeded') is True,'Actual App assertions failed')
        checks=value['asrChecks'];ids=[c['id'] for c in checks];require(len(ids)==len(set(ids)) and set(ids)==expected(mode,pairs) and all(c['passed'] is True for c in checks),'Exact actual check gates differ')
        embedded=[c for c in checks if c['id'].startswith('selected-embedded-audio-')]
        codec,rate=('aac',48000) if source=='aac7' else ('pcm_s16le',16000)
        for c in embedded:
            d=c['detail'];rows=d['actualNativeTracks'];selected=[r for r in rows if r.get('type')=='audio' and r.get('selected') is True]
            require(len(selected)==1 and selected[0].get('external') is not True and selected[0]['id']==d['requestedNativeID']==d['actualPublishedAid'] and d['actualAid']==str(d['requestedNativeID']),'Actual embedded native selection missing')
            require(d['external'] is False and d['currentDemuxer']=='lavf' and d['actualFFmpegIndex']==selected[0]['ff-index']==1 and d['codec']==selected[0]['codec']==codec and d['sampleRate']==selected[0]['demux-samplerate']==rate and d['channels']==selected[0]['demux-channel-count']==1,'Actual embedded stream metadata differs')
        controls=value['actualControlReceipts'];require(controls,'Real native controls not saved')
        for c in controls:
            r=c['receipt'];require(r['event']==c['event'] and r['serial']>c['minimumSerial'] and r['epoch']==c['epoch']==c['actualEpoch']==c['desiredEpoch'] and c['hostPaused']==c['paused'] and not c['hostSeeking'] and c['hostSeekGeneration']==c['hostSettledSeekGeneration'],'Real ACK/baseline/native settled gate differs')
        png=Path(value['screenshotPath']);require(png==report.with_suffix('.continuous-window.png'),'Wrong screenshot receipt path')
        raw=helper.bounded_regular_bytes(png,64*1048576);require(len(raw)>5000 and raw[:8]==b'\x89PNG\r\n\x1a\n' and raw[12:16]==b'IHDR','Real screenshot PNG absent')
        width,height=struct.unpack('>II',raw[16:24]);require(0<width<=16384 and 0<height<=16384,'Real PNG bounds invalid')
        tpath=report.with_suffix('.asr-termination.json');t=json.loads(helper.bounded_regular_bytes(tpath,64*1048576));close=t.get('after',{}).get('close',{})
        require(t.get('succeeded') is True and t.get('asrStopped') is True and t.get('ownedJobs') is False and t.get('overlayOwner')=='' and closed(close),'Actual termination strong pair receipt missing')
        warm_cancel=[]
        if mode=='live-asr-continuous-cancel':
            backend=t.get('backendActual');require(isinstance(backend,dict) and 'lastError' in backend and backend['lastError'] is None,'Actual cancel pair error diagnostic not clean')
            stages=value['stageReceipts'];require([x['action'] for x in stages]==['seek','reload','stop','quit'],'Bound action inventory differs')
            for s in stages:
                r=s['receipt'];require(r['maximumSamples']==1920000 and r['decodedSamples']+r['nextChunkSamplesNotPublished']>1920000 and s['controller']['processID']==r['processID'],'User action lacks validated actual bound ticket')
                if s['action']!='quit':require(closed(s['after'].get('close')) and s['backendAfter']['lastError'] is None,'User action has incomplete owned cleanup')
                warm=s['controller'].get('preparedProcessID');require(isinstance(warm,str) and warm,'Bound action did not retain an actual prepared pair')
                if s['action']=='quit':
                    raw_pairs=t.get('preparedPairRawJSONBase64');counts=t.get('preparedPairRawByteCounts')
                    require(isinstance(raw_pairs,dict) and isinstance(counts,dict) and set(raw_pairs)==set(counts) and len(raw_pairs)<=256 and all(type(n) is int and 0<n<=32*1048576 for n in counts.values()) and t.get('preparedPairRawBytes')==sum(counts.values())<=8*1048576,'Final warm wire inventory/bound absent')
                    require(warm in raw_pairs and 0<counts[warm]<=32*1048576,'Exact quit warm Data missing')
                    encoded=raw_pairs[warm];require(isinstance(encoded,str) and len(encoded)<=((counts[warm]+2)//3)*4,'Warm base64 bound invalid')
                    raw=base64.b64decode(encoded,validate=True);require(len(raw)==counts[warm],'Warm raw Data byte count differs')
                    prepared=json.loads(raw);after=t['after'];raw_sha=hashlib.sha256(raw).hexdigest()
                else:
                    prepared=value['preparedPairWire'].get(warm);after=s['after'];raw_sha=None
                receipts=[x for x in after.get('preparationReceipts',[]) if x.get('processID')==warm and x.get('resourcesReleased') is True]
                require(len(receipts)==1 and receipts[0].get('predecessor')==s['controller']['processID'],'Exact warm/predecessor cancellation mapping absent')
                item=audit_cancelled_preparation(warm,receipts[0],prepared,s['controller']['sourceProof']);item['action']=s['action']
                if raw_sha is not None:item['originalRawSHA256']=raw_sha
                warm_cancel.append(item)
            require(len(warm_cancel)==4 and len({x['processID'] for x in warm_cancel})==4,'Four distinct cancelled warm process wires required')
            chain=[]
        else:chain=audit_continuity(value,out,report)
        require(helper.daily_shortcut_key(bundle)==daily,'Daily shortcut changed')
        barrier=helper.termination_barrier(report,storage,mode)
        return {'id':ident,'mode':mode,'status':'passed','appPID':proc.pid,'appExit':0,'forcedCleanup':False,'ownedSurvivors':remaining,'observationCount':len(checks),'reportSHA256':digest(report),'terminationSHA256':digest(tpath),'pngSHA256':digest(png),'PNG':[width,height],'terminationBarrier':barrier,'actualPairSourceChain':chain,'actualCancelledWarmPairs':warm_cancel,'qualityVerified':False,'wordEndAlignmentVerified':False,'realGUIAutomationVerified':False}
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
                try:os.kill(current['pid'],signal.SIGKILL)
                except ProcessLookupError:pass
        write(out/(ident+'-process.json'),{'pid':proc.pid if proc else None,'exit':proc.returncode if proc else None,'knownOwned':list(known.values()),'samples':samples,'forcedCleanup':forced,'ownedSurvivors':helper.survivors(helper.process_table(),known)})

def main():
    a=argparse.ArgumentParser();a.add_argument('--app',type=Path,required=True);a.add_argument('--expected-app-sha256',required=True);a.add_argument('--expected-runtime-sha256',required=True);a.add_argument('--fixture-receipt',type=Path,required=True);a.add_argument('--report-directory',type=Path,required=True);a.add_argument('--project-root',type=Path,required=True);a.add_argument('--case',choices=[c[0] for c in CASES],action='append');args=a.parse_args()
    global ROOT;ROOT=args.project_root.resolve(strict=True)
    app=args.app.resolve(strict=True);exe=app/'Contents/MacOS/SiliconPlayer';runtime=app/'Contents/Resources/LiveASR/runtime-manifest.json';out=args.report_directory.resolve()
    require(app.suffix=='.app' and digest(exe)==args.expected_app_sha256 and digest(runtime)==args.expected_runtime_sha256,'Exact compiled/signed App/runtime required');require(not out.exists(),'Fresh report directory required');out.mkdir(parents=True)
    spec=importlib.util.spec_from_file_location('owned_app_helpers',ROOT/'scripts/verify_native_audio_queue.py');helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
    provenance=json.loads((app/'Contents/Resources/build-provenance.json').read_text());inputs=provenance['inputFiles'];require(provenance['inputFilesUnchanged'] is True and 'Sources/SiliconPlayer/ContinuousLocalASRVerifier.swift' in inputs,'Actual compiled continuity verifier required');require(all(digest(ROOT/n)==h for n,h in inputs.items()),'Build inputs drift')
    receipt=json.loads(helper.bounded_regular_bytes(args.fixture_receipt,1048576));require(receipt['sourceInputsBeforeEndSame'] is True and receipt['ASRExecuted'] is False and receipt['AppExecuted'] is False,'Root original fixture generation receipt required')
    fixtures={}
    for source,(name,expected_sha,seconds) in FIXTURES.items():
        row=next(x for x in receipt['fixtures'] if x['name']==name);path=Path(row['path']).resolve(strict=True);require(row['sha256']==expected_sha and row['exactSourceDuration']==seconds and digest(path)==expected_sha,'Root fixed recording composition fixture mismatch');fixtures[source]=path
    before=inventory(app);bundle=plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleIdentifier'];daily=helper.daily_shortcut_key(bundle)
    start={'app':str(app),'appSHA256':args.expected_app_sha256,'runtimeSHA256':args.expected_runtime_sha256,'buildInputs':inputs,'bundle':before,'fixtures':{str(p):digest(p) for p in fixtures.values()},'fixtureReceiptSHA256':digest(args.fixture_receipt),'driverSHA256':digest(Path(__file__)),'dailyShortcut':daily};write(out/'inputs-before.json',start)
    cases=[c for c in CASES if not args.case or c[0] in args.case];summary={'status':'running','expectedGroups':[c[0] for c in cases],'results':[],'scope':'Actual source continuity/lifecycle, repeated human fixtures, not held-out ASR quality/word alignment'}
    try:
        with tempfile.TemporaryDirectory(prefix='siliconplayer-continuous-asr-',dir='/private/tmp') as raw:
            work=Path(raw).resolve()
            for case in cases:
                storage=work/case[0];storage.mkdir();tmp=storage/'tmp';tmp.mkdir();summary['results'].append(run(helper,exe,case,fixtures[case[2]],out,storage,tmp,daily,bundle));write(out/'summary.json',summary)
        require(inventory(app)==before and all(digest(ROOT/n)==h for n,h in inputs.items()) and all(digest(Path(p))==h for p,h in start['fixtures'].items()) and digest(runtime)==args.expected_runtime_sha256,'Actual immutable inputs drift');require(helper.daily_shortcut_key(bundle)==daily,'Daily shortcut drift');summary.update(status='passed',passed=len(cases),failed=0,inputsUnchanged=True,bundleUnchanged=True)
    except BaseException as e:summary.update(status='failed',passed=len(summary['results']),error=str(e));raise
    finally:
        write(out/'inputs-end.json',{'bundle':inventory(app),'buildInputs':{n:digest(ROOT/n) for n in inputs},'fixtures':{p:digest(Path(p)) for p in start['fixtures']},'dailyShortcut':helper.daily_shortcut_key(bundle),'runtimeSHA256':digest(runtime)});write(out/'summary.json',summary)
if __name__=='__main__':main()
