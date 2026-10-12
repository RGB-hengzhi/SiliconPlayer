import AppKit
import SwiftUI

/// A real AppKit color well with an explicit, scoped native-panel presentation.
/// It never owns a playback setting; changes still use the supplied checked binding.
@MainActor
struct NativeSubtitleColorWell: NSViewRepresentable {
    @Binding var selection: Color
    let contextID: UUID
    let supportsAlpha: Bool
    let accessibilityName: String
    let isContextCurrent: () -> Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }
    func makeNSView(context: Context) -> ModalSubtitleColorWell {
        let well = ModalSubtitleColorWell(frame: .zero)
        well.colorWellStyle = .minimal
        well.coordinator = context.coordinator
        well.target = context.coordinator
        well.action = #selector(Coordinator.changed(_:))
        well.pulldownTarget = context.coordinator
        well.pulldownAction = #selector(Coordinator.openPanel(_:))
        context.coordinator.well = well
        updateNSView(well, context: context)
        return well
    }
    func updateNSView(_ well: ModalSubtitleColorWell, context: Context) {
        let coordinator = context.coordinator
        if coordinator.owner.contextID != contextID || !isEnabled || !isContextCurrent() {
            coordinator.retire(hidePanel: true)
        }
        coordinator.owner = self
        well.isEnabled = isEnabled
        well.supportsAlpha = supportsAlpha
        well.setAccessibilityLabel(accessibilityName)
        well.color = NSColor(selection)
    }
    static func dismantleNSView(_ well: ModalSubtitleColorWell, coordinator: Coordinator) {
        coordinator.retire(hidePanel: true)
        well.target = nil; well.action = nil
        well.pulldownTarget = nil; well.pulldownAction = nil
        well.coordinator = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        fileprivate var owner: NativeSubtitleColorWell
        fileprivate weak var well: ModalSubtitleColorWell?
        private static weak var active: Coordinator?
        private var savedWorksWhenModal: Bool?
        private var savedLevel: NSWindow.Level?
        private var capturedContextID: UUID?

        init(owner: NativeSubtitleColorWell) { self.owner = owner }
        @objc func openPanel(_ sender: NSColorWell) { well?.activate(true) }
        fileprivate func preparePanel() -> Bool {
            guard let well, well.isEnabled, let parent = well.window,
                  parent.isVisible, owner.isContextCurrent() else { return false }
            if Self.active !== self {
                Self.active?.retire(hidePanel: false)
                let panel = NSColorPanel.shared
                savedWorksWhenModal = panel.worksWhenModal
                savedLevel = panel.level
                Self.active = self
                NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                    name: NSWindow.willCloseNotification, object: panel)
                NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                    name: NSWindow.willCloseNotification, object: parent)
            }
            capturedContextID = owner.contextID
            let panel = NSColorPanel.shared
            panel.worksWhenModal = true
            panel.level = NSWindow.Level(rawValue: max(panel.level.rawValue, parent.level.rawValue))
            return true
        }
        @objc func changed(_ sender: NSColorWell) {
            guard let well, sender === well, Self.active === self, well.isActive,
                  capturedContextID == owner.contextID, sender.isEnabled,
                  owner.isContextCurrent() else {
                retire(hidePanel: true); return
            }
            owner.selection = Color(nsColor: sender.color)
        }
        @objc private func windowWillClose(_ notice: Notification) { retire(hidePanel: true) }
        fileprivate func retire(hidePanel: Bool) {
            capturedContextID = nil
            guard Self.active === self else { return }
            Self.active = nil
            NotificationCenter.default.removeObserver(self)
            let panel = NSColorPanel.shared
            if let savedWorksWhenModal { panel.worksWhenModal = savedWorksWhenModal }
            if let savedLevel { panel.level = savedLevel }
            savedWorksWhenModal = nil; savedLevel = nil
            if hidePanel { panel.orderOut(nil) }
            well?.deactivate()
        }
    }
}

@MainActor
final class ModalSubtitleColorWell: NSColorWell {
    fileprivate weak var coordinator: NativeSubtitleColorWell.Coordinator?
    override func activate(_ exclusive: Bool) {
        guard coordinator?.preparePanel() == true else { NSSound.beep(); return }
        super.activate(exclusive)
        NSColorPanel.shared.makeKeyAndOrderFront(nil)
    }
    override func deactivate() {
        super.deactivate()
        coordinator?.retire(hidePanel: false)
    }
}
