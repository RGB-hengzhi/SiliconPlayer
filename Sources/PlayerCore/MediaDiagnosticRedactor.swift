import Foundation

/// Diagnostic text only. Never returns raw data as a failure fallback.
public enum MediaDiagnosticRedactor {
    public static let maximumInputBytes = 16 * 1024
    public static let maximumOutputBytes = 4 * 1024
    private static let unicode = try? NSRegularExpression(pattern: #"\\[uU]([0-9a-fA-F]{4})"#)
    private static let percent = try? NSRegularExpression(pattern: #"%([0-9a-fA-F]{2})"#)
    private static let credentials = try? NSRegularExpression(pattern: #"(?i)\b(authorization|set[-_]cookie|cookies?|bearer|api[-_ ]?key|access[-_ ]?token|token|signature|sig|credentials?|password|passwd|secret)\b"#)
    private static let addresses = try? NSRegularExpression(pattern: #"(?i)\b(?:https?|rtsps?|rtmps?|ftp|smb|nfs|file|ytdl)://[^\s\"'<>]*"#)
    // After two bounded decoding passes, any remaining escape immediately
    // following a known scheme is conservatively omitted as a whole message.
    private static let suspiciousScheme = try? NSRegularExpression(pattern: #"(?i)\b(?:https?|rtsps?|rtmps?|ftp|smb|nfs|file|ytdl)(?::|%|\\)"#)
    private static let forbiddenControls = CharacterSet.controlCharacters.union(.newlines)
    public static func redactUTF8(_ data: Data) -> String {
        guard data.count <= maximumInputBytes, let line = String(data: data, encoding: .utf8) else { return "[invalid or oversized diagnostic omitted]" }
        return redact(line)
    }
    public static func redact(_ input: String) -> String {
        guard input.utf8.count <= maximumInputBytes else { return "[oversized diagnostic omitted]" }
        var line = input
        // mpv log messages normally end with LF. Preserve their useful text,
        // while embedded line/control separators cannot expose a URL tail.
        while let last = line.unicodeScalars.last, last.value == 10 || last.value == 13 { line.unicodeScalars.removeLast() }
        guard !line.unicodeScalars.contains(where: { forbiddenControls.contains($0) }) else { return "[control-bearing diagnostic omitted]" }
        guard let unicode, let percent, let credentials, let addresses, let suspiciousScheme else { return "[diagnostic omitted]" }
        for _ in 0..<2 {
            line = line.replacingOccurrences(of: #"\/"#, with: "/")
            let matches = unicode.matches(in: line, range: NSRange(line.startIndex..., in: line))
            for match in matches.reversed() {
                guard let digits = Range(match.range(at: 1), in: line), let range = Range(match.range, in: line),
                      let number = UInt32(line[digits], radix: 16), let scalar = UnicodeScalar(number) else { return "[invalid escaped diagnostic omitted]" }
                line.replaceSubrange(range, with: String(scalar))
            }
            if let decoded = line.removingPercentEncoding { line = decoded }
            else {
                // An invalid percent byte elsewhere must not prevent recognition
                // of an encoded ASCII scheme/separator/credential field.
                for match in percent.matches(in: line,range: NSRange(line.startIndex...,in: line)).reversed() {
                    guard let digits = Range(match.range(at: 1),in: line), let range = Range(match.range,in: line),
                          let byte = UInt8(line[digits],radix: 16), byte < 128 else { continue }
                    line.replaceSubrange(range,with: String(UnicodeScalar(byte)))
                }
            }
        }
        guard !line.unicodeScalars.contains(where: { forbiddenControls.contains($0) }) else { return "[control-bearing diagnostic omitted]" }
        if credentials.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { return "[credential-bearing diagnostic omitted]" }
        line = addresses.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "[URL omitted]")
        if suspiciousScheme.firstMatch(in: line,range: NSRange(line.startIndex...,in: line)) != nil { return "[escaped address diagnostic omitted]" }
        guard line.utf8.count <= maximumOutputBytes else { return "[oversized diagnostic omitted]" }
        return line
    }
}
