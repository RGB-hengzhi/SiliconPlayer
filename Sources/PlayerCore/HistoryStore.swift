import Foundation

public struct PlaybackHistoryEntry: Identifiable {
    public let url: URL
    public let position: Double
    public let duration: Double
    public let updatedAt: Date
    public var id: String { url.absoluteString }
}

public final class HistoryStore {
    public private(set) var lastError: String?
    private let fileURL: URL
    private var entries: [String: Entry] = [:]
    private var isDirty = false
    public var recentEntries: [PlaybackHistoryEntry] {
        entries.compactMap { key, entry in
            guard let url = URL(string: key), entry.position.isFinite, entry.duration.isFinite else { return nil }
            return PlaybackHistoryEntry(url: url, position: entry.position, duration: entry.duration, updatedAt: entry.updatedAt)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private struct Entry: Codable {
        var position: Double
        var duration: Double
        var updatedAt: Date
    }

    private struct Document: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("SiliconPlayer/history.json")
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: self.fileURL))
            guard document.version == 1 else {
                lastError = "Unsupported playback history version: \(document.version)"
                return
            }
            entries = document.entries
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func resumePosition(for url: URL) -> Double? {
        guard let entry = entries[key(for: url)],
              entry.position.isFinite, entry.duration.isFinite,
              entry.position > 5, entry.duration > 0,
              entry.duration - entry.position > 10,
              entry.position / entry.duration < 0.95 else { return nil }
        return entry.position
    }

    public func record(url: URL, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, position >= 0, duration > 0 else { return }
        entries[key(for: url)] = Entry(
            position: min(position, duration),
            duration: duration,
            updatedAt: Date()
        )
        isDirty = true
    }

    /// Explicit synchronous persistence lets the application batch position updates.
    public func flush() {
        guard isDirty else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Document(version: 1, entries: entries))
            try data.write(to: fileURL, options: .atomic)
            isDirty = false
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func key(for url: URL) -> String {
        MediaItem.normalized(url).absoluteString
    }
}
