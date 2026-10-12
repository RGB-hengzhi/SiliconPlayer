import Foundation
import PlayerCore

/// Same legal import subset and bounded reader as the resource store. A native
/// path/DESC receipt certifies dispatch, not the bytes; SHA bytes are verified
/// before the renderer transaction and the store retains its publication lease.
enum MetalManagedShaders {
    static func descriptions(paths: [String], directory: URL) throws -> [String] {
        guard paths.count <= 12, Set(paths).count == paths.count else { throw VideoAssetError.invalidShader }
        let root = directory.standardizedFileURL.path
        return try paths.map { path in
            let url = URL(fileURLWithPath: path)
            let digest = url.deletingPathExtension().lastPathComponent
            guard path.hasPrefix("/"), path.utf8.count <= 4096, url.standardizedFileURL.path == path,
                  url.deletingLastPathComponent().standardizedFileURL.path == root,
                  url.pathExtension == "glsl", digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let bytes = try BoundedProfileFile.read(url, maximumBytes: VideoAssetContent.maximumBytes(.glsl)),
                  VideoAssetContent.checksum(bytes) == digest else { throw VideoAssetError.changedAsset }
            try VideoAssetContent.validate(bytes, kind: .glsl)
            return try VideoAssetContent.shaderDescription(bytes)
        }
    }
}

/// MainActor-only permit, created after a bounded background source read.
/// The old synchronous initializer still refuses nonempty unprepared shaders.
@MainActor final class MetalShaderStartupPermit {
    fileprivate let playerID: ObjectIdentifier
    fileprivate let handle: OpaquePointer
    fileprivate let epoch: UUID
    fileprivate let token: UUID
    fileprivate let preferenceToken: UUID
    fileprivate let item: UUID?
    fileprivate let renderer: UUID?
    fileprivate let selectedVideo: String
    let paths: [String]
    let descriptions: [String]
    private var consumed = false
    fileprivate init(playerID: ObjectIdentifier, handle: OpaquePointer, epoch: UUID, token: UUID,
                     preferenceToken: UUID, item: UUID?, renderer: UUID?, selectedVideo: String, paths: [String], descriptions: [String]) {
        self.playerID=playerID;self.handle=handle;self.epoch=epoch;self.token=token
        self.preferenceToken=preferenceToken;self.item=item;self.renderer=renderer
        self.selectedVideo=selectedVideo;self.paths=paths;self.descriptions=descriptions
    }
    func consumeForCreation(_ player: PlayerModel) -> Bool {
        guard !consumed, matches(player), player.videoHost?.video.rendererIdentity == renderer else { return false }
        consumed = true; return true
    }
    func permitsPreparedCreation(_ player: PlayerModel) -> Bool { consumed && matches(player) }
    func matches(_ player: PlayerModel) -> Bool {
        ObjectIdentifier(player) == playerID && player.handle == handle
            && player.videoConfigurationEpoch == epoch && player.mediaPreferenceToken == token
            && player.mediaPreferences.token == preferenceToken && player.mediaPreferences.boundItemID == item
            && player.string("vid") == selectedVideo
            && !player.videoConfigurationClosing && !player.isLoading
            && player.jsonProperty("glsl-shaders") as? [String] == paths
            && (player.jsonProperty("glsl-shader-opts") as? [String: Any])?.isEmpty == true
    }
}

extension MPVVideoHost {
    /// Explicit candidate only; default production VideoSurface still uses GL.
    /// Preparation happens before replacing/closing the current renderer.
    @MainActor static func preparedMetalCandidate(player: PlayerModel, output: MetalOutputRequest) async throws -> MPVVideoHost? {
        guard let handle = player.handle, !player.videoConfigurationClosing, !player.isLoading,
              !player.videoAssets.isApplying, !player.profileRecoveryBlocked,
              let paths = player.jsonProperty("glsl-shaders") as? [String],
              (player.jsonProperty("glsl-shader-opts") as? [String: Any])?.isEmpty == true,
              paths.isEmpty || (player.loaded && player.mediaPreferences.boundItemID != nil
                  && player.mediaPreferences.token == player.mediaPreferenceToken) else { throw VideoAssetError.busy }
        let playerID = ObjectIdentifier(player), epoch = player.videoConfigurationEpoch
        let token = player.mediaPreferenceToken, preferenceToken = player.mediaPreferences.token
        let item = player.mediaPreferences.boundItemID, renderer = player.videoHost?.video.rendererIdentity
        let selectedVideo = player.string("vid")
        let directory = PlayerModel.supportDirectory.appendingPathComponent("video-assets", isDirectory: true)
        let descriptions = try await Task.detached(priority: .userInitiated) {
            try MetalManagedShaders.descriptions(paths: paths, directory: directory)
        }.value
        guard Set(descriptions).count == descriptions.count else { throw VideoAssetError.invalidShader }
        let permit = MetalShaderStartupPermit(playerID: playerID, handle: handle, epoch: epoch, token: token,
            preferenceToken: preferenceToken, item: item, renderer: renderer, selectedVideo: selectedVideo, paths: paths, descriptions: descriptions)
        guard !Task.isCancelled, permit.matches(player), !player.videoAssets.isApplying,
              !player.profileRecoveryBlocked, player.videoHost?.video.rendererIdentity == renderer else {
            throw VideoAssetError.staleTicket
        }
        return MPVVideoHost(player: player, backend: .metalCandidate(output: output), metalShaders: permit)
    }
}

enum VideoAssetNativeProof {
    case openGL(VideoPipelineValidation)
    case metal(GPUVideoPipelineValidation)
    var sequence: Int64 { pipeline.sequence }
    var generation: Int64 { pipeline.generation }
    var offscreen: Bool { pipeline.current.offscreen }
    private var pipeline: VideoPipelineValidation {
        switch self { case .openGL(let p): return p; case .metal(let p): return p.pipeline }
    }
    static func parse(_ object: [String: Any], metal: Bool) throws -> Self {
        metal ? .metal(try GPUVideoPipelineValidation.parse(object)) : .openGL(try VideoPipelineValidation.parse(object))
    }
    func hasCurrentRenderFailure(sequenceAfter before: Int64, paths: [String]) -> Bool {
        switch self {
        case .openGL(let p): return p.hasCurrentRenderFailure(sequenceAfter: before, paths: paths)
        case .metal(let p): return p.hasCurrentRenderFailure(sequenceAfter: before, paths: paths)
        }
    }
    func confirmed(after before: Self, paths: [String], descriptions: [String]) -> [String]? {
        switch (self, before) {
        case (.openGL(let p), .openGL(let old)):
            return p.confirmed(sequenceAfter: old.sequence, paths: paths, descriptions: descriptions)
        case (.metal(let p), .metal(let old)):
            return p.confirmed(after: old, paths: paths, descriptions: descriptions)
        default: return nil
        }
    }
}

enum VideoAssetDrawableProof {
    case openGL(VideoConfigurationDrawableReceipt)
    case metal(MetalShaderDrawableReceipt)
    var sequence: UInt64 {
        switch self { case .openGL(let p): return p.sequence; case .metal(let p): return p.attemptSequence }
    }
    func ready(ticket: UUID, renderer: UUID, requestedAt: TimeInterval) -> Bool {
        switch self {
        case .openGL(let p):
            return p.ticket == ticket && p.rendererID == renderer && p.status >= 0 && p.forced
                && p.width > 0 && p.height > 0 && p.completedAt >= requestedAt
        case .metal(let p): return p.matches(ticket: ticket, renderer: renderer, requestedAfter: requestedAt)
        }
    }
    var diagnostics: [String: Any] {
        switch self {
        case .openGL(let p):
            return ["ticket":p.ticket.uuidString,"rendererID":p.rendererID.uuidString,"sequence":p.sequence,
                "status":p.status,"width":p.width,"height":p.height,"updateFlags":p.updateFlags,
                "forced":p.forced,"completedAt":p.completedAt]
        case .metal(let p):
            return ["backend":"metal","ticket":p.ticket.uuidString,"rendererID":p.rendererID.uuidString,
                "attemptSequence":p.attemptSequence,"acquisitionSequence":p.acquisitionSequence,
                "width":p.width,"height":p.height,"updateFlags":p.updateFlags,"requestedAt":p.requestedAt,
                "apiReturnedAt":p.apiReturnedAt,"reportedSwapAt":p.reportedSwapAt,
                "callbackObservedAt":p.callbackObservedAt,"presentedTime":p.presentedTime]
        }
    }
}
