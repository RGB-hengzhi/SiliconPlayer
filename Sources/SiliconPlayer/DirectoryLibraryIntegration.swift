import Foundation
import PlayerCore

@MainActor
extension PlayerModel {
    /// Only an explicit Add button uses this entry. Unlike open(append: true),
    /// this never calls load/Play even when no file is loaded.
    func appendDirectoryLibraryFiles(_ urls: [URL]) {
        guard !profileRecoveryBlocked, !urls.isEmpty, urls.count <= 200,
              urls.allSatisfy({ $0.isFileURL && MediaFormats.mediaExtensions.contains($0.pathExtension.lowercased()) }) else {
            toast("目录加入请求不可用；一次最多 200 个本机媒体。"); return
        }
        playlist = DirectoryLibraryQueueAppend.applying(urls, to: playlist)
        persistQueue(); toast("已加入列表；当前播放不变。")
    }
}
