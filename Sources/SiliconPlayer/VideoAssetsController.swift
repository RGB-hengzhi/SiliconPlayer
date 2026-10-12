import Foundation
import Combine
import PlayerCore

struct VideoAssetPlaybackBinding: Equatable, Sendable {
    let coreID: UUID
    let mediaEpoch: UUID
    let loadedItemID: UUID
    let loadToken: UUID
}
struct VideoAssetPipeline: Equatable, Sendable {
    let shaders: [URL]       // Literal NODE_ARRAY, never a colon-joined string.
    let lutGraphs: [String]  // Append after the existing CPU user-filter chain.
}
struct VideoAssetAcceptance: Sendable {
    let binding: VideoAssetPlaybackBinding
    let ticket: UUID
    let pipeline: VideoAssetPipeline
    let configuredAndReadBack: Bool
    let producedVideoOutput: Bool
    let shadersConfirmed: Bool
    // Actual observation identifiers, not values made up by this controller.
    let shaderEvidence: [String]
}
enum VideoAssetActivity: Equatable { case ready, checking, active, suspended, closing }

/// Engine implementation remains a separate integration/review boundary.
/// It must use one shared video-config arbiter for existing user filters and
/// assets; renderer success cannot be inferred from property setters alone.
@MainActor protocol VideoAssetRuntime: AnyObject {
    var assetBinding: VideoAssetPlaybackBinding? {get}
    var activeAssets: VideoAssetPipeline {get}
    func applyAssets(_ pipeline: VideoAssetPipeline, binding: VideoAssetPlaybackBinding,
                     ticket: UUID) async throws -> VideoAssetAcceptance
    func applyProfileAssets(_ pipeline: VideoAssetPipeline, settings:PlaybackSettings,
                            userFragments:[String],binding:VideoAssetPlaybackBinding,
                            ticket:UUID) async throws -> VideoAssetAcceptance
    func restoreAssets(_ pipeline: VideoAssetPipeline, binding: VideoAssetPlaybackBinding,
                       ticket: UUID) async throws -> VideoAssetAcceptance
    func cancelAssets(ticket: UUID)
    func suspendAssetsForCurrentMedia()
}

// Existing injected runtimes cannot accidentally certify a newly added API.
// Real adapter explicitly implements this full-profile candidate path.
extension VideoAssetRuntime {
    func applyProfileAssets(_ pipeline:VideoAssetPipeline,settings:PlaybackSettings,
                            userFragments:[String],binding:VideoAssetPlaybackBinding,
                            ticket:UUID) async throws -> VideoAssetAcceptance {
        throw VideoAssetError.unsupportedRenderer
    }
}

@MainActor final class VideoAssetsController: ObservableObject {
    @Published private(set) var document=VideoAssetDocument()
    @Published private(set) var activity=VideoAssetActivity.ready
    @Published private(set) var message: String?
    @Published private(set) var loaded=false
    private let store: VideoAssetStore
    private weak var runtime: (any VideoAssetRuntime)?
    private var work: Task<Void,Never>? {willSet {objectWillChange.send()}}
    private var generation=UUID()
    private var activeTicket: UUID?
    private var closing=false
    private var profileImport:Task<ProfileImportOutcome,Error>? {willSet {objectWillChange.send()}}
    private var profileExport:Task<VideoAssetPortableBundle,Error>? {willSet {objectWillChange.send()}}
    var hasActiveJobs: Bool {work != nil || profileImport != nil || profileExport != nil}
    init(store: VideoAssetStore,runtime: any VideoAssetRuntime) {self.store=store;self.runtime=runtime}

    func load() {
        guard !hasActiveJobs,!closing else {return}
        let token=UUID();generation=token;activity = .checking
        work=Task { [weak self] in
            guard let self else {return}
            do {
                let value=try await store.loadVerified()
                guard generation==token,!closing else {throw VideoAssetError.staleTicket}
                document=value;loaded=true;activity = .ready;message=nil
                // Loading preferences does not assert renderer acceptance.
            } catch {if generation==token && !closing {activity = .suspended;message="视频资源读取失败，现有设置未覆盖"}}
            work=nil
        }
    }
    func importFile(_ url: URL) {
        mutate { [store] lease in
            let entry=try await store.importFile(url,lease:lease)
            var next=lease.document
            if !next.entries.contains(where:{$0.basename==entry.basename}) {next.entries.append(entry)}
            return next
        }
    }
    func importArchive(_ url: URL) {
        mutate { [store] lease in
            let bundle=try await Task.detached(priority:.userInitiated) {try VideoAssetStore.readPortable(url)}.value
            // Validate the full payload before any resource publication.
            try await store.stageRestore(bundle,lease:lease)
            return bundle.document
        }
    }
    func exportArchive(_ url: URL) {
        guard !hasActiveJobs,!closing,loaded else {message="资源仍在读取或验证，请稍后重试";return}
        let token=UUID();generation=token;activity = .checking;message=nil
        work=Task { [weak self] in
            guard let self else {return}
            do {
                let bundle=try await store.exportSnapshot()
                let directory=await store.directory
                guard generation==token,!closing,!Task.isCancelled else {throw VideoAssetError.staleTicket}
                try await Task.detached(priority:.userInitiated) {
                    try VideoAssetStore.writePortable(bundle,to:url,managedDirectory:directory)
                }.value
                if generation==token,!closing {activity = .ready;message="已导出包含完整资源的迁移包"}
            } catch {if generation==token,!closing {activity = .suspended;message="资源包未导出，原目标已保留"}}
            work=nil
        }
    }
    func snapshotForProfile() async throws -> VideoAssetPortableBundle {
        guard loaded,!hasActiveJobs,!closing else {throw VideoAssetError.busy}
        let task=Task { @MainActor [self] in
            defer {profileExport=nil};return try await store.exportSnapshot()
        };profileExport=task
        return try await task.value
    }
    /// The complete import owns the real lease through staged runtime acceptance
    /// and the original profile journal. Disk committed truth is adopted once.
    func importProfile(_ backup:UserProfileBackupDocument,
                       commit:@escaping @MainActor (Data?,@escaping @Sendable (Data?) async throws -> Void,@escaping @MainActor () -> Bool) async throws -> ProfileImportOutcome) async throws -> ProfileImportOutcome {
        guard loaded,!hasActiveJobs,!closing,let runtime else {throw VideoAssetError.busy}
        let token=UUID();generation=token;activeTicket=token;activity = .checking
        let task=Task { @MainActor [self,weak runtime] () throws -> ProfileImportOutcome in
            defer {profileImport=nil;activeTicket=nil}
            guard let runtime else {throw VideoAssetError.staleTicket}
            var lease:VideoAssetLease?,previous:VideoAssetPipeline?,binding:VideoAssetPlaybackBinding?
            var touched=false,committed=false
            do {
                let owned=try await store.begin();lease=owned
                if let bundle=backup.videoAssets {try await store.stageRestore(bundle,lease:owned)}
                let candidate=backup.videoAssets?.document ?? owned.document
                let oldManifest=try await store.manifestBytes(lease:owned)
                let urls=try await store.verifiedURLs(candidate,lease:owned)
                let next=try Self.pipeline(candidate,urls:urls)
                previous=runtime.activeAssets;binding=runtime.assetBinding
                let fragments=try backup.filters.lavfiFragments()
                guard generation==token,!closing,!Task.isCancelled else {throw VideoAssetError.staleTicket}
                if let current=binding {
                    touched=true
                    let receipt=try await runtime.applyProfileAssets(next,settings:backup.global,
                        userFragments:fragments,binding:current,ticket:token)
                    guard generation==token,runtime.assetBinding==current,!closing,!Task.isCancelled else {throw VideoAssetError.staleTicket}
                    try Self.validate(receipt,pipeline:next,binding:current,ticket:token)
                } else if !next.shaders.isEmpty || !next.lutGraphs.isEmpty {
                    // No rendered media cannot certify newly enabled resources.
                    throw VideoAssetError.unsupportedRenderer
                }
                guard generation==token,!closing,!Task.isCancelled else {throw VideoAssetError.staleTicket}
                _=try await store.verifiedURLs(candidate,lease:owned)
                _=try await store.manifestBytes(lease:owned)
                guard generation==token,!closing,!Task.isCancelled else {throw VideoAssetError.staleTicket}
                let outcome=try await commit(oldManifest,{[store] bytes in try await store.publishProfileManifest(bytes,lease:owned)},
                    {[weak self,weak runtime] in
                        guard let self,let runtime else {return false}
                        return self.generation==token && !self.closing && !Task.isCancelled
                            && runtime.assetBinding==binding && (binding==nil || runtime.activeAssets==next)
                    })
                committed=true;document=candidate
                await store.end(owned);lease=nil
                if !closing {activity = next.shaders.isEmpty && next.lutGraphs.isEmpty ? .ready : .active}
                return outcome
            } catch {
                // Committed disk truth is never undone due to UI cancellation.
                if !committed,touched,let previous,let binding,generation==token,
                   runtime.assetBinding==binding,!closing {
                    do {
                        let restoreTicket=UUID()
                        let receipt=try await Task { @MainActor in
                            guard runtime.assetBinding==binding else {throw VideoAssetError.staleTicket}
                            return try await runtime.restoreAssets(previous,binding:binding,ticket:restoreTicket)
                        }.value
                        guard generation==token,runtime.assetBinding==binding,!closing else {throw VideoAssetError.staleTicket}
                        try Self.validate(receipt,pipeline:previous,binding:binding,ticket:restoreTicket)
                    } catch {runtime.suspendAssetsForCurrentMedia()}
                }
                if let lease {await store.end(lease)}
                activity = .suspended
                throw error
            }
        }
        profileImport=task
        return try await task.value
    }
    func requireSeparateProfileArchive() throws {
        guard loaded,!hasActiveJobs,!closing else {throw VideoAssetError.busy}
        guard document.entries.isEmpty else {throw VideoAssetError.separateResourceArchiveRequired}
    }
    func enabled(_ id: UUID,_ value: Bool) {
        mutate {lease in var next=lease.document;try next.setEnabled(id,value);return next}
    }
    func move(_ id: UUID,before target: UUID?) {
        mutate {lease in var next=lease.document;try next.move(id,before:target);return next}
    }
    func remove(_ id: UUID) {
        mutate {lease in
            guard lease.document.entries.contains(where:{$0.id==id}) else {throw VideoAssetError.unknownAsset}
            return VideoAssetDocument(entries:lease.document.entries.filter{$0.id != id})
        }
    }
    func reapplySavedForCurrentMedia() {
        guard AppCapabilities.current.profile == .full else {return}
        mutate {lease in lease.document}
    }
    func waitForIdle() async {
        await work?.value
        _=try? await profileImport?.value
        _=try? await profileExport?.value
    }
    func contextEnded() {
        // Initial disk-only preference loading has no media ticket. A START or
        // FILE_LOADED race must not cancel it and strand `loaded == false`.
        if !loaded && !closing {return}
        generation=UUID()
        if let activeTicket {runtime?.cancelAssets(ticket:activeTicket)}
        activeTicket=nil;work?.cancel();profileImport?.cancel();profileExport?.cancel()
        // Keep `work` until its actual lease/rollback cleanup completes.
        // Do not rollback an old epoch into a new media or closed core.
        activity = closing ? .closing : .suspended
    }
    func cancelRequest() {
        // UI cancellation within this media keeps the generation so the task
        // can strongly restore its previous pipeline before releasing a lease.
        if let activeTicket {runtime?.cancelAssets(ticket:activeTicket)}
        work?.cancel();profileImport?.cancel();profileExport?.cancel()
    }
    func beginTermination() {closing=true;contextEnded();activity = .closing}
    func shutdown() async -> Bool {
        beginTermination()
        await waitForIdle()
        return !hasActiveJobs
    }
    func resumeAfterCancelledTermination() {
        guard !hasActiveJobs else {return};closing=false;activity = .ready
    }
    private func mutate(_ change: @escaping @Sendable (VideoAssetLease) async throws -> VideoAssetDocument) {
        guard loaded,!hasActiveJobs,!closing,let runtime else {message="资源仍在读取或另一个视频配置正在验证，请稍后重试";return}
        let token=UUID();generation=token;activeTicket=token;activity = .checking;message=nil
        work=Task { [weak self,weak runtime] in
            guard let self else {return}
            guard let runtime else {work=nil;activeTicket=nil;activity = .suspended;return}
            var lease:VideoAssetLease?,previous:VideoAssetPipeline?,binding:VideoAssetPlaybackBinding?
            var touchedRuntime=false
            do {
                let owned=try await store.begin();lease=owned
                let candidate=try await change(owned)
                _=try candidate.validated()
                _=try await store.verifiedURLs(owned.document,lease:owned)
                let afterURLs=try await store.verifiedURLs(candidate,lease:owned)
                let old=runtime.activeAssets
                let next=try Self.pipeline(candidate,urls:afterURLs)
                previous=old;binding=runtime.assetBinding
                guard generation==token,!closing,!Task.isCancelled else {throw VideoAssetError.staleTicket}
                if next != old {
                    guard let current=binding else {throw VideoAssetError.unsupportedRenderer}
                    touchedRuntime=true
                    let receipt=try await runtime.applyAssets(next,binding:current,ticket:token)
                    guard generation==token,runtime.assetBinding==current,!closing,!Task.isCancelled else {throw VideoAssetError.staleTicket}
                    try Self.validate(receipt,pipeline:next,binding:current,ticket:token)
                }
                guard generation==token,!closing,!Task.isCancelled else {throw VideoAssetError.staleTicket}
                try await store.commit(candidate,lease:owned)
                // Commit is the last fallible mutation. It may have finished
                // while UI cancellation queued, so adopt committed disk truth
                // without claiming this media is still rendered/active.
                document=candidate
                if generation==token,!closing {activity=next.shaders.isEmpty && next.lutGraphs.isEmpty ? .ready : .active}
            } catch {
                var restored = !touchedRuntime
                if touchedRuntime,let previous,let binding,generation==token,
                   runtime.assetBinding==binding,!closing {
                    do {
                        let restoreTicket=UUID()
                        // Independent owned restoration is not cancelled merely
                        // because the candidate task was cancelled by the UI.
                        let r=try await Task { @MainActor in
                            guard runtime.assetBinding==binding else {throw VideoAssetError.staleTicket}
                            return try await runtime.restoreAssets(previous,binding:binding,ticket:restoreTicket)
                        }.value
                        guard generation==token,runtime.assetBinding==binding,!closing else {throw VideoAssetError.staleTicket}
                        try Self.validate(r,pipeline:previous,binding:binding,ticket:restoreTicket)
                        restored=true
                    } catch {restored=false}
                }
                if generation==token,!closing {
                    if !restored {runtime.suspendAssetsForCurrentMedia()}
                    activity = .suspended
                    message=restored ? "资源未能生效，原资源顺序与设置已保留" : "资源验证和恢复失败，本媒体已暂时停用资源；保存设置未覆盖"
                }
            }
            if let lease {await store.end(lease)}
            // One task at a time; clear actual work even after generation was
            // invalidated. Clearing a ticket alone was never resource release.
            work=nil;activeTicket=nil
        }
    }
    private static func pipeline(_ document: VideoAssetDocument,urls: [UUID:URL]) throws -> VideoAssetPipeline {
        // Preserve verified resource documents and profile archives for the
        // full edition; core imports do not activate these runtime resources.
        guard AppCapabilities.current.profile == .full else {
            return VideoAssetPipeline(shaders:[],lutGraphs:[])
        }
        let shaders=try document.enabled(.glsl).map {entry -> URL in
            guard let url=urls[entry.id] else {throw VideoAssetError.changedAsset};return url
        }
        let graphs=try document.enabled(.cube).map {entry -> String in
            guard let url=urls[entry.id] else {throw VideoAssetError.changedAsset};return try VideoAssetGraph.lut3d(path:url.path)
        }
        return VideoAssetPipeline(shaders:shaders,lutGraphs:graphs)
    }
    private static func validate(_ receipt:VideoAssetAcceptance,pipeline:VideoAssetPipeline,
                                 binding:VideoAssetPlaybackBinding,ticket:UUID) throws {
        guard receipt.ticket==ticket,receipt.binding==binding,receipt.pipeline==pipeline,
              receipt.configuredAndReadBack,receipt.producedVideoOutput else {throw VideoAssetError.applyFailed}
        guard pipeline.shaders.isEmpty || (receipt.shadersConfirmed && !receipt.shaderEvidence.isEmpty) else {
            throw VideoAssetError.shaderNotConfirmed
        }
    }
}
