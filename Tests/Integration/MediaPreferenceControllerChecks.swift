import Foundation
import Darwin
import PlayerCore

private struct CheckError: Error { let message: String }
private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw CheckError(message: message) }
}
private func media(_ name: String) -> MediaItem { MediaItem(url: URL(fileURLWithPath: "/tmp/中文媒体 \(name).mkv")) }
private func audio(_ id: Int) throws -> MediaTrackCandidate {
    try .init(runtimeID: id, descriptor: .init(kind: .audio, language: "zh", title: "原声", codec: "aac", channels: 2))
}
private func subtitle(_ id: Int, file: URL) throws -> MediaTrackCandidate {
    try .init(runtimeID: id, descriptor: .init(kind: .subtitle, language: "zh", title: "中文", codec: "subrip", source: .localFile(file)))
}

@main @MainActor struct MediaPreferenceControllerChecks {
    static func main() throws {
        let report = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let work = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var passed: [String] = [], failed: [String: String] = [:]
        func group(_ name: String, _ test: () throws -> Void) {
            do { try test(); passed.append(name); print("PASS \(name)") }
            catch { failed[name] = "\(error)"; print("FAIL \(name): \(error)") }
        }
        func prepared(_ name: String) throws -> (MediaPreferencesController, MediaItem, URL, MediaTrackCandidate) {
            let directory = work.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let item = media(name), external = directory.appendingPathComponent("字幕:斜\\线，中文.srt")
            try Data("1\n00:00:00,000 --> 00:00:02,000\n中文\n".utf8).write(to: external)
            let candidate = try subtitle(5, file: external)
            var record = MediaPreferenceRecord(identity: try .init(originalURL: item.url))
            record.audio = .match(try audio(11).descriptor); record.primarySubtitle = .match(candidate.descriptor)
            record.secondarySubtitle = .disabled; record.audioDelay = 0.3; record.subtitleDelay = -0.2
            record.secondarySubtitleDelay = 0.6
            var geometry = MediaGeometryPreference(); geometry.rotation = 90; geometry.zoom = 0.8
            geometry.projection = .equirect; geometry.yaw = 40; record.geometry = geometry
            var document = MediaPreferenceDocument(); try document.save(record)
            let file = directory.appendingPathComponent("media-preferences.json")
            try MediaPreferenceStore(fileURL: file).save(document)
            return (MediaPreferencesController(fileURL: file), item, external, candidate)
        }
        group("controller-stale-entry-and-before-load-save-preserve-file") {
            let (controller, item, _, _) = try prepared("stale")
            let token = controller.prepareForLoad(item: item), file = work.appendingPathComponent("stale/media-preferences.json")
            let bytes = try Data(contentsOf: file)
            try expect(!controller.saveCurrent(snapshot: .init(), token: token), "saved before actual load")
            let next = media("next"); _ = controller.prepareForLoad(item: next)
            try expect(controller.applyRestoredTracksOnUpdate(token: token, itemID: item.id, candidates: [audio(19)], now: 10) == nil, "late load callback accepted")
            try expect(!controller.isLoaded && !controller.saveCurrent(snapshot: .init(), token: token), "stale save changed active load")
            try expect(Data(contentsOf: file) == bytes, "rejected operation changed saved bytes")
        }
        group("controller-late-external-track-retry-resolves-once") {
            let (controller, item, external, _) = try prepared("late")
            let token = controller.prepareForLoad(item: item)
            try expect(controller.currentExternalFiles.count == 1 && controller.currentExternalFiles.first?.url.standardizedFileURL.path == external.standardizedFileURL.path, "original external source lost: \(controller.currentExternalFiles.map { $0.url.absoluteString }) versus \(external.absoluteString)")
            let first = controller.applyRestoredTracksOnUpdate(token: token, itemID: item.id, candidates: [try audio(23)], now: 10)
            try expect(first?.audio == .matched(23) && first?.primarySubtitle == nil && first?.audioDelay == 0.3 && controller.hasPendingTrackRestoration, "missing external prematurely fell back")
            let second = controller.applyRestoredTracksOnUpdate(token: token, itemID: item.id, candidates: [try audio(99), try subtitle(17, file: external)], now: 11)
            try expect(second?.audio == nil && second?.primarySubtitle == .matched(17) && second?.audioDelay == nil && !controller.hasPendingTrackRestoration, "late descriptor/ID restore not bounded once")
            try expect(controller.applyRestoredTracksOnUpdate(token: token, itemID: item.id, candidates: [try audio(99)], now: 12) == nil, "resolved tracks overwritten by later refresh")
        }
        group("controller-missing-ambiguity-timeout-visible-auto-fallback") {
            let (controller, item, _, _) = try prepared("missing")
            let token = controller.prepareForLoad(item: item)
            let first = controller.applyRestoredTracksOnUpdate(token: token, itemID: item.id, candidates: [try audio(2), try audio(3)], now: 100)
            try expect(first?.audio == .automatic && first?.notices.first?.contains("多个匹配") == true, "ambiguous audio picked arbitrary ID")
            let last = controller.applyRestoredTracksOnUpdate(token: token, itemID: item.id, candidates: [try audio(2)], now: 102.1)
            try expect(last?.primarySubtitle == .automatic && last?.notices.first?.contains("未找到") == true && !controller.hasPendingTrackRestoration, "missing subtitle did not visibly fall back after bounded wait")
        }
        group("controller-manual-choice-and-stop-cancel-late-restoration") {
            let (controller, item, external, _) = try prepared("manual")
            let token = controller.prepareForLoad(item: item)
            _ = controller.applyRestoredTracksOnUpdate(token: token, itemID: item.id, candidates: [try audio(9)], now: 10)
            controller.markTrackSelectionEdited(kind: .subtitle, secondary: false)
            try expect(controller.applyRestoredTracksOnUpdate(token: token, itemID: item.id, candidates: [try audio(9), try subtitle(14, file: external)], now: 11) == nil, "late saved track replaced manual selection")
            controller.invalidatePlayback()
            try expect(!controller.isLoaded && !controller.isActive && controller.effectiveSettings.rotation == 0 && controller.effectiveSettings.processing.secondarySubtitleDelay == 0, "Stop retained current media overrides")
            try expect(controller.applyRestoredTracksOnUpdate(token: token, itemID: item.id, candidates: [try audio(9)], now: 13) == nil && controller.document.entries.count == 1, "Stop callback resurrected playback or deleted history")
        }
        group("controller-recovery-block-prevents-all-sheet-publications") {
            let (controller, item, _, _) = try prepared("blocked")
            let token = controller.prepareForLoad(item: item)
            _ = controller.applyRestoredTracksOnUpdate(token: token, itemID: item.id, candidates: [try audio(2)], now: 10)
            let file = work.appendingPathComponent("blocked/media-preferences.json"), bytes = try Data(contentsOf: file)
            controller.setPersistenceBlocked(true)
            try expect(!controller.canSave && !controller.saveCurrent(snapshot: .init(), token: token) && !controller.clearCurrent() && !controller.setAutomaticallyRestore(false), "recovery block allowed settings write")
            try expect(Data(contentsOf: file) == bytes && controller.document.automaticallyRestore, "blocked sheet publication changed stores")
            controller.setPersistenceBlocked(false); try expect(controller.setAutomaticallyRestore(false), "explicit recovery unblock did not restore mutation")
        }
        group("controller-clear-current-and-corrupt-reload-preserve-other-records") {
            let (controller, item, _, _) = try prepared("clear")
            let token = controller.prepareForLoad(item: item)
            _ = controller.applyRestoredTracksOnUpdate(token: token, itemID: item.id, candidates: [try audio(2)], now: 10)
            var snapshot = MediaPreferenceSnapshot(); snapshot.geometry.rotation = 180
            try expect(controller.saveCurrent(snapshot: snapshot, token: token), "explicit save failed")
            let file = work.appendingPathComponent("clear/media-preferences.json")
            var document = try MediaPreferenceStore(fileURL: file).load()
            let other = MediaPreferenceRecord(identity: try .init(originalURL: media("other").url))
            try document.save(other); try MediaPreferenceStore(fileURL: file).save(document)
            try expect(controller.loadDocument() && controller.clearCurrent(), "clear current failed")
            try expect(controller.document.entries.count == 1 && controller.document.record(for: other.identity) != nil && controller.effectiveSettings.rotation == 0, "clear removed another media or retained overlay")
            let malformed = Data("not-json".utf8); try malformed.write(to: file)
            try expect(!controller.loadDocument() && controller.document.entries.count == 1 && Data(contentsOf: file) == malformed, "bad reload overwrote document or original bytes")
        }
        group("controller-loaded-global-reset-keeps-media-edits-and-cancels-old-restore") {
            let (controller, item, external, _) = try prepared("reset")
            let token = controller.prepareForLoad(item: item)
            _ = controller.applyRestoredTracksOnUpdate(token: token, itemID: item.id, candidates: [try audio(2)], now: 10)
            try expect(controller.hasPendingTrackRestoration && controller.isLoaded, "fixture did not enter loaded pending restore")
            controller.installBaseSettings(PlaybackSettings())
            try expect(controller.isLoaded && controller.token == token && controller.isActive && !controller.hasPendingTrackRestoration, "global reset lost media context or retained pending restore")
            controller.updateSettings { $0.rotation = 180; $0.zoom = 0.7; $0.processing.yaw = 25; $0.brightness = 4 }
            let persisted = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(controller.baseSnapshot))
            try expect(persisted.rotation == 0 && persisted.zoom == 0 && persisted.processing.yaw == 0 && persisted.brightness == 4 && controller.effectiveSettings.rotation == 180, "post-reset geometry polluted global publication")
            try expect(controller.applyRestoredTracksOnUpdate(token: token, itemID: item.id, candidates: [try audio(8), try subtitle(19, file: external)], now: 11) == nil && controller.effectiveSettings.rotation == 180, "late pre-reset record revived")
            controller.invalidatePlayback()
            try expect(controller.effectiveSettings.rotation == 0 && controller.effectiveSettings.zoom == 0 && controller.baseSnapshot.brightness == 4, "Stop retained post-reset media geometry")
            let next = media("reset-next"); let nextToken = controller.prepareForLoad(item: next)
            _ = controller.applyRestoredTracksOnUpdate(token: nextToken, itemID: next.id, candidates: [try audio(1)], now: 13)
            try expect(controller.effectiveSettings.rotation == 0 && controller.effectiveSettings.processing.yaw == 0 && controller.baseSnapshot.brightness == 4, "next source inherited post-reset session geometry")
        }
        let summary: [String: Any] = ["status": failed.isEmpty ? "passed" : "failed", "uniqueScenarioGroups": passed.count + failed.count,
            "passed": passed.count, "failed": failed.count, "passedScenarioIDs": passed, "failures": failed,
            "scope": "Actual production MainActor controller and PlayerCore; real isolated files and injected monotonic times. No mpv, player, AppKit GUI, or daily preferences access." ]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: report.appendingPathComponent("scenario-summary.json"))
        print("INFO suite completed: \(passed.count) passed, \(failed.count) failed")
        if !failed.isEmpty { exit(1) }
    }
}
