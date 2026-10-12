import Foundation

public enum SubtitlePreservationError: LocalizedError {
    case invalid(String), precision, bounds, missingCue, unsafeSourceDestination
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "字幕格式无效：\(detail)"
        case .precision: return "校准结果不能精确写入原格式；可明确选择按原格式刻度舍入。"
        case .bounds: return "字幕时间越界、比例倒置或校准后时长不足一个刻度；原文保持不变。"
        case .missingCue: return "所选字幕已不存在。"
        case .unsafeSourceDestination: return "请保存到另一文件；原始字幕保持不变。"
        }
    }
}

/// The only Double boundary is an explicitly observed player clock. File
/// parsing, affine mapping and quantization never use floating-point arithmetic.
public enum SubtitleExactClock {
    public static let maximumMicroseconds: Int64 = 999_999_999_000_000
    public static func parse(_ value: String) throws -> Int64 {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { throw SubtitlePreservationError.invalid("时间需要分:秒或时:分:秒") }
        let whole = parts.last!.split(separator: ".", omittingEmptySubsequences: false)
        guard whole.count == 2, (1...6).contains(whole[1].count),
              let seconds = digits(whole[0]), seconds < 60,
              let minutes = digits(parts[parts.count - 2]), minutes < 60,
              let hours = parts.count == 3 ? digits(parts[0]) : 0,
              let fraction = digits(whole[1]) else { throw SubtitlePreservationError.invalid("时间数字或小数精度") }
        let h = hours.multipliedReportingOverflow(by: 3_600_000_000)
        let m = minutes.multipliedReportingOverflow(by: 60_000_000)
        guard !h.overflow, !m.overflow else { throw SubtitlePreservationError.bounds }
        let base = h.partialValue.addingReportingOverflow(m.partialValue)
        guard !base.overflow else { throw SubtitlePreservationError.bounds }
        let result = base.partialValue.addingReportingOverflow(seconds * 1_000_000 + fraction * powers[6 - whole[1].count])
        guard !result.overflow, result.partialValue <= maximumMicroseconds else { throw SubtitlePreservationError.bounds }
        return result.partialValue
    }
    public static func decimal(_ value: String, signed: Bool) throws -> (numerator: Int64, denominator: Int64) {
        var text = value.trimmingCharacters(in: .whitespaces)
        let negative = text.hasPrefix("-")
        if negative || text.hasPrefix("+") { text.removeFirst() }
        guard signed || !negative else { throw SubtitlePreservationError.bounds }
        let p = text.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 1 || p.count == 2, let whole = digits(p[0]),
              p.count == 1 || ((1...6).contains(p[1].count) && digits(p[1]) != nil) else {
            throw SubtitlePreservationError.invalid("需要最多六位小数的十进制数")
        }
        let den = p.count == 2 ? powers[p[1].count] : 1
        let product = whole.multipliedReportingOverflow(by: den)
        let total = product.partialValue.addingReportingOverflow(p.count == 2 ? digits(p[1])! : 0)
        guard !product.overflow, !total.overflow else { throw SubtitlePreservationError.bounds }
        return (negative ? -total.partialValue : total.partialValue, den)
    }
    public static func observedPlayerSeconds(_ seconds: Double) throws -> Int64 {
        guard seconds.isFinite, seconds >= 0, seconds <= Double(maximumMicroseconds) / 1_000_000 else {
            throw SubtitlePreservationError.bounds
        }
        return Int64((seconds * 1_000_000).rounded())
    }
    static func digits(_ text: Substring) -> Int64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(text)
    }
    static let powers: [Int64] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000]
}

public enum SubtitleQuantization: Sendable { case exact, nearestNativeTick }

/// Positive affine map: videoA + (source-sourceA)*(videoB-videoA)/(sourceB-sourceA).
/// Swift full-width unsigned multiplication retains all 128 product bits. This
/// avoids both Double drift and an Int128 deployment/runtime dependency.
public struct SubtitleTwoPointMap: Sendable {
    public let sourceA: Int64, sourceB: Int64, videoA: Int64, videoB: Int64
    public init(sourceA: Int64, videoA: Int64, sourceB: Int64, videoB: Int64) throws {
        guard [sourceA, sourceB, videoA, videoB].allSatisfy({ $0 >= 0 && $0 <= SubtitleExactClock.maximumMicroseconds }),
              sourceB > sourceA, videoB > videoA else { throw SubtitlePreservationError.bounds }
        self.sourceA = sourceA; self.sourceB = sourceB; self.videoA = videoA; self.videoB = videoB
    }
    /// Decimal frame-rate labels are exact rationals. For an NTSC rate use an
    /// explicit two-anchor ratio (e.g. 1001 vs 1000); 23.976 is the literal decimal.
    public static func frameRateConversion(subtitleFPS: String, videoFPS: String) throws -> Self {
        let a = try SubtitleExactClock.decimal(subtitleFPS, signed: false)
        let b = try SubtitleExactClock.decimal(videoFPS, signed: false)
        guard a.numerator > 0, b.numerator > 0,
              a.numerator <= a.denominator * 1_000, b.numerator <= b.denominator * 1_000 else { throw SubtitlePreservationError.bounds }
        let numerator = a.numerator.multipliedReportingOverflow(by: b.denominator)
        let denominator = a.denominator.multipliedReportingOverflow(by: b.numerator)
        guard !numerator.overflow, !denominator.overflow else { throw SubtitlePreservationError.bounds }
        var x = numerator.partialValue, y = denominator.partialValue
        while y != 0 { let remainder = x % y; x = y; y = remainder }
        return try Self(sourceA: 0, videoA: 0, sourceB: denominator.partialValue / x, videoB: numerator.partialValue / x)
    }
    public func map(_ source: Int64, quantum: Int64, quantization: SubtitleQuantization = .exact) throws -> Int64 {
        guard source >= 0, source <= SubtitleExactClock.maximumMicroseconds,
              quantum > 0, quantum <= 10_000 else { throw SubtitlePreservationError.bounds }
        let dx = UInt64(sourceB - sourceA), dy = UInt64(videoB - videoA)
        let magnitude = UInt64(source >= sourceA ? source - sourceA : sourceA - source)
        let base = Wide(UInt64(videoA).multipliedFullWidth(by: dx))
        let delta = Wide(magnitude.multipliedFullWidth(by: dy))
        let total: Wide
        if source >= sourceA { total = try base.adding(delta) }
        else { total = try base.subtracting(delta) }
        let denominator = dx.multipliedReportingOverflow(by: UInt64(quantum))
        guard !denominator.overflow, total.high < denominator.partialValue else { throw SubtitlePreservationError.bounds }
        let division = denominator.partialValue.dividingFullWidth((high: total.high, low: total.low))
        var ticks = division.quotient
        if division.remainder != 0 {
            switch quantization {
            case .exact: throw SubtitlePreservationError.precision
            case .nearestNativeTick:
                let half = denominator.partialValue / 2 + denominator.partialValue % 2
                if division.remainder >= half {
                    let rounded = ticks.addingReportingOverflow(1)
                    guard !rounded.overflow else { throw SubtitlePreservationError.bounds }
                    ticks = rounded.partialValue
                }
            }
        }
        let mapped = ticks.multipliedReportingOverflow(by: UInt64(quantum))
        guard !mapped.overflow, mapped.partialValue <= UInt64(SubtitleExactClock.maximumMicroseconds) else {
            throw SubtitlePreservationError.bounds
        }
        return Int64(mapped.partialValue)
    }
    private struct Wide {
        let high: UInt64, low: UInt64
        init(_ parts: (high: UInt64, low: UInt64)) { high = parts.high; low = parts.low }
        func adding(_ other: Wide) throws -> Wide {
            let lowSum = low.addingReportingOverflow(other.low)
            let highSum = high.addingReportingOverflow(other.high)
            let carried = highSum.partialValue.addingReportingOverflow(lowSum.overflow ? 1 : 0)
            guard !highSum.overflow, !carried.overflow else { throw SubtitlePreservationError.bounds }
            return Wide((carried.partialValue, lowSum.partialValue))
        }
        func subtracting(_ other: Wide) throws -> Wide {
            guard high > other.high || (high == other.high && low >= other.low) else { throw SubtitlePreservationError.bounds }
            let difference = low.subtractingReportingOverflow(other.low)
            return Wide((high - other.high - (difference.overflow ? 1 : 0), difference.partialValue))
        }
    }
}
