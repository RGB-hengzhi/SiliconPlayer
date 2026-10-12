import Foundation

public struct MediaItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let webMedia: WebMediaSelection?

    public var title: String {
        webMedia?.title ?? (url.isFileURL ? url.lastPathComponent : url.absoluteString)
    }

    public init(url: URL, id: UUID = UUID()) {
        self.id = id
        self.url = Self.normalized(url)
        self.webMedia = nil
    }

    public init(webPageURL: URL, selection: WebMediaSelection, id: UUID = UUID()) throws {
        self.id = id
        self.url = try WebMediaDocument.validatedPageURL(webPageURL)
        self.webMedia = selection
    }

    private enum CodingKeys: String, CodingKey { case id, url, webMedia }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let url = try values.decode(URL.self, forKey: .url)
        let address = url.absoluteString
        guard url.user == nil, url.password == nil, !WebMediaDocument.hasControls(address),
              !(address.removingPercentEncoding.map(WebMediaDocument.hasControls) ?? true) else { throw WebMediaError.unsafeURL }
        if let webMedia = try values.decodeIfPresent(WebMediaSelection.self, forKey: .webMedia) {
            try self.init(webPageURL: url, selection: webMedia, id: id)
        } else {
            self.init(url: url, id: id)
        }
    }

    public static func normalized(_ url: URL) -> URL {
        url.isFileURL ? url.standardizedFileURL : url
    }
}
