import AppKit
import SwiftUI

/// Diagnostic-only carrier comparison. Not enabled by a normal/daily launch.
/// Hosts the production settings content unchanged, with its existing model.
@MainActor
final class AdvancedWindowDiagnosticPresenter: NSObject, NSWindowDelegate {
    static let shared = AdvancedWindowDiagnosticPresenter()

    static var enabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["SILICONPLAYER_VERIFY_ADVANCED_WINDOW_DIAGNOSTIC"] == "1"
            && environment["SILICONPLAYER_VERIFY_MODE"] == "native-ui-manual"
            && InputController.verificationSuiteName(environment: environment) != nil
    }

    private weak var player: PlayerModel?
    private weak var parentWindow: NSWindow?
    private var window: NSWindow?
    private var synchronizationQueued = false

    /// @Published emits before assignment. Read the latest Boolean on the next
    /// main run-loop turn; a stale queued open notification cannot reopen a close.
    func requestSynchronization(player: PlayerModel) {
        guard Self.enabled else { return }
        if let bound = self.player, bound !== player, window != nil { return }
        self.player = player
        guard !synchronizationQueued else { return }
        synchronizationQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.synchronizationQueued = false
            guard Self.enabled, let player = self.player else { return }
            if player.showAdvanced { self.present(player: player) }
            else { self.window?.close() }
        }
    }

    /// Global playback bindings must not capture controls in this plain window.
    func ownsPlaybackInput(_ event: NSEvent) -> Bool {
        guard Self.enabled, let window else { return false }
        return event.window === window || NSApp.keyWindow === window
    }

    private func present(player: PlayerModel) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        guard let parent = player.playerWindow, parent.isVisible else {
            player.showAdvanced = false
            player.toast("高级设置诊断窗口未找到当前播放器主窗口")
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "高级播放设置"
        window.identifier = NSUserInterfaceItemIdentifier("advanced-settings-diagnostic")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        // Same production tree, same PlayerModel and real settings bindings.
        // No reparenting of MPVVideoHost or hiding of accessibility descendants.
        window.contentView = NSHostingView(rootView: AdvancedControlsView(player: player))
        self.window = window
        parentWindow = parent
        NotificationCenter.default.addObserver(self, selector: #selector(parentWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: parent)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate(_:)),
                                               name: NSApplication.willTerminateNotification, object: NSApp)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        // Done already commits its original drafts and sets showAdvanced=false.
        // Chrome close only clears the presentation flag; it adds no new commit.
        player?.showAdvanced = false
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: parentWindow)
        NotificationCenter.default.removeObserver(self, name: NSApplication.willTerminateNotification, object: NSApp)
        parentWindow = nil
        closed.contentView = nil
        window = nil
    }

    @objc private func parentWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === parentWindow else { return }
        window?.close()
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        window?.close()
    }
}
