import Foundation

/// Private queue drag data never carries paths or reopens media as a file drop.
public struct PlaylistDragPayload: Codable {
    public static let typeIdentifier = "local.siliconplayer.playlist-items"
    public static let maximumItems = 10_000
    public static let maximumBytes = 1_048_576
    public let version: Int
    public let sessionID: UUID
    public let itemIDs: [UUID]

    public init(sessionID: UUID, itemIDs: [UUID]) {
        version = 1
        self.sessionID = sessionID
        self.itemIDs = itemIDs
    }

    public func encoded() throws -> Data {
        guard !itemIDs.isEmpty, itemIDs.count <= Self.maximumItems,
              Set(itemIDs).count == itemIDs.count else { throw ValidationError.invalidItems }
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw ValidationError.tooLarge }
        return data
    }

    public static func validatedIDs(_ data: Data, sessionID: UUID, availableIDs: Set<UUID>) throws -> Set<UUID> {
        guard data.count <= maximumBytes else { throw ValidationError.tooLarge }
        let payload: Self
        do { payload = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ValidationError.invalidData }
        guard payload.version == 1, payload.sessionID == sessionID else { throw ValidationError.wrongSession }
        let ids = Set(payload.itemIDs)
        guard !ids.isEmpty, payload.itemIDs.count <= maximumItems,
              ids.count == payload.itemIDs.count else { throw ValidationError.invalidItems }
        guard ids.isSubset(of: availableIDs) else { throw ValidationError.staleItems }
        return ids
    }

    public enum ValidationError: LocalizedError {
        case invalidData, wrongSession, invalidItems, staleItems, tooLarge
        public var errorDescription: String? {
            switch self {
            case .invalidData: return "无法读取播放列表拖动数据。"
            case .wrongSession: return "该拖动来自其他播放列表或不支持的格式。"
            case .invalidItems: return "拖动数据包含空列表、重复项或过多项目。"
            case .staleItems: return "列表已发生变化，请重新拖动。"
            case .tooLarge: return "播放列表拖动数据过大。"
            }
        }
    }
}
