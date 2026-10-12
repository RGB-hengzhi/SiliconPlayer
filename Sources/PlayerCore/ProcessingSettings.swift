import Foundation

public struct ProcessingSettings: Codable, Equatable {
    public var deband = false
    public var scaler = "bilinear"
    public var interpolation = false
    public var forceSDR = false
    public var toneMapping = "auto"
    public var stereoInput = "off"
    public var stereoOutput = "ml"
    public var projection = "off"
    public var yaw = 0.0
    public var pitch = 0.0
    public var fieldOfView = 90.0
    public var cropWidth = 1.0
    public var cropHeight = 1.0
    public var assOverride = "scale"
    public var subtitleEncoding = "auto"
    public var subtitleFPS = 0.0
    public var secondarySubtitleDelay = 0.0
    public var audioExclusive = false
    public var audioSampleRate = 0
    public var pitchCorrection = true
    public var pitchSemitones = 0.0
    public var crossfeed = false
    public var limiter = true
    public var swapChannels = false

    public init() {}
    public func sanitized() -> Self {
        var result = self
        func option(_ value: String, _ allowed: [String], _ fallback: String) -> String { allowed.contains(value) ? value : fallback }
        func finite(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double = 0) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        result.scaler = option(scaler, ["bilinear", "bicubic", "lanczos", "ewa_lanczossharp"], "bilinear")
        result.toneMapping = option(toneMapping, ["auto", "mobius", "reinhard", "hable", "bt.2390", "clip"], "auto")
        result.stereoInput = option(stereoInput, ["off", "sbsl", "sbsr", "abl", "abr"], "off")
        result.stereoOutput = option(stereoOutput, ["ml", "mr", "arcd", "arcc", "sbsl", "sbsr"], "ml")
        result.projection = option(projection, ["off", "equirect", "c3x2", "eac"], "off")
        result.yaw = finite(yaw, -180...180); result.pitch = finite(pitch, -90...90)
        result.fieldOfView = finite(fieldOfView, 30...150, 90)
        result.cropWidth = finite(cropWidth, 0.1...1, 1); result.cropHeight = finite(cropHeight, 0.1...1, 1)
        result.assOverride = option(assOverride, ["no", "scale", "force", "strip"], "scale")
        result.subtitleEncoding = option(subtitleEncoding, ["auto", "utf-8", "+gb18030", "+big5", "+utf-16"], "auto")
        result.subtitleFPS = finite(subtitleFPS, 0...120)
        result.secondarySubtitleDelay = finite(secondarySubtitleDelay, -600...600)
        result.audioSampleRate = [0, 44100, 48000, 96000, 192000].contains(audioSampleRate) ? audioSampleRate : 0
        result.pitchSemitones = finite(pitchSemitones, -12...12)
        return result
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case deband, scaler, interpolation, forceSDR, toneMapping, stereoInput, stereoOutput, projection, yaw, pitch, fieldOfView
        case cropWidth, cropHeight, assOverride, subtitleEncoding, subtitleFPS, secondarySubtitleDelay
        case audioExclusive, audioSampleRate, pitchCorrection, pitchSemitones, crossfeed, limiter, swapChannels
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ value: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? value }
        deband = read(.deband, deband); scaler = read(.scaler, scaler); interpolation = read(.interpolation, interpolation)
        forceSDR = read(.forceSDR, forceSDR); toneMapping = read(.toneMapping, toneMapping)
        stereoInput = read(.stereoInput, stereoInput); stereoOutput = read(.stereoOutput, stereoOutput)
        projection = read(.projection, projection); yaw = read(.yaw, yaw); pitch = read(.pitch, pitch); fieldOfView = read(.fieldOfView, fieldOfView)
        cropWidth = read(.cropWidth, cropWidth); cropHeight = read(.cropHeight, cropHeight)
        assOverride = read(.assOverride, assOverride); subtitleEncoding = read(.subtitleEncoding, subtitleEncoding)
        subtitleFPS = read(.subtitleFPS, subtitleFPS); secondarySubtitleDelay = read(.secondarySubtitleDelay, secondarySubtitleDelay)
        audioExclusive = read(.audioExclusive, audioExclusive); audioSampleRate = read(.audioSampleRate, audioSampleRate)
        pitchCorrection = read(.pitchCorrection, pitchCorrection); pitchSemitones = read(.pitchSemitones, pitchSemitones)
        crossfeed = read(.crossfeed, crossfeed); limiter = read(.limiter, limiter); swapChannels = read(.swapChannels, swapChannels)
        self = sanitized()
    }
}
