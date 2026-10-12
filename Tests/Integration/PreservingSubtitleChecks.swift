import Foundation
import Darwin
import PlayerCore

/// Prepared tests for real PlayerCore code. No compile/run has occurred in this
/// leaf. These case IDs are future module cases, never inherited App groups.
@main struct PreservingSubtitleChecks {
    static func require(_ value: Bool, _ detail: String) throws {
        if !value { throw NSError(domain: "SubtitleAuthoringChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: detail]) }
    }
    static func rejects(_ action: () throws -> Void) throws {
        var rejected = false; do { try action() } catch { rejected = true }
        try require(rejected, "Expected rejection")
    }
    static let ass = "\u{FEFF}[Script Info]\r\nTitle: 保留测试\r\nPlayResX: 1920\r\n[V4+ Styles]\r\nFormat: Name, Fontname, Fontsize, PrimaryColour, Alignment\r\nStyle: 中文,Noto Sans,28,&H00FFFFFF,8\r\n[Events]\r\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Custom, Text\r\nComment: 9,0:00:00.01,0:00:01.01,中文,注释,0010,0020,0030,Scroll up,opaque,{\\b1}别改\r\nDialogue: 7, 0:00:01.20 , 0:00:03.40 ,中文,讲者,0010,0020,0030,fx,keep,{\\pos(20,30)\\an8\\k20}你,{\\i1}好\\N{\\p1}m 0 0 l 5 5{\\p0}\r\nDialogue: 2,0:00:04.00,0:00:06.00,中文,乙,0040,0050,0060,,unknown,{\\t(0,300,\\alpha&H80&)}再见"
    static let vtt = "\u{FEFF}WEBVTT 标题\r\n\r\nNOTE 原注释\r\nmetadata untouched\r\n\r\nSTYLE\r\n::cue(.中文) { color: lime; }\r\n\r\nREGION\r\nid:bottom\r\nwidth:80%\r\nlines:3\r\n\r\n第一条\r\n  00:01.000\t--> 00:03.000 region:bottom vertical:rl line:20% position:30%,line-left size:40% align:start\r\n<v 李><c.中文>你<00:01.500>好</c></v>\r\n<ruby>漢<rt>han</rt></ruby>&amp;\r\n\r\n第二条\r\n00:00:04.000 --> 00:00:06.000 line:-1 align:center\r\n<i>再见</i>\r\n"

    static func main() throws {
        let cases: [(String, () throws -> Void)] = [
            ("subtitle-authoring-ass-field-preservation", assFields),
            ("subtitle-authoring-vtt-opaque-and-lexical-preservation", vttFields),
            ("subtitle-authoring-full-width-two-point-exact", exactArithmetic),
            ("subtitle-authoring-atomic-quantization", atomicCalibration),
            ("subtitle-authoring-vtt-inline-time-and-rejection", inlineTimes),
            ("subtitle-authoring-copy-protect-source-and-io", safeCopy),
            ("subtitle-authoring-explicit-insert-delete-boundary", insertion),
            ("subtitle-authoring-legacy-text-model-unchanged", legacyBoundary)
        ]
        for (id, test) in cases { try test(); print("PASS \(id)") }
        print("Prepared case count: \(cases.count); real Core only, no App/render verification")
    }
    static func assFields() throws {
        var d = try PreservingSubtitleDocument.parse(ass, format: .ass)
        try require(try d.text() == ass, "ASS no-op BOM/CRLF/unknown field/raw overrides")
        let first = d.cues[0]
        try d.update(id: first.id, start: first.startMicroseconds, end: first.endMicroseconds, rawBody: first.rawBody + "新")
        try require(try d.text() == ass.replacingOccurrences(of: first.rawBody + "\r\n", with: first.rawBody + "新\r\n"), "Only requested ASS Text field changed")
        try d.update(id: first.id, start: 1_210_000, end: first.endMicroseconds, rawBody: first.rawBody)
        try require(try d.text() == ass.replacingOccurrences(of: " 0:00:01.20 ", with: " 0:00:01.21 "), "ASS time whitespace/other fields preserved")
        let ssa = "[V4 Styles]\nFormat: Name,Fontname\nStyle: Default,Arial\n[Events]\nFormat: Marked,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text\nDialogue: Marked=1,0:00:00.10,0:00:01.20,Default,A,1,2,3,,{\\h}保留,逗号\n"
        try require(try PreservingSubtitleDocument.parse(ssa, format: .ssa).text() == ssa, "SSA Marked and style preserved")
    }
    static func vttFields() throws {
        var d = try PreservingSubtitleDocument.parse(vtt, format: .vtt)
        try require(try d.text() == vtt, "VTT opaque/style/settings/tags/lexical times")
        let first = d.cues[0]; try d.update(id: first.id, start: first.startMicroseconds, end: first.endMicroseconds, rawBody: first.rawBody.replacingOccurrences(of: "你", with: "您好"))
        try require(try d.text() == vtt.replacingOccurrences(of: "你<", with: "您好<"), "VTT multiline body edit, opaque blocks unchanged")
        // Identical templates/payload cannot be looked up by value: lexical
        // timestamps belong to distinct cue UUIDs.
        let twins = "WEBVTT\n\n00:01.000 --> 00:02.000\n相同\n\n00:00:03.000 --> 00:00:04.000\n相同\n"
        try require(try PreservingSubtitleDocument.parse(twins, format: .vtt).text() == twins, "Per-ID original lexical timestamp")
    }
    static func exactArithmetic() throws {
        let map = try SubtitleTwoPointMap(sourceA: 10_000_000, videoA: 12_000_000, sourceB: 20_000_000, videoB: 23_000_000)
        try require(try map.map(10_000_000, quantum: 1_000) == 12_000_000, "Anchor A exact")
        try require(try map.map(20_000_000, quantum: 1_000) == 23_000_000, "Anchor B exact")
        try require(try map.map(15_000_000, quantum: 1_000) == 17_500_000, "Independent affine midpoint")
        try require(try map.map(0, quantum: 1_000) == 1_000_000, "Earlier nonnegative extrapolation")
        let wide = try SubtitleTwoPointMap(sourceA: 0, videoA: 0, sourceB: 900_000_000_000_000, videoB: 900_000_000_000_000)
        try require(try wide.map(800_000_000_000_000, quantum: 10_000) == 800_000_000_000_000, "128-bit product above UInt64")
        try rejects { _ = try SubtitleTwoPointMap(sourceA: 2, videoA: 1, sourceB: 2, videoB: 3) }
        try rejects { _ = try SubtitleTwoPointMap(sourceA: 1, videoA: 2, sourceB: 3, videoB: 1) }
        let negative = try SubtitleTwoPointMap(sourceA: 10_000, videoA: 0, sourceB: 20_000, videoB: 10_000)
        try rejects { _ = try negative.map(0, quantum: 1_000) }
        try rejects { _ = try SubtitleExactClock.parse("00:60:01.000") }
        try rejects { _ = try SubtitleExactClock.parse("00:00:01.0000001") }
        try rejects { _ = try SubtitleExactClock.observedPlayerSeconds(.nan) }
        let fps = try SubtitleTwoPointMap.frameRateConversion(subtitleFPS: "25", videoFPS: "23.976")
        try require(fps.sourceB == 2_997 && fps.videoB == 3_125, "Reduced rational literal frame-rate ratio")
        try rejects { _ = try fps.map(1_000_000, quantum: 1_000) }
        try require(try fps.map(1_000_000, quantum: 1_000, quantization: .nearestNativeTick) == 1_043_000, "Explicit millisecond FPS rounding")
        try rejects { _ = try SubtitleTwoPointMap.frameRateConversion(subtitleFPS: "25", videoFPS: "0") }
    }
    static func atomicCalibration() throws {
        var d = try PreservingSubtitleDocument.parse(ass, format: .ass); let before = try d.text()
        let map = try SubtitleTwoPointMap(sourceA: 0, videoA: 0, sourceB: 3_000_000, videoB: 1_000_000)
        try rejects { try d.calibrate(map) }; try require(try d.text() == before, "Non-centisecond exact result preserves entire document")
        try d.calibrate(map, quantization: .nearestNativeTick)
        try require(d.cues[0].startMicroseconds == 400_000 && d.cues[0].endMicroseconds == 1_130_000, "Explicit half-up native quantization")
        var tiny = try PreservingSubtitleDocument.parse("[Events]\nFormat: Start,End,Text\nDialogue: 0:00:00.01,0:00:00.02,x", format: .ass)
        let tinyBefore = try tiny.text(); let collapse = try SubtitleTwoPointMap(sourceA: 0, videoA: 0, sourceB: 100_000_000, videoB: 1_000_000)
        try rejects { try tiny.calibrate(collapse, quantization: .nearestNativeTick) }
        try require(try tiny.text() == tinyBefore, "Rounded zero duration rejects atomically")
        try rejects { try tiny.shift(decimalSeconds: "-1") }; try require(try tiny.text() == tinyBefore, "Negative time rejects atomically")
        try rejects { try tiny.shift(decimalSeconds: "0.001") }; try require(try tiny.text() == tinyBefore, "ASS sub-centisecond shift rejected")
    }
    static func inlineTimes() throws {
        var d = try PreservingSubtitleDocument.parse(vtt, format: .vtt)
        let map = try SubtitleTwoPointMap(sourceA: 1_000_000, videoA: 2_000_000, sourceB: 3_000_000, videoB: 6_000_000)
        try d.calibrate(map)
        try require(d.cues[0].startMicroseconds == 2_000_000 && d.cues[0].endMicroseconds == 6_000_000, "Cue boundaries mapped")
        try require(d.cues[0].rawBody.contains("<00:00:03.000>"), "Absolute inline timestamp mapped, ruby/voice/class retained")
        try require(try d.text().contains("region:bottom vertical:rl line:20% position:30%,line-left size:40% align:start"), "Settings untouched")
        let two = "WEBVTT\n\n00:01.000 --> 00:03.000\n甲<00:01.500>乙<00:02.500>丙\n"
        let identity = try SubtitleTwoPointMap(sourceA: 0, videoA: 0, sourceB: 10_000_000, videoB: 10_000_000)
        var lexical = try PreservingSubtitleDocument.parse(two, format: .vtt); try lexical.calibrate(identity)
        try require(try lexical.text() == two, "Forward-order validation + identity keeps inline lexical times")
        for bad in ["00:03.000", "00:01.000", "00:00.999"] {
            try rejects { _ = try PreservingSubtitleDocument.parse(two.replacingOccurrences(of: "00:01.500", with: bad), format: .vtt) }
        }
        try rejects { _ = try PreservingSubtitleDocument.parse("WEBVTTjunk\n\n00:01.000 --> 00:02.000\nx", format: .vtt) }
        try rejects { _ = try PreservingSubtitleDocument.parse(two.replacingOccurrences(of: "00:02.500", with: "00:01.400"), format: .vtt) }
        let bodyBefore = try lexical.text()
        try rejects { try lexical.update(id: lexical.cues[0].id, start: 1_000_000, end: 3_000_000, rawBody: "甲\n\n乙") }
        try require(try lexical.text() == bodyBefore, "No cue/metadata injection by blank line")
    }
    static func safeCopy() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-authoring-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let original = work.appendingPathComponent("源.vtt"); try Data(vtt.utf8).write(to: original)
        let d = try PreservingSubtitleDocument.read(from: original); let copy = work.appendingPathComponent("副本.vtt")
        try d.writeCopy(to: copy, sourceURL: original)
        try require(try Data(contentsOf: copy) == Data(vtt.utf8), "UTF8/BOM read/no-op copy actual bytes")
        try require(try Data(contentsOf: original) == Data(vtt.utf8), "Original not overwritten")
        try rejects { try d.writeCopy(to: original, sourceURL: original) }
        let alias = work.appendingPathComponent("硬链接.vtt"); try FileManager.default.linkItem(at: original, to: alias)
        try rejects { try d.writeCopy(to: alias, sourceURL: original) }
        let symlink = work.appendingPathComponent("链接.vtt"); try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        try rejects { try d.writeCopy(to: symlink, sourceURL: original) }
        try rejects { try d.writeCopy(to: work.appendingPathComponent("错格式.srt"), sourceURL: original) }
        let directory = work.appendingPathComponent("目录.vtt"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try rejects { try d.writeCopy(to: directory, sourceURL: original) }
        try require(try Data(contentsOf: original) == Data(vtt.utf8), "All rejected writes preserve source bytes")
        let fifo = work.appendingPathComponent("fifo.vtt"); try require(mkfifo(fifo.path, 0o600) == 0, "Own FIFO creation")
        try rejects { _ = try PreservingSubtitleDocument.read(from: fifo) }
    }
    static func insertion() throws {
        let sources: [(SubtitleDocument.Format, String)] = [(.srt, "1\n00:00:00,000 --> 00:00:01,000\n原"), (.vtt, "WEBVTT\n\n00:00.000 --> 00:01.000\n原"), (.ass, "[Events]\nFormat: Start,End,Style,Text\nDialogue: 0:00:00.00,0:00:01.00,Default,{\\b1}原")]
        for (format, source) in sources {
            var d = try PreservingSubtitleDocument.parse(source, format: format); let id = try d.insert(after: d.cues[0].id)
            let output = try d.text(); let reopened = try PreservingSubtitleDocument.parse(output, format: format)
            try require(reopened.cues.count == 2 && reopened.cues[1].startMicroseconds == 1_000_000 && reopened.cues[1].rawBody == "新字幕", "Insert normal cue after original EOF lacking newline")
            if format == .srt { try require(output.contains("\n\n2\n00:00:01,000 --> 00:00:03,000\n"), "Unused positive SRT ID") }
            if format == .vtt { try require(!output.contains("\n2\n"), "No implicit VTT ID/CSS selector") }
            d.remove(id: id); try require(d.cues.count == 1, "Delete only requested cue")
            d.remove(id: d.cues[0].id); _ = try d.insert(after: nil)
            let restored = try PreservingSubtitleDocument.parse(d.text(), format: format)
            try require(restored.cues.count == 1 && restored.cues[0].rawBody == "新字幕", "Delete-all then add retains correct format/Event position")
        }
    }
    static func legacyBoundary() throws {
        let d = try SubtitleDocument.parse(vtt, format: .vtt)
        try require(d.sourceFormat == .vtt && d.losesFormatting, "Existing translation/ASR plain-text contract remains")
        try require(!d.cues[0].text.contains("<v "), "Existing stripping remains in legacy model only")
        try require(try PreservingSubtitleDocument.parse(vtt, format: .vtt).text() == vtt, "Authoring model does not reuse lossy legacy parse")
    }
}
