import Foundation

/// Persistent playback preferences, shared by the player and its controls.
public struct PlaybackSettings: Codable, Equatable {
    public var processing = ProcessingSettings()
    public var brightness = 0.0
    public var contrast = 0.0
    public var saturation = 0.0
    public var gamma = 0.0
    public var hue = 0.0
    public var rotation = 0
    public var aspect = "-1"
    public var zoom = 0.0
    public var panX = 0.0
    public var panY = 0.0
    public var sharpen = 0.0
    public var denoise = 0.0
    public var flipHorizontal = false
    public var flipVertical = false
    public var deinterlace = false
    public var equalizerEnabled = false
    /// Gain in dB at 32, 64, 125, 250, 500, 1000, 2000, 4000, 8000 and 16000 Hz.
    public var equalizer = Array(repeating: 0.0, count: 10)
    public var normalizeAudio = false
    public var channelMode = "auto-safe"
    public var audioDevice = "auto"
    public var subtitleFont = "Heiti SC"
    public var subtitleSize = 40.0
    public var subtitlePosition = 100.0
    public var subtitleColor = "#FFFFFF"
    public var subtitleOutline = 2.0
    public var subtitleBackground = false
    public var secondarySubtitleID = 0
    public var secondarySubtitleStyle: SecondarySubtitleStyleSettings? = nil
    public var secondarySubtitlePosition = 0.0
    public var preferredAudioLanguages = "zh,zho,chi,en,eng"
    public var preferredSubtitleLanguages = "zh,zho,chi,en,eng"
    public var hardwareDecoder = "videotoolbox"
    public var cacheMB = 128
    public var theme = "dark"
    public var keepOnTop = false
    public var preventSleep = true
    public var screenshotFormat = "png"
    public var screenshot = ScreenshotPreferences()
    public var autoplay = true
    public var subtitleVisible = true

    public init() {}

    /// Constrain persisted or imported preferences before passing them to playback.
    public func sanitized() -> Self {
        var result = self
        result.processing = processing.sanitized()
        result.brightness = Self.finite(brightness, in: -100...100)
        result.contrast = Self.finite(contrast, in: -100...100)
        result.saturation = Self.finite(saturation, in: -100...100)
        result.gamma = Self.finite(gamma, in: -100...100)
        result.hue = Self.finite(hue, in: -100...100)
        result.rotation = [0, 90, 180, 270].contains(rotation) ? rotation : 0
        result.aspect = Self.option(aspect, among: ["-1", "16:9", "4:3", "2.35:1", "1:1"], fallback: "-1")
        result.zoom = Self.finite(zoom, in: -2...4)
        result.panX = Self.finite(panX, in: -1...1)
        result.panY = Self.finite(panY, in: -1...1)
        result.sharpen = Self.finite(sharpen, in: 0...3)
        result.denoise = Self.finite(denoise, in: 0...5)
        result.equalizer = (0..<10).map { index in
            Self.finite(index < equalizer.count ? equalizer[index] : 0, in: -12...12)
        }
        result.channelMode = Self.option(channelMode, among: ["auto-safe", "stereo", "mono", "5.1", "7.1"], fallback: "auto-safe")
        result.audioDevice = Self.text(audioDevice, fallback: "auto", maxLength: 512)
        result.subtitleFont = Self.text(subtitleFont, fallback: "Heiti SC", maxLength: 128)
        result.subtitleSize = Self.finite(subtitleSize, in: 12...100, fallback: 40)
        result.subtitlePosition = Self.finite(subtitlePosition, in: 0...100, fallback: 100)
        result.subtitleColor = Self.color(subtitleColor)
        result.subtitleOutline = Self.finite(subtitleOutline, in: 0...10, fallback: 2)
        result.secondarySubtitleID = max(0, secondarySubtitleID)
        result.secondarySubtitleStyle = secondarySubtitleStyle?.sanitized()
        result.secondarySubtitlePosition = Self.finite(secondarySubtitlePosition, in: 0...100)
        result.preferredAudioLanguages = Self.languages(preferredAudioLanguages)
        result.preferredSubtitleLanguages = Self.languages(preferredSubtitleLanguages)
        result.hardwareDecoder = Self.option(hardwareDecoder, among: ["videotoolbox", "videotoolbox-copy", "no"], fallback: "videotoolbox")
        result.cacheMB = min(2048, max(16, cacheMB))
        result.theme = Self.option(theme, among: ["dark", "system", "light"], fallback: "dark")
        result.screenshotFormat = Self.option(screenshotFormat, among: ["png", "jpg", "webp"], fallback: "png")
        result.screenshot = screenshot.sanitized()
        return result
    }

    private static func finite(_ value: Double, in range: ClosedRange<Double>, fallback: Double = 0) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    private static func option(_ value: String, among allowed: [String], fallback: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowed.contains(normalized) ? normalized : fallback
    }

    private static func text(_ value: String, fallback: String, maxLength: Int) -> String {
        let cleaned = value.components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(maxLength))
    }

    private static func color(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard cleaned.count == 7, cleaned.first == "#", cleaned.dropFirst().allSatisfy({ "0123456789ABCDEF".contains($0) }) else { return "#FFFFFF" }
        return cleaned
    }

    private static func languages(_ value: String) -> String {
        var seen = Set<String>()
        return value.replacingOccurrences(of: "，", with: ",").split(separator: ",").compactMap { raw -> String? in
            let language = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !language.isEmpty, language.count <= 16,
                  language.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) }),
                  seen.insert(language).inserted, seen.count <= 16 else { return nil }
            return language
        }.joined(separator: ",")
    }

    private enum CodingKeys: String, CodingKey {
        case processing, screenshot
        case brightness, contrast, saturation, gamma, hue, rotation, aspect, zoom, panX, panY, sharpen, denoise
        case flipHorizontal, flipVertical, deinterlace, equalizerEnabled, equalizer, normalizeAudio, channelMode, audioDevice
        case subtitleFont, subtitleSize, subtitlePosition, subtitleColor, subtitleOutline, subtitleBackground
        case secondarySubtitleID, secondarySubtitlePosition, secondarySubtitleStyle, preferredAudioLanguages, preferredSubtitleLanguages
        case hardwareDecoder, cacheMB, theme, keepOnTop, preventSleep, screenshotFormat, autoplay, subtitleVisible
    }

    /// Missing or malformed fields keep their defaults so older preference files can migrate safely.
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        processing = values.value(.processing, default: processing)
        screenshot = values.value(.screenshot, default: screenshot)
        brightness = values.value(.brightness, default: brightness)
        contrast = values.value(.contrast, default: contrast)
        saturation = values.value(.saturation, default: saturation)
        gamma = values.value(.gamma, default: gamma)
        hue = values.value(.hue, default: hue)
        rotation = values.value(.rotation, default: rotation)
        aspect = values.value(.aspect, default: aspect)
        zoom = values.value(.zoom, default: zoom)
        panX = values.value(.panX, default: panX)
        panY = values.value(.panY, default: panY)
        sharpen = values.value(.sharpen, default: sharpen)
        denoise = values.value(.denoise, default: denoise)
        flipHorizontal = values.value(.flipHorizontal, default: flipHorizontal)
        flipVertical = values.value(.flipVertical, default: flipVertical)
        deinterlace = values.value(.deinterlace, default: deinterlace)
        equalizerEnabled = values.value(.equalizerEnabled, default: equalizerEnabled)
        equalizer = values.value(.equalizer, default: equalizer)
        normalizeAudio = values.value(.normalizeAudio, default: normalizeAudio)
        channelMode = values.value(.channelMode, default: channelMode)
        audioDevice = values.value(.audioDevice, default: audioDevice)
        subtitleFont = values.value(.subtitleFont, default: subtitleFont)
        subtitleSize = values.value(.subtitleSize, default: subtitleSize)
        subtitlePosition = values.value(.subtitlePosition, default: subtitlePosition)
        subtitleColor = values.value(.subtitleColor, default: subtitleColor)
        subtitleOutline = values.value(.subtitleOutline, default: subtitleOutline)
        subtitleBackground = values.value(.subtitleBackground, default: subtitleBackground)
        secondarySubtitleID = values.value(.secondarySubtitleID, default: secondarySubtitleID)
        secondarySubtitleStyle = values.value(.secondarySubtitleStyle, default: secondarySubtitleStyle)
        secondarySubtitlePosition = values.value(.secondarySubtitlePosition, default: secondarySubtitlePosition)
        preferredAudioLanguages = values.value(.preferredAudioLanguages, default: preferredAudioLanguages)
        preferredSubtitleLanguages = values.value(.preferredSubtitleLanguages, default: preferredSubtitleLanguages)
        hardwareDecoder = values.value(.hardwareDecoder, default: hardwareDecoder)
        cacheMB = values.value(.cacheMB, default: cacheMB)
        theme = values.value(.theme, default: theme)
        keepOnTop = values.value(.keepOnTop, default: keepOnTop)
        preventSleep = values.value(.preventSleep, default: preventSleep)
        screenshotFormat = values.value(.screenshotFormat, default: screenshotFormat)
        autoplay = values.value(.autoplay, default: autoplay)
        subtitleVisible = values.value(.subtitleVisible, default: subtitleVisible)
        self = sanitized()
    }
}

private extension KeyedDecodingContainer {
    func value<Value: Decodable>(_ key: Key, default fallback: Value) -> Value {
        (try? decodeIfPresent(Value.self, forKey: key)) ?? fallback
    }
}
