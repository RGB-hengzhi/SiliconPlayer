import Foundation
import Darwin

/// Read a bounded regular file without opening a blocking FIFO/device or
/// following the final parent/leaf symlink. Never creates or rewrites a file.
public enum BoundedProfileFile {
    public static func read(_ url: URL, maximumBytes: Int, allowMissing: Bool = false) throws -> Data? {
        guard url.isFileURL, maximumBytes > 0, maximumBytes < Int.max,
              !["", ".", ".."].contains(url.lastPathComponent) else { throw MediaPreferenceError.invalidDocument }
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard parent >= 0 else {
            if allowMissing && errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        defer { Darwin.close(parent) }
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if allowMissing && errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        let file = FileHandle(fileDescriptor: descriptor,closeOnDealloc: true)
        defer { try? file.close() }
        var information = stat()
        guard fstat(descriptor,&information) == 0, information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_size >= 0 else { throw MediaPreferenceError.invalidDocument }
        guard information.st_size <= maximumBytes else { throw MediaPreferenceError.tooLarge }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw MediaPreferenceError.tooLarge }
        return data
    }
}
