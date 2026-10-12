import AppKit
import CMPV
import PlayerCore
import CoreVideo
@preconcurrency import ScreenCaptureKit

/// Private, bounded native Metal evidence. Normal App launches never instantiate it.
@MainActor
final class MetalAppSmokeVerifier {
    static let modes: Set<String> = ["metal-sdr-nv12", "metal-sdr-p010"]
    private static var acceptingCaptures = true
    private static var captureTasks: [UUID: Task<Void, Never>] = [:]
    private var captureResults: [String: [String: Any]] = [:]
    private var captureFailure: String?
    static var ownedCaptureCount: Int { captureTasks.count }
    static func beginTermination() { acceptingCaptures = false }
    static func shutdownForTermination(timeout: TimeInterval) async -> Bool {
        guard timeout.isFinite, (0...5).contains(timeout) else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !captureTasks.isEmpty {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return false }
        }
        return true // Only actual task return removes capture ownership.
    }
    static func resumeAfterCancelledTermination() { acceptingCaptures = true }
    private let player: PlayerModel
    private let report: URL
    private let mode: String
    private let began = ProcessInfo.processInfo.systemUptime
    private var phase = 0
    private var phaseAt = ProcessInfo.processInfo.systemUptime
    private var rows: [[String: Any]] = []
    private var identity: (OpaquePointer, UUID, UUID, UUID)?
    private var ticket: UUID?
    private var requestedAt: TimeInterval = 0
    private var beforeNative: GPUVideoPipelineValidation?
    private var beforeRaw: [String: Any]?
    private var beforeSeek: UInt64 = 0
    private var initialSize: CGSize?
    private var requiredSize: CGSize?
    private var originalWindowSize: CGSize?
    private var captureNonce: UUID?
    private var finished: [String: Any]?
    private var traceReturn: Int32?
    private var pauseReturn: Int32?
    private var initialized = false
    private var offscreenRaw: [String: Any]?
    init(player: PlayerModel, report: URL, mode: String) {
        self.player = player; self.report = report; self.mode = mode
    }
    func tick() -> [String: Any]? {
        if let finished { return finished }
        do {
            guard Self.modes.contains(mode),
                  InputController.verificationSuiteName(environment: ProcessInfo.processInfo.environment) != nil,
                  ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_RENDERER"] == "metal-sdr" else {
                throw failure("Explicit private Metal route absent")
            }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - began < 70, now - phaseAt < 15 else { throw failure("Metal native stage deadline") }
            if !player.loaded || player.isLoading { return nil }
            guard let handle = player.handle, let host = player.videoHost,
                  let metal = host.video as? MPVMetalVideoView,
                  let renderer = metal.rendererIdentity, metal.window != nil,
                  host.effectiveBackend == "metal-candidate", host.fallbackReason == nil,
                  let item = player.mediaPreferences.boundItemID,
                  player.mediaPreferenceToken == player.mediaPreferences.token,
                  (player.jsonProperty("glsl-shaders") as? [String])?.isEmpty == true,
                  (player.jsonProperty("glsl-shader-opts") as? [String: Any])?.isEmpty == true,
                  player.error == nil else { throw failure("Exact active Metal/source binding absent") }
            if let old = identity {
                guard old.0 == handle, old.1 == player.mediaPreferenceToken,
                      old.2 == item, old.3 == renderer else { throw failure("Core/source/renderer replaced") }
            } else { identity = (handle, player.mediaPreferenceToken, item, renderer) }
            if !initialized {
                let trace = mpv_request_log_messages(handle, "trace")
                let pause = player.setChecked("pause", "yes")
                traceReturn = trace; pauseReturn = pause
                guard trace >= 0, pause >= 0 else { throw failure("Real trace/pause request rejected") }
                beforeSeek = player.liveASRHostState.seekGeneration
                player.seek(1, remember: false) // Real decoder/mapper work after trace activation.
                initialized = true; return nil
            }
            guard player.flag("pause"), !player.flag("seeking"),
                  player.liveASRHostState.seekGeneration > beforeSeek,
                  player.liveASRHostState.settledSeekGeneration == player.liveASRHostState.seekGeneration else { return nil }
            let pixel = mode == "metal-sdr-nv12" ? "nv12" : "p010"
            guard player.string("hwdec-current") == "videotoolbox",
                  let sourceParams = player.jsonProperty("video-params") as? [String: Any],
                  sourceParams["pixelformat"] as? String == "videotoolbox",
                  sourceParams["hw-pixelformat"] as? String == pixel else { throw failure("Actual codec VT subtype differs") }
            guard player.string("target-trc") == "srgb", player.string("target-prim") == "bt.709",
                  (player.string("target-peak") == "auto" || Double(player.string("target-peak")) == 0) else { throw failure("SDR output getter differs") }
            guard player.drainCoreEventsToEmpty(expectedHandle: handle, maximum: 512),
                  let raw = (player.jsonProperty("vo-passes") as? [String: Any])?["gpu-next-validation"] as? [String: Any],
                  let native = try? GPUVideoPipelineValidation.parse(raw) else { return nil }
            guard player.handle == handle, player.videoHost === host, metal.rendererIdentity == renderer,
                  player.mediaPreferenceToken == identity?.1, player.mediaPreferences.token == identity?.1,
                  player.mediaPreferences.boundItemID == identity?.2, player.loaded, !player.isLoading,
                  player.flag("pause"), !player.flag("seeking") else { throw failure("Binding changed during real event drain") }
            if phase == 0 {
                guard abs(player.position - 1) < 0.15 else { return nil }
                if ticket == nil { try request(metal, native: native, raw: raw) }
                guard let observation = try drawObservation(metal, native: native, raw: raw, stage: "initial") else { return nil }
                rows.append(observation); initialSize = CGSize(width: CGFloat(observation["width"] as? Int ?? 0), height: CGFloat(observation["height"] as? Int ?? 0))
                try queueCapture(metal, stage: "initial", observation: observation); advance(1); return nil
            }
            if phase == 1 {
                guard try captureCompleted(stage: "initial") else { return nil }
                beforeSeek = player.liveASRHostState.seekGeneration
                player.seek(4, remember: false); advance(2); return nil
            }
            if phase == 2 {
                guard player.liveASRHostState.seekGeneration > beforeSeek,
                      player.position.isFinite, abs(player.position - 4) < 0.15 else { return nil }
                if ticket == nil { try request(metal, native: native, raw: raw) }
                guard let observation = try drawObservation(metal, native: native, raw: raw, stage: "seek") else { return nil }
                rows.append(observation)
                guard let window = metal.window else { throw failure("Window vanished") }
                originalWindowSize = window.contentLayoutRect.size
                window.setContentSize(CGSize(width: window.contentLayoutRect.width + 80, height: window.contentLayoutRect.height + 40))
                requiredSize = nil; advance(3); return nil
            }
            if phase == 3 {
                let actual = metal.convertToBacking(metal.bounds).size
                guard actual.width > 0, actual.height > 0, actual != initialSize else { return nil }
                requiredSize = CGSize(width: ceil(actual.width), height: ceil(actual.height))
                if ticket == nil { try request(metal, native: native, raw: raw) }
                guard let observation = try drawObservation(metal, native: native, raw: raw, stage: "resize") else { return nil }
                rows.append(observation)
                let environment = ProcessInfo.processInfo.environment
                guard let path = environment["SILICONPLAYER_METAL_SMOKE_SUBTITLE"], path.hasPrefix("/"),
                      path.utf8.count <= 8192, FileManager.default.fileExists(atPath: path) else { throw failure("Pinned local subtitle absent") }
                player.addSubtitle(URL(fileURLWithPath: path))
                guard player.executeCommand(["show-text", "Metal Smoke OSD", "10000"]) >= 0 else { throw failure("Actual OSD command rejected") }
                advance(4); return nil
            }
            if phase == 4 {
                guard player.subtitleID > 0, let subtitlePath = ProcessInfo.processInfo.environment["SILICONPLAYER_METAL_SMOKE_SUBTITLE"],
                      let track = (player.jsonProperty("track-list") as? [[String: Any]])?.first(where: {
                          ($0["type"] as? String) == "sub" && ($0["id"] as? Int) == player.subtitleID }),
                      track["selected"] as? Bool == true, track["external"] as? Bool == true,
                      track["external-filename"] as? String == subtitlePath else { return nil }
                if ticket == nil { try request(metal, native: native, raw: raw) }
                guard let observation = try drawObservation(metal, native: native, raw: raw, stage: "osd") else { return nil }
                rows.append(observation); try queueCapture(metal, stage: "osd", observation: observation); advance(5); return nil
            }
            if phase == 5 {
                guard try captureCompleted(stage: "osd") else { return nil }
                let screenshot = report.deletingLastPathComponent().appendingPathComponent("offscreen-window.png")
                guard !FileManager.default.fileExists(atPath: screenshot.path) else { throw failure("Offscreen output already exists") }
                guard player.executeCommand(["screenshot-to-file", screenshot.path, "window"]) >= 0,
                      let actual = (player.jsonProperty("vo-passes") as? [String: Any])?["gpu-next-validation"] as? [String: Any] else {
                    throw failure("Actual C screenshot command/receipt absent")
                }
                offscreenRaw = actual // Immediate actual getter, separate from drawable proof.
                advance(6); return nil
            }
            guard phase == 6 else { throw failure("Invalid verifier state") }
            let screenshot = report.deletingLastPathComponent().appendingPathComponent("offscreen-window.png")
            guard FileManager.default.fileExists(atPath: screenshot.path) else { return nil }
            guard let offscreenRaw, let offscreen = try? GPUVideoPipelineValidation.parse(offscreenRaw),
                  offscreenRaw["download-attempted"] as? Bool == true, offscreenRaw["download-succeeded"] as? Bool == true,
                  offscreenRaw["screenshot-scaled"] as? Bool == true, offscreenRaw["screenshot-subs"] as? Bool == true,
                  offscreenRaw["screenshot-osd"] as? Bool == true, offscreen.pipeline.current.offscreen,
                  offscreen.pipeline.current.hasFrame, offscreen.pipeline.current.completed, offscreen.pipeline.current.success,
                  !offscreen.pipeline.current.shaderError, !offscreen.pipeline.current.resourceError,
                  !offscreen.pipeline.current.brokenFrame, !offscreen.pipeline.current.overflow,
                  offscreen.renderAttempted, offscreen.renderSucceeded, offscreen.rendererErrors == 0 else {
                throw failure("Actual subs/OSD/scaled screenshot receipt absent")
            }
            if let originalWindowSize { metal.window?.setContentSize(originalWindowSize) }
            finished = ["metalSmokePassed": true, "nativeStages": rows, "offscreenReceipt": offscreenRaw,
                "registryBeforeQuit": MetalRenderOwnership.diagnostics, "expectedPixelFormat": pixel,
                "codecMapperTraceRequired": true, "renderProgressUsed": false, "physicalHDRClaim": false,
                "zeroCopyClaim": false, "shaderCompileClaim": false, "newActualAppGroupClaim": false]
            return finished
        } catch {
            finished = ["metalSmokePassed": false, "nativeStages": rows, "failure": error.localizedDescription,
                "registryBeforeQuit": MetalRenderOwnership.diagnostics, "renderProgressUsed": false]
            return finished
        }
    }
    private func request(_ metal: MPVMetalVideoView, native: GPUVideoPipelineValidation, raw: [String: Any]) throws {
        let value = UUID(); beforeNative = native; beforeRaw = raw; requestedAt = ProcessInfo.processInfo.systemUptime
        guard metal.requestConfigurationRedraw(ticket: value) else { throw failure("Actual Metal forced ticket rejected") }
        ticket = value
    }
    private func drawObservation(_ metal: MPVMetalVideoView, native: GPUVideoPipelineValidation,
                                 raw: [String: Any], stage: String) throws -> [String: Any]? {
        guard let ticket, let beforeNative, let renderer = identity?.3 else { throw failure("Owned stage request missing") }
        if native.hasCurrentRenderFailure(sequenceAfter: beforeNative.pipeline.sequence, paths: []) {
            throw failure("Fresh native Metal render/submit failure")
        }
        guard let drawable = metal.configurationDrawable(ticket: ticket),
              drawable.matches(ticket: ticket, renderer: renderer, requestedAfter: requestedAt),
              native.confirmed(after: beforeNative, paths: [], descriptions: []) != nil else { return nil }
        if let requiredSize {
            guard CGFloat(drawable.width) == requiredSize.width, CGFloat(drawable.height) == requiredSize.height else { return nil }
        }
        metal.retireConfigurationRedraw(ticket: ticket); self.ticket = nil
        return ["stage": stage, "ticket": ticket.uuidString, "rendererID": renderer.uuidString,
            "nativeBefore": beforeRaw ?? [:], "nativeAfter": raw, "actualConsumer": metal.metalDiagnostics,
            "actualSourcePath": player.currentURL?.path as Any? ?? NSNull(),
            "width": drawable.width, "height": drawable.height, "requestedAt": requestedAt,
            "observedAt": ProcessInfo.processInfo.systemUptime, "eventsEmpty": true,
            "coreID": player.liveASRHostState.coreID.uuidString, "loadToken": player.mediaPreferenceToken.uuidString,
            "itemID": player.mediaPreferences.boundItemID?.uuidString ?? "", "seekGeneration": player.liveASRHostState.seekGeneration,
            "settledSeekGeneration": player.liveASRHostState.settledSeekGeneration as Any? ?? NSNull(),
            "traceRequestReturn": traceReturn as Any? ?? NSNull(), "pauseRequestReturn": pauseReturn as Any? ?? NSNull(),
            "actualPaused": player.flag("pause"), "position": player.position, "decoder": player.string("hwdec-current"),
            "videoParams": player.jsonProperty("video-params") ?? [:], "output": ["trc": player.string("target-trc"),
                "primaries": player.string("target-prim"), "peak": player.string("target-peak")],
            "notOneToOneNativeAttemptAssociation": true]
    }
    private struct CaptureBindingState: Equatable {
        let coreID: UUID
        let handleIdentity: String
        let loadToken: UUID
        let itemID: UUID
        let queueItemID: UUID?
        let rendererID: UUID
        let hostIdentity: ObjectIdentifier
        let windowIdentity: ObjectIdentifier
        let windowNumber: Int
        let seekGeneration: UInt64
        let settledSeekGeneration: UInt64
        let corePosition: Double
        let timeStatus: Int32
        let pauseStatus: Int32
        let pauseValue: Int32
        let seekingStatus: Int32
        let seekingValue: Int32
        let windowFrame: NSRect
        let contentLayoutRect: NSRect
        let metalFrame: NSRect
        let metalBounds: NSRect
        let metalBackingBounds: NSRect
        let backingScale: CGFloat
        let configurationEpoch: UUID
        let configurationRequestID: UUID
        let configurationApplyCount: UInt64
        var receipt: [String: Any] {
            func rectangle(_ value: NSRect) -> [Double] {
                [Double(value.origin.x), Double(value.origin.y), Double(value.width), Double(value.height)]
            }
            return ["coreID": coreID.uuidString, "handleIdentity": handleIdentity,
                "loadToken": loadToken.uuidString, "itemID": itemID.uuidString,
                "queueItemID": queueItemID?.uuidString as Any? ?? NSNull(), "rendererID": rendererID.uuidString,
                "hostIdentity": String(describing: hostIdentity), "windowIdentity": String(describing: windowIdentity),
                "windowNumber": windowNumber, "seekGeneration": seekGeneration, "settledSeekGeneration": settledSeekGeneration,
                "timePosGetter": ["format": "MPV_FORMAT_DOUBLE", "status": timeStatus, "value": corePosition],
                "pauseGetter": ["format": "MPV_FORMAT_FLAG", "status": pauseStatus, "value": pauseValue],
                "seekingGetter": ["format": "MPV_FORMAT_FLAG", "status": seekingStatus, "value": seekingValue],
                "windowFrame": rectangle(windowFrame), "contentLayoutRect": rectangle(contentLayoutRect),
                "metalFrame": rectangle(metalFrame), "metalBounds": rectangle(metalBounds),
                "metalBackingBounds": rectangle(metalBackingBounds), "backingScale": Double(backingScale),
                "configurationEpoch": configurationEpoch.uuidString, "configurationRequestID": configurationRequestID.uuidString,
                "configurationApplyCount": configurationApplyCount]
        }
    }
    private func captureBindingReadback(_ metal: MPVMetalVideoView, window: NSWindow,
                                       identity: (OpaquePointer, UUID, UUID, UUID), phase: String) throws
        -> (state: CaptureBindingState, receipt: [String: Any]) {
        let began = ProcessInfo.processInfo.systemUptime
        guard captureBindingCurrent(metal, window: window, identity: identity), let host = player.videoHost,
              let settled = player.liveASRHostState.settledSeekGeneration,
              settled == player.liveASRHostState.seekGeneration, !player.videoConfigurationClosing else {
            throw failure("Capture settled binding absent")
        }
        let seek = player.liveASRHostState.seekGeneration
        let epoch = player.videoConfigurationEpoch, request = player.videoConfigurationRequestID
        let count = player.videoConfigurationApplyCount
        let frame = window.frame, layout = window.contentLayoutRect
        let metalFrame = metal.frame, bounds = metal.bounds, backing = metal.convertToBacking(bounds)
        let scale = window.backingScaleFactor
        var position = Double.nan, pause: Int32 = -1, seeking: Int32 = -1
        let timeStatus = mpv_get_property(identity.0, "time-pos", MPV_FORMAT_DOUBLE, &position)
        let pauseStatus = mpv_get_property(identity.0, "pause", MPV_FORMAT_FLAG, &pause)
        let seekingStatus = mpv_get_property(identity.0, "seeking", MPV_FORMAT_FLAG, &seeking)
        let rectangles = [frame, layout, metalFrame, bounds, backing]
        guard timeStatus >= 0, position.isFinite, position >= 0,
              pauseStatus >= 0, pause == 1, seekingStatus >= 0, seeking == 0,
              scale.isFinite, scale > 0,
              rectangles.allSatisfy({ $0.origin.x.isFinite && $0.origin.y.isFinite
                  && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }),
              captureBindingCurrent(metal, window: window, identity: identity), player.videoHost === host,
              player.liveASRHostState.seekGeneration == seek, player.liveASRHostState.settledSeekGeneration == settled,
              player.videoConfigurationEpoch == epoch, player.videoConfigurationRequestID == request,
              player.videoConfigurationApplyCount == count, !player.videoConfigurationClosing,
              window.frame == frame, window.contentLayoutRect == layout, metal.frame == metalFrame,
              metal.bounds == bounds, metal.convertToBacking(bounds) == backing, window.backingScaleFactor == scale else {
            throw failure("Capture actual Core/geometry/configuration readback invalid or changed")
        }
        let state = CaptureBindingState(coreID: player.liveASRHostState.coreID, handleIdentity: String(describing: identity.0),
            loadToken: identity.1, itemID: identity.2, queueItemID: player.playlist.currentItem?.id, rendererID: identity.3,
            hostIdentity: ObjectIdentifier(host), windowIdentity: ObjectIdentifier(window), windowNumber: window.windowNumber,
            seekGeneration: seek, settledSeekGeneration: settled, corePosition: position, timeStatus: timeStatus,
            pauseStatus: pauseStatus, pauseValue: pause, seekingStatus: seekingStatus, seekingValue: seeking,
            windowFrame: frame, contentLayoutRect: layout, metalFrame: metalFrame, metalBounds: bounds,
            metalBackingBounds: backing, backingScale: scale, configurationEpoch: epoch,
            configurationRequestID: request, configurationApplyCount: count)
        return (state, ["phase": phase, "readBeganAt": began, "readEndedAt": ProcessInfo.processInfo.systemUptime,
                        "nonAtomicHostReads": true, "state": state.receipt])
    }
    private func queueCapture(_ metal: MPVMetalVideoView, stage: String, observation: [String: Any]) throws {
        guard let window = metal.window, let identity, Self.acceptingCaptures,
              Self.captureTasks.count < 2, window.windowNumber > 0 else { throw failure("Owned actual window capture unavailable") }
        let baseline = try captureBindingReadback(metal, window: window, identity: identity, phase: "before-content-await")
        let nonce = UUID(); captureNonce = nonce
        let windowNumber = window.windowNumber
        let destination = report.deletingLastPathComponent().appendingPathComponent("on-window-\(stage).png")
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw failure("Window PNG already exists") }
        try write(["mode": mode, "stage": stage, "nonce": nonce.uuidString, "windowID": windowNumber,
            "appPID": ProcessInfo.processInfo.processIdentifier, "observation": observation,
            "bindingReadback": baseline.receipt], name: "capture-\(stage)-ready.json")
        Self.captureTasks[nonce] = Task { @MainActor [self, weak metal] in
            defer { Self.captureTasks.removeValue(forKey: nonce) }
            var bindingReads = [baseline.receipt]
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let metal else { throw failure("Capture renderer retired") }
                let afterContent = try captureBindingReadback(metal, window: window, identity: identity, phase: "after-content-await")
                bindingReads.append(afterContent.receipt)
                guard afterContent.state == baseline.state,
                      let actualWindow = content.windows.first(where: { $0.windowID == UInt32(windowNumber)
                          && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier && $0.isOnScreen }) else {
                    throw failure("Actual on-screen owned window absent")
                }
                let filter = SCContentFilter(desktopIndependentWindow: actualWindow)
                let configuration = SCStreamConfiguration()
                let width = Int(ceil(actualWindow.frame.width * CGFloat(filter.pointPixelScale)))
                let height = Int(ceil(actualWindow.frame.height * CGFloat(filter.pointPixelScale)))
                guard (1...8192).contains(width), (1...8192).contains(height), width * height <= 16_777_216 else {
                    throw failure("Window capture pixel bound")
                }
                configuration.width = width; configuration.height = height
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.showsCursor = false; configuration.capturesAudio = false
                let beforeImage = try captureBindingReadback(metal, window: window, identity: identity, phase: "before-image-await")
                bindingReads.append(beforeImage.receipt)
                guard beforeImage.state == baseline.state else { throw failure("Capture binding changed before image await") }
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let afterImage = try captureBindingReadback(metal, window: window, identity: identity, phase: "after-image-await")
                bindingReads.append(afterImage.receipt)
                guard afterImage.state == baseline.state, image.width == width, image.height == height,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                      !png.isEmpty, png.count <= 64 * 1_048_576 else { throw failure("Actual window capture changed or PNG invalid") }
                try png.write(to: destination, options: [.withoutOverwriting])
                let value: [String: Any] = ["mode": mode, "stage": stage, "nonce": nonce.uuidString,
                    "actualCaptureAPI": "SCScreenshotManager.captureImage", "actualWindowID": actualWindow.windowID,
                    "actualOwnerPID": actualWindow.owningApplication?.processID as Any? ?? NSNull(), "actualOnScreen": actualWindow.isOnScreen,
                    "imageWidth": image.width, "imageHeight": image.height, "pngBytes": png.count,
                    "imagePath": destination.path, "observedAt": ProcessInfo.processInfo.systemUptime,
                    "bindingReads": bindingReads, "sameBindingBeforeAndAfterAwait": true, "notAtomicFrameCapture": true]
                try write(value, name: "capture-\(stage)-done.json")
                captureResults[stage] = value
            } catch {
                captureFailure = error.localizedDescription
                try? write(["mode": mode, "stage": stage, "nonce": nonce.uuidString,
                    "failed": true, "failure": error.localizedDescription, "bindingReads": bindingReads,
                    "notAtomicFrameCapture": true], name: "capture-\(stage)-failed.json")
            }
        }
    }
    private func captureBindingCurrent(_ metal: MPVMetalVideoView, window: NSWindow,
                                       identity: (OpaquePointer, UUID, UUID, UUID)) -> Bool {
        Self.acceptingCaptures && player.handle == identity.0 && player.mediaPreferenceToken == identity.1
            && player.mediaPreferences.token == identity.1 && player.mediaPreferences.boundItemID == identity.2
            && metal.rendererIdentity == identity.3 && player.videoHost?.video === metal && metal.window === window
            && window.isVisible && player.loaded && !player.isLoading && player.flag("pause") && !player.flag("seeking")
    }
    private func captureCompleted(stage: String) throws -> Bool {
        if let captureFailure { throw failure(captureFailure) }
        guard let value = captureResults[stage] else { return false }
        guard value["nonce"] as? String == captureNonce?.uuidString, value["stage"] as? String == stage,
              value["mode"] as? String == mode else { throw failure("Owned window capture receipt differs") }
        captureNonce = nil; return true
    }
    private func write(_ object: [String: Any], name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= 262_144 else { throw failure("Private Metal receipt capacity") }
        try data.write(to: report.deletingLastPathComponent().appendingPathComponent(name), options: .atomic)
    }
    private func advance(_ next: Int) { phase = next; phaseAt = ProcessInfo.processInfo.systemUptime }
    private func failure(_ text: String) -> NSError { NSError(domain: "MetalAppSmoke", code: 1,
        userInfo: [NSLocalizedDescriptionKey: text]) }
}

@MainActor
struct MetalSmokeCloseCapture {
    let view: MPVMetalVideoView?
    let rendererID: UUID?
    let before: [String: Any]
    static func begin(player: PlayerModel) -> Self? {
        let environment = ProcessInfo.processInfo.environment
        guard MetalAppSmokeVerifier.modes.contains(environment["SILICONPLAYER_VERIFY_MODE"] ?? ""),
              InputController.verificationSuiteName(environment: environment) != nil else { return nil }
        MetalAppSmokeVerifier.beginTermination()
        let view = player.videoHost?.video as? MPVMetalVideoView
        let rendererID = view?.rendererIdentity
        return Self(view: view, rendererID: rendererID,
                    before: ["consumer": view?.metalDiagnostics as Any? ?? NSNull(), "registry": MetalRenderOwnership.diagnostics,
                             "rendererID": rendererID?.uuidString as Any? ?? NSNull(), "observedAt": ProcessInfo.processInfo.systemUptime])
    }
    static func save(_ capture: Self?, stopped: Bool, environment: [String: String]) -> Bool {
        guard MetalAppSmokeVerifier.modes.contains(environment["SILICONPLAYER_VERIFY_MODE"] ?? ""),
              InputController.verificationSuiteName(environment: environment) != nil else { return true }
        guard let capture, let path = environment["SILICONPLAYER_VERIFY_REPORT"],
              stopped, MetalRenderOwnership.terminationConfirmed, MetalAppSmokeVerifier.ownedCaptureCount == 0,
              MetalRenderOwnership.diagnostics["leaseCount"] as? Int == 0,
              MetalRenderOwnership.diagnostics["hostCount"] as? Int == 0 else { return false }
        if let view = capture.view {
            guard let rendererID = capture.rendererID, let render = view.finalMetalDiagnostics,
                  render["rendererID"] as? String == rendererID.uuidString,
                  render["closed"] as? Bool == true, render["closing"] as? Bool == true,
                  render["renderContextFreed"] as? Bool == true,
                  render["callbackUnregistered"] as? Bool == true,
                  (view.metalDiagnostics["color"] as? [String: Any])?["active"] as? Bool == false else { return false }
        } // A failed creation may have no view. Empty real registry permits
          // failure exit; it is explicitly NOT an exact renderer-free receipt.
        do {
            let object: [String: Any] = ["mode": environment["SILICONPLAYER_VERIFY_MODE"] ?? "", "before": capture.before,
                "after": ["consumer": capture.view?.metalDiagnostics as Any? ?? NSNull(), "registry": MetalRenderOwnership.diagnostics,
                          "actualStopped": stopped, "ownedCaptureCount": MetalAppSmokeVerifier.ownedCaptureCount,
                          "observedAt": ProcessInfo.processInfo.systemUptime], "rendererAbsent": capture.view == nil,
                "closedExactRenderer": capture.rendererID?.uuidString as Any? ?? NSNull()]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 524_288 else { return false }
            try data.write(to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("metal-termination.json"), options: .atomic)
            return true
        } catch { return false }
    }
}
