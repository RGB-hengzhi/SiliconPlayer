#!/usr/bin/env python3
"""Direct signed packaged PCM validation: unchanged13 + six new contracts."""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import selectors
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import wave

LEGACY_SHA='3b9231f46f245d121db2c4b22085f0b1fbe6005afd2ee9410aa2b06ee381c0ec'
SUPERVISOR_SHA='f84d9f94e2a759342294441b16b62e2b65d7834eab31d764de44ad54e6d82406'
INPUT_SHA='24aeb113af71d05f374d8e4dabae0e3006190c20e4d4ee805ed45ae455fa2fd7'
C_SHA='b5c433c24d2ef4605b71ecd0f394f2fb6f22eda3fc8b0b3ed263e4ca76a79d43'
CAP_IDS=('one-second-whole-chunk','exact-one-second-eof','invalid-limits','resampler-drain-limit','source-mutation','cancel-backpressure')
HOLD_IDS=('short-one-sample-hold','short-one-block-seek','hold-cancel','hold-explicit-limit','hold-control-negative','hold-invalid-flag')


def require(value,reason):
    if not value: raise RuntimeError(reason)


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for b in iter(lambda:stream.read(1024*1024),b''):h.update(b)
    return h.hexdigest()


def save(path,value):
    with path.open('x') as f:json.dump(value,f,indent=2,ensure_ascii=False,allow_nan=False);f.write('\n')


def load(path,pinned,name):
    require(sha(path)==pinned,'Frozen helper differs: '+str(path))
    sys.dont_write_bytecode=True
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def environment(work):
    result={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LANG':'en_US.UTF-8','LC_ALL':'en_US.UTF-8','TMPDIR':str(work)+'/'}
    for key in ('HOME','USER','LOGNAME'):
        if key in os.environ:result[key]=os.environ[key]
    return result


def new_wave(path,rate,samples):
    # Test-only real PCM/WAV media. No model inference or simulated decoder.
    with wave.open(str(path),'wb') as f:
        f.setnchannels(1);f.setsampwidth(2);f.setframerate(rate)
        f.writeframes(b''.join(struct.pack('<h',int(6000*math.sin(2*math.pi*440*i/rate))) for i in range(samples)))


def capture(identifier,argv,folder,env,supervisor,legacy,expected_code=0,mutation=None,handshake=None):
    folder.mkdir();events=[];line=b'';forced=False;failure=None;commands=[];began=time.monotonic()
    process=subprocess.Popen(argv,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,
                             start_new_session=True,close_fds=True,cwd=folder)
    selector=selectors.DefaultSelector()
    for pipe,kind in ((process.stdout,'pcm'),(process.stderr,'json')):
        os.set_blocking(pipe.fileno(),False);selector.register(pipe,selectors.EVENT_READ,kind)
    size={'pcm':0,'json':0};mutation_receipt=None
    hold_bytes=bytearray();hold_started=None;pause_started=None;hold_stage=0;pause_confirmed=False;handshake_observations=[];startup_pause_sent=False;startup_resume_sent=False;startup_opened_at=None;birth_observations=[];pause_receipts=[]
    def first_packet():
        require(112<=len(hold_bytes)<=1392,'Held startup IPC is not one bounded complete record')
        n=struct.unpack_from('<I',hold_bytes,8)[0]
        require(116<=n<=1392 and len(hold_bytes)==n,'Held startup IPC framing incomplete or extra output')
        rows=legacy.packets(bytes(hold_bytes));require(len(rows)==1 and rows[0]['epoch']==1,'Held first packet identity')
        return rows[0]
    def no_terminal():
        require(not any(r['event'] in ('media_eof','input_limit_reached','closed','error') for r in events),'Startup terminal event preceded actual host control')

    def send(value):
        process.stdin.write(value.encode('ascii'));process.stdin.flush();commands.append(value)
    with (folder/'stdout.spcm').open('xb') as pcm,(folder/'stderr.jsonl').open('xb') as stderr:
        try:
            while selector.get_map():
                require(time.monotonic()-began<30,'Capability process deadline')
                now=time.monotonic()
                if handshake and startup_opened_at is not None and not startup_pause_sent and now-startup_opened_at>=.15:
                    no_terminal()
                    require(size['pcm']==0 and not any(r['event'] in ('pcm','first_block_waiting','paused','resumed') for r in events),'Held birth progressed or emitted synthetic control ACK before actual PAUSE')
                    birth_observations.append({'phase':'before-first-actual-pause','elapsedSeconds':now-startup_opened_at,'actualPCMBytes':size['pcm'],'completeSPCMRecords':0})
                    send('PAUSE 1\n');startup_pause_sent=True
                if handshake and hold_started is not None and hold_stage==0 and now-hold_started>=.15:
                    no_terminal();first=first_packet()
                    require(len([r for r in events if r['event']=='pcm'])==1,'Extra PCM during first-block wait')
                    gate=next(r for r in events if r['event']=='first_block_waiting')
                    require(gate['epoch']==first['epoch']==1 and gate['sequence']==first['sequence'] and gate['samples']==first['samples']
                            and gate['header_bytes']==112 and gate['record_bytes']==len(hold_bytes),'First-block event is not actual complete SPCM')
                    handshake_observations.append({'phase':'awaiting-native-pause','elapsedSeconds':now-hold_started,'completeSPCMRecords':1,'sequence':first['sequence'],'epoch':first['epoch']})
                    if handshake=='premature-resume':send('RESUME 1\n')
                    elif handshake=='premature-seek':send('SEEK 1 2 0\n')
                    elif handshake=='premature-track':send('TRACK 1 2 0\n')
                    elif handshake=='cancel-before-pause':send('CANCEL 1\n');hold_stage=3
                    elif handshake=='signal-before-pause':
                        require(process.poll() is None and os.getpgid(process.pid)==process.pid,'Held own leader/group unavailable before signal')
                        os.killpg(process.pid,signal.SIGTERM);commands.append('SIGTERM_EXACT_UNREAPED_OWN_GROUP');hold_stage=3
                    elif handshake=='control-eof':process.stdin.close();commands.append('CLOSE_OWN_STDIN')
                    elif handshake=='no-control':commands.append('NO_CONTROL_SENT')
                    else:send('PAUSE 1\n')
                    if hold_stage!=3:hold_stage=1
                if handshake and pause_confirmed and pause_started is not None and hold_stage==1 and now-pause_started>=.15:
                    no_terminal();first_packet()
                    require(len([r for r in events if r['event']=='pcm'])==1,'PCM progressed while real paused ACK active')
                    handshake_observations.append({'phase':'actual-paused','elapsedSeconds':now-pause_started,'completeSPCMRecords':1,'epoch':1})
                    if handshake=='cancel':send('CANCEL 1\n');hold_stage=3
                    elif handshake=='signal':
                        require(process.poll() is None and os.getpgid(process.pid)==process.pid,'Held own leader/group unavailable before signal')
                        os.killpg(process.pid,signal.SIGTERM);commands.append('SIGTERM_EXACT_UNREAPED_OWN_GROUP');hold_stage=3
                    elif handshake=='seek':send('SEEK 1 2 0\n');hold_stage=2
                    else:send('RESUME 1\n');hold_stage=3

                for key,_ in selector.select(.02):
                    b=os.read(key.fileobj.fileno(),65536)
                    if not b:selector.unregister(key.fileobj);key.fileobj.close();continue
                    kind=key.data;size[kind]+=len(b);require(size[kind]<=16*1024*1024,'Capability output bound')
                    (pcm if kind=='pcm' else stderr).write(b)
                    if handshake and kind=='pcm' and hold_stage<3:
                        hold_bytes.extend(b);require(len(hold_bytes)<=1392,'Startup hold emitted more than one record')
                    if kind!='json':continue
                    line+=b
                    while b'\n' in line:
                        raw,line=line.split(b'\n',1);row=legacy.parse(raw);events.append(row)
                        if handshake and row['event']=='media_opened' and startup_opened_at is None:
                            startup_opened_at=time.monotonic()
                        if handshake and row['event']=='paused':
                            native_serial=sum(r['event'] in ('paused','resumed','speed_changed','epoch_changed','cancel_acknowledged') for r in events)
                            pause_receipts.append({'observedControlReceiptSerial':native_serial,'stderrEventOrdinal':len(events),'event':row['event'],'epoch':row['epoch']})
                        if handshake and row['event']=='paused' and hold_started is None and startup_pause_sent and not startup_resume_sent:
                            require(row['epoch']==1,'Held birth actual pause epoch')
                            send('RESUME 1\n');startup_resume_sent=True
                        if handshake and row['event']=='first_block_waiting':
                            require(startup_resume_sent and any(r['event']=='resumed' and r['epoch']==1 for r in events),'First block preceded held-birth actual controls')
                            require(hold_started is None,'Duplicate first-block hold')
                            hold_started=time.monotonic()
                        if handshake and row['event']=='first_block_pause_confirmed':
                            require(hold_stage==1 and row['epoch']==1 and len(pause_receipts)==2 and pause_receipts[0]['epoch']==pause_receipts[1]['epoch']==1
                                    and pause_receipts[1]['observedControlReceiptSerial']>pause_receipts[0]['observedControlReceiptSerial']
                                    and len(events)>=2 and events[-2]['event']=='paused','Hold confirmation missing distinct second actual same-epoch paused ACK')
                            pause_confirmed=True;pause_started=time.monotonic()
                        if handshake=='seek' and hold_stage==2 and row['event']=='epoch_changed':
                            require(row['epoch']==2,'Actual new seek ACK epoch mismatch')
                            send('SPEED 2 1\n');send('RESUME 2\n');hold_stage=3
                        if mutation and row['event']=='pcm' and not commands:send('PAUSE 1\n')
                        if mutation and row['event']=='paused' and mutation_receipt is None:
                            original=sha(mutation);before=mutation.stat()
                            with mutation.open('ab') as f:f.write(b'\0');f.flush();os.fsync(f.fileno())
                            mutation_receipt={'path':str(mutation),'beforeSHA256':original,'afterSHA256':sha(mutation),
                                              'beforeBytes':before.st_size,'afterBytes':mutation.stat().st_size}
                            send('CANCEL 1\n')
                require(len(line)<=65536,'Capability JSON line bound')
            require(not line,'Truncated capability JSON')
            code=process.wait(timeout=3)
        except BaseException as error:
            failure=str(error);forced=True;supervisor.terminate_timed_out_group(process,env);code=process.returncode
        finally:
            selector.close()
            for pipe in (process.stdin,process.stdout,process.stderr):
                if not pipe.closed:pipe.close()
            pcm.flush();stderr.flush();os.fsync(pcm.fileno());os.fsync(stderr.fileno())
    survivors=supervisor.owned_group_snapshot(process.pid,env)
    receipt={'id':identifier,'argv':argv,'pid':process.pid,'pgid':process.pid,'exitCode':code,
             'forcedCleanup':forced,'remainingOwnedProcesses':survivors,'failure':failure,
             'commands':commands,'mutation':mutation_receipt,'elapsedSeconds':time.monotonic()-began}
    if handshake is not None:receipt.update(handshakeMode=handshake,handshakeObservations=handshake_observations,actualFirstBlockPauseConfirmed=pause_confirmed,actualHeldBirthPauseAndResume=startup_pause_sent and startup_resume_sent,heldBirthObservations=birth_observations,actualPauseReceipts=pause_receipts)
    save(folder/'process.json',receipt)
    require(code==expected_code and not forced and not survivors and failure is None,'Capability natural exit contract')
    if handshake is not None:
        require(startup_pause_sent and startup_resume_sent and len(birth_observations)==1,'Held birth lacks actual initial PAUSE/RESUME and zero-output window')
        eof_indices=[i for i,r in enumerate(events) if r['event']=='media_eof']
        if eof_indices:
            resume_indices=[i for i,r in enumerate(events) if r['event']=='resumed']
            require(pause_confirmed and len(resume_indices)>=2 and min(eof_indices)>max(resume_indices),'Actual media EOF preceded last actual RESUME')
    data=(folder/'stdout.spcm').read_bytes();records=legacy.packets(data)
    metadata=[r for r in events if r['event']=='pcm']
    require(len(metadata)==len(records),'Capability PCM telemetry mismatch')
    for p,r in zip(records,metadata):
        require(p['sequence']==r['sequence'] and p['epoch']==r['epoch'] and p['samples']==r['samples'] and p['pts']==r['pcm_pts']
                and p['source']==r['source_pts'] and p['stream']==r['stream_index'],'Capability actual IPC differs')
        if p['flags']&1 and not p['flags']&4:
            scaled=legacy.near_away(p['source']*p['timeBase'][0]*p['denominator'],p['timeBase'][1])
            require(p['pts']==scaled-p['delay']+p['offset']*p['inputRate'],'Capability PTS/delay/offset changed')
    save(folder/'decoded-packet-evidence.json',{'records':records,'rawSHA256':sha(folder/'stdout.spcm'),'traceSHA256':sha(folder/'stderr.jsonl'),'AppGroups':0})
    return receipt,events,records


def check_closed(events,success):
    require(events and events[-1]['event']=='closed' and events[-1]['ok'] is success and events[-1]['remaining_owned_contexts']==0,'Capability resource close')


def bounded(events,records):
    check_closed(events,True)
    limit=[r for r in events if r['event']=='input_limit_reached']
    require(len(limit)==1 and not any(r['event'] in ('media_eof','error') for r in events),'Limit was confused with EOF/error')
    n=sum(r['samples'] for r in records)
    require(0<n<=16000 and 0<=16000-n<320,'Whole-chunk limit sample budget')
    require(limit[0]['max_samples']==16000 and limit[0]['output_samples']==n
            and 1<=limit[0]['next_chunk_samples_not_published']<=320
            and n+limit[0]['next_chunk_samples_not_published']>16000,'Skipped next chunk not proven')
    require(events[-1]['output_samples']==n and events[-1]['cancelled'] is False,'Limit output or cancel scope differs')
    return limit[0]


# Exact-source-range cases are appended to, never substituted for, the existing25.
RANGE_IDS=('aac-fresh-origin-exact-range','pcm-exact-range-controls')
RANGE_AAC_SHA='656fce09b6c9d8d4e54fe35ca4f08f0f8ade5e2d994297ead57b859b77ffadc2'


def range_payload(raw,records):
    cursor=0;chunks=[]
    for r in records:
        total=112+4*r['samples'];data=raw[cursor+112:cursor+total]
        require(len(data)==4*r['samples'] and hashlib.sha256(data).hexdigest()==r['pcmSHA256'],'Exact-range whole actual Float32 payload')
        chunks.append(data);cursor+=total
    require(cursor==len(raw),'Exact-range trailing/truncated SPCM')
    return b''.join(chunks)


def range_capture(identifier,path,stream,target,folder,args,env,supervisor,legacy,action='eof',invalid=None):
    from fractions import Fraction
    folder.mkdir();raw=bytearray();trace=bytearray();pending=bytearray();events=[];commands=[];cleanup=None;failure=None;code=None;group=None;reaped=False;stage=0;began=time.monotonic()
    argv=[str(args.pcm_binary),'--input',str(path),'--audio-stream',str(stream),'--epoch','1','--item','1','--max-seconds','180','--first-block-hold']
    process=subprocess.Popen(argv,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,start_new_session=True,close_fds=True,cwd=folder)
    for pipe in (process.stdin,process.stdout,process.stderr):os.set_blocking(pipe.fileno(),False)
    selector=selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ,'pcm');selector.register(process.stderr,selectors.EVENT_READ,'json')
    def send(value):
        data=value.encode('ascii');cursor=0;until=time.monotonic()+1
        while cursor<len(data):
            require(time.monotonic()<until,'Exact-range control write deadline')
            try:cursor+=os.write(process.stdin.fileno(),data[cursor:])
            except BlockingIOError:time.sleep(.001)
        commands.append({'command':value.strip(),'hostObservedMonotonic':time.monotonic(),'stdoutBytesBeforeCommand':len(raw)})
    try:
        while selector.get_map():
            require(time.monotonic()-began<30,'Exact-range actual helper deadline')
            if stage==0 and any(r['event']=='media_opened' for r in events):
                require(not raw,'Held birth published before actual PAUSE');send('PAUSE 1\n');stage=1
            if stage==1 and any(r['event']=='paused' and r['epoch']==1 for r in events):
                require(not raw,'Held birth published before RANGE')
                send(invalid if invalid is not None else 'RANGE 1 2 '+str(target.numerator)+' '+str(target.denominator)+'\n');stage=2
            if invalid is None and stage==2 and any(r['event']=='epoch_changed' and r['epoch']==2 for r in events):
                require(not raw and not any(r['event']=='range_first_sample' for r in events),'Control ACK was used as actual first sample')
                reopened=[r for r in events if r['event']=='range_origin_reopened']
                require(len(reopened)==1 and reopened[0]['epoch']==2 and reopened[0]['item']==1 and reopened[0]['selected_stream_index']==stream
                        and reopened[0]['target_num']==target.numerator and reopened[0]['target_den']==target.denominator
                        and reopened[0]['source_fingerprint_preserved'] is True,'Actual RANGE held-FD reopen ACK')
                send('SPEED 2 1\n');send('RESUME 2\n');stage=3
            if invalid is None and stage==3 and any(r['event']=='first_block_waiting' for r in events) and len(raw)>=112 and len(raw)==struct.unpack_from('<I',raw,8)[0]:
                require(112<=len(raw)<=1392,'First range block was not one actual record');records=legacy.packets(bytes(raw))
                require(len(records)==1 and records[0]['epoch']==2,'First range block ticket');send('PAUSE 2\n');stage=4
            if invalid is None and stage==4 and any(r['event']=='first_block_pause_confirmed' for r in events):
                require(any(r['event']=='paused' and r['epoch']==2 for r in events),'Second actual PAUSE ACK absent')
                if action=='cancel':send('RESUME 1\n');send('CANCEL 2\n')
                else:send('RESUME 2\n')
                stage=5
            for key,_ in selector.select(.002):
                try:data=os.read(key.fileobj.fileno(),65536)
                except BlockingIOError:continue
                if not data:selector.unregister(key.fileobj);continue
                if key.data=='pcm':raw.extend(data);require(len(raw)<=24*1024*1024,'Exact-range IPC byte bound')
                else:
                    trace.extend(data);pending.extend(data);require(len(trace)<=32*1024*1024,'Exact-range event byte bound')
                    while b'\n' in pending:
                        line,_,rest=pending.partition(b'\n');pending[:]=rest;require(len(line)<=16384,'Exact-range actual line bound');events.append(legacy.parse(line))
                    require(len(pending)<=16384,'Exact-range partial line bound')
        require(not pending,'Exact-range event framing incomplete')
        until=time.monotonic()+2
        while time.monotonic()<until:
            group=supervisor.owned_group_snapshot(process.pid,env)
            if group and any(r['pid']==process.pid and r['pgid']==process.pid for r in group) and all(r['state'].startswith('Z') for r in group):break
            time.sleep(.002)
        require(group and any(r['pid']==process.pid and r['pgid']==process.pid for r in group) and all(r['state'].startswith('Z') for r in group),'Exact unreaped owned leader/group complete-zombie proof')
        code=process.wait(timeout=1);reaped=True
        require(supervisor.owned_group_snapshot(process.pid,env)==[],'Exact-range owned group remains after exact child reap')
        require(code==(1 if invalid is not None else 0),'Exact-range natural helper exit differs')
        check_closed(events,invalid is None)
        if invalid is not None:
            require(not raw and not any(r['event'] in ('pcm','range_origin_reopened','range_first_sample','media_eof','input_limit_reached') for r in events),'Invalid RANGE allocated/publicized successful range PCM')
        else:
            require(stage==5,'Incomplete actual RANGE/first-block control sequence')
            require(not any(r['event'] in ('error','input_limit_reached') for r in events),'Range capture confused with error/bound')
            require(events[-1]['cancelled'] is (action=='cancel'),'Range close cancel scope')
            if action=='cancel':
                require(any(r['event']=='cancel_acknowledged' and r['epoch']==2 for r in events) and any(r['event']=='control_rejected' for r in events)
                        and not any(r['event']=='media_eof' for r in events),'Stale-control rejection and real same-epoch cancel')
            else:require(sum(r['event']=='media_eof' for r in events)==1,'Range natural media EOF absent')
        records=legacy.packets(bytes(raw));metadata=[r for r in events if r['event']=='pcm']
        require(len(records)==len(metadata),'Actual SPCM/C event count differs')
        for p,r in zip(records,metadata):
            require(p['epoch']==2 and p['item']==1 and p['stream']==stream and p['flags']&1,'Actual range source identity/known PTS')
            require(all(p[a]==r[b] for a,b in [('sequence','sequence'),('epoch','epoch'),('segment','segment'),('item','item'),('stream','stream_index'),('source','source_pts'),('pts','pcm_pts'),('denominator','time_denominator'),('samples','samples'),('delay','delay_units_before_convert'),('ordinal','decoded_frame')]),'Actual RANGE PCM telemetry mismatch')
            if not p['flags']&4:
                require(p['pts']==legacy.near_away(p['source']*p['timeBase'][0]*p['denominator'],p['timeBase'][1])-p['delay']+p['offset']*p['inputRate'],'Range changed original source PTS/delay/offset equation')
        for a,b in zip(records,records[1:]):
            require(Fraction(a['pts'],a['denominator'])+Fraction(a['samples'],16000)==Fraction(b['pts'],b['denominator']),'Actual range SPCM sample gap/overlap')
        if invalid is None:
            first=[r for r in events if r['event']=='range_first_sample'];reopened=next(r for r in events if r['event']=='range_origin_reopened')
            require(len(first)==1 and first[0]['exact'] is True and records and Fraction(records[0]['pts'],records[0]['denominator'])==target,'No exact actual first range sample')
            f=first[0];p=records[0]
            require(f['epoch']==p['epoch']==reopened['epoch'] and f['segment']==p['segment']==reopened['segment'] and f['item']==p['item']==reopened['item']
                    and f['stream_index']==p['stream'] and f['target_num']==target.numerator and f['target_den']==target.denominator
                    and f['pcm_pts']==p['pts'] and f['time_denominator']==p['denominator'] and f['source_pts']==p['source']
                    and f['delay_units_before_convert']==p['delay'] and f['converted_frame_offset']==p['offset'],'RANGE first-sample event not actual raw header')
            require(events[-1]['output_samples']==sum(r['samples'] for r in records),'Range closed actual published sample total')
            fingerprints=[r for r in events if r['event']=='source_fd_fingerprint']
            fields=('device','inode','bytes','mtime_seconds','mtime_nanoseconds')
            require(len(fingerprints)==2 and all(fingerprints[0][k]==fingerprints[1][k] for k in fields),'RANGE did not preserve initial held source FD fingerprint')
        receipt={'id':identifier,'argv':argv,'PID':process.pid,'PGID':process.pid,'exitCode':code,'naturalReaped':True,'forcedCleanup':False,'remainingOwnedProcesses':[],'beforeReapCompleteOwnedGroup':group,'commands':commands,'samples':sum(r['samples'] for r in records),'recordCount':len(records),'firstPTS':None if not records else [records[0]['pts'],records[0]['denominator']],'transportFullyFramed':True}
        return receipt,records,events,range_payload(bytes(raw),records)
    except BaseException as error:
        failure=str(error)
        if not reaped:cleanup=supervisor.terminate_timed_out_group(process,env)
        raise
    finally:
        selector.close()
        for pipe in (process.stdin,process.stdout,process.stderr):pipe.close()
        with (folder/'stdout.spcm').open('xb') as handle:handle.write(raw);handle.flush();os.fsync(handle.fileno())
        with (folder/'stderr.jsonl').open('xb') as handle:handle.write(trace);handle.flush();os.fsync(handle.fileno())
        save(folder/'process.json',{'id':identifier,'argv':argv,'PID':process.pid,'exitCode':process.returncode,'naturalReaped':reaped,'failure':failure,'cleanup':cleanup,'commands':commands,'elapsedSeconds':time.monotonic()-began,'stdoutSHA256':hashlib.sha256(raw).hexdigest(),'stderrSHA256':hashlib.sha256(trace).hexdigest()})


def execute_exact_ranges(args,output,env,supervisor,legacy,work):
    from fractions import Fraction
    aac=args.fixture_root/'LiveASR/continuous-recorded2/recorded-repeat7-aac48k.mov'
    require(aac.is_file() and not aac.is_symlink() and sha(aac)==RANGE_AAC_SHA,'Fixed real AAC fixture identity differs')
    source=args.project_root/'Sources/MediaPCMPTS/main.c';require(sha(source)==C_SHA,'Range test source proof differs from packaged helper')
    wav=work/'range-exact-1608.wav';new_wave(wav,16000,1608)
    before={str(p):sha(p) for p in (aac,source,args.pcm_binary,Path(__file__),wav)};save(output/'range-inputs-before.json',before)
    results=[];folder=output/RANGE_IDS[0];folder.mkdir()
    try:
        reference,rr,re,full=range_capture('fresh-origin-full',aac,1,Fraction(0),folder/'reference',args,env,supervisor,legacy)
        suffix,sr,se,tail=range_capture('fresh-origin-suffix',aac,1,Fraction(119999,1000),folder/'suffix',args,env,supervisor,legacy)
        cut=119999*16
        require(len(full)>cut*4 and len(tail)==len(full)-cut*4 and tail==full[cut*4:],'AAC range suffix differs from full actual fresh-origin Float32 sequence')
        require(Fraction(rr[-1]['pts'],rr[-1]['denominator'])+Fraction(rr[-1]['samples'],16000)==Fraction(sr[-1]['pts'],sr[-1]['denominator'])+Fraction(sr[-1]['samples'],16000),'AAC suffix actual terminal PTS differs')
        results.append({'id':RANGE_IDS[0],'passed':True,'reference':reference,'suffix':suffix,'target':[119999,1000],'fullSamples':len(full)//4,'referencePrefixSamplesSkipped':cut,'suffixSamples':len(tail)//4,'fullPCM_SHA256':hashlib.sha256(full).hexdigest(),'suffixPCM_SHA256':hashlib.sha256(tail).hexdigest(),'fullSuffixPCM_SHA256':hashlib.sha256(full[cut*4:]).hexdigest(),'actualFloat32FullSuffixEqual':True})
        folder=output/RANGE_IDS[1];folder.mkdir()
        reference,rr,re,full=range_capture('pcm-origin',wav,0,Fraction(0),folder/'reference',args,env,supervisor,legacy)
        suffix,sr,se,tail=range_capture('pcm-one-sample-suffix',wav,0,Fraction(1,16000),folder/'suffix',args,env,supervisor,legacy)
        require(reference['samples']==1608 and suffix['samples']==1607 and tail==full[4:],'PCM exact rational one-sample crop/payload')
        cancel,cr,ce,cp=range_capture('pcm-range-actual-cancel',wav,0,Fraction(1,16000),folder/'cancel',args,env,supervisor,legacy,action='cancel')
        require(len(cr)==1 and cr[0]['pts']==1*cr[0]['inputRate'] and cp==tail[:len(cp)],'Actual range paused cancel changed first-source PCM')
        negative=[]
        for i,(cmd,category) in enumerate([('RANGE 1 1 0 1\n','new_epoch_required'),('RANGE 1 2 -9223372036854775808 1\n','range_target_invalid'),('RANGE 1 2 0 0\n','range_target_invalid'),('RANGE 1 2 0 1000000001\n','range_target_invalid'),('RANGE 1 2 86401 1\n','range_target_bound'),('RANGE 1 2 -86401 1\n','range_target_bound'),('RANGE 1 2 0 1 extra\n','control_token_bound')]):
            receipt,nr,ne,np=range_capture('invalid-range-'+str(i),wav,0,Fraction(0),folder/('invalid-'+str(i)),args,env,supervisor,legacy,invalid=cmd)
            require(not nr and not np and any(r['event']=='error' and r['category']==category for r in ne),'Invalid RANGE exact failure category changed');negative.append(receipt)
        results.append({'id':RANGE_IDS[1],'passed':True,'reference':reference,'suffix':suffix,'cancel':cancel,'invalidControls':negative,'target':[1,16000],'actualFloat32SuffixEqual':True,'sourceSHA256':sha(wav)})
        require(tuple(r['id'] for r in results)==RANGE_IDS and len(results)==2 and all(r['passed'] is True for r in results),'Exact two range case identities')
        return results
    finally:
        after={p:sha(Path(p)) for p in before};save(output/'range-inputs-end.json',after)
        save(output/'range-evidence.json',{'rangeCases':results,'complete':len(results)==2,'inputsBefore':before,'inputsAfter':after,'inputsUnchanged':before==after,'AppGroups':0,'inferenceExecuted':False,'GPUExecuted':False,'scope':'Two additional signed-helper CPU contracts; internal processes/assertions are not extra App/release groups.'})
        require(before==after,'Exact range inputs changed')


def execute(args):
    root=args.project_root;output=args.report_directory
    require(root.is_absolute() and args.pcm_binary.is_absolute() and args.fixture_root.is_absolute(),'Absolute inputs required')
    require(not output.exists() and output.is_absolute(),'Fresh report required');output.mkdir(parents=True)
    legacy_path=args.legacy_driver or root/'scripts/live_asr_verification/pcm_contract_checks.py'
    supervisor_path=args.supervisor or root/'scripts/live_asr_verification/owned_process_supervisor.py'
    input_path=args.input_pins or root/'scripts/live_asr_verification/input-pins.json'
    legacy=load(legacy_path,LEGACY_SHA,'old_pcm_assertions');supervisor=load(supervisor_path,SUPERVISOR_SHA,'old_owned_supervisor')
    require(sha(input_path)==INPUT_SHA,'Original13 fixture manifest changed');pins=legacy.parse(input_path.read_bytes())
    require(sha(args.pcm_binary)==args.expected_pcm_sha256,'Signed PCM binary differs')
    runtime_url=args.pcm_binary.parents[1]/'runtime-manifest.json';runtime=legacy.parse(runtime_url.read_bytes())
    require(runtime['schema']==1 and runtime['pcmHelperSourceSHA256']==C_SHA,'Packaged source identity differs')
    contents=args.pcm_binary.parents[3]
    require(args.pcm_binary==contents/'Resources/LiveASR/Helpers/media-pcm-pts','Expected fixed package layout')
    before={str(p):sha(p) for p in (Path(__file__),legacy_path,supervisor_path,input_path,runtime_url)}
    require(len(runtime['files'])==26 and len({r['path'] for r in runtime['files']})==26,'Full26 runtime rows')
    for row in runtime['files']:
        path=contents/row['path'];require(not path.is_symlink() and path.stat().st_size==row['bytes'] and sha(path)==row['sha256'],'Actual runtime closure differs')
        before[str(path)]=row['sha256']
    fixture={}
    for row in pins['fixtureReferencesFromFrozenSnapshot']:
        relative=Path(row['path']).relative_to('Tests/Fixtures');path=args.fixture_root/relative
        require(not path.is_symlink() and path.stat().st_size==row['bytes'] and sha(path)==row['sha256'],'Original fixture differs')
        fixture[path.name]=path;before[str(path)]=row['sha256']
    work=Path(tempfile.mkdtemp(prefix='siliconplayer-packaged-pcm-'));env=environment(work)
    save(output/'environment.json',env);save(output/'inputs-before.json',before);save(output/'work.json',{'path':str(work),'purpose':'Owned generated WAV/mutation copies only'})
    outcomes=[];caps=[];holds=[];summary={'schema':1,'status':'running','AppGroups':0,'inferenceExecuted':False,'GPUExecuted':False}
    try:
        code=supervisor.run_owned(['/usr/bin/codesign','--verify','--strict',str(args.pcm_binary)],output,'signed-pcm',30,env);supervisor.require_natural_zero(code,'Signed PCM verification')
        multi=fixture['多音轨双字幕.mkv'];speech=fixture['UI 手工 07 中文语音.wav'];wav=fixture['wav.wav']
        # Exact old argv construction, exact old run_case assertions; no max flag.
        for name in legacy.CASES:
            if name=='time-domain':command=[str(args.pcm_binary),'--time-domain-selftest']
            else:
                path=speech if name=='speech-wav' else wav if name=='resample-wav' else multi
                stream=0 if name in ('speech-wav','resample-wav','reject-video') else 2 if name=='track-eng' else 1
                command=[str(args.pcm_binary),'--input',str(path),'--audio-stream',str(stream),'--epoch','1','--item','1']
                if name not in legacy.BASELINE and name not in ('reject-video','seek-backpressure','cancel-backpressure'):command.append('--paced')
                if name=='queue-switch':command+=['--next-input',str(speech),'--next-audio-stream','0','--next-item','2']
            outcomes.append(legacy.run_case(name,command,output/('default-'+name),env,supervisor))
        zho=legacy.parse((output/'default-track-zho/decoded-packet-evidence.json').read_bytes())['records']
        eng=legacy.parse((output/'default-track-eng/decoded-packet-evidence.json').read_bytes())['records']
        require([r['pcmSHA256'] for r in zho]!=[r['pcmSHA256'] for r in eng],'Different selected track PCM identical')
        ffprobe=args.ffprobe or contents/'Resources/Tools/ffprobe'
        require(str(ffprobe) in before,'Reference ffprobe is not pinned runtime tool')
        for name,path,stream in (('track-zho',multi,1),('track-eng',multi,2),('speech-wav',speech,0),('resample-wav',wav,0)):
            result=supervisor.run_owned([str(ffprobe),'-v','error','-select_streams',str(stream),'-show_frames','-show_entries','frame=stream_index,best_effort_timestamp,pts,nb_samples','-of','json',str(path)],output,'reference-'+name,30,env)
            supervisor.require_natural_zero(result,'Actual original frame reference')
            ref=legacy.parse((output/('reference-'+name+'.stdout.txt')).read_bytes())['frames']
            frames=[legacy.parse(line) for line in (output/('default-'+name)/'stderr.jsonl').read_bytes().splitlines() if legacy.parse(line)['event']=='decoded_frame']
            require(len(frames)==len(ref) and all(a['best_effort_timestamp']==int(b.get('best_effort_timestamp',legacy.NOPTS)) and a['input_samples']==int(b['nb_samples']) and a['stream_index']==b['stream_index'] for a,b in zip(frames,ref)),'Original actual source PTS/count/track gate')
        def argv(path,seconds):return [str(args.pcm_binary),'--input',str(path),'--audio-stream','0','--epoch','1','--item','1','--max-seconds',str(seconds)]
        receipt,events,records=capture(CAP_IDS[0],argv(speech,1),output/CAP_IDS[0],env,supervisor,legacy)
        bounded(events,records);caps.append({'id':CAP_IDS[0],'passed':True,'process':receipt})
        exact=work/'exact-one-second.wav';new_wave(exact,16000,16000)
        receipt,events,records=capture(CAP_IDS[1],argv(exact,1),output/CAP_IDS[1],env,supervisor,legacy)
        check_closed(events,True);require(sum(r['samples'] for r in records)==16000 and sum(r['input_samples'] for r in events if r['event']=='decoded_frame')==16000,'Exact one-second actual samples')
        require(sum(r['event']=='media_eof' for r in events)==1 and not any(r['event'] in ('input_limit_reached','error') for r in events),'Exact source EOF became limit');caps.append({'id':CAP_IDS[1],'passed':True,'process':receipt})
        bad=[];invalid=output/CAP_IDS[2];invalid.mkdir()
        for i,value in enumerate(('0','21601','-1','1.5','bad')):
            receipt,events,records=capture('invalid-'+str(i),argv(speech,value),invalid/str(i),env,supervisor,legacy,expected_code=2)
            require(not events and not records,'Invalid flag allocated/decoded source');bad.append(receipt)
        caps.append({'id':CAP_IDS[2],'passed':True,'processes':bad})
        resampled=work/'drain-limit-8008.wav';new_wave(resampled,8000,8008)
        receipt,events,records=capture(CAP_IDS[3],argv(resampled,1),output/CAP_IDS[3],env,supervisor,legacy)
        limit=bounded(events,records);frames=[r for r in events if r['event']=='decoded_frame']
        require(sum(r['input_samples'] for r in frames)==8008 and all(r['input_rate']==8000 for r in frames),'Drain input not fully decoded')
        last=frames[-1];last_records=[r for r in records if r['ordinal']==last['ordinal'] and not r['flags']&4]
        require(sum(r['samples'] for r in last_records)==last['input_samples']*2,'Limit interrupted ordinary last-frame conversion')
        require(not any(r['flags']&4 for r in records) and limit['next_chunk_samples_not_published']==32 and sum(r['samples'] for r in records)==15984,'Actual32 resampler drain bound not reached')
        caps.append({'id':CAP_IDS[3],'passed':True,'process':receipt,'drainEvidence':'All8008 real input samples decoded; final ordinary frame output exact2x; remaining32 drain skipped whole,15984 published.'})
        mutable=work/'owned-mutation.wav';shutil.copyfile(speech,mutable)
        receipt,events,records=capture(CAP_IDS[4],argv(mutable,120)+['--paced'],output/CAP_IDS[4],env,supervisor,legacy,expected_code=1,mutation=mutable)
        check_closed(events,False);require(receipt['mutation'] and receipt['mutation']['afterBytes']==receipt['mutation']['beforeBytes']+1 and any(r.get('category')=='source_fd_changed' for r in events),'Owned source mutation not rejected')
        require(not any(r['event'] in ('media_eof','input_limit_reached') for r in events),'Mutation mislabeled success EOF/limit');caps.append({'id':CAP_IDS[4],'passed':True,'process':receipt})
        canceled=legacy.run_case('cancel-backpressure',argv(speech,120),output/CAP_IDS[5],env,supervisor)
        trace=[legacy.parse(line) for line in (output/CAP_IDS[5]/'stderr.jsonl').read_bytes().splitlines()]
        require(not any(r['event'] in ('media_eof','input_limit_reached') for r in trace),'Cancel confused with EOF/input limit');caps.append({'id':CAP_IDS[5],'passed':True,'originalAssertionResult':canceled})
        require(len(outcomes)==13 and len(caps)==6 and tuple(c['id'] for c in caps)==CAP_IDS,'Unique nineteen scope')
        # Existing default thirteen and graceful six above remain unchanged.
        # New optional first-block handshake uses actual local PCM, not ASR.
        def hold_argv(path,seconds=120):return argv(path,seconds)+['--first-block-hold']
        one=work/'one-sample.wav';new_wave(one,16000,1)
        receipt,events,records=capture(HOLD_IDS[0],hold_argv(one),output/HOLD_IDS[0],env,supervisor,legacy,handshake='release')
        check_closed(events,True)
        require(receipt['actualFirstBlockPauseConfirmed'] and len(receipt['handshakeObservations'])==2
                and sum(r['samples'] for r in records)==1 and len(records)==1 and records[0]['pts']==0
                and any(r['event']=='media_eof' for r in events) and any(r['event']=='resumed' and r['epoch']==1 for r in events),'Single-sample actual first-block hold/EOF contract')
        holds.append({'id':HOLD_IDS[0],'passed':True,'process':receipt})
        short=work/'80-samples.wav';new_wave(short,16000,80)
        receipt,events,records=capture(HOLD_IDS[1],hold_argv(short)+['--paced'],output/HOLD_IDS[1],env,supervisor,legacy,handshake='seek')
        check_closed(events,True)
        require(receipt['actualFirstBlockPauseConfirmed'] and len(records)==2 and [r['epoch'] for r in records]==[1,2]
                and [r['samples'] for r in records]==[80,80] and all(r['pts']==0 for r in records)
                and any(r['event']=='epoch_changed' and r['epoch']==2 for r in events)
                and any(r['event']=='resumed' and r['epoch']==2 for r in events),'Actual hold+seek retirement/new-epoch short PCM')
        holds.append({'id':HOLD_IDS[1],'passed':True,'process':receipt})
        cancel_folder=output/HOLD_IDS[2];cancel_folder.mkdir();cancel_receipts=[]
        for mode in ('cancel','signal','cancel-before-pause','signal-before-pause'):
            receipt,events,records=capture(mode,hold_argv(short),cancel_folder/mode,env,supervisor,legacy,handshake=mode)
            check_closed(events,True)
            require(receipt['actualFirstBlockPauseConfirmed']==(mode in ('cancel','signal')) and events[-1]['cancelled'] is True and len(records)==1
                    and any(r['event']=='cancel_acknowledged' and r['epoch']==1 for r in events)
                    and not any(r['event'] in ('media_eof','input_limit_reached','error') for r in events),'Held actual cancel/signal became EOF/error')
            cancel_receipts.append(receipt)
        holds.append({'id':HOLD_IDS[2],'passed':True,'processes':cancel_receipts})
        limitwav=work/'hold-limit-16008.wav';new_wave(limitwav,16000,16008)
        receipt,events,records=capture(HOLD_IDS[3],hold_argv(limitwav,1),output/HOLD_IDS[3],env,supervisor,legacy,handshake='release')
        bounded(events,records);require(receipt['actualFirstBlockPauseConfirmed'],'Limit lost initial real paused ACK')
        holds.append({'id':HOLD_IDS[3],'passed':True,'process':receipt})
        negative=output/HOLD_IDS[4];negative.mkdir();negative_receipts=[]
        for mode,category in [('premature-resume','first_block_requires_pause'),('premature-seek','first_block_requires_pause'),('premature-track','first_block_requires_pause'),('control-eof','control_eof_incomplete_or_paused'),('no-control','first_block_handshake_deadline')]:
            receipt,events,records=capture(mode,hold_argv(short),negative/mode,env,supervisor,legacy,expected_code=1,handshake=mode)
            check_closed(events,False)
            require(len(records)==1 and any(r.get('category')==category for r in events)
                    and not any(r['event'] in ('media_eof','input_limit_reached') for r in events),'Premature control/EOF was faked success')
            negative_receipts.append(receipt)
        holds.append({'id':HOLD_IDS[4],'passed':True,'processes':negative_receipts})
        invalid=output/HOLD_IDS[5];invalid.mkdir();bad_hold=[]
        for i,extra in enumerate([['--first-block-hold'],['1']]):
            receipt,events,records=capture('invalid-hold-'+str(i),hold_argv(short)+extra,invalid/str(i),env,supervisor,legacy,expected_code=2)
            require(not events and not records,'Invalid optional flag allocated or decoded source');bad_hold.append(receipt)
        holds.append({'id':HOLD_IDS[5],'passed':True,'processes':bad_hold})
        require(len(holds)==6 and tuple(c['id'] for c in holds)==HOLD_IDS,'Unique first-block hold scope')
        ranges=execute_exact_ranges(args,output,env,supervisor,legacy,work)
        summary.update(status='passed',pcmBinarySHA256=args.expected_pcm_sha256,pcmSourceSHA256=C_SHA,
                       defaults={'uniqueCases':13,'passed':13,'failed':0},defaultResults=outcomes,gracefulCases=caps,
                       prototypeCaseCount=25,originalNineteenCaseCount=19,firstBlockHoldCases=holds,driverNaturalExitCode=0,forcedCleanup=False,
                       exactRangeCaseCount=2,rangeCases=ranges,
                       actualAppAcceptance=False,actualNegativeMissingPTSFixtureAcceptance=False)
    except BaseException as error:
        summary.update(status='failed',failure=str(error),completedDefaults=len(outcomes),completedGraceful=len(caps),completedFirstBlockHold=len(holds));raise
    finally:
        after={p:sha(Path(p)) for p in before};summary.update(inputsBefore=before,inputsAfter=after,inputsUnchanged=before==after)
        if summary['status']=='passed' and before!=after:summary.update(status='failed',failure='Input changed')
        save(output/'capability-evidence.json',summary)
        if before!=after:raise RuntimeError('Inputs changed')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('pcm-binary','report-directory','fixture-root','project-root'):parser.add_argument('--'+name,type=Path,required=True)
    for name in ('legacy-driver','supervisor','input-pins','ffprobe'):parser.add_argument('--'+name,type=Path)
    parser.add_argument('--expected-pcm-sha256',required=True)
    args=parser.parse_args();execute(args)


if __name__=='__main__':main()
