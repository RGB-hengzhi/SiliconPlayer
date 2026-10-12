import Foundation

public struct SubtitleCue: Identifiable, Codable, Hashable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String, id: UUID = UUID()) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum SubtitleDocumentError: LocalizedError {
    case unsupportedFormat(String)
    case unreadableText
    case invalidTimestamp(String)
    case malformedCue(Int)
    case invalidBounds(Int)
    case exportPrecision(Int)
    case invalidAdjustment
    case emptyDocument

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format): return "暂不支持编辑 \(format) 字幕。请选择 SRT、VTT、ASS 或 SSA 文本字幕。"
        case .unreadableText: return "无法读取字幕的文字编码。"
        case .invalidTimestamp(let text): return "时间格式无效：\(text)。请使用 00:00:00.000。"
        case .malformedCue(let line): return "字幕第 \(line) 行格式无效，无法解析时间或正文。"
        case .invalidBounds(let index): return "第 \(index) 条字幕时间无效：开始时间不能为负数，结束时间必须晚于开始时间。"
        case .exportPrecision(let index): return "第 \(index) 条字幕不足一毫秒，无法导出有效 SRT。请延长结束时间。"
        case .invalidAdjustment: return "时间调整无效。偏移必须是有限秒数，时间比例必须大于零。"
        case .emptyDocument: return "字幕文件中没有可编辑的字幕。"
        }
    }
}

/// A text editor model. ASS/VTT styling, positioning, drawings and metadata are
/// deliberately not represented; SRT export preserves timing and readable text.
public struct SubtitleDocument {
    public enum Format: String { case srt, vtt, ass, ssa }
    public static let maximumTime = 999_999_999.0
    public var cues: [SubtitleCue]
    public var sourceFormat: Format
    public var losesFormatting: Bool { sourceFormat != .srt }

    public init(cues: [SubtitleCue] = [], sourceFormat: Format = .srt) {
        self.cues = cues
        self.sourceFormat = sourceFormat
    }

    public static func read(from url: URL) throws -> SubtitleDocument {
        guard let format = Format(rawValue: url.pathExtension.lowercased()) else {
            throw SubtitleDocumentError.unsupportedFormat(url.pathExtension)
        }
        guard let text = DocumentTextDecoder.decode(try Data(contentsOf: url)) else { throw SubtitleDocumentError.unreadableText }
        return try parse(text, format: format)
    }

    public static func parse(_ text: String, format: Format = .srt) throws -> SubtitleDocument {
        let normalized = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let cues = try format == .ass || format == .ssa ? parseASS(normalized) : parseTimedText(normalized, format: format)
        guard !cues.isEmpty else { throw SubtitleDocumentError.emptyDocument }
        let document = SubtitleDocument(cues: cues, sourceFormat: format)
        try document.validate()
        return document
    }

    public func validate() throws {
        for (index, cue) in cues.enumerated() {
            guard cue.start.isFinite, cue.end.isFinite, cue.start >= 0, cue.end > cue.start,
                  cue.end <= Self.maximumTime else { throw SubtitleDocumentError.invalidBounds(index + 1) }
        }
    }

    /// Adjusts all cues atomically. An offset that creates negative times is
    /// rejected instead of silently clipping text at the beginning of a video.
    public mutating func shift(offset: Double) throws {
        guard offset.isFinite else { throw SubtitleDocumentError.invalidAdjustment }
        var shifted = self
        for index in shifted.cues.indices {
            shifted.cues[index].start += offset
            shifted.cues[index].end += offset
        }
        try shifted.validate()
        self = shifted
    }

    public mutating func scaleTime(factor: Double) throws {
        guard factor.isFinite, factor > 0 else { throw SubtitleDocumentError.invalidAdjustment }
        var scaled = self
        for index in scaled.cues.indices {
            scaled.cues[index].start *= factor
            scaled.cues[index].end *= factor
        }
        try scaled.validate()
        self = scaled
    }

    /// Overlapping cues are valid in many subtitles; return their indices for an
    /// editor warning without blocking export or changing their relative order.
    public var overlappingCueIndices: Set<Int> {
        let sorted = cues.enumerated().sorted { $0.element.start < $1.element.start }
        var result = Set<Int>()
        var latest: (offset: Int, end: Double)?
        for (index, cue) in sorted {
            if let active = latest, cue.start < active.end {
                result.insert(active.offset)
                result.insert(index)
            }
            if latest == nil || cue.end > latest!.end { latest = (index, cue.end) }
        }
        return result
    }

    public func srtText() throws -> String {
        try validate()
        return try cues.enumerated().map { index, cue in
            guard (cue.end * 1000).rounded() > (cue.start * 1000).rounded() else {
                throw SubtitleDocumentError.exportPrecision(index + 1)
            }
            let start = try Self.srtTimestamp(cue.start)
            let end = try Self.srtTimestamp(cue.end)
            let text = cue.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            return "\(index + 1)\n\(start) --> \(end)\n\(text)\n"
        }.joined(separator: "\n")
    }

    public func writeSRT(to url: URL) throws { try srtText().write(to: url, atomically: true, encoding: .utf8) }

    public static func timestamp(_ seconds: Double) -> String {
        guard let text = try? srtTimestamp(seconds) else { return "00:00:00.000" }
        return text.replacingOccurrences(of: ",", with: ".")
    }

    public static func parseTimestamp(_ text: String) throws -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { throw SubtitleDocumentError.invalidTimestamp(text) }
        let secondParts = parts.last!.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "." || $0 == "," })
        guard secondParts.count == 1 || secondParts.count == 2,
              secondParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.dropLast().allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let seconds = Double(secondParts[0]), seconds < 60,
              let minutes = Double(parts[parts.count - 2]), minutes < 60,
              secondParts.count < 2 || secondParts[1].count <= 6 else { throw SubtitleDocumentError.invalidTimestamp(text) }
        let hours = parts.count == 3 ? Double(parts[0]) : 0
        guard let hours, hours.isFinite else { throw SubtitleDocumentError.invalidTimestamp(text) }
        let fractional = secondParts.count == 2 ? (Double("0." + secondParts[1]) ?? 0) : 0
        let result = hours * 3600 + minutes * 60 + seconds + fractional
        guard result.isFinite, result >= 0, result <= maximumTime else { throw SubtitleDocumentError.invalidTimestamp(text) }
        return result
    }

    private static func srtTimestamp(_ seconds: Double) throws -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= maximumTime else { throw SubtitleDocumentError.invalidTimestamp("\(seconds)") }
        let total = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", total / 3_600_000, (total / 60_000) % 60, (total / 1000) % 60, total % 1000)
    }

    private static func parseTimedText(_ text: String, format: Format) throws -> [SubtitleCue] {
        let lines = text.components(separatedBy: "\n")
        var result: [SubtitleCue] = []
        var cursor = 0
        if format == .vtt, lines.first?.hasPrefix("WEBVTT") == true {
            cursor = 1
            while cursor < lines.count, !lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty { cursor += 1 }
        }
        while cursor < lines.count {
            while cursor < lines.count, lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty { cursor += 1 }
            guard cursor < lines.count else { break }
            let blockStart = cursor
            var block: [String] = []
            while cursor < lines.count, !lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
                block.append(lines[cursor]); cursor += 1
            }
            if format == .vtt {
                let first = block[0].trimmingCharacters(in: .whitespaces)
                if first == "NOTE" || first.hasPrefix("NOTE ") || first.hasPrefix("NOTE\t") || first == "STYLE" || first == "REGION" { continue }
            }
            guard let timingIndex = block.firstIndex(where: { $0.contains("-->") }), timingIndex <= 1 else {
                throw SubtitleDocumentError.malformedCue(blockStart + 1)
            }
            let timing = block[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2 else { throw SubtitleDocumentError.malformedCue(blockStart + timingIndex + 1) }
            let endText = timing[1].trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let start = try parseTimestamp(timing[0])
            let end = try parseTimestamp(endText)
            let body = block.dropFirst(timingIndex + 1).joined(separator: "\n")
            result.append(SubtitleCue(start: start, end: end, text: format == .vtt ? plainVTT(body) : body))
        }
        return result
    }

    private static func parseASS(_ text: String) throws -> [SubtitleCue] {
        var inEvents = false
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var cues: [SubtitleCue] = []
        for (offset, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { inEvents = line.lowercased() == "[events]"; continue }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                fields = line.dropFirst(7).components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:") else { continue }
            guard let startIndex = fields.firstIndex(of: "start"), let endIndex = fields.firstIndex(of: "end"),
                  let textIndex = fields.firstIndex(of: "text"), textIndex == fields.count - 1 else {
                throw SubtitleDocumentError.malformedCue(offset + 1)
            }
            let values = line.dropFirst(9).split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
            guard values.count == fields.count else { throw SubtitleDocumentError.malformedCue(offset + 1) }
            let start = try parseTimestamp(String(values[startIndex]))
            let end = try parseTimestamp(String(values[endIndex]))
            cues.append(SubtitleCue(start: start, end: end, text: plainASS(String(values[textIndex]))))
        }
        return cues
    }

    private static func plainVTT(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (encoded, decoded) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: encoded, with: decoded)
        }
        return result
    }

    private static func plainASS(_ text: String) -> String {
        var stripped = ""
        var remaining = text[...]
        var drawing = false
        while let opening = remaining.firstIndex(of: "{"), let closing = remaining[opening...].firstIndex(of: "}") {
            if !drawing { stripped += remaining[..<opening] }
            let tag = String(remaining[opening...closing])
            if let mode = tag.range(of: "\\\\p[0-9]+", options: .regularExpression) {
                drawing = Int(tag[mode].dropFirst(2)) != 0
            }
            remaining = remaining[remaining.index(after: closing)...]
        }
        if !drawing { stripped += remaining }
        return stripped.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
    }
}
