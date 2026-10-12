import Foundation
#if !PLAYER_CORE_STANDALONE
import XCTest
@testable import PlayerCore
#endif

final class EqualizerPresetTests: XCTestCase {
    func testAllPresetsHaveUniqueValidTenBandCurves() {
        XCTAssertFalse(EqualizerPreset.all.isEmpty)
        XCTAssertEqual(Set(EqualizerPreset.all.map(\.id)).count, EqualizerPreset.all.count)
        XCTAssertEqual(Set(EqualizerPreset.all.map(\.gains)).count, EqualizerPreset.all.count)
        for preset in EqualizerPreset.all {
            XCTAssertFalse(preset.id.isEmpty)
            XCTAssertFalse(preset.title.isEmpty)
            XCTAssertEqual(preset.gains.count, 10, preset.id)
            XCTAssertTrue(preset.gains.allSatisfy { $0.isFinite && (-12...12).contains($0) }, preset.id)
        }
    }

    func testMatchingRecognizesPresetsAndRejectsCustomCurves() {
        for preset in EqualizerPreset.all {
            XCTAssertEqual(EqualizerPreset.matching(gains: preset.gains), preset)
            var manuallyAdjusted = preset.gains
            manuallyAdjusted[4] += 0.125
            XCTAssertNil(EqualizerPreset.matching(gains: manuallyAdjusted), preset.id)
        }
        XCTAssertNil(EqualizerPreset.matching(gains: Array(repeating: 0.5, count: 10)))
    }

    func testMatchingRejectsMalformedAndNonFiniteCurves() {
        for count in [0, 1, 9, 11, 20] {
            XCTAssertNil(EqualizerPreset.matching(gains: Array(repeating: 0.0, count: count)))
        }
        for invalidValue in [Double.nan, .infinity, -.infinity, 12.01, -12.01] {
            for band in 0..<10 {
                var invalid = EqualizerPreset.flat.gains
                invalid[band] = invalidValue
                XCTAssertNil(EqualizerPreset.matching(gains: invalid))
            }
        }
    }

    func testSanitizingPreservesEveryValidPresetAndUnrelatedSettings() {
        for preset in EqualizerPreset.all {
            for enabled in [false, true] {
                var settings = PlaybackSettings()
                settings.equalizerEnabled = enabled
                settings.equalizer = preset.gains
                settings.brightness = 27.5
                settings.cacheMB = 256
                settings.subtitleColor = "#7A91BC"
                settings.preventSleep = false
                let sanitized = settings.sanitized()
                XCTAssertEqual(sanitized, settings, preset.id)
                XCTAssertEqual(EqualizerPreset.matching(gains: sanitized.equalizer), preset)
            }
        }
    }

    func testJSONRoundTripPreservesEnabledPresetAndUnrelatedSettings() throws {
        for preset in EqualizerPreset.all {
            for enabled in [false, true] {
                var settings = PlaybackSettings()
                settings.equalizerEnabled = enabled
                settings.equalizer = preset.gains
                settings.theme = "light"
                settings.subtitleSize = 56
                settings.audioDevice = "coreaudio/device-for-test"
                settings.normalizeAudio = true
                let restored = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings))
                XCTAssertEqual(restored, settings, preset.id)
                XCTAssertEqual(restored.equalizerEnabled, enabled)
                XCTAssertEqual(restored.equalizer, preset.gains)
                XCTAssertEqual(restored.audioDevice, settings.audioDevice)
                XCTAssertEqual(EqualizerPreset.matching(gains: restored.equalizer), preset)
            }
        }
    }
}
