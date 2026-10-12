import Foundation
import Translation

// This probe never asks to install models. macOS 26's installed-only session
// cannot request language downloads. The GUI's translation task is separate.
@main struct InstalledTranslationChecks {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileWriteInvalidFileName) }
        var report: [String: Any] = ["downloadsRequested": false, "scope": "Installed-only Apple API probe; not GUI or language-package installation acceptance"]
        if #available(macOS 26.0, *) {
            let availability = LanguageAvailability()
            var rows: [[String: Any]] = []
            for (from, to, input) in [("en", "zh-Hans", "Please open the video and turn on subtitles."), ("zh-Hans", "en", "请打开视频并显示字幕。"), ("en", "ja", "The next chapter starts in ten seconds.")] {
                let source = Locale.Language(identifier: from), target = Locale.Language(identifier: to)
                let status = await availability.status(from: source, to: target)
                var row: [String: Any] = ["source": from, "target": to, "input": input, "status": String(describing: status), "translated": false]
                if status == .installed {
                    let session = TranslationSession(installedSource: source, target: target)
                    precondition(!session.canRequestDownloads)
                    let ready = await session.isReady
                    row["ready"] = ready
                    if ready {
                        do {
                            let response = try await session.translate(input)
                            precondition(!response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            row["output"] = response.targetText; row["translated"] = true
                        } catch { row["error"] = error.localizedDescription }
                    }
                }
                rows.append(row)
            }
            report["pairs"] = rows
            report["successfulPairs"] = rows.filter { $0["translated"] as? Bool == true }.count
        } else { report["skipped"] = "Installed-only TranslationSession initializer requires macOS 26+" }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        print(String(data: try Data(contentsOf: url), encoding: .utf8)!)
    }
}
