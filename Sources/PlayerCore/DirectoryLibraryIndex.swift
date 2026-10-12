import Foundation

public struct DirectoryLibraryIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
}

public struct DirectoryLibraryFile: Identifiable, Equatable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let url: URL
    public let identity: DirectoryLibraryIdentity
    public let bytes: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public init(relativePath: String, url: URL, identity: DirectoryLibraryIdentity,
                bytes: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64) {
        self.relativePath = relativePath; self.url = url; self.identity = identity
        self.bytes = bytes; self.modifiedSeconds = modifiedSeconds; self.modifiedNanoseconds = modifiedNanoseconds
    }
}

public struct DirectoryLibraryDelta: Equatable, Sendable {
    public let added: Int
    public let removed: Int
    public let modified: Int
    public static func compare(old: [DirectoryLibraryFile], new: [DirectoryLibraryFile]) -> Self {
        let a = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let b = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        return Self(added: b.keys.filter { a[$0] == nil }.count,
                    removed: a.keys.filter { b[$0] == nil }.count,
                    modified: b.keys.filter { a[$0] != nil && a[$0] != b[$0] }.count)
    }
}

public struct DirectoryLibraryScanResult: Sendable {
    public let root: URL
    public let identity: DirectoryLibraryIdentity
    public let files: [DirectoryLibraryFile]
    public let visited: Int
    public let directories: Int
    public let skipped: Int
    public let elapsed: TimeInterval
    public init(root: URL, identity: DirectoryLibraryIdentity, files: [DirectoryLibraryFile], visited: Int,
                directories: Int, skipped: Int, elapsed: TimeInterval) {
        self.root = root; self.identity = identity; self.files = files; self.visited = visited
        self.directories = directories; self.skipped = skipped; self.elapsed = elapsed
    }
}

/// An explicit user Add operation only. The watcher/controller never invokes it.
/// Existing URL and UUID/current-item semantics remain those of the real Playlist.
public enum DirectoryLibraryQueueAppend {
    public static func applying(_ urls: [URL], to original: Playlist) -> Playlist {
        var result = original
        result.add(items: urls.map { MediaItem(url: $0) })
        return result
    }
}
