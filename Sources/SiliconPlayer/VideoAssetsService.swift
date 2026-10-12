import Foundation
import AppKit
import PlayerCore
import CMPV

@MainActor final class VideoAssetsService {
    private final class Weak {weak var value:VideoAssetsService?;init(_ value:VideoAssetsService){self.value=value}}
    private static var registry:[UUID:Weak]=[:]
    private let id=UUID()
    private let adapter:VideoAssetsEngineAdapter
    private let presenter=VideoAssetsPanelPresenter()
    private var controller:VideoAssetsController?
    private var startup:Task<Void,Never>?
    private var reapplication:Task<Void,Never>?
    private var pendingReapply:VideoAssetPlaybackBinding?
    private var closing=false
    private var startupError:String?
    var isApplying:Bool {startup != nil || reapplication != nil || controller?.hasActiveJobs==true}
    var isExecutingConfiguration:Bool {adapter.isConfiguring}
    var effectiveLUTFragments:[String] {AppCapabilities.current.profile == .full ? adapter.activeAssets.lutGraphs : []}
    var hasEnabledRuntimeAssets:Bool {AppCapabilities.current.profile == .full && (!adapter.activeAssets.shaders.isEmpty || !adapter.activeAssets.lutGraphs.isEmpty)}
    static var hasActiveJobs:Bool {registry.values.contains{$0.value?.isApplying==true}}
    init(player:PlayerModel,directory:URL) {
        adapter=VideoAssetsEngineAdapter(player:player)
        Self.registry=Self.registry.filter{$0.value.value != nil}
        Self.registry[id]=Weak(self)
        startup=Task { [weak self] in
            guard let self else {return}
            defer {startup=nil}
            do {
                let store=try await Task.detached(priority:.userInitiated) {try VideoAssetStore(directory:directory)}.value
                guard !closing,!Task.isCancelled else {return}
                let owner=VideoAssetsController(store:store,runtime:adapter)
                controller=owner;owner.load();await owner.waitForIdle()
                // FILE_LOADED may have occurred while the background store
                // opened. Reapply only a still-current actual loaded binding.
                if AppCapabilities.current.profile == .full,!closing,!Task.isCancelled,adapter.assetBinding != nil,owner.loaded {
                    owner.reapplySavedForCurrentMedia();await owner.waitForIdle()
                }
            } catch {startupError="视频资源库无法读取；现有偏好未覆盖"}
        }
    }
    func showPanel(parent:NSWindow?) {
        guard AppCapabilities.current.profile == .full,!closing,let parent,parent.attachedSheet==nil else {return}
        guard let controller,controller.loaded else {
            let alert=NSAlert();alert.messageText=startupError ?? "视频资源仍在读取，请稍后重试"
            alert.beginSheetModal(for:parent);return
        }
        presenter.show(controller:controller,parent:parent)
    }
    func mediaWillChange() {pendingReapply=nil;controller?.contextEnded();adapter.contextEnded()}
    func mediaLoaded() {
        guard AppCapabilities.current.profile == .full,!closing,let controller,let binding=adapter.assetBinding else {return}
        pendingReapply=binding
        guard reapplication==nil else {return}
        reapplication=Task { [weak self] in
            guard let self else {return}
            defer {reapplication=nil}
            while !closing,!Task.isCancelled,let next=pendingReapply {
                pendingReapply=nil
                await controller.waitForIdle()
                guard !closing,!Task.isCancelled else {return}
                guard adapter.assetBinding==next else {continue}
                controller.reapplySavedForCurrentMedia();await controller.waitForIdle()
            }
        }
    }
    func observeLog(prefix:String,level:String,message:String) {adapter.observeLog(prefix:prefix,level:level,message:message)}
    private func profileOwner() async throws -> VideoAssetsController {
        // Await initialization itself only. Startup never calls profile export,
        // so a lazy profileBackup accessor cannot recursively await this path.
        await startup?.value
        guard !closing,reapplication==nil,let controller,controller.loaded,
              !controller.hasActiveJobs else {throw VideoAssetError.busy}
        return controller
    }
    func snapshotForProfile() async throws -> VideoAssetPortableBundle {
        let owner=try await profileOwner();return try await owner.snapshotForProfile()
    }
    func importProfile(_ backup:UserProfileBackupDocument,
                       commit:@escaping @MainActor (Data?,@escaping @Sendable (Data?) async throws -> Void,@escaping @MainActor () -> Bool) async throws -> ProfileImportOutcome) async throws -> ProfileImportOutcome {
        let owner=try await profileOwner();return try await owner.importProfile(backup,commit:commit)
    }
    func requireSeparateProfileArchive() throws {
        guard startup==nil,let controller else {throw VideoAssetError.busy}
        try controller.requireSeparateProfileArchive()
    }
    func beginTermination() {closing=true;pendingReapply=nil;startup?.cancel();reapplication?.cancel();controller?.beginTermination()}
    func shutdown() async -> Bool {
        beginTermination()
        await startup?.value
        await reapplication?.value
        let ended=await controller?.shutdown() ?? true
        return ended && startup==nil && reapplication==nil && controller?.hasActiveJobs != true
    }
    func resumeAfterCancelledTermination() {
        guard startup==nil,reapplication==nil,controller?.hasActiveJobs != true else {return}
        closing=false;controller?.resumeAfterCancelledTermination()
    }
    static func shutdownAll() async -> Bool {
        let owners=registry.values.compactMap(\.value)
        // Close all acceptance gates before awaiting even the first owner.
        for owner in owners {owner.beginTermination()}
        var complete=true
        for owner in owners {if !(await owner.shutdown()) {complete=false}}
        return complete
    }
}

extension PlayerModel {
    func showVideoAssetsPanel() {videoAssets.showPanel(parent:NSApp.keyWindow?.sheetParent ?? NSApp.mainWindow)}
    /// For the existing filter dispatcher, empty asset graphs preserve its
    /// original string batch byte behavior. Only resource graphs use typed vf.
    func executeManagedAssetVideoConfiguration(decoder:String,graph:String,refreshVideo:Bool) -> Int32 {
        guard let handle,!videoConfigurationClosing else {return MPV_ERROR_UNINITIALIZED.rawValue}
        var oldVF=mpv_node()
        guard mpv_get_property(handle,"vf",MPV_FORMAT_NODE,&oldVF)>=0 else {return MPV_ERROR_PROPERTY_ERROR.rawValue}
        defer {mpv_free_node_contents(&oldVF)}
        let oldHW=string("hwdec"),oldJSON=jsonProperty("vf")
        guard !oldHW.isEmpty,oldJSON != nil else {return MPV_ERROR_PROPERTY_ERROR.rawValue}
        func rollback() {
            // Configured-property best effort only. No claim to undo derived
            // decoder/seek state or to make a failed candidate pass.
            _=mpv_set_property(handle,"vf",MPV_FORMAT_NODE,&oldVF)
            _=executeCheckedPropertyBatch([("hwdec",oldHW)])
            if string("hwdec") != oldHW || !Self.sameVideoAssetJSON(jsonProperty("vf"),oldJSON) {
                videoFilterFailure="视频资源配置失败，旧滤镜配置未能完整恢复"
            }
        }
        do {
            let status:Int32
            if graph.isEmpty {
                status=try VideoAssetMPVNode.lavfi("",handle:handle)
                guard status>=0 else {rollback();return status}
                let hw=executeCheckedPropertyBatch([("hwdec",decoder)])
                guard hw>=0 else {rollback();return hw}
            } else {
                let hw=executeCheckedPropertyBatch([("hwdec",decoder)])
                guard hw>=0 else {rollback();return hw}
                status=try VideoAssetMPVNode.lavfi(graph,handle:handle)
                guard status>=0 else {rollback();return status}
            }
            let rows=jsonProperty("vf") as? [[String:Any]]
            guard string("hwdec")==decoder,
                  (graph.isEmpty ? rows?.isEmpty==true : rows?.count==1 && (rows?.first?["params"] as? [String:Any])?["graph"] as? String==graph) else {rollback();return MPV_ERROR_PROPERTY_ERROR.rawValue}
            if refreshVideo {
                let refresh=executeCommand(["seek","0","relative+exact"])
                if refresh<0 {rollback()}
                return refresh
            }
            return 0
        } catch {rollback();return MPV_ERROR_INVALID_PARAMETER.rawValue}
    }
    private static func sameVideoAssetJSON(_ lhs:Any?,_ rhs:Any?) -> Bool {
        guard let lhs,let rhs,
              let a=try? JSONSerialization.data(withJSONObject:lhs,options:[.sortedKeys]),
              let b=try? JSONSerialization.data(withJSONObject:rhs,options:[.sortedKeys]) else {return false}
        return a==b
    }
}
