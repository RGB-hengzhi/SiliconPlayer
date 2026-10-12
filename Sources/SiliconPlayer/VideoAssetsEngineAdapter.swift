import Foundation
import PlayerCore
import CMPV

@MainActor final class VideoAssetsEngineAdapter: VideoAssetRuntime {
    private weak var player:PlayerModel?
    private let coreID=UUID()
    private(set) var activeAssets=VideoAssetPipeline(shaders:[],lutGraphs:[])
    private var applying=false
    var isConfiguring:Bool {applying}
    private var currentTicket:UUID?
    private var cancelled:Set<UUID>=[]
    private var firstFailure:String?
    private var evidence:[String]=[]
    private var diagnosticLogSequence:UInt64=0
    private var diagnosticLogCount=0
    private var lastDiagnosticTicket:UUID?
    private var diagnosticEnabled:Bool {
        let env=ProcessInfo.processInfo.environment
        return env["SILICONPLAYER_VERIFY_MODE"]=="native-ui-manual"
            && env["SILICONPLAYER_VERIFY_REPORT"]?.hasPrefix("/")==true
            && InputController.verificationSuiteName(environment:env) != nil
    }
    private func diagnostic(_ stage:String,_ values:[String:Any],maximumBytes:Int=8192) {
        guard diagnosticEnabled else {return}
        var fields=values;fields["stage"]=stage
        fields["uptime"]=ProcessInfo.processInfo.systemUptime
        fields["currentTicket"]=currentTicket?.uuidString ?? ""
        fields["lastTicket"]=lastDiagnosticTicket?.uuidString ?? ""
        fields["logSequence"]=diagnosticLogSequence
        guard let data=try? JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys]),data.count<=maximumBytes,
              let text=String(data:data,encoding:.utf8) else {return}
        NSLog("video-assets-diagnostic: %@",text)
    }
    private func nativeDiagnostic(_ stage:String,native:[String:Any]?,beforeSequence:Int64?,
                                  pipeline:VideoAssetPipeline,descriptions:[String],
                                  shaders:[String]?,filters:[[String:Any]]?,decoder:String,
                                  output:[String:Any]?,drawable:VideoAssetDrawableProof?,
                                  requestedAt:TimeInterval,eventsEmpty:Bool?) {
        guard diagnosticEnabled else {return}
        let receipt=drawable?.diagnostics
        diagnostic(stage,["nativeObject":native as Any? ?? NSNull(),"beforeNativeSequence":beforeSequence as Any? ?? NSNull(),
            "expectedPaths":pipeline.shaders.map(\.path),"expectedDescriptions":descriptions,
            "actualShaders":shaders as Any? ?? NSNull(),"actualFilters":filters as Any? ?? NSNull(),
            "decoder":decoder,"output":output as Any? ?? NSNull(),"drawable":receipt as Any? ?? NSNull(),
            "requestedAt":requestedAt,"eventsEmpty":eventsEmpty as Any? ?? NSNull(),"firstFailure":firstFailure ?? ""],maximumBytes:65536)
    }
    private func propertyStatus(_ name:String,handle:OpaquePointer) -> Int32 {
        var node=mpv_node();let status=mpv_get_property(handle,name,MPV_FORMAT_NODE,&node)
        if status>=0 {mpv_free_node_contents(&node)}
        return status
    }
    init(player:PlayerModel) {self.player=player}
    var assetBinding:VideoAssetPlaybackBinding? {
        guard let player,player.handle != nil,player.loaded,!player.isLoading,
              player.mediaPreferenceToken==player.mediaPreferences.token,
              let item=player.mediaPreferences.boundItemID,
              player.tracks.contains(where:{$0.type=="video"}),!player.videoConfigurationClosing else {return nil}
        return VideoAssetPlaybackBinding(coreID:coreID,mediaEpoch:player.videoConfigurationEpoch,
                                         loadedItemID:item,loadToken:player.mediaPreferenceToken)
    }
    func applyAssets(_ pipeline:VideoAssetPipeline,binding:VideoAssetPlaybackBinding,
                     ticket:UUID) async throws -> VideoAssetAcceptance {
        try await configure(pipeline,binding:binding,ticket:ticket,isRestore:false)
    }
    func applyProfileAssets(_ pipeline:VideoAssetPipeline,settings:PlaybackSettings,
                            userFragments:[String],binding:VideoAssetPlaybackBinding,
                            ticket:UUID) async throws -> VideoAssetAcceptance {
        try await configure(pipeline,binding:binding,ticket:ticket,isRestore:false,
                            profileSettings:settings,profileFragments:userFragments)
    }
    func restoreAssets(_ pipeline:VideoAssetPipeline,binding:VideoAssetPlaybackBinding,
                       ticket:UUID) async throws -> VideoAssetAcceptance {
        try await configure(pipeline,binding:binding,ticket:ticket,isRestore:true)
    }
    func cancelAssets(ticket:UUID) {
        if cancelled.count>=16 {cancelled.removeAll()}
        cancelled.insert(ticket)
    }
    func contextEnded() {
        if let currentTicket {cancelAssets(ticket:currentTicket)}
        activeAssets=VideoAssetPipeline(shaders:[],lutGraphs:[])
        if let player,let handle=player.handle,!player.videoConfigurationClosing {
            do {guard try VideoAssetMPVNode.shaders([],handle:handle)>=0 else {throw VideoAssetError.applyFailed}}
            catch {player.videoFilterFailure="旧媒体的 GLSL 配置未能清除；新媒体需要重新验证"}
        }
    }
    /// Called only after the existing bounded/redacted event-log conversion.
    func observeLog(prefix:String,level:String,message:String) {
        diagnosticLogSequence &+= 1
        let diagnosticText=message.lowercased()
        if diagnosticEnabled,diagnosticLogCount<128,
           diagnosticText.contains("shader") || diagnosticText.contains("compile") || diagnosticText.contains("link") || ["error","fatal"].contains(level) {
            diagnosticLogCount+=1
            // Message already passed the engine's bounded UTF8 redactor.
            diagnostic("received-renderer-log",["prefix":prefix,"level":level,
                "message":String(message.prefix(2048)),"firstFailureBefore":firstFailure ?? ""])
        }
        guard currentTicket != nil,firstFailure==nil else {return}
        let p=prefix.lowercased(),m=message.lowercased()
        let renderer=p=="libmpv_render" || p.hasPrefix("libmpv_render/") || p.contains("vo") || p.contains("gpu") || p.contains("opengl") || p.contains("lavfi") || p.contains("vf")
        let shader=m.contains("shader") || m.contains("hook") || m.contains("texture") || m.contains("compile") || m.contains("link") || m.contains("header")
        if renderer && (["error","fatal"].contains(level) || (level=="warn" && shader)) {
            firstFailure=String(message.prefix(2048))
        }
    }
    func suspendAssetsForCurrentMedia() {
        if let currentTicket {cancelAssets(ticket:currentTicket)}
        activeAssets=VideoAssetPipeline(shaders:[],lutGraphs:[])
        guard let player,let handle=player.handle,!player.videoConfigurationClosing else {return}
        _=try? VideoAssetMPVNode.shaders([],handle:handle)
        player.applySettings()
        // Caller reports suspended; this best effort is not a confirmed restore.
    }
    private func configure(_ pipeline:VideoAssetPipeline,binding:VideoAssetPlaybackBinding,
                           ticket:UUID,isRestore:Bool,profileSettings:PlaybackSettings?=nil,profileFragments:[String]?=nil) async throws -> VideoAssetAcceptance {
        guard !applying,let player,let handle=player.handle,assetBinding==binding,
              !player.userVideoFilters.isApplying,!player.profileRecoveryBlocked,!player.profileBackup.blocksPersistence else {throw VideoAssetError.busy}
        guard !cancelled.contains(ticket) else {throw VideoAssetError.staleTicket}
        guard player.drainCoreEventsToEmpty(expectedHandle:handle,maximum:512),
              assetBinding==binding,player.handle==handle,
              let expectedRenderer=player.videoHost?.video.rendererIdentity else {throw VideoAssetError.busy}
        let metalView=player.videoHost?.video as? MPVMetalVideoView
        let nativeKey=metalView == nil ? "pipeline-validation" : "gpu-next-validation"
        let capturedVideoSelection=player.string("vid")
        applying=true;currentTicket=ticket;lastDiagnosticTicket=ticket;firstFailure=nil;evidence=[]
        defer {
            diagnostic("configuration-end",["firstFailure":firstFailure ?? "","frames":player.renderProgress.frames])
            player.renderProgress.retireConfigurationDrawable(ticket:ticket)
            metalView?.retireConfigurationRedraw(ticket:ticket)
            applying=false;currentTicket=nil;cancelled.remove(ticket)
        }
        let began=ProcessInfo.processInfo.systemUptime
        let capturedSettings=player.settings.sanitized(),capturedUser=player.userVideoFilters.effectiveFragments
        let settings=profileSettings?.sanitized() ?? capturedSettings,user=profileFragments ?? capturedUser
        let graph=(player.configuredVideoFragments(settings:settings,userFragments:user)+pipeline.lutGraphs).joined(separator:",")
        let decoder=graph.isEmpty ? settings.hardwareDecoder : (settings.hardwareDecoder=="no" ? "no" : "videotoolbox-copy")
        var descriptions:[String]=[]
        // Background reads avoid synchronous hashing/file IO on MainActor.
        // Each shader filename is already the exact SHA-owned managed basename.
        if !pipeline.shaders.isEmpty {
            let managedDirectory=PlayerModel.supportDirectory.appendingPathComponent("video-assets",isDirectory:true)
            let isMetal=metalView != nil
            descriptions=try await Task.detached(priority:.userInitiated) {
                if isMetal {return try MetalManagedShaders.descriptions(paths:pipeline.shaders.map(\.path),directory:managedDirectory)}
                return try pipeline.shaders.map {url in
                    guard let bytes=try BoundedProfileFile.read(url,maximumBytes:VideoAssetContent.maximumBytes(.glsl)),
                          VideoAssetContent.checksum(bytes)==url.deletingPathExtension().lastPathComponent else {throw VideoAssetError.changedAsset}
                    try VideoAssetContent.validate(bytes,kind:.glsl)
                    return try VideoAssetContent.shaderDescription(bytes)
                }
            }.value
            guard Set(descriptions).count==descriptions.count else {throw VideoAssetError.invalidShader}
            if !isRestore {
                let oldPaths=activeAssets.shaders
                let oldDescriptions=try await Task.detached(priority:.userInitiated) {
                    try oldPaths.map {url -> String in
                        guard let bytes=try BoundedProfileFile.read(url,maximumBytes:VideoAssetContent.maximumBytes(.glsl)) else {throw VideoAssetError.changedAsset}
                        return try VideoAssetContent.shaderDescription(bytes)
                    }
                }.value
                // A cached pass with the same DESC cannot prove a different
                // source compiled. Reject that replacement rather than treating
                // an old pass as evidence for a new SHA-named file. Restore uses
                // the prior exact pipeline and is a separate owned transaction.
                for (i,name) in descriptions.enumerated() {
                    if let old=oldDescriptions.firstIndex(of:name),oldPaths[old] != pipeline.shaders[i] {
                        throw VideoAssetError.shaderNotConfirmed
                    }
                }
            }
        }
        func fresh() throws {
            guard !Task.isCancelled,!cancelled.contains(ticket),assetBinding==binding,
                  player.handle==handle,player.videoHost?.video.rendererIdentity==expectedRenderer,
                  player.settings.sanitized()==capturedSettings,
                  player.userVideoFilters.effectiveFragments==capturedUser,!player.videoConfigurationClosing else {throw VideoAssetError.staleTicket}
            if metalView != nil {
                guard player.string("vid")==capturedVideoSelection,
                      (player.jsonProperty("glsl-shader-opts") as? [String:Any])?.isEmpty==true else {throw VideoAssetError.staleTicket}
            }
        }
        // This getter is the existing .35s owned seek quiet/render barrier,
        // made internal by the exact hook. Its behavior is not copied/replaced.
        let changingDecoder=player.string("hwdec") != decoder
        while changingDecoder && (player.string("seeking") != "no" || !player.videoSeekBarrierReady(at:ProcessInfo.processInfo.systemUptime)) {
            try fresh()
            guard ProcessInfo.processInfo.systemUptime-began<1.5 else {throw VideoAssetError.applyFailed}
            try await Task.sleep(nanoseconds:150_000_000)
        }
        try fresh()
        if metalView != nil {
            guard (player.jsonProperty("glsl-shader-opts") as? [String:Any])?.isEmpty==true else {throw VideoAssetError.unsupportedRenderer}
        }
        let before=player.renderProgress.frames
        let nativeBeforeObject=(player.jsonProperty("vo-passes") as? [String:Any])?[nativeKey] as? [String:Any]
        let nativeBeforeProof=nativeBeforeObject.flatMap {try? VideoAssetNativeProof.parse($0,metal:metalView != nil)}
        let nativeBefore=nativeBeforeProof?.sequence
        if diagnosticEnabled {
            nativeDiagnostic("native-proof-before",native:nativeBeforeObject,beforeSequence:nativeBefore,
                pipeline:pipeline,descriptions:descriptions,shaders:player.jsonProperty("glsl-shaders") as? [String],
                filters:player.jsonProperty("vf") as? [[String:Any]],decoder:player.string("hwdec"),
                output:player.jsonProperty("video-out-params") as? [String:Any],drawable:nil,requestedAt:0,eventsEmpty:nil)
        }
        // Legacy engines retain their original update-frame gate only for an
        // empty shader pipeline. Unknown native proof cannot accept any GLSL.
        if (!pipeline.shaders.isEmpty || metalView != nil),nativeBefore==nil {throw VideoAssetError.unsupportedRenderer}
        var diagnosticSamples=0
        diagnostic("before-setters",["isRestore":isRestore,"beforeFrames":before,"paused":player.flag("pause"),"shaderCount":pipeline.shaders.count])
        let gpuStatus=try VideoAssetMPVNode.shaders(pipeline.shaders.map(\.path),handle:handle)
        guard gpuStatus>=0 else {throw VideoAssetError.applyFailed}
        // Each typed vf/hwdec status/readback is checked. Failure keeps a
        // negative result even when the old configured properties restore.
        guard player.executeManagedAssetVideoConfiguration(decoder:decoder,graph:graph,
            refreshVideo:changingDecoder && player.flag("seekable"))>=0 else {throw VideoAssetError.applyFailed}
        var requestedAt=ProcessInfo.processInfo.systemUptime
        guard player.videoHost?.video.requestConfigurationRedraw(ticket:ticket)==true else {throw VideoAssetError.applyFailed}
        while ProcessInfo.processInfo.systemUptime-began<3 {
            let eventsEmpty=player.drainCoreEventsToEmpty(expectedHandle:handle,maximum:512)
            try fresh()
            if firstFailure != nil {throw VideoAssetError.applyFailed}
            let actualShaders=player.jsonProperty("glsl-shaders") as? [String]
            let actualFilters=player.jsonProperty("vf") as? [[String:Any]]
            let configured=actualShaders==pipeline.shaders.map(\.path) && player.string("hwdec")==decoder
                && (graph.isEmpty ? actualFilters?.isEmpty==true : actualFilters?.count==1 && (actualFilters?.first?["params"] as? [String:Any])?["graph"] as? String==graph)
            let output=player.jsonProperty("video-out-params") as? [String:Any]
            let drawable:VideoAssetDrawableProof?
            if let metalView {drawable=metalView.configurationDrawable(ticket:ticket).map(VideoAssetDrawableProof.metal)}
            else {drawable=player.renderProgress.configurationDrawable(ticket:ticket).map(VideoAssetDrawableProof.openGL)}
            let drawableReady=drawable?.ready(ticket:ticket,renderer:expectedRenderer,requestedAt:requestedAt) ?? false
            let passes=player.jsonProperty("vo-passes") as? [String:Any]
            let freshPasses=passes?["fresh"] as? [[String:Any]]
            let actualDescriptions=freshPasses?.compactMap{$0["desc"] as? String} ?? []
            let nativeObject=passes?[nativeKey] as? [String:Any]
            let native=nativeObject.flatMap {try? VideoAssetNativeProof.parse($0,metal:metalView != nil)}
            if let nativeBefore,let native,
               native.hasCurrentRenderFailure(sequenceAfter:nativeBefore,paths:pipeline.shaders.map(\.path)) {
                firstFailure="原生视频管线报告当前着色器或资源渲染失败"
                nativeDiagnostic("native-proof-rejected",native:nativeObject,beforeSequence:nativeBefore,
                    pipeline:pipeline,descriptions:descriptions,shaders:actualShaders,filters:actualFilters,
                    decoder:player.string("hwdec"),output:output,drawable:drawable,
                    requestedAt:requestedAt,eventsEmpty:eventsEmpty)
                throw VideoAssetError.shaderNotConfirmed
            }
            let nativeEvidence=nativeBeforeProof.flatMap {old in
                native?.confirmed(after:old,paths:pipeline.shaders.map(\.path),descriptions:descriptions)
            }
            let legacyEmpty=metalView==nil && nativeBefore==nil && pipeline.shaders.isEmpty && nativeObject==nil
            let shaderReady=nativeEvidence != nil || legacyEmpty
            let outputReady=drawableReady && (output?["w"] as? Int ?? 0)>0 && (output?["h"] as? Int ?? 0)>0
                && (nativeEvidence != nil || (legacyEmpty && player.renderProgress.frames>before))
            if diagnosticEnabled,diagnosticSamples<24 {
                diagnosticSamples+=1
                nativeDiagnostic("native-proof-sample",native:nativeObject,beforeSequence:nativeBefore,
                    pipeline:pipeline,descriptions:descriptions,shaders:actualShaders,filters:actualFilters,
                    decoder:player.string("hwdec"),output:output,drawable:drawable,requestedAt:requestedAt,eventsEmpty:eventsEmpty)
                let statuses=["glsl-shaders":propertyStatus("glsl-shaders",handle:handle),
                    "vf":propertyStatus("vf",handle:handle),"video-out-params":propertyStatus("video-out-params",handle:handle),
                    "vo-passes":propertyStatus("vo-passes",handle:handle)]
                let redrawDescriptions=(passes?["redraw"] as? [[String:Any]])?.compactMap{$0["desc"] as? String} ?? []
                diagnostic("acceptance-sample",["configured":configured,"outputReady":outputReady,"shaderReady":shaderReady,
                    "beforeFrames":before,"frames":player.renderProgress.frames,"paused":player.flag("pause"),
                    "configuredShaderBasenames":(actualShaders ?? []).map{URL(fileURLWithPath:$0).lastPathComponent},
                    "shaderReadbackEqual":actualShaders==pipeline.shaders.map(\.path),"hwdec":player.string("hwdec"),
                    "vfCount":actualFilters?.count ?? -1,"outputWidth":output?["w"] ?? NSNull(),"outputHeight":output?["h"] ?? NSNull(),
                    "freshDescriptions":Array(actualDescriptions.prefix(64)).map{String($0.prefix(160))},
                    "redrawDescriptions":Array(redrawDescriptions.prefix(64)).map{String($0.prefix(160))},
                    "GETStatuses":statuses,"firstFailure":firstFailure ?? "","renderer":player.renderProgress.diagnosticsSnapshot])
            }
            if configured,outputReady,shaderReady,eventsEmpty {
                // Property/perfdata reads can enqueue diagnostics. Consume the
                // same handle after the final native proof read, then recheck
                // this exact media/context/request and every observed error.
                let finalShaders=player.jsonProperty("glsl-shaders") as? [String]
                let finalFilters=player.jsonProperty("vf") as? [[String:Any]]
                let finalOutput=player.jsonProperty("video-out-params") as? [String:Any]
                let finalNativeObject=(player.jsonProperty("vo-passes") as? [String:Any])?[nativeKey] as? [String:Any]
                let finalNative=finalNativeObject.flatMap {try? VideoAssetNativeProof.parse($0,metal:metalView != nil)}
                let finalEvidence=nativeBeforeProof.flatMap {old in
                    finalNative?.confirmed(after:old,paths:pipeline.shaders.map(\.path),descriptions:descriptions)
                }
                let finalDecoder=player.string("hwdec")
                let finalConfigured=finalShaders==pipeline.shaders.map(\.path) && finalDecoder==decoder
                    && (graph.isEmpty ? finalFilters?.isEmpty==true : finalFilters?.count==1
                        && (finalFilters?.first?["params"] as? [String:Any])?["graph"] as? String==graph)
                let finalOutputReady=(finalOutput?["w"] as? Int ?? 0)>0 && (finalOutput?["h"] as? Int ?? 0)>0
                let finalEventsEmpty=player.drainCoreEventsToEmpty(expectedHandle:handle,maximum:512)
                try fresh()
                if firstFailure != nil {throw VideoAssetError.applyFailed}
                if diagnosticEnabled {
                    nativeDiagnostic("native-proof-final",native:finalNativeObject,beforeSequence:nativeBefore,
                        pipeline:pipeline,descriptions:descriptions,shaders:finalShaders,filters:finalFilters,
                        decoder:finalDecoder,output:finalOutput,drawable:drawable,
                        requestedAt:requestedAt,eventsEmpty:finalEventsEmpty)
                }
                if finalConfigured,finalOutputReady,finalEventsEmpty,
                   finalEvidence != nil || (legacyEmpty && finalNativeObject==nil && player.renderProgress.frames>before) {
                    diagnostic("accept-after-native-proof-and-event-fence",["firstFailure":firstFailure ?? "",
                        "frames":player.renderProgress.frames,"nativeSequence":finalNative?.sequence ?? -1,
                        "nativeGeneration":finalNative?.generation ?? -1,"drawableSequence":drawable?.sequence ?? 0,
                        "eventsEmpty":finalEventsEmpty,"rendererID":expectedRenderer.uuidString])
                    evidence=finalEvidence ?? []
                    activeAssets=pipeline
                    return VideoAssetAcceptance(binding:binding,ticket:ticket,pipeline:pipeline,
                        configuredAndReadBack:true,producedVideoOutput:true,shadersConfirmed:true,shaderEvidence:evidence)
                }
            }
            // An intervening offscreen screenshot has its own native sequence;
            // request another actual display draw instead of accepting it.
            if drawableReady,native?.offscreen==true {
                let nextRequestedAt=ProcessInfo.processInfo.systemUptime
                if player.videoHost?.video.requestConfigurationRedraw(ticket:ticket)==true {requestedAt=nextRequestedAt}
            }
            try await Task.sleep(nanoseconds:150_000_000)
        }
        throw pipeline.shaders.isEmpty ? VideoAssetError.applyFailed : VideoAssetError.shaderNotConfirmed
    }
}
