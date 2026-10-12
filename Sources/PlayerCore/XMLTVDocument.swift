import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum XMLTVError: Error, LocalizedError, Equatable {
    case invalidLimits, tooLarge, unsupportedEncoding, forbiddenDeclaration
    case malformedXML(Int), invalidChannel, duplicateChannel
    case invalidProgramme(Int), tooManyChannels, tooManyProgrammes, tooDeep, tooManyNodes, textTooLarge
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: return "节目单上限设置无效。"
        case .tooLarge: return "节目单文件超过读取上限。"
        case .unsupportedEncoding: return "节目单需要 UTF-8 或带 BOM 的 UTF-16 编码。"
        case .forbiddenDeclaration: return "节目单不能包含 DTD 或实体声明。"
        case .malformedXML(let line): return "节目单 XML 格式错误（第 \(line) 行）。"
        case .invalidChannel: return "节目单频道 ID 无效。"
        case .duplicateChannel: return "节目单包含重复频道 ID。"
        case .invalidProgramme(let index): return "第 \(index) 条节目缺少有效频道、标题或精确时间。"
        case .tooManyChannels: return "节目单频道数超过上限。"
        case .tooManyProgrammes: return "节目数量超过上限。"
        case .tooDeep: return "节目单嵌套层数超过上限。"
        case .tooManyNodes: return "节目单节点数超过上限。"
        case .textTooLarge: return "节目单单个字段过长。"
        case .cancelled: return "已取消节目单读取。"
        }
    }
}

public struct XMLTVLimits: Equatable, Sendable {
    public var maximumBytes = 8 * 1024 * 1024
    public var maximumChannels = 10_000
    public var maximumProgrammes = 100_000
    public var maximumDepth = 32
    public var maximumNodes = 250_000
    public var maximumTextBytes = 64 * 1024
    public init() {}
    fileprivate var valid: Bool {
        [maximumBytes, maximumChannels, maximumProgrammes, maximumDepth, maximumNodes, maximumTextBytes].allSatisfy { $0 > 0 }
    }
}

public struct EPGChannel: Equatable, Sendable {
    public let identifier: String
    public let displayNames: [String]
    public let logoURL: URL?
}

public struct EPGProgramme: Equatable, Sendable {
    public let channelID: String
    public let start: Date
    public let explicitEnd: Date?
    public let title: String
    public let description: String
    public let sequence: Int
}

public struct EPGAiring: Equatable, Sendable {
    public let programme: EPGProgramme
    public let end: Date
    public let endWasInferred: Bool
}

public struct EPGNowNext: Equatable, Sendable {
    public let current: [EPGAiring]
    public let next: [EPGProgramme]
    /// A started entry with no known end is separate from confirmed airing.
    public let latestWithUnknownEnd: [EPGProgramme]
}

public struct XMLTVDocument: Equatable, Sendable {
    public let channels: [String: EPGChannel]
    public let programmes: [String: [EPGProgramme]]
    public let channelIDs: Set<String>

    public static func parse(_ data: Data, sourceURL: URL? = nil, limits: XMLTVLimits = .init(),
                             isCancelled: @escaping () -> Bool = { false }) throws -> Self {
        guard limits.valid else { throw XMLTVError.invalidLimits }
        guard data.count <= limits.maximumBytes else { throw XMLTVError.tooLarge }
        if isCancelled() { throw XMLTVError.cancelled }
        let text: String?
        if data.starts(with: [0xff, 0xfe]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xfe, 0xff]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else { text = String(data: data, encoding: .utf8) }
        guard let text else { throw XMLTVError.unsupportedEncoding }
        guard text.range(of: #"<!\s*(DOCTYPE|ENTITY)\b"#, options: [.regularExpression, .caseInsensitive]) == nil else {
            throw XMLTVError.forbiddenDeclaration
        }
        let delegate = XMLTVParser(limits: limits, sourceURL: sourceURL, isCancelled: isCancelled)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        if let error = delegate.failure { throw error }
        guard parsed, delegate.validRoot else { throw XMLTVError.malformedXML(parser.lineNumber) }
        if isCancelled() { throw XMLTVError.cancelled }
        var indexed: [String: [EPGProgramme]] = [:]
        for programme in delegate.programmes {
            if isCancelled() { throw XMLTVError.cancelled }
            indexed[programme.channelID, default: []].append(programme)
        }
        for channel in indexed.keys {
            if isCancelled() { throw XMLTVError.cancelled }
            indexed[channel]!.sort { $0.start == $1.start ? $0.sequence < $1.sequence : $0.start < $1.start }
        }
        if isCancelled() { throw XMLTVError.cancelled }
        return Self(channels: delegate.channels, programmes: indexed, channelIDs: Set(delegate.channels.keys).union(indexed.keys))
    }

    public func nowAndNext(channelID: String, at date: Date) -> EPGNowNext {
        let values = programmes[channelID] ?? []
        var current: [EPGAiring] = [], next: [EPGProgramme] = [], unknown: [EPGProgramme] = []
        let nextStart = values.first { $0.start > date }?.start
        let latestStarted = values.last { $0.start <= date }?.start
        var previousStart: Date?, laterStart: Date?
        for value in values.reversed() {
            if previousStart != value.start { laterStart = previousStart; previousStart = value.start }
            if value.start > date {
                if value.start == nextStart { next.append(value) }
                continue
            }
            if let end = value.explicitEnd ?? laterStart {
                if date < end { current.append(EPGAiring(programme: value, end: end, endWasInferred: value.explicitEnd == nil)) }
            } else if value.start == latestStarted { unknown.append(value) }
        }
        return EPGNowNext(current: current.reversed(), next: next.reversed(), latestWithUnknownEnd: unknown.reversed())
    }
}

private final class XMLTVParser: NSObject, XMLParserDelegate {
    private struct Node { let name: String; var text = "" }
    private struct ChannelDraft { let id: String; var names: [String] = []; var logo: URL? }
    private struct ProgrammeDraft { let channel: String; let start: Date; let end: Date?; var titles: [String] = []; var description = "" }
    let limits: XMLTVLimits
    let sourceURL: URL?
    let isCancelled: () -> Bool
    var failure: XMLTVError?
    var validRoot = false
    var channels: [String: EPGChannel] = [:]
    var programmes: [EPGProgramme] = []
    private var nodes: [Node] = []
    private var nodeCount = 0
    private var channelIDs = Set<String>()
    private var channel: ChannelDraft?
    private var programme: ProgrammeDraft?
    init(limits: XMLTVLimits, sourceURL: URL?, isCancelled: @escaping () -> Bool) {
        self.limits = limits; self.sourceURL = sourceURL; self.isCancelled = isCancelled
    }
    private func stop(_ parser: XMLParser, _ error: XMLTVError) { if failure == nil { failure = error }; parser.abortParsing() }
    private func check(_ parser: XMLParser) -> Bool {
        if failure != nil { return false }
        if isCancelled() { stop(parser, .cancelled); return false }
        return true
    }
    private func channelID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 256,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return raw
    }
    private func register(_ id: String, parser: XMLParser) -> Bool {
        channelIDs.insert(id)
        if channelIDs.count > limits.maximumChannels { stop(parser, .tooManyChannels); return false }
        return true
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String]) {
        guard check(parser) else { return }
        nodeCount += 1
        guard nodeCount <= limits.maximumNodes else { stop(parser, .tooManyNodes); return }
        guard nodes.count < limits.maximumDepth else { stop(parser, .tooDeep); return }
        guard namespaceURI == nil || namespaceURI == "" else { stop(parser, .malformedXML(parser.lineNumber)); return }
        nodes.append(Node(name: elementName))
        if nodes.count == 1 {
            guard elementName == "tv", namespaceURI == nil || namespaceURI == "" else { stop(parser, .malformedXML(parser.lineNumber)); return }
            validRoot = true
        }
        if nodes.count == 2, nodes.first?.name == "tv", elementName == "channel" {
            guard let id = channelID(attributes["id"]) else { stop(parser, .invalidChannel); return }
            guard channels[id] == nil else { stop(parser, .duplicateChannel); return }
            guard register(id, parser: parser) else { return }
            channel = ChannelDraft(id: id)
        } else if nodes.count == 2, nodes.first?.name == "tv", elementName == "programme" {
            guard programmes.count < limits.maximumProgrammes else { stop(parser, .tooManyProgrammes); return }
            guard let id = channelID(attributes["channel"]), let start = XMLTVTime.date(attributes["start"]) else {
                stop(parser, .invalidProgramme(programmes.count + 1)); return
            }
            let end = attributes["stop"].flatMap(XMLTVTime.date)
            guard attributes["stop"] == nil || end != nil, end == nil || end! > start else {
                stop(parser, .invalidProgramme(programmes.count + 1)); return
            }
            guard register(id, parser: parser) else { return }
            programme = ProgrammeDraft(channel: id, start: start, end: end)
        }
        if nodes.count == 3, nodes[nodes.count - 2].name == "channel", elementName == "icon",
           let raw = attributes["src"], let url = URL(string: raw, relativeTo: sourceURL)?.absoluteURL,
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil {
            if channel?.logo == nil { channel?.logo = url }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard check(parser), let node = nodes.last, ["title", "desc", "display-name"].contains(node.name) else { return }
        let index = nodes.count - 1
        guard nodes[index].text.utf8.count + string.utf8.count <= limits.maximumTextBytes else { stop(parser, .textTooLarge); return }
        nodes[index].text += string
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { stop(parser, .malformedXML(parser.lineNumber)); return }
        self.parser(parser, foundCharacters: text)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard check(parser), let node = nodes.popLast() else { return }
        let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if nodes.count == 2 {
            if nodes.last?.name == "channel", elementName == "display-name", !text.isEmpty { channel?.names.append(text) }
            if nodes.last?.name == "programme", elementName == "title", !text.isEmpty { programme?.titles.append(text) }
            if nodes.last?.name == "programme", elementName == "desc", programme?.description.isEmpty == true { programme?.description = text }
        } else if nodes.count == 1 {
            if elementName == "channel", let value = channel {
                channels[value.id] = EPGChannel(identifier: value.id, displayNames: value.names, logoURL: value.logo)
                channel = nil
            } else if elementName == "programme", let value = programme {
                guard let title = value.titles.first else { stop(parser, .invalidProgramme(programmes.count + 1)); return }
                programmes.append(EPGProgramme(channelID: value.channel, start: value.start, explicitEnd: value.end,
                                               title: title, description: value.description, sequence: programmes.count))
                programme = nil
            }
        }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { stop(parser, .forbiddenDeclaration) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { stop(parser, .forbiddenDeclaration) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { stop(parser, .forbiddenDeclaration); return nil }
}

private enum XMLTVTime {
    static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let parts = raw.split(whereSeparator: \.isWhitespace)
        guard (1...2).contains(parts.count), [12, 14].contains(parts[0].count), parts[0].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let bytes = Array(parts[0].utf8)
        func integer(_ start: Int, _ count: Int) -> Int { Int(String(decoding: bytes[start..<(start + count)], as: UTF8.self))! }
        let year = integer(0, 4), month = integer(4, 2), day = integer(6, 2), hour = integer(8, 2), minute = integer(10, 2)
        let second = bytes.count == 14 ? integer(12, 2) : 0
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        var offset = 0
        if parts.count == 2 {
            let zone = String(parts[1])
            if ["UTC", "GMT", "Z"].contains(zone) { offset = 0 }
            else if zone == "BST" { offset = 3600 }
            else {
                let characters = Array(zone.utf8)
                guard characters.count == 5, characters[0] == 43 || characters[0] == 45,
                      characters.dropFirst().allSatisfy({ (48...57).contains($0) }) else { return nil }
                let hours = Int(String(decoding: characters[1...2], as: UTF8.self))!
                let minutes = Int(String(decoding: characters[3...4], as: UTF8.self))!
                guard hours <= 14, minutes < 60, hours < 14 || minutes == 0 else { return nil }
                offset = (hours * 3600 + minutes * 60) * (characters[0] == 45 ? -1 : 1)
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let wall = calendar.date(from: components) else { return nil }
        let checked = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wall)
        guard checked.year == year, checked.month == month, checked.day == day, checked.hour == hour, checked.minute == minute, checked.second == second else { return nil }
        return wall.addingTimeInterval(TimeInterval(-offset))
    }
}
