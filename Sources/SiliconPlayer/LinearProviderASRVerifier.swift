import AppKit
import Foundation
import CryptoKit
import CoreFoundation
import Darwin
import ImageIO
import PlayerCore

/// Private-suite actual Host/actor verifier. No fake clock, service or child.
/// Every result belongs to this exact newly compiled App; hours remain not-run
/// until the explicit hour mode completes real 1x Core playback.
@MainActor final class LinearProviderASRVerifier {
    static let ids = [
        "linear-native-actual-prime-ready-before-core-align",
        "linear-native-three-natural-windows",
        "linear-native-joint-future-budget",
        "linear-native-paused-start-resume",
        "linear-native-seek-before-first-and-active",
        "linear-native-stop-reload-quit",
        "linear-native-final-cue-and-external-short-eof",
        "linear-native-budgeted-logs-and-real-credit-negative",
        "linear-native-two-hour-then-three-hour"]
    static let modes = Set(ids)
    private let player:PlayerModel, report:URL, mode:String
    private var task:Task<Void,Never>?, result:[String:Any]?
    private var checks:[[String:Any]]=[], episodes:[[String:Any]]=[]
    private var observations:[[String:Any]]=[]
    private var lastPresentationObservation:[String:Any]?
    private var beforeDaily:Data?, fixture:[String:Any]=[:]
    private var initialBinding:LiveASRBinding?, lastBackend:[String:Any]=[:]
    private var seenProviders:Set<String>=[], journalRows:[String:[String:Any]]=[:]
    private var closedRows:[String:[String:Any]]=[:]
    private var snapshots:Int=0, overlayObserved=false
    private var screenshotPending=false, screenshot:[String:Any]?
    private let began=ProcessInfo.processInfo.systemUptime
    private var lastProgressWrite = -Double.infinity
    private var hourIndex=0
    private var progressFD:Int32 = -1, progressBytes:UInt64=0
    init(player:PlayerModel,report:URL,mode:String){self.player=player;self.report=report;self.mode=mode}
    func tick()->[String:Any]? {
        if let result{return result}
        if task != nil{return nil}
        task=Task{[weak self] in
            guard let self else{return}
            do{try self.configure();try await self.run();try self.check("daily-shortcuts-byte-unchanged",UserDefaults.standard.data(forKey:"SiliconPlayer.shortcuts.v1")==self.beforeDaily);self.finish(true,nil)}
            catch{let original=error.localizedDescription;_ = await self.player.liveASR.stop();try? await self.collect();self.finish(false,original)}
        }
        return nil
    }
    private func configure()throws {
        let env=ProcessInfo.processInfo.environment
        guard Self.modes.contains(mode),env["SILICONPLAYER_VERIFY_REPORT"]==report.path,
              InputController.verificationSuiteName(environment:env) != nil,
              env["SILICONPLAYER_LONG_ASR_CANDIDATE"]=="1",
              env["SILICONPLAYER_CAPTURE_LINEAR_ASR_RAW"]=="1",
              let path=env["SILICONPLAYER_LINEAR_FIXTURE"],path.hasPrefix("/") else{throw LiveASRFailure("Explicit private persistent-provider verification required")}
        let bytes=try Data(contentsOf:URL(fileURLWithPath:path));guard bytes.count<=65536,
            let value=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],value["caseID"] as? String==mode else{throw LiveASRFailure("Exact small fixture binding required")}
        fixture=value;beforeDaily=UserDefaults.standard.data(forKey:"SiliconPlayer.shortcuts.v1")
        guard let duration=fixture["duration"] as? NSNumber,duration.doubleValue.isFinite,duration.doubleValue>5,
              let source=fixture["path"] as? String,source.hasPrefix("/"),
              let fp=LiveASRMPVHostState.fingerprint(URL(fileURLWithPath:source)),fp.byteCount>0 else{throw LiveASRFailure("Preselected real local fixture required")}
        try check("private-suite-and-real-fixture",true,["path":source,"duration":duration.doubleValue,"rule":"no synthetic Core clock"])
    }
    private func run()async throws {
        try await prepare()
        switch mode {
        case Self.ids[0]:
            try await startPaused();try await resumeAndInput();try await speechAndExport();try await stopClosed("prime")
        case Self.ids[1]:
            guard number(fixture,"duration")>245 else{throw LiveASRFailure("Three real windows need a >245-second source")}
            try await startPaused();try await resumeAndInput()
            try await wait("actual-third-window-and-input",seconds:300){
                self.integer(self.lastBackend,"currentWindow")>=3 && self.integer(self.lastBackend,"actualAcceptedSamples")>=16000
            }
            try check("same-provider-across-three-windows",seenProviders.count==1)
            try await speechAndExport(requireAfter120:true);try await stopClosed("three-windows")
        case Self.ids[2]:
            try await startPaused();try await resumeAndInput();try await holdPause(seconds:3.6)
            let beforeSpeed=integer(lastBackend,"nativeControlSerial")
            player.setSpeed(1.25);try await wait("actual-paused-speed-ack",seconds:5){
                self.lastBackend["nativePaused"] as? Bool==true && self.player.number("speed")==1.25
                    && self.integer(self.lastBackend,"nativeControlSerial")>beforeSpeed && self.number(self.lastBackend,"nativeSpeed")==1.25
            }
            let beforeRestore=integer(lastBackend,"nativeControlSerial");player.setSpeed(1)
            try await wait("actual-restored-speed-ack",seconds:5){self.number(self.lastBackend,"nativeSpeed")==1 && self.integer(self.lastBackend,"nativeControlSerial")>beforeRestore}
            try await resumeAndInput();try await wait("actual-joint-budget-observed",seconds:15){self.lastBackend["actualActorBudget"] is [String:Any] && self.lastBackend["lastNativeBudget"] is [String:Any]}
            try budget();try await stopClosed("joint-budget")
        case Self.ids[3]:
            try await startPaused();try await heldStartup(seconds:3.6);try await resumeAndInput()
            try await holdPause(seconds:3.6);try await resumeAndInput();try await speechAndExport();try await stopClosed("paused-resume")
        case Self.ids[4]:
            try await startPaused();let first=try providerIdentity()
            try await seek(3);try check("same-held-provider-before-first-seek",try providerIdentity()==first)
            try await resumeAndInput();try await wait("real-prefix-before-active-seek",seconds:15){self.integer(self.lastBackend,"actualAcceptedSamples")>=16000}
            let oldGeneration=lastBackend["generation"] as? String
            player.set("pause","yes");try await seek(6)
            try check("same-held-provider-after-active-seek",try providerIdentity()==first)
            try check("seek-changed-policy-generation",lastBackend["generation"] as? String != oldGeneration)
            try await resumeAndInput();try await speechAndExport();try await stopClosed("seek")
        case Self.ids[5]:
            try await startPaused();try await resumeAndInput();try await stopClosed("explicit-stop")
            let before=player.liveASRSnapshot().binding
            guard let url=player.currentURL else{throw LiveASRFailure("Loaded source disappeared")}
            try await player.openAndWaitForCommit([url]);try await prepare()
            try check("replacement-has-new-Core-binding",player.liveASRSnapshot().binding?.loadToken != before?.loadToken)
            try await startPaused();try await resumeAndInput()
            let previous=lastBackend["providerID"] as? String
            try await player.openAndWaitForCommit([url]);try await wait("replacement-strongly-retired-old-actor",seconds:20){!LiveASRController.hasActiveJobs && !self.player.liveASR.isActive}
            try await collect();try requireClosed("replacement");try await prepare();try await startPaused();try await resumeAndInput()
            try check("quit-has-new-live-actual-actor",lastBackend["providerID"] as? String != previous && LiveASRController.hasActiveJobs)
            // Return while genuinely owned. SessionVerifier requests normal
            // AppKit quit; AppDelegate actual sidecar supplies final closure.
            try check("quit-awaits-real-termination-sidecar",true)
        case Self.ids[6]:
            guard let external=fixture["externalPath"] as? String,external.hasPrefix("/"),
                  let d=fixture["externalDuration"] as? NSNumber,(1...20).contains(d.doubleValue),
                  d.doubleValue+5<number(fixture,"duration") else{throw LiveASRFailure("Real short external WAV fixture required")}
            guard player.executeCommand(["audio-add",external,"select"])>=0 else{throw LiveASRFailure("Actual mpv external source attachment failed")}
            try await wait("actual-external-audio-selected",seconds:6){self.player.liveASRSnapshot().selectedTrack?.externalSource?.url.path==external}
            try await startPaused();try await resumeAndInput()
            try await wait("actual-external-final-before-main-EOF",seconds:d.doubleValue+20){
                self.player.liveASR.state == .sourceCompleted && !self.player.liveASR.isActive && !LiveASRController.hasActiveJobs && !self.player.flag("eof-reached")
            }
            try requireClosed("external-EOF");let count=player.liveASR.finalCues.count
            try await speechAndExport();let identity=lastBackend["providerID"] as? String
            try await delay(1)
            try check("final-retained-with-no-auto-restart",player.liveASR.finalCues.count==count && player.liveASR.state == .sourceCompleted && lastBackend["providerID"] as? String==identity && !LiveASRController.hasActiveJobs)
            try check("completed-source-remains-stoppable",player.liveASR.canStop);try await stopClosed("external-stop")
        case Self.ids[7]:
            try await startPaused();try await resumeAndInput();try await delay(8);try budget();try await stopClosed("real-credit-budget")
            // Owner must additionally execute two exact invalid CREDIT inputs
            // against this candidate's signed PCM helper. This App does not
            // claim those negative native subprocesses before they really run.
            try check("negative-credit-external-Owner-required",true)
        case Self.ids[8]:
            for (index,key) in ["twoHour","threeHour"].enumerated(){
                guard let row=fixture[key] as? [String:Any],let path=row["path"] as? String,
                      let duration=row["duration"] as? NSNumber,
                      duration.doubleValue>=(index==0 ? 7200:10800),
                      duration.doubleValue<=(index==0 ? 7202:10802) else{throw LiveASRFailure("Prebound complete 2h then 3h fixtures required")}
                hourIndex=index;try await player.openAndWaitForCommit([URL(fileURLWithPath:path)]);try await prepare(duration:duration.doubleValue)
                try await startPaused();let wall=ProcessInfo.processInfo.systemUptime;try await resumeAndInput()
                try await wait("real-complete-hour-\(index+1)",seconds:duration.doubleValue+180){self.player.flag("eof-reached") && !self.player.liveASR.isActive && !LiveASRController.hasActiveJobs}
                try check("real-1x-hour-wall-\(index+1)",ProcessInfo.processInfo.systemUptime-wall>=duration.doubleValue-0.5 && abs(player.number("speed")-1)<0.0001)
                try requireClosed("hour-\(index+1)");try await speechAndExport(requireAfter120:true)
                episodes.append(["hourIndex":index,"duration":duration.doubleValue,"wallSeconds":ProcessInfo.processInfo.systemUptime-wall,"backend":lastBackend])
            }
        default:throw LiveASRFailure("Unknown explicit native case")
        }
    }
    private func prepare(duration:Double?=nil)async throws {
        let wanted=duration ?? number(fixture,"duration")
        try await wait("loaded-real-source",seconds:30){self.player.loaded && !self.player.isLoading && abs(self.player.number("duration")-wanted)<0.15}
        player.set("pause","yes");player.setSpeed(1);player.seek(0,remember:false)
        try await wait("actual-Core-paused-zero",seconds:8){self.settled(0) && self.player.flag("pause")}
        if fixture["externalPath"] != nil {initialBinding=player.liveASRSnapshot().binding;return}
        if fixture["externalPath"]==nil {
            let trackIndex=integer(fixture,"trackIndex")
            let candidates=(player.jsonProperty("track-list") as? [[String:Any]] ?? []).filter{
                $0["type"] as? String=="audio" && $0["external"] as? Bool != true && self.integer($0,"ff-index")==trackIndex
            }
            guard candidates.count==1,let native=candidates.first?["id"] as? Int else{throw LiveASRFailure("Exact embedded stream index required")}
            player.selectAudio(native)
            try await wait("actual-embedded-audio-binding",seconds:6){
                guard let selected=self.player.liveASRSnapshot().selectedTrack else{return false}
                return selected.runtimeAudioID==native && Int64(selected.absoluteFFmpegIndex)==trackIndex
            }
        }
        let snapshot=player.liveASRSnapshot();guard let track=snapshot.selectedTrack,let binding=snapshot.binding,
            track.codec==fixture["codec"] as? String,track.sampleRate==integer(fixture,"rate"),track.channels==integer(fixture,"channels") else{throw LiveASRFailure("Actual Host audio metadata differs from prebound fixture")}
        initialBinding=binding
        try check("actual-Host-selected-source",true,["nativeEntryID":binding.nativeEntryID,"coreID":binding.coreID.uuidString,"loadToken":binding.loadToken.uuidString,"queueID":binding.queueItemID.uuidString,"trackIndex":track.absoluteFFmpegIndex,"codec":track.codec,"rate":track.sampleRate])
    }
    private func startPaused()async throws {
        try check("real-persistent-provider-start",await player.startLiveASR(mode:.persistentProvider))
        try await collect()
        guard let startup=lastBackend["actualStartup"] as? [String:Any],let prime=startup["unpublishedPrime"] as? [String:Any],
              prime["published"] as? Bool==false,let hex=prime["record_hex"] as? String,hex.count>=224,
              startup["serviceReady"] as? Bool==true,startup["nativePaused"] as? Bool==true,
              (startup["actualPauseACK"] as? [String:Any])?["command"] as? String=="PAUSE",
              (startup["actualPauseACK"] as? [String:Any])?["paused"] as? Bool==true,
              integer(startup,"writtenPayloadBytes")==0,integer(startup,"acceptedSamples")==0,
              integer(lastBackend,"actualWrittenPayloadBytes")==0,integer(lastBackend,"actualAcceptedSamples")==0,
              lastBackend["nativePaused"] as? Bool==true,player.flag("pause"),player.liveASR.isActive else{throw LiveASRFailure("Actual unpublished prime/PAUSE/zero-written/ready-before-alignment evidence missing")}
        try check("unpublished-prime-ready-before-Core-alignment",true,["startup":startup,"actualBackend":lastBackend])
    }
    private func heldStartup(seconds:Double)async throws {
        let serial=integer(lastBackend,"nativeControlSerial"),position=player.number("time-pos"),end=ProcessInfo.processInfo.systemUptime+seconds
        while ProcessInfo.processInfo.systemUptime<end {
            try await collect();guard player.flag("pause"),abs(player.number("time-pos")-position)<=0.05,lastBackend["nativePaused"] as? Bool==true,
                integer(lastBackend,"actualWrittenPayloadBytes")==0,integer(lastBackend,"actualAcceptedSamples")==0,
                integer(lastBackend,"nativeControlSerial")==serial else{throw LiveASRFailure("Paused initial actor leaked actual input or changed Core clock")}
            try await Task.sleep(nanoseconds:50_000_000)
        }
        try check("real-paused-initial-hold",true,["wallSeconds":seconds,"nativeControlSerial":serial])
    }
    private func resumeAndInput()async throws {
        let previous=integer(lastBackend,"nativeControlSerial");player.set("pause","no")
        try await wait("actual-resume-ACK-and-CAPI-input",seconds:20){self.lastBackend["nativePaused"] as? Bool==false && self.integer(self.lastBackend,"nativeControlSerial")>previous && self.integer(self.lastBackend,"actualAcceptedSamples")>0}
    }
    private func holdPause(seconds:Double)async throws {
        let previous=integer(lastBackend,"nativeControlSerial");player.set("pause","yes")
        try await wait("actual-pause-ACK",seconds:5){self.lastBackend["nativePaused"] as? Bool==true && self.integer(self.lastBackend,"nativeControlSerial")>previous && self.integer(self.lastBackend,"actualWrittenPayloadBytes")==self.integer(self.lastBackend,"actualAcceptedSamples")*4}
        let accepted=integer(lastBackend,"actualAcceptedSamples"),position=player.number("time-pos"),end=ProcessInfo.processInfo.systemUptime+seconds
        while ProcessInfo.processInfo.systemUptime<end {
            try await collect();guard player.flag("pause"),abs(player.number("time-pos")-position)<=0.05,
                integer(lastBackend,"actualAcceptedSamples")==accepted else{throw LiveASRFailure("User pause advanced real accepted input or clock")}
            try await Task.sleep(nanoseconds:50_000_000)
        }
        try check("actual-pause-over-three-seconds",true,["actualWallSeconds":seconds,"accepted":accepted,"position":position])
    }
    private func seek(_ target:Double)async throws {
        let generation=player.liveASRHostState.seekGeneration,serial=integer(lastBackend,"nativeControlSerial")
        player.seek(target,remember:false)
        try await wait("actual-seek-settled-and-provider-ACK",seconds:12){self.player.liveASRHostState.seekGeneration>generation && self.settled(target) && self.lastBackend["nativePaused"] as? Bool==true && self.integer(self.lastBackend,"nativeControlSerial")>serial && self.integer(self.lastBackend,"readyServiceCount")>=1
            && (self.lastBackend["services"] as? [[String:Any]] ?? []).contains{row in
                row["window"] as? String==self.lastBackend["startedReadyWindow"] as? String && self.integer(row,"serial")==self.integer(self.lastBackend,"currentWindow")
            }}
        try check("seek-kept-actual-Core-load-binding",player.liveASRSnapshot().binding==initialBinding)
    }
    private func speechAndExport(requireAfter120:Bool=false)async throws {
        try await wait("actual-final-Chinese-cues",seconds:25){self.player.liveASR.finalCues.contains{self.chinese($0.text)} && (!requireAfter120 || self.player.liveASR.finalCues.contains{$0.start.seconds>=120})}
        let cues=player.liveASR.finalCues
        try check("actual-cue-source-time-bounds",cues.allSatisfy{$0.start.seconds>=0 && $0.end.seconds>$0.start.seconds && $0.end.seconds<=player.number("duration")+0.001})
        let srt=report.deletingPathExtension().appendingPathExtension("\(hourIndex).srt")
        try await player.liveASR.export(to:srt)
        let parsed=try SubtitleDocument.parse(String(contentsOf:srt,encoding:.utf8))
        try check("actual-export-SRT-reparse",parsed.cues.count==cues.count && zip(parsed.cues,cues).allSatisfy{
            $0.0.text.trimmingCharacters(in:.whitespacesAndNewlines)==$0.1.text.trimmingCharacters(in:.whitespacesAndNewlines) && abs($0.0.start-$0.1.start.seconds)<=0.0011 && abs($0.0.end-$0.1.end.seconds)<=0.0011
        },["path":srt.path,"cueCount":cues.count])
        if mode != Self.ids[5],mode != Self.ids[6] {
            try await wait("real-owned-Chinese-OSD-and-window-PNG",seconds:8){self.overlayObserved && !self.screenshotPending && self.screenshot?["decoded"] as? Bool==true}
        }
        // OSD command ownership is observed separately from readable bitmap.
        if player.liveASRHostState.overlayOwner != nil,let payload=player.liveASRHostState.overlayPayload,!payload.isEmpty{overlayObserved=true}
    }
    private func stopClosed(_ label:String)async throws {
        _ = await player.liveASR.stop();try await collect();try requireClosed(label)
        try check("actual-overlay-cleared-"+label,player.liveASRHostState.overlayOwner==nil && !LiveASRController.hasActiveJobs)
        episodes.append(["label":label,"controller":player.liveASR.diagnosticsSnapshot,"backend":lastBackend])
    }
    private func requireClosed(_ label:String)throws {
        let controller=player.liveASR.diagnosticsSnapshot
        guard controller["actualOwnedResourcesReleased"] as? Bool==true,controller["actualNativeNormalClosure"] as? Bool==true,
              lastBackend["closedResources"] as? Bool==true,lastBackend["allNativeServiceZero"] as? Bool==true,
              lastBackend["allServiceNaturalZero"] as? Bool==true,lastBackend["firstFailure"] is NSNull,
              !LiveASRController.hasActiveJobs,!player.liveASR.isActive else{throw LiveASRFailure("Actual strong/native closure missing: "+label)}
        try check("strong-native-close-"+label,true)
    }
    private func budget()throws {
        guard let c=lastBackend["lastNativeBudget"] as? [String:Any],let a=lastBackend["actualActorBudget"] as? [String:Any],
              ["reserved_total","external_cap","converted_remaining","swr_out_upper","record_copy_samples"].allSatisfy({integer(c,$0)>=0}),
              ["logicalExternal","ringSamples","partialSamples","unacceptedSamples","jointReservedUpper"].allSatisfy({integer(a,$0)>=0}),
              integer(c,"reserved_total")<=32000,integer(c,"external_cap")==11584,
              integer(c,"converted_remaining")+integer(c,"swr_out_upper")+integer(c,"record_copy_samples")<=16000,
              integer(a,"logicalExternal")<=11584,integer(a,"ringSamples")<=4096,
              integer(a,"partialSamples")<=320,integer(a,"unacceptedSamples")<=4096,
              integer(a,"jointReservedUpper")==32000 else{throw LiveASRFailure("Actual native/actor future partitions absent or over original bounds")}
        try check("real-C-and-actor-joint-future-budget",true,["native":c,"actor":a])
    }
    private func providerIdentity()throws->String {
        guard let born=lastBackend["sourceBorn"] as? [String:Any],integer(born,"held_fd")>=0,integer(born,"pid")>0,
              let id=lastBackend["providerID"] as? String else{throw LiveASRFailure("Actual held FD/provider birth unavailable")}
        return id+":"+String(integer(born,"pid"))+":"+String(integer(born,"held_fd"))
    }
    private func collect()async throws {
        guard let data=await player.liveASR.backendDiagnostics(),data.count<=4*1048576,
              let actual=try JSONSerialization.jsonObject(with:data) as? [String:Any],actual["status"] as? String=="actual-runtime-snapshot",
              actual["captureEnabled"] as? Bool==true else {
            if !player.liveASR.isActive && lastBackend.isEmpty{return};throw LiveASRFailure("Actual actor diagnostics unavailable")
        }
        lastBackend=actual
        if let p=actual["providerID"] as? String{seenProviders.insert(p)}
        if let failure=actual["firstFailure"] as? String{throw LiveASRFailure("Actual actor first failure: "+failure)}
        lastPresentationObservation=actualPresentationObservation()
        for row in actual["journals"] as? [[String:Any]] ?? [] {
            guard let p=actual["providerID"] as? String,let serial=row["serial"] as? NSNumber else{throw LiveASRFailure("Finalized raw journal identity missing")}
            var enriched=row;enriched["providerID"]=p;enriched["workPath"]=actual["workPath"]
            journalRows[p+":"+serial.stringValue]=enriched
        }
        for row in actual["closeHistory"] as? [[String:Any]] ?? [] {
            guard let p=actual["providerID"] as? String,let kind=row["kind"] as? String else{throw LiveASRFailure("Actual native close row missing")}
            let key=p+":"+kind+":"+String(integer(row,"serial"));closedRows[key]=row
        }
        if let owner=player.liveASRHostState.overlayOwner,let payload=player.liveASRHostState.overlayPayload,chinese(payload){
            overlayObserved=true
            if !screenshotPending,screenshot==nil {
                screenshotPending=true
                let destination=report.deletingPathExtension().appendingPathExtension("linear-window.png")
                let at:[String:Any]=["overlayOwner":owner.uuidString,"overlayPayload":payload,"corePosition":player.number("time-pos"),"uptime":ProcessInfo.processInfo.systemUptime,"presentationObservation":lastPresentationObservation as Any? ?? NSNull()]
                player.saveScreenshotAsync(to:destination,mode:.window){[weak self] outcome in
                    guard let self else{return};self.screenshotPending=false
                    switch outcome {
                    case .success(let url):
                        if let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil){var row=at;row["path"]=url.path;row["decoded"]=true;row["width"]=image.width;row["height"]=image.height;self.screenshot=row}
                        else{self.screenshot=["decoded":false,"path":url.path]}
                    case .failure(let error):self.screenshot=["decoded":false,"error":error.localizedDescription]
                    }
                }
            }
        }
        snapshots+=1
        let sample:[String:Any]=["uptime":ProcessInfo.processInfo.systemUptime,"corePosition":player.number("time-pos"),"corePaused":player.flag("pause"),"coreSpeed":player.number("speed"),"controller":player.liveASR.diagnosticsSnapshot,"backend":actual,"presentationObservation":lastPresentationObservation as Any? ?? NSNull()]
        observations.append(sample);if observations.count>64{observations.removeFirst(observations.count-64)}
        // Append real progress; this is not a synthetic child/native event.
        if ProcessInfo.processInfo.systemUptime-lastProgressWrite>=0.5 {
            let path=report.deletingPathExtension().appendingPathExtension("linear-progress.jsonl")
            let keys=["providerID","generation","phase","sourcePID","currentWindow","nativeControlSerial","nativePaused","actualWrittenPayloadBytes","actualAcceptedSamples","ringSamples","lastNativeBudget","actualActorBudget","serviceCloseCount","closedResources","firstFailure"]
            let compact=actual.filter{keys.contains($0.key)}
            let progress:[String:Any]=["uptime":ProcessInfo.processInfo.systemUptime,"corePosition":player.number("time-pos"),"corePaused":player.flag("pause"),"coreSpeed":player.number("speed"),"controller":player.liveASR.diagnosticsSnapshot,"backend":compact,"presentationObservation":lastPresentationObservation as Any? ?? NSNull()]
            let bytes=try JSONSerialization.data(withJSONObject:progress,options:[.sortedKeys])+Data([10])
            guard bytes.count<=65536,progressBytes+UInt64(bytes.count)<=256*1048576 else{throw LiveASRFailure("Progress output budget exceeded")}
            if progressFD<0{progressFD=Darwin.open(path.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,mode_t(0o600));guard progressFD>=0 else{throw LiveASRFailure("Fresh progress output required")}}
            var offset=0
            while offset<bytes.count{let n=bytes.withUnsafeBytes{Darwin.write(progressFD,$0.baseAddress!.advanced(by:offset),bytes.count-offset)};if n<0 && errno==EINTR{continue};guard n>0 else{throw LiveASRFailure("Actual progress write failed")};offset+=n}
            guard fsync(progressFD)==0 else{throw LiveASRFailure("Actual progress fsync failed")};progressBytes+=UInt64(bytes.count);lastProgressWrite=ProcessInfo.processInfo.systemUptime
        }
    }
    private func actualPresentationObservation()->[String:Any] {
        let began=ProcessInfo.processInfo.systemUptime
        let current=player.liveASRSnapshot()
        let controller=player.liveASR.diagnosticsSnapshot
        let overlayOwner=player.liveASRHostState.overlayOwner
        let payload=player.liveASRHostState.overlayPayload
        let binding:[String:Any]?=current.binding.map {
            ["coreID":$0.coreID.uuidString,"queueItemID":$0.queueItemID.uuidString,
             "loadToken":$0.loadToken.uuidString,"nativeEntryID":$0.nativeEntryID]
        }
        let track:[String:Any]?=current.selectedTrack.map {
            ["runtimeAudioID":$0.runtimeAudioID,"ffmpegIndex":$0.absoluteFFmpegIndex,
             "codec":$0.codec,"rate":$0.sampleRate,"external":$0.isExternal]
        }
        return ["readBeganUptime":began,"readEndedUptime":ProcessInfo.processInfo.systemUptime,
                "coreSnapshotObservedUptime":current.observedUptime,"nonAtomicHostReads":true,
                "binding":binding as Any? ?? NSNull(),"selectedTrack":track as Any? ?? NSNull(),
                "corePosition":current.corePosition as Any? ?? NSNull(),
                "coreAudioPTS":current.coreAudioPTS as Any? ?? NSNull(),
                "loaded":current.loaded,"loading":current.loading,"paused":current.paused,
                "seeking":current.seeking,"eof":current.eof,"speed":current.speed,
                "seekGeneration":current.seekGeneration,
                "settledSeekGeneration":current.settledSeekGeneration as Any? ?? NSNull(),
                "controllerOwner":controller["owner"] ?? NSNull(),
                "controllerProcessID":controller["processID"] ?? NSNull(),
                "controllerOperation":controller["operation"] ?? NSNull(),
                "latestPresentation":controller["latestPresentation"] ?? NSNull(),
                "actualOverlayOwner":overlayOwner?.uuidString as Any? ?? NSNull(),
                "actualOverlayPayloadUTF8Bytes":payload?.utf8.count as Any? ?? NSNull(),
                "actualOverlayPayloadSHA256":payload.map { SHA256.hash(data:Data($0.utf8)).map{String(format:"%02x",$0)}.joined() } as Any? ?? NSNull()]
    }
    private func wait(_ label:String,seconds:Double,_ condition:()->Bool)async throws {
        let end=ProcessInfo.processInfo.systemUptime+seconds
        while ProcessInfo.processInfo.systemUptime<end {
            if player.liveASR.mode == .persistentProvider{try await collect()}
            if condition(){try check(label,true);return}
            try await Task.sleep(nanoseconds:50_000_000)
        }
        throw LiveASRFailure("Real Host timeout: "+label)
    }
    private func delay(_ seconds:Double)async throws {
        let end=ProcessInfo.processInfo.systemUptime+seconds
        while ProcessInfo.processInfo.systemUptime<end{try await collect();try await Task.sleep(nanoseconds:50_000_000)}
    }
    private func settled(_ position:Double)->Bool {
        let s=player.liveASRSnapshot();return !s.seeking && s.settledSeekGeneration==s.seekGeneration && abs(player.number("time-pos")-position)<0.12
    }
    private func integer(_ o:[String:Any],_ key:String)->Int64 {
        guard let n=o[key] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),let v=Int64(n.stringValue) else{return Int64.min};return v
    }
    private func number(_ o:[String:Any],_ key:String)->Double {guard let n=o[key] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{return -.infinity};return n.doubleValue}
    private func chinese(_ text:String)->Bool{text.unicodeScalars.contains{(0x3400...0x9fff).contains($0.value)}}
    private func check(_ id:String,_ ok:Bool,_ extra:[String:Any]=[:])throws {
        var row=extra;row["id"]=id;row["passed"]=ok;row["uptime"]=ProcessInfo.processInfo.systemUptime
        // This is the latest independently read observation, not an atomic
        // state assertion at this check's later uptime. Missing stays null.
        row["presentationObservation"]=lastPresentationObservation as Any? ?? NSNull();checks.append(row)
        guard ok else{throw LiveASRFailure("Actual check failed: "+id)}
    }
    private func finish(_ ok:Bool,_ error:String?) {
        var success=ok,detail=error
        if progressFD>=0{let sync=fsync(progressFD),closed=Darwin.close(progressFD);progressFD = -1;if sync != 0 || closed != 0{success=false;detail="Actual progress final close failed"}}
        result=["linearSucceeded":success,"linearCaseID":mode,"linearError":detail as Any? ?? NSNull(),
            "linearChecks":checks,"linearEpisodes":episodes,"linearSamplesTail":observations,
            "linearSnapshotCount":snapshots,"linearJournals":Array(journalRows.values),
            "linearClosedRows":Array(closedRows.values),"linearLastBackend":lastBackend,
            "linearController":player.liveASR.diagnosticsSnapshot,"linearRealWallSeconds":ProcessInfo.processInfo.systemUptime-began,
            "linearOverlayCommandObserved":overlayObserved,"linearScreenshot":screenshot as Any? ?? NSNull(),"linearScope":"actual selected actor/MPVHost case; no held-out accuracy/word alignment claim"]
    }
}
