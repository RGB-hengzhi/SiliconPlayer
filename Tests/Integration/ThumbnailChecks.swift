import AppKit
import CryptoKit
import Foundation
import Darwin

@main struct ThumbnailChecks {
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "ThumbnailChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor private static func wait(_ tools: ThumbnailTools, allowError: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(45)
        while tools.busy && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        if tools.busy { tools.cancel(); try require(false, "Thumbnail job timeout") }
        if !allowError { try require(tools.error == nil, tools.error ?? "") }
    }
    private static func png(_ image: NSImage?) throws -> Data {
        guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ThumbnailChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid thumbnail image"])
        }
        return data
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        try require(CommandLine.arguments.count == 3, "Pass fixture and report directories")
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let report = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let source = fixture.appendingPathComponent("中文 generated-video.mp4")
        let tools = ThumbnailTools.shared
        let cacheBefore = try tools.checkCacheFiles()
        defer { tools.cancel(); tools.removeCheckCacheFiles(excluding: cacheBefore) }
        var checks: [String] = []
        var image: NSImage?
        tools.frame(source: source, time: 1) { image = $0 }; try await wait(tools)
        let framePNG = try png(image)
        let frame = NSBitmapImageRep(data: framePNG)!
        try require(frame.pixelsWide == 720 && frame.pixelsHigh > 0, "Frame dimensions invalid")
        try framePNG.write(to: report.appendingPathComponent("thumbnail-frame.png"))
        checks.append("actual local frame PNG"); print("PASS actual local frame PNG")
        let sheet = report.appendingPathComponent("contact-sheet-12.png")
        try Data("previous destination".utf8).write(to: sheet)
        tools.generateContactSheet(source: source, duration: 5, count: 12, columns: 4, width: 1600, output: sheet)
        var hoverCalled = false, hover: NSImage?
        tools.frame(source: source, time: 2) { hoverCalled = true; hover = $0 }
        try require(hoverCalled && hover == nil && tools.busy && tools.generatingSheet, "Hover cancelled a contact sheet")
        try await wait(tools)
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: sheet))!
        try require(bitmap.pixelsWide == 1600 && bitmap.pixelsHigh > 600, "Sheet size invalid")
        try require(tools.lastOutput == sheet && tools.progress == 1, "Sheet completion state invalid")
        checks.append("12-frame labeled PNG, atomic replacement and hover isolation")
        print("PASS 12-frame labeled PNG \(bitmap.pixelsWide)x\(bitmap.pixelsHigh), replacement and hover isolation")
        let cancelled = report.appendingPathComponent("cancelled-sheet.png")
        let original = Data("keep previous sheet".utf8); try original.write(to: cancelled)
        tools.generateContactSheet(source: source, duration: 5, count: 60, columns: 5, width: 1600, output: cancelled)
        try await Task.sleep(nanoseconds: 50_000_000); tools.cancel()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        try require(try Data(contentsOf: cancelled) == original && !tools.busy && !tools.generatingSheet, "Cancel changed output or left busy state")
        checks.append("cancel preserves previous destination"); print("PASS cancellation preserves existing output")
        var stale = false, newest = false
        tools.frame(source: source, time: 0.179) { _ in stale = true }
        tools.frame(source: source, time: 2.333) { value in newest = value != nil }
        try await wait(tools)
        try require(!stale && newest, "Obsolete completion was not suppressed")
        checks.append("obsolete completion suppressed"); print("PASS obsolete frame completion suppressed")
        for (badSource, time) in [(URL(string: "https://example.invalid/video.mp4")!, 0),
            (fixture.appendingPathComponent("missing.mp4"), 0), (source, Double.nan), (source, Double.infinity),
            (source, -1), (fixture.appendingPathComponent("audio-only.wav"), 0),
            (fixture.appendingPathComponent("damaged.mp4"), 0), (source, 999)] {
            var called = false, value: NSImage?
            tools.frame(source: badSource, time: time) { called = true; value = $0 }
            try await wait(tools, allowError: true)
            try require(called && value == nil && tools.error != nil, "Bad source/time did not fail: \(badSource.lastPathComponent)/\(time)")
        }
        checks.append("bad sources and invalid/out-of-range times rejected")
        print("PASS remote/missing/audio-only/damaged sources and invalid/out-of-range times")
        let protected = report.appendingPathComponent("invalid-sheet.png"); try original.write(to: protected)
        for (duration, count, columns, width) in [(Double.nan, 12, 4, 1600), (0, 12, 4, 1600),
            (5, 0, 4, 1600), (5, 61, 4, 1600), (5, 12, 0, 1600), (5, 12, 11, 1600),
            (5, 2, 3, 1600), (5, 12, 4, 399), (5, 12, 4, 4097), (5, 60, 1, 4096)] {
            tools.generateContactSheet(source: source, duration: duration, count: count, columns: columns, width: width, output: protected)
            try await wait(tools, allowError: true)
            try require(tools.error != nil && !tools.generatingSheet && (try Data(contentsOf: protected)) == original, "Invalid sheet changed destination")
        }
        let before = try Data(contentsOf: source)
        tools.generateContactSheet(source: source, duration: 5, count: 1, columns: 1, width: 800, output: source)
        try await wait(tools, allowError: true)
        try require(tools.error != nil && (try Data(contentsOf: source)) == before, "Sheet overwrote source media")
        checks.append("invalid/oversized geometry and source overwrite rejected")
        print("PASS invalid/oversized geometry and source overwrite protection")
        try Data(contentsOf: fixture.appendingPathComponent("alternate.mp4")).write(to: source)
        var changed: NSImage?
        tools.frame(source: source, time: 1) { changed = $0 }; try await wait(tools)
        try require(try png(changed) != framePNG, "Same-path changed media returned stale cache")
        checks.append("same-path changed media invalidates cache"); print("PASS same-path changed media invalidates cache")
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let cacheAfter = try tools.checkCacheFiles()
        try require(!cacheAfter.subtracting(cacheBefore).contains { $0.hasPrefix(".tmp-") }, "Temporary frame files remain")
        try require(!FileManager.default.contentsOfDirectory(atPath: report.path).contains { $0.hasPrefix(".siliconplayer-sheet-") }, "Temporary sheet files remain")
        checks.append("temporary frame/sheet files cleaned"); print("PASS temporary frame/sheet files cleaned")
        var outputs: [String: Any] = [:]
        for name in ["thumbnail-frame.png", "contact-sheet-12.png"] {
            let data = try Data(contentsOf: report.appendingPathComponent(name)), rep = NSBitmapImageRep(data: try Data(contentsOf: report.appendingPathComponent(name)))!
            outputs[name] = ["bytes": data.count, "width": rep.pixelsWide, "height": rep.pixelsHigh,
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        }
        let result: [String: Any] = ["passed": true, "checks": checks, "outputs": outputs,
            "scope": "production ThumbnailTools/FFmpeg, synthetic local media; no player app or timeline UI acceptance"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report.appendingPathComponent("thumbnails.json"))
        print("\(checks.count) thumbnail integration groups passed")
    }
}

// Concatenated with the production source to inspect private cache state.
private extension ThumbnailTools {
    func checkCacheFiles() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) }
    func removeCheckCacheFiles(excluding original: Set<String>) {
        guard let current = try? checkCacheFiles() else { return }
        for name in current.subtracting(original) { try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(name)) }
    }
}
