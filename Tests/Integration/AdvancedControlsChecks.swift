import AppKit
import Foundation
import PlayerCore
import Darwin

// A command recorder, not an mpv substitute. The script supplies the current
// production applySettings() method; no image/audio output is produced.
// Video properties below are transcribed from the production pure factory;
// its async submission, decoder acceptance and lifecycle are NOT tested here.
// Secondary-subtitle styling is an explicitly untested typed dependency;
// its recorder only preserves the complete production applySettings() call.
@MainActor final class PlayerModel {
    var settings = PlaybackSettings()
    var miniMode = false
    var sleepActivity: NSObjectProtocol?
    var error: String?
    var candidateVideoFilters: [String]?
    var userVideoFilters = FilterRecorder()
    var secondarySubtitleStyle = UntestedSecondarySubtitleStyleRecorder()
    var videoHost: UntestedVideoHostDependency? { nil }
    var writes: [[String: String]] = []
    private(set) var requestedVideoFactoryCalls = 0
    func set(_ property: String, _ value: String) { writes.append(["property": property, "value": value]) }
    func setChecked(_ property: String, _ value: String) -> Int32 { set(property, value); return 0 }
    func applyVideoFilterProperties(settings: PlaybackSettings, userFragments: [String]) -> Int32 {
        let configuration = videoFilterConfiguration(settings: settings, userFragments: userFragments)
        requestedVideoFactoryCalls += 1
        set("hwdec", configuration.decoder); set("vf", configuration.filter)
        return 0
    }
    func value(_ property: String) -> String? { writes.last { $0["property"] == property }?["value"] }
}
struct FilterRecorder { var effectiveFragments: [String] = [] }

// This is not SecondarySubtitleStyleRuntime: it never calls mpv or verifies
// style properties, rendering, primary/secondary isolation or performance.
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

@main struct AdvancedControlsChecks {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NSError(domain: "AdvancedControlsChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func main() throws {
        setbuf(stdout, nil); _ = NSApplication.shared
        let player = PlayerModel()
        var cases: [[String: Any]] = []
        func record(_ title: String) { cases.append(["name": title, "writes": player.writes, "requestedVideoFactoryCalls": player.requestedVideoFactoryCalls]); print("PASS \(title)") }
        player.applySettings()
        try require(player.value("vf") == "" && player.value("af") == "" && player.value("hwdec") == "videotoolbox", "Defaults retained a processing filter")
        record("default filter clearing and requested hardware decoder")
        player.writes = []
        player.settings.flipHorizontal = true; player.settings.flipVertical = true; player.settings.denoise = 1
        player.settings.processing.cropWidth = 0.5; player.settings.processing.cropHeight = 0.75
        player.settings.processing.stereoInput = "sbsl"; player.settings.processing.stereoOutput = "ml"
        player.settings.processing.projection = "equirect"; player.settings.processing.yaw = 90
        player.settings.processing.fieldOfView = 120; player.settings.processing.forceSDR = true
        player.applySettings()
        let vf = player.value("vf") ?? ""
        for token in ["hflip", "vflip", "hqdn3d=", "crop=", "stereo3d=sbsl:ml", "v360=input=equirect:"] {
            try require(vf.contains(token), "Combined video chain lost \(token)")
        }
        try require(player.value("hwdec") == "videotoolbox-copy" && player.value("target-prim") == "bt.709", "Filter decoder/SDR target orchestration invalid")
        try require(player.writes.filter { $0["property"] == "vf" }.count == 1, "Multiple video chain assignments")
        record("combined geometry/denoise/stereo/360 chain and copy decoder selection")
        player.writes = []; player.settings.processing.projection = "off"; player.applySettings()
        let reduced = player.value("vf") ?? ""
        try require(!reduced.contains("v360=") && reduced.contains("stereo3d=") && reduced.contains("crop=") && reduced.contains("hqdn3d="), "Disabling projection removed unrelated video processing")
        player.settings.hardwareDecoder = "no"; player.applySettings()
        try require(player.value("hwdec") == "no", "A filter overrode requested software decoding")
        record("independent video toggle and explicit software-decoder preservation")
        player.writes = []
        player.settings.equalizerEnabled = true; player.settings.equalizer = EqualizerPreset.rock.gains
        player.settings.normalizeAudio = true; player.settings.processing.swapChannels = true
        player.settings.processing.pitchSemitones = 3; player.settings.processing.crossfeed = true
        player.applySettings()
        let af = player.value("af") ?? ""
        try require(af.components(separatedBy: "equalizer=f=").count - 1 == 10, "EQ chain does not contain all ten bands")
        for token in ["dynaudnorm=", "pan=stereo", "rubberband=pitch=", "bs2b", "alimiter="] {
            try require(af.contains(token), "Combined audio chain lost \(token)")
        }
        try require(player.writes.filter { $0["property"] == "af" }.count == 1, "Multiple audio chain assignments")
        record("ten EQ bands and combined normalization/channel/pitch/crossfeed/limiter chain")
        player.writes = []; player.settings.equalizerEnabled = false; player.applySettings()
        try require(!(player.value("af") ?? "").contains("equalizer=") && (player.value("af") ?? "").contains("dynaudnorm="), "Disabling EQ removed unrelated audio processing")
        player.settings = PlaybackSettings(); player.applySettings()
        try require(player.value("vf") == "" && player.value("af") == "" && player.value("hwdec") == "videotoolbox", "Reset retained old filters/decoder mode")
        record("independent EQ toggle and resetting both filter chains")
        player.writes = []
        player.settings.secondarySubtitleID = 2; player.settings.secondarySubtitlePosition = 15
        player.settings.processing.secondarySubtitleDelay = 1.5
        player.settings.brightness = .nan; player.settings.cacheMB = Int.max
        player.settings.equalizerEnabled = true; player.settings.equalizer = [.infinity, 99, -99]
        player.applySettings()
        try require(player.value("secondary-sid") == "2" && player.value("secondary-sub-pos") == "15.0" && player.value("secondary-sub-delay") == "1.5", "Secondary subtitle settings not forwarded independently")
        try require(player.value("brightness") == "0.0" && player.value("demuxer-max-bytes") == String(2048 * 1024 * 1024), "Invalid preferences were not sanitized before commands")
        try require(!player.writes.contains { ($0["value"] ?? "").lowercased().contains("nan") || ($0["value"] ?? "").lowercased().contains("inf") }, "Nonfinite values escaped into a command")
        try require((player.value("af") ?? "").components(separatedBy: "equalizer=f=").count - 1 == 10, "Malformed EQ array produced an incomplete chain")
        record("subtitle independence and invalid-value sanitation before command dispatch")
        try require(player.secondarySubtitleStyle.requestedStyles.count == player.requestedVideoFactoryCalls,
                    "Full applySettings did not call the untested secondary-style dependency once per video factory call")
        let secondaryRequests = try JSONSerialization.jsonObject(with: JSONEncoder().encode(player.secondarySubtitleStyle.requestedStyles))
        let report: [String: Any] = ["passed": true, "cases": cases,
            "videoLifecycleTested": false,
            "secondarySubtitleStyleTested": false,
            "untestedSecondarySubtitleStyleRequests": secondaryRequests,
            "secondarySubtitleStyleRecorderReturnedSuccess": true,
            "compiledVideoScope": "production configuredVideoFragments and videoFilterConfiguration only; recorder transcribes requested properties",
            "scope": "current applySettings and requested-configuration orchestration only; no asynchronous video lifecycle, mpv acceptance, secondary-subtitle style/rendering/performance, pixel/HDR/colour or audible frequency-response/quality inference"]
        if CommandLine.arguments.count == 2 {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("6 advanced control orchestration groups passed; commands are recorded, not rendered or heard")
    }
}
