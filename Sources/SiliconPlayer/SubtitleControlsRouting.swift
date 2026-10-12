import Foundation

@MainActor
extension PlayerModel {
    /// A presentation request only; it does not change tracks or saved settings.
    func openSubtitleSettings() {
        advancedSettingsInitialTab = "subtitles"
        showAdvanced = true
    }
}
