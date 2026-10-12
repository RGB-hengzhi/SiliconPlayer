import Foundation
import CryptoKit

public struct EPGChannelReference: Equatable, Sendable {
    public let mediaURL: URL
    public let tvgID: String?
    public let displayName: String
    public let logoURL: URL?
    /// Exact original media identity plus XMLTV identity. Two aliases of one
    /// media URL with different tvg-id must not share a manual override.
    public let stableKey: String
    public init(mediaURL: URL, tvgID: String?, displayName: String, logoURL: URL? = nil) {
        self.mediaURL = mediaURL.isFileURL ? mediaURL.standardizedFileURL : mediaURL.absoluteURL
        self.tvgID = tvgID
        self.displayName = displayName
        self.logoURL = logoURL
        // Persistent mapping keys cannot expose authentication in media paths
        // or query strings. Compute once rather than hashing during row renders.
        let identity = self.mediaURL.absoluteString + "\u{0}" + (tvgID ?? "")
        self.stableKey = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum EPGMappingMethod: Equatable, Sendable { case tvgID, manual }
public enum EPGMappingResult: Equatable, Sendable {
    case matched(String, EPGMappingMethod)
    case unavailable(String)
    case unmapped
}

public struct EPGChannelMapping: Sendable {
    public var explicitOverrides: [String: String]
    public init(explicitOverrides: [String: String] = [:]) { self.explicitOverrides = explicitOverrides }
    public func resolve(_ channel: EPGChannelReference, document: XMLTVDocument) -> EPGMappingResult {
        if let id = explicitOverrides[channel.stableKey] {
            return document.channelIDs.contains(id) ? .matched(id, .manual) : .unavailable(id)
        }
        if let id = channel.tvgID, !id.isEmpty {
            return document.channelIDs.contains(id) ? .matched(id, .tvgID) : .unavailable(id)
        }
        return .unmapped
    }
}
