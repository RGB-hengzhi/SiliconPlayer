import Foundation

public struct PlaybackBookmark: Identifiable, Codable, Hashable {
    public var id: UUID
    public var url: URL
    public var position: Double
    public var title: String
    public var createdAt: Date

    public init(url: URL, position: Double, title: String, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.url = MediaItem.normalized(url)
        self.position = position
        self.title = title
        self.createdAt = createdAt
    }
}

public struct SavedPlaylist: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String
    public var urls: [URL]
    public var createdAt: Date

    public init(name: String, urls: [URL], id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.urls = urls.map(MediaItem.normalized)
        self.createdAt = createdAt
    }
}

/// A small local library. Each user action is persisted atomically so bookmarks
/// survive a forced quit; the application can expose `lastError` to the user.
public final class LibraryStore {
    public private(set) var bookmarks: [PlaybackBookmark] = []
    public private(set) var favorites: [MediaItem] = []
    public private(set) var savedPlaylists: [SavedPlaylist] = []
    public private(set) var lastError: String?
    private let fileURL: URL
    private var isDirty = false

    private struct LossyArray<Element: Codable>: Codable {
        var elements: [Element]
        var rejectedCount = 0

        init(_ elements: [Element]) { self.elements = elements }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var decoded: [Element] = []
            while !container.isAtEnd {
                let entryDecoder = try container.superDecoder()
                do { decoded.append(try Element(from: entryDecoder)) }
                catch { rejectedCount += 1 }
            }
            elements = decoded
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            for element in elements { try container.encode(element) }
        }
    }

    private struct Document: Codable {
        var version: Int
        var bookmarks: LossyArray<PlaybackBookmark>
        var favorites: LossyArray<MediaItem>
        var savedPlaylists: LossyArray<SavedPlaylist>

        enum CodingKeys: String, CodingKey { case version, bookmarks, favorites, savedPlaylists }

        init(bookmarks: [PlaybackBookmark], favorites: [MediaItem], savedPlaylists: [SavedPlaylist]) {
            version = 1
            self.bookmarks = LossyArray(bookmarks)
            self.favorites = LossyArray(favorites)
            self.savedPlaylists = LossyArray(savedPlaylists)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            bookmarks = try container.decodeIfPresent(LossyArray<PlaybackBookmark>.self, forKey: .bookmarks) ?? LossyArray([])
            favorites = try container.decodeIfPresent(LossyArray<MediaItem>.self, forKey: .favorites) ?? LossyArray([])
            savedPlaylists = try container.decodeIfPresent(LossyArray<SavedPlaylist>.self, forKey: .savedPlaylists) ?? LossyArray([])
        }
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiliconPlayer/library.json")
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: self.fileURL))
            guard document.version == 1 else {
                lastError = "不支持的媒体库版本：\(document.version)"
                return
            }
            var bookmarkIDs = Set<UUID>()
            bookmarks = document.bookmarks.elements.filter {
                $0.position.isFinite && $0.position >= 0 && bookmarkIDs.insert($0.id).inserted
            }.map {
                var value = $0
                value.url = MediaItem.normalized(value.url)
                if value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.title = MediaItem(url: value.url).title }
                return value
            }
            var favoriteURLs = Set<URL>()
            favorites = document.favorites.elements.map { MediaItem(url: $0.url, id: $0.id) }
                .filter { favoriteURLs.insert($0.url).inserted }
            var playlistIDs = Set<UUID>()
            savedPlaylists = document.savedPlaylists.elements.filter { playlistIDs.insert($0.id).inserted }.map {
                SavedPlaylist(name: $0.name, urls: $0.urls, id: $0.id, createdAt: $0.createdAt)
            }
            let rejected = document.bookmarks.rejectedCount + document.favorites.rejectedCount + document.savedPlaylists.rejectedCount
            if rejected > 0 { lastError = "已忽略媒体库中的 \(rejected) 条损坏记录。" }
        } catch { lastError = "媒体库读取失败：\(error.localizedDescription)" }
    }

    @discardableResult
    public func addBookmark(url: URL, position: Double, title: String) -> PlaybackBookmark? {
        guard position.isFinite, position >= 0 else {
            lastError = "书签时间必须是大于或等于零的有效秒数。"
            return nil
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = PlaybackBookmark(url: url, position: position, title: name.isEmpty ? MediaItem(url: url).title : name)
        bookmarks.append(bookmark)
        persist()
        return bookmark
    }

    public func removeBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        persist()
    }

    /// Updates only the editable fields, preserving the media, identity and date.
    /// A failed disk write restores the previous value so the caller can retry.
    @discardableResult
    public func updateBookmark(id: UUID, title: String, position: Double) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            lastError = "书签名称不能为空，也不能含换行符或控制字符。"
            return false
        }
        guard position.isFinite, position >= 0 else {
            lastError = "书签时间必须是大于或等于零的有效秒数。"
            return false
        }
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else {
            lastError = "这条书签已不存在，请重新选择。"
            return false
        }
        let previous = bookmarks[index]
        let previouslyDirty = isDirty
        bookmarks[index].title = trimmed
        bookmarks[index].position = position
        persist()
        guard !isDirty else {
            bookmarks[index] = previous
            isDirty = previouslyDirty
            return false
        }
        return true
    }

    public func isFavorite(_ url: URL) -> Bool { favorites.contains { $0.url == MediaItem.normalized(url) } }

    /// Returns the resulting favorite state.
    @discardableResult
    public func toggleFavorite(url: URL) -> Bool {
        let normalized = MediaItem.normalized(url)
        if let index = favorites.firstIndex(where: { $0.url == normalized }) {
            favorites.remove(at: index)
            persist()
            return false
        }
        favorites.append(MediaItem(url: normalized))
        persist()
        return true
    }

    @discardableResult
    public func savePlaylist(name: String, urls: [URL]) -> SavedPlaylist? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !urls.isEmpty else {
            lastError = "请填写列表名称，并至少添加一个媒体。"
            return nil
        }
        let saved = SavedPlaylist(name: trimmed, urls: urls)
        savedPlaylists.append(saved)
        persist()
        return saved
    }

    public func removeSavedPlaylist(id: UUID) {
        savedPlaylists.removeAll { $0.id == id }
        persist()
    }

    @discardableResult
    public func renameSavedPlaylist(id: UUID, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            lastError = "列表名称不能为空，也不能含换行符或控制字符。"
            return false
        }
        guard let index = savedPlaylists.firstIndex(where: { $0.id == id }) else {
            lastError = "这个保存的列表已不存在，请重新选择。"
            return false
        }
        let previous = savedPlaylists[index]
        let previouslyDirty = isDirty
        savedPlaylists[index].name = trimmed
        persist()
        guard !isDirty else {
            savedPlaylists[index] = previous
            isDirty = previouslyDirty
            return false
        }
        return true
    }

    public func flush() {
        guard isDirty else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Document(bookmarks: bookmarks, favorites: favorites, savedPlaylists: savedPlaylists))
            try data.write(to: fileURL, options: .atomic)
            isDirty = false
            lastError = nil
        } catch { lastError = "媒体库保存失败：\(error.localizedDescription)" }
    }

    private func persist() { isDirty = true; flush() }
}
