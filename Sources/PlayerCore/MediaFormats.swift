import Foundation

public enum MediaFormats {
    public static let mediaExtensions: Set<String> = [
        "mp4", "mkv", "avi", "mov", "m4v", "webm", "ts", "m2ts", "mts",
        "mpg", "mpeg", "vob", "flv", "wmv", "asf", "ogv", "3gp", "3g2",
        "mxf", "rm", "rmvb", "divx", "f4v", "mp3", "flac", "wav", "aac",
        "m4a", "alac", "opus", "aiff", "aif", "ape", "dff", "dsf", "ac3",
        "eac3", "wma", "ogg", "mka"
    ]

    public static let subtitleExtensions: Set<String> = [
        "srt", "ass", "ssa", "vtt", "sub", "idx", "sup", "lrc", "smi", "sami", "mks"
    ]

    public static func isSubtitle(_ url: URL) -> Bool {
        subtitleExtensions.contains(url.pathExtension.lowercased())
    }

    /// Directory scans use the media extension list. Explicit files and network
    /// URLs are passed through so the playback engine can recognize other formats.
    public static func expand(_ urls: [URL]) -> [URL] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isHiddenKey]
        var result: [URL] = []
        var known: Set<URL> = []

        func append(_ url: URL) {
            let normalized = MediaItem.normalized(url)
            if !isSubtitle(normalized), known.insert(normalized).inserted {
                result.append(normalized)
            }
        }

        for input in urls {
            let url = MediaItem.normalized(input)
            guard url.isFileURL,
                  let values = try? url.resourceValues(forKeys: keys) else {
                append(url)
                continue
            }
            if values.isSymbolicLink == true {
                var targetIsDirectory = ObjCBool(false)
                if manager.fileExists(atPath: url.path, isDirectory: &targetIsDirectory), targetIsDirectory.boolValue {
                    continue
                }
            }
            guard values.isDirectory == true else {
                append(url)
                continue
            }
            // Never traverse a symlink supplied as the directory root either.
            guard values.isSymbolicLink != true, values.isHidden != true else { continue }
            guard let enumerator = manager.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            var directoryFiles: [URL] = []
            for case let child as URL in enumerator {
                guard let childValues = try? child.resourceValues(forKeys: keys) else { continue }
                if childValues.isSymbolicLink == true || childValues.isHidden == true {
                    // Foundation does not descend through symbolic links. Calling
                    // skipDescendants on a non-directory can skip the next folder.
                    if childValues.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                if childValues.isRegularFile == true,
                   mediaExtensions.contains(child.pathExtension.lowercased()) {
                    directoryFiles.append(child)
                }
            }
            directoryFiles.sort {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            directoryFiles.forEach(append)
        }
        return result
    }
}
