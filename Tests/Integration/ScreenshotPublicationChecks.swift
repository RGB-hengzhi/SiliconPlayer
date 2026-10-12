// The script prefixes this harness with the unmodified production file
// publication/gate helpers. It runs filesystem checks, not player/UI checks.
@main
struct ScreenshotPublicationChecks {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "ScreenshotPublicationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() throws {
        let apfs = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-publish-apfs-\(UUID().uuidString)")
        let external = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("screenshot-publish-external-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: apfs); try? FileManager.default.removeItem(at: external) }
        let payload = Data(repeating: 0x61, count: 2 * 1024 * 1024), sentinel = Data("external-content-must-stay".utf8)
        var count = 0
        for (name, folder) in [("APFS", apfs), ("workspace", external)] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func stage() throws -> URL {
                let url = folder.appendingPathComponent("stage-\(UUID().uuidString)")
                try payload.write(to: url)
                return url
            }
            let target = folder.appendingPathComponent("frame.png")
            let firstStage = try stage()
            let published = try publishScreenshotFile(staged: firstStage, target: target, replacement: false, gate: ScreenshotPublicationGate())
            try require(try Data(contentsOf: target) == payload, "\(name): new destination bytes differ")
            print("PASS \(name) exclusive publication; atomic=\(published.atomic)")
            count += 1

            try sentinel.write(to: target)
            let raceStage = try stage()
            do {
                _ = try publishScreenshotFile(staged: raceStage, target: target, replacement: false, gate: ScreenshotPublicationGate())
                try require(false, "\(name): existing destination was accepted")
            } catch let error as NSError {
                try require(error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST), "\(name): expected EEXIST, got \(error)")
            }
            try require(try Data(contentsOf: target) == sentinel && FileManager.default.fileExists(atPath: raceStage.path), "\(name): same-name race changed target/stage")
            print("PASS \(name) same-name destination preserved")
            count += 1

            let replacement = try publishScreenshotFile(staged: try stage(), target: target, replacement: true, gate: ScreenshotPublicationGate())
            try require(replacement.atomic && (try Data(contentsOf: target)) == payload, "\(name): explicitly approved replacement failed")
            print("PASS \(name) approved replacement")
            count += 1

            let cancelledTarget = folder.appendingPathComponent("cancelled.png")
            let cancelledStage = try stage(), cancelledGate = ScreenshotPublicationGate()
            cancelledGate.cancel()
            do {
                _ = try publishScreenshotFile(staged: cancelledStage, target: cancelledTarget, replacement: false, gate: cancelledGate)
                try require(false, "\(name): cancelled commit was accepted")
            } catch {
                try require(error.localizedDescription == "截图已取消", "\(name): wrong cancellation error")
            }
            try require(!FileManager.default.fileExists(atPath: cancelledTarget.path) && FileManager.default.fileExists(atPath: cancelledStage.path), "\(name): cancellation created target or removed writer stage")
            print("PASS \(name) cancellation before commit")
            count += 1
        }
        print("PASS \(count) production filesystem checks; no application, mpv reply or UI latency certification")
    }
}
