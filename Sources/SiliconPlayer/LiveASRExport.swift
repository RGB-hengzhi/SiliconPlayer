import Foundation
import Darwin

enum LiveASRExport {
    /// Background, user-selected SRT only. Own temporary inode and directory FD;
    /// refuses FIFO/device/symlink/current media, then POSIX rename within that
    /// directory. No claim of a transaction over other preference stores.
    static func write(_ bytes: Data, to destination: URL, source: URL, proof: LiveASRSourceProof,
                      protectedMediaFingerprint: LiveASRFileFingerprint? = nil) throws {
        guard bytes.count <= 2_097_152, destination.isFileURL, destination.path.hasPrefix("/"),
              destination.pathExtension.lowercased() == "srt", destination.user == nil, destination.password == nil,
              destination.query == nil, destination.fragment == nil,
              destination.host == nil || destination.host == "" || destination.host == "localhost" else {
            throw LiveASRFailure("请选择本地 SRT 文件，导出内容不能超过上限")
        }
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let target = parent.appendingPathComponent(destination.lastPathComponent)
        let original = source.resolvingSymlinksInPath().standardizedFileURL
        func identityText(_ url: URL) -> String { url.path.precomposedStringWithCanonicalMapping.lowercased() }
        let audioSource = proof.canonicalSourceURL.resolvingSymlinksInPath().standardizedFileURL
        guard identityText(target) != identityText(original), identityText(target) != identityText(audioSource),
              !destination.lastPathComponent.contains("\0") else {
            throw LiveASRFailure("不能用字幕覆盖原媒体")
        }
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw LiveASRFailure("无法打开字幕导出目录") }
        defer { close(directory) }
        let existing = openat(directory, destination.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if existing >= 0 {
            defer { close(existing) }
            var info = stat()
            guard fstat(existing, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  !(UInt64(UInt32(truncatingIfNeeded: info.st_dev)) == proof.device && UInt64(info.st_ino) == proof.inode),
                  !(protectedMediaFingerprint.map {
                      UInt64(UInt32(truncatingIfNeeded: info.st_dev)) == $0.device && UInt64(info.st_ino) == $0.inode
                  } ?? false) else {
                throw LiveASRFailure("导出目标不是普通文件，或仍是原媒体的文件身份")
            }
        } else if errno != ENOENT { throw LiveASRFailure("无法安全检查字幕导出目标") }
        let temporary = ".siliconplayer-asr-" + UUID().uuidString + ".tmp"
        let fd = openat(directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw LiveASRFailure("无法创建字幕导出临时文件") }
        var renamed = false
        defer { close(fd); if !renamed { _ = unlinkat(directory, temporary, 0) } }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw LiveASRFailure("字幕写入未完成") }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw LiveASRFailure("字幕写入同步失败") }
        var verified = Data(count: bytes.count)
        try verified.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let count = pread(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw LiveASRFailure("字幕临时文件重读失败") }
                offset += count
            }
        }
        guard verified == bytes, renameat(directory, temporary, directory, destination.lastPathComponent) == 0 else {
            throw LiveASRFailure("字幕最终发布失败")
        }
        renamed = true
    }
}
