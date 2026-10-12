import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

struct EPGLogoThumbnail: Sendable {
    let png: Data
    let width: Int
    let height: Int
    let usedPreviousCache: Bool
    var memoryCost: Int { png.count + width * height * 4 }
}

protocol EPGLogoPublication: Sendable {
    /// A thrown error must leave an existing target unchanged.
    func publish(_ data: Data, to target: URL) throws
}

/// Cache files are disposable and live in the application's own APFS directory.
/// User-selected exports retain the separately audited publication path.
struct EPGAtomicCachePublication: EPGLogoPublication {
    func publish(_ data: Data, to target: URL) throws { try data.write(to: target, options: .atomic) }
}

struct EPGLogoCacheLimits: Sendable {
    var maximumDownloadBytes = 1024 * 1024
    var maximumSourcePixels = 4_194_304
    var maximumSourceDimension = 4096
    var maximumPNGBytes = 256 * 1024
    var maximumDiskBytes = 16 * 1024 * 1024
    var maximumDiskEntries = 256
    var maximumDimension = 128
    var valid: Bool {
        maximumDownloadBytes > 0 && maximumDownloadBytes <= 1024 * 1024
        && maximumSourcePixels > 0 && maximumSourceDimension > 0
        && maximumPNGBytes > 0 && maximumDiskBytes >= maximumPNGBytes
        && maximumDiskEntries > 0 && (1...128).contains(maximumDimension)
    }
}

enum EPGLogoCodec {
    static func normalize(_ data: Data, limits: EPGLogoCacheLimits, previous: Bool = false) throws -> EPGLogoThumbnail {
        try Task.checkCancellation()
        guard limits.valid else { throw EPGServiceError.cacheFailure }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source),
              UTType(type as String)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw EPGServiceError.invalidImage }
        guard width <= limits.maximumSourceDimension, height <= limits.maximumSourceDimension,
              width <= limits.maximumSourcePixels / height else { throw EPGServiceError.imageTooLarge }
        try Task.checkCancellation()
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: limits.maximumDimension,
                                     kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0,
              image.width <= limits.maximumDimension, image.height <= limits.maximumDimension else { throw EPGServiceError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw EPGServiceError.invalidImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= limits.maximumPNGBytes else { throw EPGServiceError.invalidImage }
        try Task.checkCancellation()
        return EPGLogoThumbnail(png: output as Data, width: image.width, height: image.height, usedPreviousCache: previous)
    }
}

actor EPGLogoCache {
    private let directory: URL
    private let transport: any EPGLogoTransport
    private let publication: any EPGLogoPublication
    private let limits: EPGLogoCacheLimits
    private let limiter = EPGAsyncLimiter(limit: 2, maximumWaiting: 32)
    init(directory: URL, transport: any EPGLogoTransport = AnonymousEPGLogoTransport(),
         publication: any EPGLogoPublication = EPGAtomicCachePublication(), limits: EPGLogoCacheLimits = .init()) {
        self.directory = directory.standardizedFileURL
        self.transport = transport; self.publication = publication; self.limits = limits
    }
    private func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func boundedRead(_ file: URL) throws -> Data {
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw EPGServiceError.cacheFailure }
        defer { Darwin.close(parent) }
        let descriptor = openat(parent, file.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw EPGServiceError.cacheFailure }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_size > 0, information.st_size <= limits.maximumPNGBytes else { throw EPGServiceError.cacheFailure }
        let data = try handle.read(upToCount: limits.maximumPNGBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= limits.maximumPNGBytes else { throw EPGServiceError.cacheFailure }
        return data
    }
    private func cached(_ file: URL) -> EPGLogoThumbnail? {
        guard let data = try? boundedRead(file) else { return nil }
        return try? EPGLogoCodec.normalize(data, limits: limits)
    }
    func thumbnail(at input: URL, refresh: Bool = false) async throws -> EPGLogoThumbnail {
        try Task.checkCancellation()
        guard limits.valid else { throw EPGServiceError.cacheFailure }
        let url = try EPGAddress.validated(input.absoluteString)
        let target = directory.appendingPathComponent(key(url) + ".png")
        let previous = cached(target)
        if !refresh, let previous {
            try Task.checkCancellation()
            // LRU maintenance must not follow a substituted link or block waiting
            // for another process. Cached pixels can still be returned on lock failure.
            try? withCacheLock {
                try reserve(bytes: boundedRead(target).count, for: target)
                if (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false {
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
                }
            }
            return previous
        }
        try await limiter.acquire()
        do {
            try Task.checkCancellation()
            let data = try await transport.logo(at: url, maximumBytes: limits.maximumDownloadBytes)
            guard data.count <= limits.maximumDownloadBytes else { throw EPGServiceError.tooLarge }
            let codecLimits = limits
            let worker = Task.detached(priority: .utility) { try EPGLogoCodec.normalize(data, limits: codecLimits) }
            let normalized = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            try withCacheLock {
                // Reserve before publication. The old target is never an eviction
                // candidate; a failed refresh leaves its bytes untouched.
                try reserve(bytes: normalized.png.count, for: target)
                if (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    throw EPGServiceError.cacheFailure
                }
                try Task.checkCancellation()
                try publication.publish(normalized.png, to: target)
            }
            await limiter.release()
            return normalized
        } catch {
            await limiter.release()
            if error is CancellationError { throw error }
            if let previous {
                return EPGLogoThumbnail(png: previous.png, width: previous.width, height: previous.height, usedPreviousCache: true)
            }
            throw error
        }
    }
    private func withCacheLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw EPGServiceError.cacheFailure }
        defer { Darwin.close(descriptor) }
        let lock = openat(descriptor, ".epg-cache-lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard lock >= 0 else { throw EPGServiceError.cacheFailure }
        defer { Darwin.close(lock) }
        var information = stat()
        guard fstat(lock, &information) == 0, information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw EPGServiceError.cacheFailure }
        defer { _ = flock(lock, LOCK_UN) }
        return try operation()
    }
    private func reserve(bytes candidateBytes: Int, for protected: URL) throws {
        guard candidateBytes <= limits.maximumDiskBytes else { throw EPGServiceError.cacheFailure }
        let values = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey, .isRegularFileKey])
        var files: [(URL, Int, Date)] = []
        for file in values where file != protected {
            guard file.lastPathComponent.range(of: #"^[0-9a-f]{64}\.png$"#, options: .regularExpression) != nil,
                  let info = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey, .isRegularFileKey]),
                  info.isSymbolicLink != true, info.isRegularFile == true, let bytes = info.fileSize, bytes >= 0 else { continue }
            files.append((file, bytes, info.contentModificationDate ?? .distantPast))
        }
        files.sort { $0.2 == $1.2 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.2 < $1.2 }
        var total = candidateBytes, count = 1
        for file in files {
            let result = total.addingReportingOverflow(file.1)
            guard !result.overflow else { throw EPGServiceError.cacheFailure }
            total = result.partialValue; count += 1
        }
        for file in files {
            guard total > limits.maximumDiskBytes || count > limits.maximumDiskEntries else { break }
            try FileManager.default.removeItem(at: file.0)
            total -= file.1; count -= 1
        }
        guard total <= limits.maximumDiskBytes, count <= limits.maximumDiskEntries else { throw EPGServiceError.cacheFailure }
    }
}
