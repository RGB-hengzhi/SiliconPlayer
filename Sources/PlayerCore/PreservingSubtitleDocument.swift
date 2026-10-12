import Foundation

public struct PreservingSubtitleCue: Identifiable, Equatable {
    public let id: UUID
    public var startMicroseconds: Int64
    public var endMicroseconds: Int64
    /// Authoring payload, including ASS overrides/drawing commands or VTT tags.
    /// It is never replaced with a stripped/plain-text rendering.
    public var rawBody: String
    public var start: Double { Double(startMicroseconds) / 1_000_000 }
    public var end: Double { Double(endMicroseconds) / 1_000_000 }
}

/// Loss-preserving editing stores opaque source blocks plus a narrow cue
/// template. No-op UTF-8 roundtrip is byte-identical, including BOM/CRLF and
/// whitespace. Edited copies are UTF-8; original files are never overwritten.
public struct PreservingSubtitleDocument {
    public typealias Format = SubtitleDocument.Format
    public static let maximumBytes = 16 * 1_048_576
    public static let maximumCues = 100_000
    public let format: Format
    public private(set) var cues: [PreservingSubtitleCue]
    private var pieces: [Piece]
    private let newline: String
    private enum Piece { case raw(String), cue(UUID, Template), vacant(Template) }
    private enum Template {
        case ass(prefix: String, fields: [String], start: Int, end: Int, body: Int, eol: String)
        case timed(prefix: String, leading: String, between: String, suffix: String, eol: String, payload: String, payloadEnd: String)
    }
    private struct Line { var text: String; var eol: String; var full: String { text + eol } }
    private var originals: [UUID: PreservingSubtitleCue]
    public var quantumMicroseconds: Int64 { format == .ass || format == .ssa ? 10_000 : 1_000 }
    public var nativePrecisionDescription: String { quantumMicroseconds == 10_000 ? "百分之一秒" : "毫秒" }

    public static func read(from url: URL) throws -> Self {
        guard let format = Format(rawValue: url.pathExtension.lowercased()),
              let data = try BoundedProfileFile.read(url, maximumBytes: maximumBytes) else { throw SubtitlePreservationError.invalid("文件格式或编码") }
        let text: String
        if String(data: data, encoding: .utf8) != nil {
            // Foundation's UTF-8 decoder strips a leading BOM on macOS.
            // Validate first, then retain every original valid UTF-8 scalar.
            text = String(decoding: data, as: UTF8.self)
        } else if let decoded = DocumentTextDecoder.decode(data) {
            text = decoded
        } else { throw SubtitlePreservationError.invalid("文件格式或编码") }
        return try parse(text, format: format)
    }
    public static func parse(_ text: String, format: Format) throws -> Self {
        guard !text.isEmpty, text.utf8.count <= maximumBytes, !text.contains("\0") else {
            throw SubtitlePreservationError.invalid("文件体积或NUL字符")
        }
        let lines = splitLines(text)
        let newline = lines.first(where: { !$0.eol.isEmpty })?.eol ?? "\n"
        var document = Self(format: format, cues: [], pieces: [], newline: newline, originals: [:])
        if format == .ass || format == .ssa { try document.parseASS(lines) }
        else { try document.parseTimed(lines) }
        guard !document.cues.isEmpty else { throw SubtitlePreservationError.invalid("没有可编辑的字幕") }
        try document.validate()
        document.originals = Dictionary(uniqueKeysWithValues: document.cues.map { ($0.id, $0) })
        return document
    }
    public func displayTime(_ microseconds: Int64) -> String { Self.timestamp(microseconds, format: format) }
    public func parseEditableTime(_ text: String) throws -> Int64 {
        let parsed = try SubtitleExactClock.parse(text.replacingOccurrences(of: ",", with: "."))
        guard parsed % quantumMicroseconds == 0 else { throw SubtitlePreservationError.precision }
        return parsed
    }
    public mutating func update(id: UUID, start: Int64, end: Int64, rawBody: String) throws {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { throw SubtitlePreservationError.missingCue }
        var changed = self
        changed.cues[index].startMicroseconds = start; changed.cues[index].endMicroseconds = end
        changed.cues[index].rawBody = rawBody
        try changed.validate(); self = changed
    }
    public mutating func remove(id: UUID) {
        cues.removeAll { $0.id == id }
        pieces = pieces.map { if case .cue(let value, let template) = $0, value == id { return .vacant(template) }; return $0 }
    }
    @discardableResult public mutating func insert(after selected: UUID?, rawBody: String = "新字幕") throws -> UUID {
        if let selected, !cues.contains(where: { $0.id == selected }) { throw SubtitlePreservationError.missingCue }
        guard pieces.count < Self.maximumCues * 4 else { throw SubtitlePreservationError.invalid("编辑片段达到界限；请保存副本后重新打开") }
        let index = selected.flatMap { id in cues.firstIndex { $0.id == id } }.map { $0 + 1 } ?? cues.count
        let start = index > 0 ? cues[index - 1].endMicroseconds : 0
        let end = start.addingReportingOverflow(2_000_000)
        guard !end.overflow else { throw SubtitlePreservationError.bounds }
        let cue = PreservingSubtitleCue(id: UUID(), startMicroseconds: start, endMicroseconds: end.partialValue, rawBody: rawBody)
        var changed = self
        let sourceID = selected ?? cues.last?.id
        let pieceIndex = sourceID.flatMap { id in pieces.firstIndex { if case .cue(let value, _) = $0 { return value == id }; return false } }
            ?? (cues.isEmpty ? pieces.lastIndex(where: { if case .vacant = $0 { return true }; return false }) : nil)
        let inherited: Template?
        let replaceVacant: Bool
        if let pieceIndex {
            switch pieces[pieceIndex] {
            case .cue(_, let value): inherited = value; replaceVacant = false
            case .vacant(let value): inherited = value; replaceVacant = true
            case .raw: inherited = nil; replaceVacant = false
            }
        } else { inherited = nil; replaceVacant = false }
        let template: Template
        if let previous = inherited, case .ass(let prefix, var fields, let s, let e, let t, _) = previous {
            fields[s] = displayTime(start); fields[e] = displayTime(end.partialValue); fields[t] = rawBody
            template = .ass(prefix: prefix, fields: fields, start: s, end: e, body: t, eol: newline)
        } else {
            // Existing SRT numbers remain opaque; a new cue gets an unused
            // positive identifier. VTT adds no ID/CSS selector implicitly.
            let used = Set(pieces.compactMap { piece -> Int? in
                guard case .cue(_, .timed(let prefix, _, _, _, _, _, _)) = piece else { return nil }
                return Int(prefix.trimmingCharacters(in: .whitespacesAndNewlines))
            })
            var identifier = 1
            while used.contains(identifier) { identifier += 1 }
            let prefix = format == .srt ? String(identifier) + newline : ""
            template = .timed(prefix: prefix, leading: "", between: " --> ", suffix: "", eol: newline, payload: "", payloadEnd: newline)
        }
        changed.cues.insert(cue, at: index)
        let insertion = pieceIndex.map { replaceVacant ? $0 : $0 + 1 } ?? pieces.count
        // Preserve an original final line without newline, then add only the
        // separator necessary for this explicit new cue.
        let precedingHasEOL: Bool
        if let previous = inherited {
            switch previous {
            case .ass(_, _, _, _, _, let eol): precedingHasEOL = !eol.isEmpty
            case .timed(_, _, _, _, _, _, let payloadEnd): precedingHasEOL = !payloadEnd.isEmpty
            }
        } else { precedingHasEOL = true }
        let separator = format == .ass || format == .ssa ? (precedingHasEOL ? "" : newline) : (precedingHasEOL ? newline : newline + newline)
        var additions: [Piece] = []
        if !replaceVacant && !separator.isEmpty { additions.append(.raw(separator)) }
        additions.append(.cue(cue.id, template))
        if replaceVacant { changed.pieces.replaceSubrange(insertion...insertion, with: additions) }
        else if insertion < changed.pieces.count, case .vacant = changed.pieces[insertion] {
            changed.pieces.replaceSubrange(insertion...insertion, with: additions)
        } else { changed.pieces.insert(contentsOf: additions, at: insertion) }
        try changed.validate(); self = changed; return cue.id
    }
    public mutating func calibrate(_ map: SubtitleTwoPointMap, quantization: SubtitleQuantization = .exact) throws {
        let quantum = quantumMicroseconds
        try applyTimes { try map.map($0, quantum: quantum, quantization: quantization) }
    }
    public mutating func shift(decimalSeconds: String) throws {
        let fraction = try SubtitleExactClock.decimal(decimalSeconds, signed: true)
        let product = fraction.numerator.multipliedReportingOverflow(by: 1_000_000 / fraction.denominator)
        guard !product.overflow, product.partialValue % quantumMicroseconds == 0 else { throw SubtitlePreservationError.precision }
        try applyTimes { value in
            let shifted = value.addingReportingOverflow(product.partialValue)
            guard !shifted.overflow else { throw SubtitlePreservationError.bounds }; return shifted.partialValue
        }
    }
    public mutating func scale(decimalFactor: String, quantization: SubtitleQuantization = .exact) throws {
        let fraction = try SubtitleExactClock.decimal(decimalFactor, signed: false)
        guard fraction.numerator > 0 else { throw SubtitlePreservationError.bounds }
        let map = try SubtitleTwoPointMap(sourceA: 0, videoA: 0, sourceB: fraction.denominator, videoB: fraction.numerator)
        try calibrate(map, quantization: quantization)
    }
    private mutating func applyTimes(_ map: (Int64) throws -> Int64) throws {
        var changed = self
        for index in changed.cues.indices {
            changed.cues[index].startMicroseconds = try map(cues[index].startMicroseconds)
            changed.cues[index].endMicroseconds = try map(cues[index].endMicroseconds)
            if format == .vtt {
                changed.cues[index].rawBody = try Self.mappingInlineTimestamps(cues[index].rawBody, map)
            }
        }
        try changed.validate(); self = changed
    }
    public func text() throws -> String {
        try validate(); let table = Dictionary(uniqueKeysWithValues: cues.map { ($0.id, $0) })
        let output = try pieces.map { piece -> String in
            switch piece {
            case .raw(let text): return text
            case .vacant: return ""
            case .cue(let id, let template):
                guard let cue = table[id] else { throw SubtitlePreservationError.missingCue }
                let prior = originals[id]
                switch template {
                case .ass(let prefix, var fields, let s, let e, let t, let eol):
                    if prior?.startMicroseconds != cue.startMicroseconds { fields[s] = Self.replaceTrimmed(fields[s], with: displayTime(cue.startMicroseconds)) }
                    if prior?.endMicroseconds != cue.endMicroseconds { fields[e] = Self.replaceTrimmed(fields[e], with: displayTime(cue.endMicroseconds)) }
                    if prior?.rawBody != cue.rawBody { fields[t] = cue.rawBody }
                    return prefix + fields.joined(separator: ",") + eol
                case .timed(let prefix, let leading, let between, let suffix, let eol, let payload, let payloadEnd):
                    let token = timedTokens[id]
                    if prior != nil, token == nil { throw SubtitlePreservationError.invalid("原时间词元已不存在") }
                    let start = prior?.startMicroseconds == cue.startMicroseconds ? token!.0 : displayTime(cue.startMicroseconds)
                    let end = prior?.endMicroseconds == cue.endMicroseconds ? token!.1 : displayTime(cue.endMicroseconds)
                    let body = prior?.rawBody == cue.rawBody ? payload : cue.rawBody.replacingOccurrences(of: "\n", with: newline) + payloadEnd
                    return prefix + leading + start + between + end + suffix + eol + body
                }
            }
        }.joined()
        guard output.utf8.count <= Self.maximumBytes else { throw SubtitlePreservationError.invalid("导出体积超限") }
        return output
    }
    // Original lexical timestamps live separately from editable microseconds.
    private var timedTokens: [UUID: (String, String)] = [:]
    public func writeCopy(to destination: URL, sourceURL: URL) throws {
        guard destination.isFileURL, sourceURL.isFileURL, destination.pathExtension.lowercased() == format.rawValue,
              destination.resolvingSymlinksInPath().standardizedFileURL != sourceURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw SubtitlePreservationError.unsafeSourceDestination
        }
        let source = try sourceURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
        if FileManager.default.fileExists(atPath: destination.path) {
            let target = try destination.resourceValues(forKeys: [.fileResourceIdentifierKey])
            if let lhs = source.fileResourceIdentifier as? NSObject, let rhs = target.fileResourceIdentifier as? NSObject, lhs.isEqual(rhs) { throw SubtitlePreservationError.unsafeSourceDestination }
        }
        try text().write(to: destination, atomically: true, encoding: .utf8)
    }
    public func validate() throws {
        guard cues.count <= Self.maximumCues, Set(cues.map(\.id)).count == cues.count else { throw SubtitlePreservationError.bounds }
        var previousStart: Int64 = -1
        for cue in cues {
            guard cue.startMicroseconds >= 0, cue.endMicroseconds > cue.startMicroseconds,
                  cue.endMicroseconds <= SubtitleExactClock.maximumMicroseconds,
                  cue.startMicroseconds % quantumMicroseconds == 0, cue.endMicroseconds % quantumMicroseconds == 0,
                  !cue.rawBody.contains("\0"), cue.rawBody.utf8.count <= 1_048_576 else { throw SubtitlePreservationError.bounds }
            if format == .ass || format == .ssa {
                guard !cue.rawBody.contains("\n"), !cue.rawBody.contains("\r") else { throw SubtitlePreservationError.invalid("ASS换行请使用\\N，不能插入事件行") }
            } else {
                guard !cue.rawBody.contains("\r"), (cue.rawBody.isEmpty || !cue.rawBody.components(separatedBy: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty })) else { throw SubtitlePreservationError.invalid("字幕正文不能含空白分段") }
            }
            if format == .vtt {
                guard cue.startMicroseconds >= previousStart, !cue.rawBody.contains("-->") else { throw SubtitlePreservationError.invalid("VTT顺序或正文分隔符") }
                previousStart = cue.startMicroseconds
                var last = cue.startMicroseconds
                _ = try Self.mappingInlineTimestamps(cue.rawBody) { timestamp in
                    guard timestamp > last, timestamp < cue.endMicroseconds else { throw SubtitlePreservationError.invalid("VTT内嵌时间需严格递增且在本条范围内") }
                    last = timestamp; return timestamp
                }
            }
        }
    }
    private mutating func parseASS(_ lines: [Line]) throws {
        var inEvents = false
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FEFF}", with: "")
            if trimmed.hasPrefix("[") { inEvents = trimmed.lowercased() == "[events]" }
            if inEvents, trimmed.lowercased().hasPrefix("format:") {
                fields = trimmed.dropFirst(7).split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            }
            guard inEvents, trimmed.lowercased().hasPrefix("dialogue:"), let colon = line.text.firstIndex(of: ":") else { pieces.append(.raw(line.full)); continue }
            guard Set(fields).count == fields.count, let s = fields.firstIndex(of: "start"), let e = fields.firstIndex(of: "end"), let t = fields.firstIndex(of: "text"), t == fields.count - 1 else { throw SubtitlePreservationError.invalid("ASS Events Format字段") }
            let prefix = String(line.text[...colon])
            let values = line.text[line.text.index(after: colon)...].split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false).map(String.init)
            guard values.count == fields.count else { throw SubtitlePreservationError.invalid("ASS事件字段数") }
            let cue = PreservingSubtitleCue(id: UUID(), startMicroseconds: try fileTime(values[s]), endMicroseconds: try fileTime(values[e]), rawBody: values[t])
            cues.append(cue); pieces.append(.cue(cue.id, .ass(prefix: prefix, fields: values, start: s, end: e, body: t, eol: line.eol)))
        }
    }
    private mutating func parseTimed(_ lines: [Line]) throws {
        var cursor = 0
        if format == .vtt {
            guard let first = lines.first else { throw SubtitlePreservationError.invalid("WEBVTT文件头") }
            let header = first.text.hasPrefix("\u{FEFF}") ? String(first.text.dropFirst()) : first.text
            guard header == "WEBVTT" || header.hasPrefix("WEBVTT ") || header.hasPrefix("WEBVTT\t"), !header.contains("-->") else { throw SubtitlePreservationError.invalid("WEBVTT文件头") }
            while cursor < lines.count, !lines[cursor].text.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(.raw(lines[cursor].full)); cursor += 1 }
        }
        let pattern = try NSRegularExpression(pattern: "^([ \\t]*)([^ \\t]+)([ \\t]+-->[ \\t]+)([^ \\t]+)(.*)$")
        while cursor < lines.count {
            if lines[cursor].text.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(.raw(lines[cursor].full)); cursor += 1; continue }
            let start = cursor
            while cursor < lines.count, !lines[cursor].text.trimmingCharacters(in: .whitespaces).isEmpty { cursor += 1 }
            let block = Array(lines[start..<cursor]); let first = block[0].text
            if format == .vtt, first == "STYLE" || first == "REGION" || first == "NOTE" || first.hasPrefix("NOTE ") || first.hasPrefix("NOTE\t") {
                pieces.append(.raw(block.map(\.full).joined())); continue
            }
            guard let ti = block.firstIndex(where: { $0.text.contains("-->") }), ti <= 1,
                  let match = pattern.firstMatch(in: block[ti].text, range: NSRange(block[ti].text.startIndex..., in: block[ti].text)),
                  match.range.length == (block[ti].text as NSString).length else { throw SubtitlePreservationError.invalid("字幕时间行") }
            func group(_ index: Int) -> String { Range(match.range(at: index), in: block[ti].text).map { String(block[ti].text[$0]) } ?? "" }
            let payloadLines = Array(block.dropFirst(ti + 1)); let body = payloadLines.map(\.text).joined(separator: "\n")
            let cue = PreservingSubtitleCue(id: UUID(), startMicroseconds: try fileTime(group(2)), endMicroseconds: try fileTime(group(4)), rawBody: body)
            cues.append(cue); timedTokens[cue.id] = (group(2), group(4))
            pieces.append(.cue(cue.id, .timed(prefix: block.prefix(ti).map(\.full).joined(), leading: group(1), between: group(3), suffix: group(5), eol: block[ti].eol, payload: payloadLines.map(\.full).joined(), payloadEnd: payloadLines.last?.eol ?? "")))
        }
    }
    private func fileTime(_ text: String) throws -> Int64 {
        let clean = text.trimmingCharacters(in: .whitespaces)
        let syntax: String
        switch format {
        case .vtt: syntax = "^(?:[0-9]{2,}:)?[0-5][0-9]:[0-5][0-9]\\.[0-9]{3}$"
        case .ass, .ssa: syntax = "^[0-9]+:[0-5][0-9]:[0-5][0-9]\\.[0-9]{2}$"
        case .srt: syntax = "^[0-9]{2,}:[0-5][0-9]:[0-5][0-9][,.][0-9]{3}$"
        }
        guard clean.range(of: syntax, options: .regularExpression) != nil else { throw SubtitlePreservationError.invalid("原格式时间精度") }
        return try parseEditableTime(clean)
    }
    private static func timestamp(_ microseconds: Int64, format: Format) -> String {
        let quantum: Int64 = format == .ass || format == .ssa ? 10_000 : 1_000
        let ticks = microseconds / quantum; let perSecond = 1_000_000 / quantum
        let seconds = ticks / perSecond
        let prefix = format == .ass || format == .ssa ? String(seconds / 3600) : String(format: "%02lld", seconds / 3600)
        return prefix + String(format: ":%02lld:%02lld", (seconds / 60) % 60, seconds % 60)
            + (format == .srt ? "," : ".") + String(format: quantum == 10_000 ? "%02lld" : "%03lld", ticks % perSecond)
    }
    private static func replaceTrimmed(_ old: String, with replacement: String) -> String {
        let leading = old.prefix(while: { $0 == " " || $0 == "\t" })
        let trailing = old.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed()
        return String(leading) + replacement + String(trailing)
    }
    private static func mappingInlineTimestamps(_ payload: String, _ map: (Int64) throws -> Int64) throws -> String {
        let regex = try NSRegularExpression(pattern: "<((?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}\\.[0-9]{3})>")
        var result = payload
        var edits: [(Range<String.Index>, String)] = []
        for match in regex.matches(in: payload, range: NSRange(payload.startIndex..., in: payload)) {
            guard let range = Range(match.range, in: payload), let token = Range(match.range(at: 1), in: payload) else { throw SubtitlePreservationError.invalid("内嵌时间标签") }
            let original = try SubtitleExactClock.parse(String(payload[token]))
            let mapped = try map(original)
            guard mapped >= 0, mapped <= SubtitleExactClock.maximumMicroseconds, mapped % 1000 == 0 else { throw SubtitlePreservationError.bounds }
            if mapped != original { edits.append((range, "<" + timestamp(mapped, format: .vtt) + ">")) }
        }
        for (range, text) in edits.reversed() { result.replaceSubrange(range, with: text) }
        return result
    }
    private static func splitLines(_ value: String) -> [Line] {
        var result: [Line] = []; var start = value.startIndex; var cursor = start
        while cursor < value.endIndex {
            if value[cursor] == "\r" || value[cursor] == "\n" || value[cursor] == "\r\n" {
                let end = cursor; let eol = String(value[cursor]); cursor = value.index(after: cursor)
                result.append(Line(text: String(value[start..<end]), eol: eol)); start = cursor
            } else { cursor = value.index(after: cursor) }
        }
        if start < value.endIndex { result.append(Line(text: String(value[start...]), eol: "")) }
        return result
    }
}
