/// Application presets for the ten EQ bands, ordered from bass to treble.
public struct EqualizerPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let gains: [Double]

    public static let frequencies = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    public static let flat = Self(id: "flat", title: "平直", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    public static let voice = Self(id: "voice", title: "人声", gains: [-2, -1, 0, 2, 3, 4, 3, 1, 0, -1])
    public static let rock = Self(id: "rock", title: "摇滚", gains: [4, 3, 1, -1, -2, 1, 3, 4, 3, 2])
    public static let classical = Self(id: "classical", title: "古典", gains: [2, 1, 0, -1, -1, 0, 1, 2, 3, 3])
    public static let bassBoost = Self(id: "bass-boost", title: "低音增强", gains: [6, 5, 3, 1, 0, 0, 0, 0, 0, 0])
    public static let trebleBoost = Self(id: "treble-boost", title: "高音增强", gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6])
    public static let all = [flat, voice, rock, classical, bassBoost, trebleBoost]

    /// Derive the displayed preset from stored gains; manual changes need no separate state.
    public static func matching(gains: [Double]) -> Self? {
        all.first { $0.gains == gains }
    }

    private init(id: String, title: String, gains: [Double]) {
        precondition(gains.count == Self.frequencies.count && gains.allSatisfy { $0.isFinite && (-12...12).contains($0) })
        self.id = id
        self.title = title
        self.gains = gains
    }
}
