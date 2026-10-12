import Foundation
import PlayerCore

extension PlayerModel {
    private static var webPreferencesURL: URL {
        supportDirectory.appendingPathComponent("web-media-preferences.json")
    }

    func restoreWebMediaPreferences() {
        let url = Self.webPreferencesURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? Int.max
            guard size <= WebMediaCatalog.maximumBytes else { throw WebMediaError.tooLarge }
            webMediaCatalog = try WebMediaCatalog.boundedDecode(Data(contentsOf: url))
        } catch {
            toast("网页媒体偏好无法恢复，请重新解析网页")
        }
    }

    func rememberWebMediaPreference(pageURL: URL, selection: WebMediaSelection) {
        guard !profileStoresBlocked else { return }
        do {
            try webMediaCatalog.remember(pageURL: pageURL, selection: selection)
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(webMediaCatalog)
            guard data.count <= WebMediaCatalog.maximumBytes else { throw WebMediaError.tooLarge }
            try data.write(to: Self.webPreferencesURL, options: .atomic)
        } catch {
            toast("网页偏好未能保存；当前播放仍可继续")
        }
    }

    func knownWebMediaItem(for url: URL) -> MediaItem {
        if let selection = webMediaCatalog.selection(for: url),
           let item = try? MediaItem(webPageURL: url, selection: selection) { return item }
        return MediaItem(url: url)
    }
}
