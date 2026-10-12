import AppKit

extension PlayerModel {
    func temporarySpeedSnapshot() -> TemporaryPlaybackSpeedController.Snapshot? {
        guard handle != nil, !liveASRCoreClosed,
              mediaPreferenceToken == mediaPreferences.token,
              let itemID = mediaPreferences.boundItemID else { return nil }
        return .init(mediaToken: mediaPreferenceToken, itemID: itemID, speed: number("speed"),
            eligible: loaded && !isLoading && !flag("pause") && !flag("eof-reached")
                && !videoConfigurationClosing && !continuousAudioEnabled && !nativeAudioQueue.ownsEvents)
    }

    @discardableResult
    func beginTemporarySpeed(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let window = event.window, window === NSApp.keyWindow,
              videoHost?.video.window === window, NSApp.isActive,
              window.sheetParent == nil, window.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
              !(window.firstResponder is NSTableView) else { return false }
        let accepted = temporaryPlaybackSpeed.begin(code: event.keyCode,
            modifiers: event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue,
            windowNumber: window.windowNumber, isRepeat: event.isARepeat)
        if let message = temporaryPlaybackSpeed.error { toast(message) }
        return accepted
    }

    func observeTemporarySpeed() {
        temporaryPlaybackSpeed.observe()
        guard let number = temporaryPlaybackSpeed.originWindowNumber else { return }
        guard NSApp.isActive, let window = NSApp.windows.first(where: { $0.windowNumber == number }),
              window === NSApp.keyWindow, videoHost?.video.window === window,
              window.isVisible, window.sheetParent == nil,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
              !(window.firstResponder is NSTableView) else {
            _ = finishTemporarySpeed(reason: "input-focus-changed"); return
        }
    }

    func closingAfterTemporarySpeedRestore<Result>(operation: () -> Result) -> Result {
        temporaryPlaybackSpeed.closingAfterRestore(reason: "core-command-quit") {
            if let message = temporaryPlaybackSpeed.error { error = message; toast(message) }
            return operation()
        }
    }

    @discardableResult
    func finishTemporarySpeed(reason: String) -> Bool {
        let restored = temporaryPlaybackSpeed.finish(reason: reason)
        if !restored, let message = temporaryPlaybackSpeed.error { error = message; toast(message) }
        return restored
    }
}
