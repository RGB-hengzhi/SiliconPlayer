import AppKit
import Foundation
import PlayerCore
import Darwin

// The runner compiles current production applySettings() and setVolume() byte
// for byte into this recorder. Audio formulae are never duplicated here.
// Video configuration and secondary-subtitle styling below are explicitly untested
// dependencies. Their recorders preserve full applySettings() call coverage only.
@MainActor final class PlayerModel {
    var settings = PlaybackSettings()
    var miniMode = false
    var sleepActivity: NSObjectProtocol?
    var error: String?
    var candidateVideoFilters: [String]?
    var userVideoFilters = AudioFilterRecorder()
    var secondarySubtitleStyle = UntestedSecondarySubtitleStyleRecorder()
    var videoHost: UntestedVideoHostDependency? { nil }
    var volume = 100.0
    var writes: [String: String] = [:]
    private(set) var untestedVideoDependencyCalls: [[String: Any]] = []
    func set(_ name: String, _ value: String) { writes[name] = value }
    func setChecked(_ name: String, _ value: String) -> Int32 { set(name, value); return 0 }
    func applyVideoFilterProperties(settings: PlaybackSettings, userFragments: [String]) -> Int32 {
        untestedVideoDependencyCalls.append(["dependency": "video configuration NOT tested",
            "requestedDecoder": settings.hardwareDecoder, "userFragmentCount": userFragments.count, "returnedStatus": 0])
        return 0
    }
}
struct AudioFilterRecorder { var effectiveFragments: [String] = [] }

// This is not SecondarySubtitleStyleRuntime and never talks to libmpv, reads
// subtitle properties, or certifies primary/secondary styling or performance.
@MainActor final class UntestedSecondarySubtitleStyleRecorder {
    private(set) var requestedStyles: [SecondarySubtitleStyleSettings?] = []
    let status = "Secondary subtitle style dependency NOT tested"
    @discardableResult func apply(_ style: SecondarySubtitleStyleSettings?) -> Bool {
        requestedStyles.append(style)
        return true
    }
}

// This nil typed dependency preserves the complete current applySettings()
// extraction. It has no implementation, never creates a display, and does not
// test GL/Metal settings transactions, renderer ownership, output or performance.
@MainActor protocol UntestedVideoOutputTransactionDependency: AnyObject {
    func beginBaseSettingsUpdate() -> Bool
    func endBaseSettingsUpdate()
}
@MainActor struct UntestedVideoHostDependency {
    let video: any UntestedVideoOutputTransactionDependency
}

@main struct AudioSignalChains {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var cases: [[String: Any]] = []
        func record(_ id: String, volume: Double = 100, edit: (inout PlaybackSettings) -> Void = { _ in }) throws {
            let player = PlayerModel()
            edit(&player.settings); player.applySettings(); player.setVolume(volume)
            guard player.error == nil, let chain = player.writes["af"], player.untestedVideoDependencyCalls.count == 1,
                  player.secondarySubtitleStyle.requestedStyles.count == 1,
                  player.secondarySubtitleStyle.requestedStyles[0] == player.settings.sanitized().secondarySubtitleStyle else {
                throw NSError(domain: "AudioSignalChains", code: 1, userInfo: [NSLocalizedDescriptionKey: "No generated audio chain"])
            }
            let settings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(player.settings))
            let secondaryRequests = try JSONSerialization.jsonObject(with: JSONEncoder().encode(player.secondarySubtitleStyle.requestedStyles))
            cases.append(["id": id, "chain": chain, "properties": player.writes,
                          "videoConfigurationTested": false, "untestedVideoDependencyCalls": player.untestedVideoDependencyCalls,
                          "secondarySubtitleStyleTested": false, "untestedSecondarySubtitleStyleRequests": secondaryRequests,
                          "secondarySubtitleStyleRecorderReturnedSuccess": true,
                          "requestedVolume": volume, "actualVolume": player.volume, "settings": settings])
        }
        try record("baseline")
        try record("eq-3db") { $0.equalizerEnabled = true; $0.equalizer[5] = 3 }
        try record("swap") { $0.processing.swapChannels = true }
        try record("pitch-one-semitone") { $0.processing.pitchSemitones = 1 }
        try record("eq-overload-unlimited") { $0.equalizerEnabled = true; $0.equalizer[5] = 12; $0.processing.limiter = false }
        try record("eq-overload-limited") { $0.equalizerEnabled = true; $0.equalizer[5] = 12 }
        try record("volume-half", volume: 50)
        try record("volume-low-bound", volume: -25)
        try record("volume-high-bound", volume: 150)
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileNoSuchFile) }
        try JSONSerialization.data(withJSONObject: ["cases": cases], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Exported \(cases.count) actual production audio/volume configurations")
    }
}
