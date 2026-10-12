import Foundation
import Darwin
import PlayerCore
@main struct NamespaceChecks {
    static func main() throws {
        setbuf(stdout, nil)
        let url = URL(string: "https://example.com/dav/")!
        let document = """
        <d:multistatus xmlns:d="DAV:" xmlns:x="urn:foreign">
        <d:response><d:href>中文%20视频.mp4</d:href><d:propstat>
          <d:prop><d:resourcetype/><d:displayname>中文视频</d:displayname><d:getcontentlength>42</d:getcontentlength></d:prop>
          <x:prop><d:resourcetype><d:collection/></d:resourcetype><d:displayname>坏名字</d:displayname><d:getcontentlength>999</d:getcontentlength></x:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat></d:response>
        </d:multistatus>
        """
        let listing = try WebDAVDocumentParser.parse(Data(document.utf8), baseURL: url)
        precondition(listing.resources.count == 1)
        precondition(listing.resources[0].url.path == "/dav/中文 视频.mp4")
        precondition(listing.resources[0].name == "中文视频" && listing.resources[0].size == 42 && !listing.resources[0].isCollection)
        let hls = "#EXTM3U\n#EXT-X-TARGETDURATION:6\nsegment.ts\n"
        do { _ = try ChannelDocument.parse(hls, baseURL: url); preconditionFailure("parsed HLS as channel list") }
        catch ChannelDocumentError.streamingManifest {}
        print("PASS prefixed DAV namespace, foreign property container, raw Chinese href, HLS guard")
    }
}
