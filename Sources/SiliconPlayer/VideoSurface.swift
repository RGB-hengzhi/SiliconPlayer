import AppKit
import SwiftUI
import CMPV

private let glLibrary = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)


struct VideoSurface: NSViewRepresentable {
    let player: PlayerModel
    func makeNSView(context: Context) -> NSView {
        let environment = ProcessInfo.processInfo.environment
        let privateMetal = environment["SILICONPLAYER_VERIFY_RENDERER"] == "metal-sdr"
            && InputController.verificationSuiteName(environment: environment) != nil
        let candidate: MPVVideoHost?
        if privateMetal {
            // This synchronous private route is intentionally empty-shader.
            // Managed startup paths require the separate real async permit.
            guard let shaders = player.jsonProperty("glsl-shaders") as? [String], shaders.isEmpty,
                  let options = player.jsonProperty("glsl-shader-opts") as? [String: Any], options.isEmpty else {
                DispatchQueue.main.async { player.error = "私有 Metal 验证入口需要空着色器设置" }
                return NSView()
            }
            candidate = MPVVideoHost(player: player, backend: .metalCandidate(output: .sdr))
        } else {
            candidate = MPVVideoHost(player: player)
        }
        guard let host = candidate else {
            DispatchQueue.main.async { player.error = "无法创建视频显示上下文" }
            return NSView()
        }
        if privateMetal, host.effectiveBackend != "metal-candidate" || host.fallbackReason != nil {
            // A real GL fallback is not Metal acceptance. Keep any failed
            // teardown in the host/lease registries for normal quit retry.
            _ = host.closeRenderer()
            DispatchQueue.main.async { player.error = "显式 Metal 验证未取得 Metal 输出" }
            return NSView()
        }
        return host
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? MPVVideoHost)?.closeRenderer()
    }
}

@MainActor
protocol MPVVideoDisplay: AnyObject {
    var rendererIdentity: UUID? { get }
    func requestRedraw()
    func requestConfigurationRedraw(ticket: UUID) -> Bool
    func prepareForSurfaceMove()
    func beginBaseSettingsUpdate() -> Bool
    func endBaseSettingsUpdate()
    @discardableResult func closeRenderer() -> Bool
}

enum MPVVideoBackendRequest {
    case openGL
    // Only an explicitly constructed candidate host uses this route. The
    // normal VideoSurface initializer still requests OpenGL until acceptance.
    case metalCandidate(output: MetalOutputRequest)
}

/// SwiftUI owns this stable host while the system PiP panel temporarily owns
/// its original video child. A host layout must never resize a detached child.
final class MPVVideoHost: NSView {
    let video: NSView & MPVVideoDisplay
    let effectiveBackend: String
    let fallbackReason: String?
    private weak var player: PlayerModel?
    private var rendererClosed = false
    private static var retainedCloseFailures: [ObjectIdentifier: MPVVideoHost] = [:]
    init?(player: PlayerModel, backend: MPVVideoBackendRequest = .openGL,
          metalShaders: MetalShaderStartupPermit? = nil) {
        if case .metalCandidate = backend, let metalShaders {
            guard metalShaders.consumeForCreation(player) else { return nil }
        }
        // This gate includes failed init leases, even with no player.videoHost.
        guard MetalRenderOwnership.prepareForCreation(player: player) else {
            player.error = "上一个视频输出尚未确认释放"; return nil
        }
        if let retained = Self.retainedCloseFailures[ObjectIdentifier(player)] {
            guard retained.closeRenderer() else { return nil }
        }
        if let previous = player.videoHost {
            // Do not redirect callbacks or create a second render context while
            // the system still owns the original surface.
            guard !player.systemPiP.hasPendingJobs, previous.closeRenderer() else { return nil }
        }
        let video: NSView & MPVVideoDisplay
        switch backend {
        case .openGL:
            guard let gl = MPVVideoView(player: player) else { return nil }
            video = gl; effectiveBackend = "opengl"; fallbackReason = nil
        case .metalCandidate(let output):
            do {
                video = try MPVMetalVideoView(player: player, output: output, shaderPermit: metalShaders)
                effectiveBackend = "metal-candidate"; fallbackReason = nil
            } catch let failure as MetalViewCreationError where failure.canFallbackToGL {
                guard let gl = MPVVideoView(player: player) else { return nil }
                video = gl; effectiveBackend = "opengl"; fallbackReason = failure.localizedDescription
            } catch {
                player.error = error.localizedDescription; return nil
            }
        }
        self.video = video
        self.player = player
        super.init(frame: .zero)
        if let metal = video as? MPVMetalVideoView {
            guard MetalRenderOwnership.attach(host: self, leaseID: metal.outputLeaseIdentity) else {
                _ = closeRenderer(); return nil
            }
        }
        video.autoresizingMask = [.width, .height]
        addSubview(video)
        // Keep the recovery host reachable if color restoration cannot yet be
        // confirmed after registration failure. No second context may replace it.
        player.videoHost = self
        _ = player.systemPiP.register(videoView: video, host: self)
        guard player.systemPiP.ownsRegistration(videoView: video, host: self) else {
            // The owned host is registered before PiP registration so a failed
            // registration cannot discard renderer/color retry ownership.
            _ = closeRenderer()
            return nil
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func layout() {
        super.layout()
        if video.superview === self { video.frame = bounds }
    }
    @discardableResult func closeRenderer() -> Bool {
        if rendererClosed { return true }
        guard let player else {
            guard video.closeRenderer() else { return false }; rendererClosed = true; return true
        }
        guard player.systemPiP.teardown(host: self) else {
            player.toast("系统画中画尚未释放视频视图，正在保留渲染上下文。")
            return false
        }
        guard video.closeRenderer() else {
            Self.retainedCloseFailures[ObjectIdentifier(player)] = self; return false
        }
        if Self.retainedCloseFailures[ObjectIdentifier(player)] === self {
            Self.retainedCloseFailures.removeValue(forKey: ObjectIdentifier(player))
        }
        if player.videoHost === self { player.videoHost = nil }
        rendererClosed = true
        return true
    }
}

// Owns the renderer independently of NSView/AppKit redraw scheduling. With
// advanced control, mpv may request GPU work while a synchronous client command
// (for example screenshot) is occupying the main thread.
private final class RendererSession {
    let identity = UUID()
    private let context: NSOpenGLContext
    private let cgl: CGLContextObj
    private let renderQueue = DispatchQueue(label: "local.siliconplayer.render", qos: .userInteractive)
    private var renderContext: OpaquePointer? // Accessed only on renderQueue.
    private let requestLock = NSLock()
    private var cachedSize: CGSize
    private var requestGeneration: UInt64 = 0
    private var forceRedraw = false
    private var configurationTicket: UUID?
    private var scheduled = false
    private var closing = false
    private let progress: RenderProgress

    init(context: NSOpenGLContext, handle: OpaquePointer, size: CGSize, progress: RenderProgress) throws {
        guard let cgl = context.cglContextObj else { throw RendererError(code: -1) }
        self.context = context
        self.cgl = cgl
        cachedSize = size
        self.progress = progress
        var result: Int32 = -1
        renderQueue.sync {
            CGLLockContext(cgl)
            defer { NSOpenGLContext.clearCurrentContext(); CGLUnlockContext(cgl) }
            context.makeCurrentContext()
            var swap: GLint = 1
            context.setValues(&swap, for: .swapInterval)
            var gl = mpv_opengl_init_params(get_proc_address: { _, name in
                guard let name else { return nil }
                return dlsym(glLibrary, name)
            }, get_proc_address_ctx: nil)
            var advanced: Int32 = 1
            let api = strdup(MPV_RENDER_API_TYPE_OPENGL)!
            defer { free(api) }
            result = withUnsafeMutablePointer(to: &gl) { glPointer in
                withUnsafeMutablePointer(to: &advanced) { advancedPointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(glPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: UnsafeMutableRawPointer(advancedPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]
                    return mpv_render_context_create(&renderContext, handle, &params)
                }
            }
            if result >= 0, let renderer = renderContext {
                // Register before the core can start playback. The callback is
                // permitted to schedule work, but cannot call a render API itself.
                mpv_render_context_set_update_callback(renderer, { opaque in
                    guard let opaque else { return }
                    let session = Unmanaged<RendererSession>.fromOpaque(opaque).takeUnretainedValue()
                    session.requestRender()
                }, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        guard result >= 0 else { throw RendererError(code: result) }
    }

    private struct RendererError: LocalizedError {
        let code: Int32
        var errorDescription: String? { String(cString: mpv_error_string(code)) }
    }

    func updateSurfaceSize(_ size: CGSize) {
        requestRender(size: size, redraw: true)
    }

    @discardableResult func requestConfigurationRedraw(size: CGSize, ticket: UUID) -> Bool {
        requestLock.lock()
        guard !closing, configurationTicket == nil, size.width > 0, size.height > 0 else {
            requestLock.unlock(); return false
        }
        cachedSize = size; configurationTicket = ticket; forceRedraw = true
        requestGeneration &+= 1
        let shouldSchedule = !scheduled; scheduled = true
        requestLock.unlock()
        if shouldSchedule { renderQueue.async { [weak self] in self?.drainRequests() } }
        return true
    }

    private func requestRender(size: CGSize? = nil, redraw: Bool = false) {
        requestLock.lock()
        guard !closing else { requestLock.unlock(); return }
        if let size { cachedSize = size }
        requestGeneration &+= 1
        forceRedraw = forceRedraw || redraw
        let shouldSchedule = !scheduled
        scheduled = true
        requestLock.unlock()
        if shouldSchedule {
            renderQueue.async { [weak self] in self?.drainRequests() }
        }
    }

    private func drainRequests() {
        while true {
            requestLock.lock()
            if closing {
                scheduled = false
                requestLock.unlock()
                return
            }
            let generation = requestGeneration
            let size = cachedSize
            let redraw = forceRedraw
            let ticket = configurationTicket; configurationTicket = nil
            forceRedraw = false
            requestLock.unlock()

            render(size: size, forceRedraw: redraw, configurationTicket: ticket)

            requestLock.lock()
            // Updates raised during update()/render() must be serviced again.
            // Clearing scheduled under this same lock prevents a lost wakeup.
            if closing || generation == requestGeneration {
                scheduled = false
                requestLock.unlock()
                return
            }
            requestLock.unlock()
        }
    }

    private func render(size: CGSize, forceRedraw: Bool, configurationTicket: UUID?) {
        guard let renderer = renderContext else { return }
        CGLLockContext(cgl)
        defer { NSOpenGLContext.clearCurrentContext(); CGLUnlockContext(cgl) }
        context.makeCurrentContext()
        // Always call update, including callback requests with no video frame:
        // it executes advanced-control work such as GPU screenshots.
        let flags = mpv_render_context_update(renderer)
        guard forceRedraw || flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        var block: Int32 = 0
        var drawableStatus: Int32?
        if size.width > 0, size.height > 0 {
            glViewport(0, 0, GLsizei(size.width), GLsizei(size.height))
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            var fbo = mpv_opengl_fbo(fbo: 0, w: Int32(size.width), h: Int32(size.height), internal_format: 0)
            var flip: Int32 = 1
            let rendered = withUnsafeMutablePointer(to: &fbo) { fboPointer in
                withUnsafeMutablePointer(to: &flip) { flipPointer in
                    withUnsafeMutablePointer(to: &block) { blockPointer in
                        var params = [
                            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer)),
                            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                            mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(blockPointer)),
                            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                        ]
                        return mpv_render_context_render(renderer, &params)
                    }
                }
            }
            context.flushBuffer()
            drawableStatus = rendered
            if rendered >= 0 && flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 { progress.didRenderFrame() }
        } else {
            // A detached/zero-size surface still services core requests. Mark
            // frames consumed without attempting to render an invalid drawable.
            var skip: Int32 = 1
            withUnsafeMutablePointer(to: &skip) { skipPointer in
                withUnsafeMutablePointer(to: &block) { blockPointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: UnsafeMutableRawPointer(skipPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(blockPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]
                    _ = mpv_render_context_render(renderer, &params)
                }
            }
        }
        mpv_render_context_report_swap(renderer)
        // Receipt is emitted only after the actual render, buffer flush and swap
        // report. A skipped/zero-size surface cannot complete this request.
        if let status = drawableStatus {
            progress.completedDrawable(status: status, flags: flags, forced: forceRedraw,
                width: Int(size.width), height: Int(size.height), rendererID: identity, configurationTicket: configurationTicket)
        }
    }

    // The owning view holds the session until this returns. Disabling requests
    // and draining the queue keeps the callback pointer and GL context alive
    // until no queued render can access them.
    func close() {
        requestLock.lock()
        guard !closing else { requestLock.unlock(); return }
        closing = true
        requestLock.unlock()
        renderQueue.sync {
            guard let renderer = renderContext else { return }
            mpv_render_context_set_update_callback(renderer, nil, nil)
            CGLLockContext(cgl)
            context.makeCurrentContext()
            mpv_render_context_free(renderer)
            NSOpenGLContext.clearCurrentContext()
            CGLUnlockContext(cgl)
            renderContext = nil
        }
    }
}

final class MPVVideoView: NSOpenGLView, MPVVideoDisplay {
    private var session: RendererSession?
    private var rendererClosed = false
    private let player: PlayerModel
    private var singleClick: DispatchWorkItem?
    init?(player: PlayerModel) {
        self.player = player
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAAccelerated), UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAColorSize), 24, UInt32(NSOpenGLPFAAlphaSize), 8, 0
        ]
        super.init(frame: .zero, pixelFormat: NSOpenGLPixelFormat(attributes: attributes))
        wantsBestResolutionOpenGLSurface = true
        registerForDraggedTypes([.fileURL, .URL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override var acceptsFirstResponder: Bool { true }
    private func withLockedOpenGL(_ operation: () -> Void) {
        guard let cgl = openGLContext?.cglContextObj else { operation(); return }
        CGLLockContext(cgl)
        defer { NSOpenGLContext.clearCurrentContext(); CGLUnlockContext(cgl) }
        operation()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        withLockedOpenGL { super.viewWillMove(toWindow: newWindow) }
    }
    override func viewDidMoveToWindow() {
        withLockedOpenGL {
            super.viewDidMoveToWindow()
            openGLContext?.update()
        }
        if window != nil { prepareOpenGL() }
        requestRedraw()
    }
    override func prepareOpenGL() {
        withLockedOpenGL { super.prepareOpenGL() }
        // AppKit can leave this current on main. Rendering owns it thereafter.
        NSOpenGLContext.clearCurrentContext()
        guard !rendererClosed, session == nil, let handle = player.handle, let context = openGLContext else { return }
        do {
            session = try RendererSession(context: context, handle: handle, size: convertToBacking(bounds).size, progress: player.renderProgress)
            player.rendererDidBecomeReady()
        } catch {
            player.error = "视频渲染初始化失败：\(error.localizedDescription)"
        }
    }
    override func reshape() {
        if let cgl = openGLContext?.cglContextObj {
            CGLLockContext(cgl)
            super.reshape()
            NSOpenGLContext.clearCurrentContext()
            CGLUnlockContext(cgl)
        } else { super.reshape() }
        requestRedraw()
    }
    override func draw(_ dirtyRect: NSRect) {
        requestRedraw()
    }
    var rendererIdentity: UUID? { session?.identity }
    func requestRedraw() { session?.updateSurfaceSize(window == nil ? .zero : convertToBacking(bounds).size) }
    @discardableResult func requestConfigurationRedraw(ticket: UUID) -> Bool {
        guard window != nil, !rendererClosed, let session else { return false }
        return session.requestConfigurationRedraw(size: convertToBacking(bounds).size, ticket: ticket)
    }
    func prepareForSurfaceMove() { session?.updateSurfaceSize(.zero) }
    override func mouseDown(with event: NSEvent) {
        singleClick?.cancel()
        window?.makeFirstResponder(self)
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
        } else {
            player.setVolume(player.volume + Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.1 : 2))
        }
    }
    override func magnify(with event: NSEvent) {
        player.updateSettings { $0.zoom += Double(event.magnification) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else { return false }
        player.open(urls); return true
    }
    func beginBaseSettingsUpdate() -> Bool { true }
    func endBaseSettingsUpdate() {}
    @discardableResult func closeRenderer() -> Bool {
        guard !rendererClosed else { return true }
        rendererClosed = true
        singleClick?.cancel()
        session?.close()
        session = nil
        return true
    }
    deinit { session?.close() }
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.title = "SiliconPlayer"
            window.minSize = NSSize(width: 760, height: 500)
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
