import AppKit
import Metal
import QuartzCore
import CMPV
import PlayerCore
import MetalRenderBridge

struct MetalViewCreationError: LocalizedError {
    let message: String
    let canFallbackToGL: Bool
    var errorDescription: String? { message }
}

/// Shares the original PlayerModel/core and PiP child identity. It does not own
/// media loading, seek, user subtitle selection, or a second player instance.
final class MPVMetalVideoView: NSView, MPVVideoDisplay {
    private let player: PlayerModel
    private let output: MetalOutputLease
    private let metalLayer: CAMetalLayer
    private var session: SPMetalSessionRef?
    private var rendererClosed = false
    private var readyReported = false
    private var startupShaderValidationPending = false
    private var baseSettingsUpdateInProgress = false
    private var configurationTicket: UUID?
    private var singleClick: DispatchWorkItem?
    private(set) var finalMetalDiagnostics: [String: Any]?

    init(player: PlayerModel, output request: MetalOutputRequest, shaderPermit: MetalShaderStartupPermit? = nil) throws {
        self.player = player
        let lease = try MetalRenderOwnership.reserve(player: player, request: request)
        output = lease
        guard let handle = player.handle, let device = MTLCreateSystemDefaultDevice() else {
            let restored = MetalRenderOwnership.release(lease)
            throw MetalViewCreationError(message: "Metal 设备或播放核心不可用", canFallbackToGL: restored)
        }
        metalLayer = SPMetalMakeObservedLayer(device)
        super.init(frame: .zero)
        wantsLayer = true; layer = metalLayer
        registerForDraggedTypes([.fileURL, .URL])
        guard let shaderPaths = player.jsonProperty("glsl-shaders") as? [String],
              (shaderPaths.isEmpty || shaderPermit?.permitsPreparedCreation(player) == true),
              (player.jsonProperty("glsl-shader-opts") as? [String: Any])?.isEmpty == true,
              ["no", "videotoolbox-copy", "videotoolbox"].contains(player.string("hwdec")) else {
            let restored = MetalRenderOwnership.release(output)
            throw MetalViewCreationError(message: "当前着色器或硬件解码设置需使用 OpenGL", canFallbackToGL: restored)
        }
        startupShaderValidationPending = !shaderPaths.isEmpty
        guard output.reconcile() else {
            let restored = MetalRenderOwnership.release(output)
            throw MetalViewCreationError(message: output.firstError ?? "Metal 色彩初始化未确认", canFallbackToGL: restored)
        }
        var status: Int32 = MPV_ERROR_UNINITIALIZED.rawValue
        session = SPMetalSessionCreate(UnsafeMutableRawPointer(handle), metalLayer, &status)
        guard session != nil else {
            let restored = MetalRenderOwnership.release(output)
            throw MetalViewCreationError(message: "Metal 渲染上下文创建失败：\(String(cString: mpv_error_string(status)))",
                                         canFallbackToGL: restored)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    var outputLeaseIdentity: UUID { output.identity }
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !rendererClosed, !readyReported {
            readyReported = true; player.rendererDidBecomeReady()
            if startupShaderValidationPending {
                startupShaderValidationPending = false
                // Reuse the store's owned runtime/readback/manifest lease once
                // the new context has an actual positive-size attached view.
                player.videoAssets.mediaLoaded()
            }
        }
        requestRedraw()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); requestRedraw() }
    override func layout() { super.layout(); requestRedraw() }
    override func draw(_ dirtyRect: NSRect) { requestRedraw() }
    var rendererIdentity: UUID? {
        guard let session else { return nil }
        return UUID(uuidString: SPMetalSessionIdentity(session).uuidString)
    }
    var metalDiagnostics: [String: Any] {
        let render = session.flatMap { SPMetalSessionDiagnostics($0) as? [String: Any] } ?? finalMetalDiagnostics ?? [:]
        let screen = window?.screen
        return ["render": render, "color": output.diagnostics,
                "viewAttached": window != nil, "viewIdentity": String(describing: ObjectIdentifier(self)),
                "layerIdentity": String(describing: ObjectIdentifier(metalLayer)),
                "screenNumber": screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as Any? ?? NSNull(),
                "currentHeadroom": screen?.maximumExtendedDynamicRangeColorComponentValue as Any? ?? NSNull(),
                "potentialHeadroom": screen?.maximumPotentialExtendedDynamicRangeColorComponentValue as Any? ?? NSNull(),
                "referenceHeadroom": screen?.maximumReferenceExtendedDynamicRangeColorComponentValue as Any? ?? NSNull(),
                "observedAt": ProcessInfo.processInfo.systemUptime,
                "physicalHDRClaim": false, "zeroCopyClaim": false]
    }
    func requestRedraw() {
        guard !rendererClosed, !baseSettingsUpdateInProgress, let session else { return }
        // This MainActor transaction never runs inside a libmpv callback.
        guard SPMetalSessionBeginConfiguration(session) else { return }
        let colorsConfirmed = output.reconcile()
        SPMetalSessionEndConfiguration(session)
        if !colorsConfirmed { player.error = output.firstError; return }
        let size = window == nil ? CGSize.zero : convertToBacking(bounds).size
        let pixels = CGSize(width: ceil(size.width), height: ceil(size.height))
        let scale = window?.backingScaleFactor ?? 1
        _ = SPMetalSessionRequest(session, pixels, scale, true, nil)
    }
    /// Uses the real Metal render request; no GL RenderProgress completion is
    /// synthesized. Late callbacks are usable only by the still-owned ticket.
    func requestConfigurationRedraw(ticket: UUID) -> Bool {
        guard configurationTicket == nil || configurationTicket == ticket else { return false }
        guard requestMetalRedraw(ticket: ticket) else { return false }
        configurationTicket = ticket
        return true
    }
    func retireConfigurationRedraw(ticket: UUID) {
        if configurationTicket == ticket { configurationTicket = nil }
    }
    func configurationDrawable(ticket: UUID) -> MetalShaderDrawableReceipt? {
        guard configurationTicket == ticket, !rendererClosed, let session,
              let object = SPMetalSessionDiagnostics(session) as? [String: Any],
              object["schema"] as? String == "siliconplayer.metal-consumer.v1",
              object["closed"] as? Bool == false, object["closing"] as? Bool == false,
              let rows = object["drawables"] as? [[String: Any]], rows.count <= 128 else { return nil }
        return rows.reversed().compactMap { try? MetalShaderDrawableReceipt.parse($0) }
            .first { $0.ticket == ticket && $0.rendererID == rendererIdentity }
    }
    /// Separate Metal ticket for its own numerical/lifecycle verifier, never a GL ticket.
    @discardableResult func requestMetalRedraw(ticket: UUID) -> Bool {
        guard window != nil, !rendererClosed, let session else { return false }
        guard SPMetalSessionBeginConfiguration(session) else { return false }
        defer { SPMetalSessionEndConfiguration(session) }
        guard output.reconcile() else { player.error = output.firstError; return false }
        let size = convertToBacking(bounds).size
        return SPMetalSessionRequest(session, .init(width: ceil(size.width), height: ceil(size.height)),
                                     window?.backingScaleFactor ?? 1, true, ticket)
    }
    func prepareForSurfaceMove() {
        guard !rendererClosed, let session else { return }
        _ = SPMetalSessionRequest(session, .zero, window?.backingScaleFactor ?? 1, true, nil)
    }
    func beginBaseSettingsUpdate() -> Bool {
        guard !rendererClosed, !baseSettingsUpdateInProgress, let session,
              SPMetalSessionBeginConfiguration(session) else { return false }
        baseSettingsUpdateInProgress = true; return true
    }
    func endBaseSettingsUpdate() {
        guard baseSettingsUpdateInProgress, let session else { return }
        let confirmed = output.reconcile()
        baseSettingsUpdateInProgress = false
        if confirmed {
            let size = window == nil ? CGSize.zero : convertToBacking(bounds).size
            _ = SPMetalSessionRequest(session, .init(width: ceil(size.width), height: ceil(size.height)),
                                     window?.backingScaleFactor ?? 1, true, nil)
        } else { player.error = output.firstError }
        SPMetalSessionEndConfiguration(session)
    }
    @discardableResult func closeRenderer() -> Bool {
        guard !rendererClosed else { return true }
        configurationTicket = nil
        singleClick?.cancel()
        if let session {
            guard SPMetalSessionClose(session) else { return false }
            finalMetalDiagnostics = SPMetalSessionDiagnostics(session) as? [String: Any]
            SPMetalSessionDestroy(session); self.session = nil
        }
        guard MetalRenderOwnership.release(output) else { player.error = output.firstError; return false }
        rendererClosed = true; return true
    }
    override func mouseDown(with event: NSEvent) {
        singleClick?.cancel(); window?.makeFirstResponder(self)
        if event.clickCount == 2 { window?.toggleFullScreen(nil); return }
        if AppCapabilities.current.profile == .full && player.settings.processing.projection != "off" { return }
        let click = DispatchWorkItem { [weak self] in self?.player.togglePause() }
        singleClick = click
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: click)
    }
    override func mouseDragged(with event: NSEvent) {
        singleClick?.cancel()
        guard AppCapabilities.current.profile == .full, player.settings.processing.projection != "off" else { return }
        player.updateSettings {
            $0.processing.yaw = max(-180, min(180, $0.processing.yaw - event.deltaX * 0.3))
            $0.processing.pitch = max(-90, min(90, $0.processing.pitch + event.deltaY * 0.3))
        }
    }
    override func scrollWheel(with event: NSEvent) {
        guard player.loaded else { return }
        if AppCapabilities.current.profile == .full && player.settings.processing.projection != "off" {
            player.updateSettings { $0.processing.fieldOfView -= Double(event.scrollingDeltaY) * 0.3 }
        } else if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            player.jump(Double(event.scrollingDeltaX) * (event.hasPreciseScrollingDeltas ? 0.05 : 1))
        } else { player.setVolume(player.volume + Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.1 : 2)) }
    }
    override func magnify(with event: NSEvent) { player.updateSettings { $0.zoom += Double(event.magnification) } }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else { return false }
        player.open(urls); return true
    }
    deinit {
        // No client setters in deinit. The host's explicit close owns color restoration.
        if let session { SPMetalSessionDestroy(session) }
    }
}
