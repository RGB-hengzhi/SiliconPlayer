import AppKit
import Combine
import PlayerCore
import SystemPiPBridge

/// Owns window/attachment transitions only. The existing player, renderer and
/// audio master continue to own media. All callbacks and moves are on main.
@MainActor
final class SystemPiPController: ObservableObject {
    typealias State = SystemPiPLifecycle.State
    @Published private(set) var state: State = .idle
    @Published private(set) var error: String?
    var active: Bool { state == .active }
    var available: Bool { bridge.available && !lifecycle.terminal && state != .disabled }
    var playing = false { didSet { bridge.update(playing: playing) } }
    var aspectRatio = NSSize(width: 16, height: 9)
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    var onSkip: ((Double) -> Void)?
    var onRedraw: (() -> Void)?
    var onSurfaceWillMove: (() -> Void)?
    var onSurfaceDidMove: (() -> Void)?
    var onStateChanged: ((State) -> Void)?

    private let bridge = SPSystemPiPBridge()
    private var lifecycle = SystemPiPLifecycle()
    private var lastReportedAvailability: Bool?
    private weak var videoView: NSView?
    private weak var host: NSView?
    private var attachment: SPSystemPiPAttachment?
    // Ownership survives a disabled lifecycle state until both native detach
    // and original-host restoration are confirmed. Failures can be retried.
    private var ownershipTicket: UInt64?
    private var nativeDetached = true
    private var normallyClosed = Set<UInt64>()
    private var normalCloseOrder: [UInt64] = []
    private var normalCloseCount = 0
    private var enterCount = 0
    private var startedCallbacks = 0
    private var willCloseCallbacks = 0
    private var closedCallbacks = 0
    private var forcedDetachCount = 0
    private var observedWindowClass: String?
    private var lateStartedWhileExitingCount = 0
    private var ignoredStaleCallbacks = 0
    private var eventHistory: [[String: Any]] = []
    private var lastEnterFailureStage: String?
    private var lastAttachmentDiagnostics: [String: Any] = [:]

    init() {
        bridge.onEvent = { [weak self] event, generation, value, message in
            // Native adapter delivers all callbacks on main, including callbacks
            // originally raised by an unexpected framework thread.
            MainActor.assumeIsolated { self?.receive(event, generation: generation, value: value, message: message) }
        }
        if !bridge.available { error = bridge.unavailableReason; lifecycle.disable(); publish() }
    }

    @discardableResult
    func register(videoView: NSView, host: NSView) -> Bool {
        if self.videoView === videoView && self.host === host { return available }
        guard !hasPendingJobs, !lifecycle.terminal, videoView.superview === host,
              lifecycle.resetRegistration() else { return false }
        self.videoView = videoView; self.host = host
        if !bridge.available { lifecycle.disable(); error = bridge.unavailableReason }
        publish(); return bridge.available
    }

    /// Availability and registration differ: an unavailable system framework
    /// can still register the main video surface safely.
    func ownsRegistration(videoView: NSView, host: NSView) -> Bool {
        self.videoView === videoView && self.host === host
    }

    @discardableResult
    func enter() -> Bool {
        guard bridge.available, let videoView, let host,
              let saved = SPSystemPiPAttachment(videoView: videoView, host: host),
              let generation = lifecycle.beginEnter() else { return false }
        attachment = saved; ownershipTicket = generation; nativeDetached = false
        enterCount += 1; error = nil; lastEnterFailureStage = nil; publish()
        onSurfaceWillMove?()
        let prepared = saved.prepareForPiP()
        lastAttachmentDiagnostics = safeDiagnostics(saved.diagnostics)
        let accepted = prepared && bridge.present(view: videoView, originWindow: host.window,
                          aspectRatio: aspectRatio, playing: playing, generation: generation)
        onSurfaceDidMove?(); onRedraw?()
        if !accepted {
            lastEnterFailureStage = prepared ? "native presentation" : "attachment preparation"
            let diagnostics = prepared ? safeDiagnostics(bridge.diagnostics) : lastAttachmentDiagnostics
            let failure = diagnostics["lastFailure"] as? [String: Any] ?? [:]
            let detail = [failure["stage"], failure["exceptionName"], failure["reason"]]
                .compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: ": ")
            let reason = "无法进入系统画中画（\(lastEnterFailureStage!)）" + (detail.isEmpty ? "" : ": " + detail)
            if ownershipTicket == generation { _ = recover(generation, reason: reason, disable: true) }
            else { error = reason }
            return false
        }
        // A selector returning successfully is not proof of actual presentation.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.lifecycle.generation == generation, self.state == .entering else { return }
            _ = self.recover(generation, reason: "系统画中画未完成启动", disable: true)
        }
        return true
    }

    func exit() {
        guard let generation = ownershipTicket else { return }
        _ = lifecycle.beginExit(); publish(); bridge.dismiss(generation: generation)
    }
    func toggle() { if state == .idle { _ = enter() } else if state == .active || state == .entering { exit() } }

    /// Reusable media-stop/EOF/replacement exit. False means the normal close
    /// was not confirmed; consult safeToReleaseVideoView before renderer teardown.
    func exitAndWait(timeout: TimeInterval = 3) async -> Bool {
        guard let generation = ownershipTicket else { return safeToReleaseVideoView }
        exit()
        let duration = timeout.isFinite ? max(0.1, min(timeout, 10)) : 3
        let deadline = Date().addingTimeInterval(duration)
        while ownershipTicket == generation && Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if normallyClosed.contains(generation) { return true }
        if ownershipTicket == generation { _ = recover(generation, reason: "画中画退出未确认，已尝试安全恢复", disable: true) }
        return false
    }

    /// Terminal quit/disposal only. Ordinary stop/replacement uses exitAndWait.
    func shutdown(timeout: TimeInterval = 3) async -> Bool {
        lifecycle.beginShutdown(); publish()
        return await exitAndWait(timeout: timeout)
    }
    @discardableResult
    func cancelShutdownIfSafe() -> Bool {
        guard !hasPendingJobs, lifecycle.cancelShutdownIfSafe() else {
            lifecycle.disable(); publish(); return false
        }
        if !bridge.available { lifecycle.disable() }
        publish(); return true
    }

    /// Synchronous host dismantle. Only detaches this registered identity and
    /// only reports true once the actual view is restored/outside PiP ownership.
    @discardableResult
    func unregister(videoView: NSView) -> Bool {
        guard self.videoView === videoView else { return false }
        if let generation = ownershipTicket {
            guard recover(generation, reason: nil, disable: false) else { return false }
        }
        if let saved = attachment, !restore(saved) { return false }
        attachment = nil; ownershipTicket = nil; nativeDetached = true
        lifecycle.cancelForTeardown(); self.videoView = nil; host = nil; publish()
        return true
    }
    @discardableResult
    func teardown(host: NSView) -> Bool {
        guard self.host === host, let videoView else { return false }
        return unregister(videoView: videoView)
    }
    var safeToReleaseVideoView: Bool {
        guard !hasPendingJobs else { return false }
        guard let videoView, let host else { return true }
        return videoView.superview === host
    }
    var hasPendingJobs: Bool {
        ownershipTicket != nil || attachment != nil || !nativeDetached
            || state == .entering || state == .active || state == .exiting
    }

    var diagnosticsSnapshot: [String: Any] {
        var result: [String: Any] = ["state": state.rawValue, "active": active, "available": available,
            "terminal": lifecycle.terminal, "generation": lifecycle.generation.map { NSNumber(value: $0) } ?? NSNull(),
            "enterCount": enterCount, "startedCallbacks": startedCallbacks, "willCloseCallbacks": willCloseCallbacks,
            "closedCallbacks": closedCallbacks, "forcedDetachCount": forcedDetachCount,
            "safeToReleaseVideoView": safeToReleaseVideoView, "playing": playing,
            "observedSystemWindowClass": observedWindowClass ?? "none",
            "didStartSource": "actual view in visible installed-framework PIPPanel; not AVKit delegate",
            "normalCloseCount": normalCloseCount, "hasPendingJobs": hasPendingJobs,
            "nativeDetached": nativeDetached, "ownershipTicket": ownershipTicket.map { NSNumber(value: $0) } ?? NSNull(),
            "lateStartedWhileExitingCount": lateStartedWhileExitingCount,
            "ignoredStaleCallbacks": ignoredStaleCallbacks, "events": eventHistory,
            "lastEnterFailureStage": lastEnterFailureStage ?? "none",
            "nativeBridge": safeDiagnostics(bridge.diagnostics),
            "lastAttachment": lastAttachmentDiagnostics]
        if let videoView {
            result["videoWindowClass"] = videoView.window.map { NSStringFromClass(type(of: $0)) } ?? "none"
            result["videoInOriginalHost"] = videoView.superview === host
            result["videoBounds"] = ["width": videoView.bounds.width, "height": videoView.bounds.height]
        }
        if let error { result["error"] = error }
        return result
    }

    private func publish() {
        let nextAvailability = bridge.available && !lifecycle.terminal && lifecycle.state != .disabled
        guard state != lifecycle.state || lastReportedAvailability != nextAvailability else { return }
        if state != lifecycle.state { state = lifecycle.state }
        lastReportedAvailability = nextAvailability
        onStateChanged?(state)
    }
    private func safeDiagnostics(_ input: [String: Any]) -> [String: Any] {
        input.mapValues { value in
            if let text = value as? String { return MediaDiagnosticRedactor.redact(text) }
            if let map = value as? [String: Any] { return safeDiagnostics(map) }
            return value
        }
    }
    private func restore(_ saved: SPSystemPiPAttachment) -> Bool {
        onSurfaceWillMove?(); let result = saved.restore(); onSurfaceDidMove?(); onRedraw?(); return result
    }
    @discardableResult
    private func recover(_ generation: UInt64, reason: String?, disable: Bool) -> Bool {
        guard ownershipTicket == generation else { return !hasPendingJobs }
        if !nativeDetached {
            onSurfaceWillMove?(); let detached = bridge.forceDetach(generation: generation); onSurfaceDidMove?()
            guard detached else { error = "系统画中画仍持有视频视图"; lifecycle.disable(); publish(); return false }
            nativeDetached = true; forcedDetachCount += 1
        }
        if let saved = attachment {
            guard restore(saved) else { error = "无法恢复原视频容器"; lifecycle.disable(); publish(); return false }
        }
        attachment = nil; ownershipTicket = nil; error = reason
        if disable { lifecycle.disable() } else { lifecycle.cancelForTeardown() }
        publish(); return true
    }
    private func receive(_ event: SPPiPEvent, generation: UInt64, value: Double, message: String?) {
        eventHistory.append(["event": event.rawValue, "generation": generation,
                             "monotonicSeconds": ProcessInfo.processInfo.systemUptime, "source": "native bridge callback"])
        if eventHistory.count > 64 { eventHistory.removeFirst(eventHistory.count - 64) }
        guard ownershipTicket == generation else { ignoredStaleCallbacks += 1; return }
        switch event {
        case .started:
            startedCallbacks += 1; observedWindowClass = message
            if lifecycle.observeStart(generation) { publish(); onRedraw?() }
            else if state == .exiting {
                // Native bridge owns the pending exit and issues it once after
                // actual panel observation. Do not duplicate its selector here.
                lateStartedWhileExitingCount += 1
            } else if state == .disabled {
                lateStartedWhileExitingCount += 1; bridge.dismiss(generation: generation)
            }
        case .willClose:
            willCloseCallbacks += 1; _ = lifecycle.beginExit(); publish()
        case .closed:
            closedCallbacks += 1
            nativeDetached = true
            _ = lifecycle.close(generation)
            if let saved = attachment, !restore(saved) { error = "无法恢复原视频容器"; lifecycle.disable(); publish(); return }
            attachment = nil; ownershipTicket = nil; normallyClosed.insert(generation)
            normalCloseCount += 1; normalCloseOrder.append(generation)
            if normalCloseOrder.count > 64 { normallyClosed.remove(normalCloseOrder.removeFirst()) }
            publish()
        case .failed: _ = recover(generation, reason: message ?? "系统画中画发生错误", disable: true)
        case .play: if state == .active { onPlay?() }
        case .pause: if state == .active { onPause?() }
        case .stop: if state == .active { onStop?() }
        case .skip: if state == .active && value.isFinite { onSkip?(value) }
        case .redraw: onRedraw?()
        @unknown default: break
        }
    }
}
