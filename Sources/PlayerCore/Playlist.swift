import Foundation

public struct Playlist {
    public private(set) var items: [MediaItem] = []
    public private(set) var currentIndex: Int?

    public var currentItem: MediaItem? {
        guard let index = currentIndex, items.indices.contains(index) else { return nil }
        return items[index]
    }

    public init() {}

    public mutating func add(_ urls: [URL]) {
        var known = Set(items.map(\.url))
        for url in urls {
            let normalized = MediaItem.normalized(url)
            if known.insert(normalized).inserted {
                items.append(MediaItem(url: normalized))
            }
        }
        if currentIndex == nil, !items.isEmpty { currentIndex = 0 }
    }

    /// Merge stored items without changing an existing URL's playback identity.
    public mutating func add(items incoming: [MediaItem]) {
        for item in incoming {
            if let index = items.firstIndex(where: { $0.url == item.url }) {
                if let selection = item.webMedia,
                   let replacement = try? MediaItem(webPageURL: item.url, selection: selection, id: items[index].id) {
                    items[index] = replacement
                }
            } else if !items.contains(where: { $0.id == item.id }) {
                items.append(item)
            }
        }
        if currentIndex == nil, !items.isEmpty { currentIndex = 0 }
    }

    @discardableResult
    public mutating func upsertWebMedia(pageURL: URL, selection: WebMediaSelection) throws -> MediaItem {
        let pageURL = try WebMediaDocument.validatedPageURL(pageURL)
        let id = items.first(where: { $0.url == pageURL })?.id ?? UUID()
        let item = try MediaItem(webPageURL: pageURL, selection: selection, id: id)
        add(items: [item])
        return item
    }

    @discardableResult
    public mutating func select(id: UUID) -> MediaItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        currentIndex = index
        return items[index]
    }

    @discardableResult
    public mutating func next(wrap: Bool = true) -> MediaItem? {
        guard !items.isEmpty else { return nil }
        let nextIndex = (currentIndex ?? -1) + 1
        guard nextIndex < items.count || wrap else { return nil }
        currentIndex = nextIndex < items.count ? nextIndex : 0
        return currentItem
    }

    @discardableResult
    public mutating func previous(wrap: Bool = true) -> MediaItem? {
        guard !items.isEmpty else { return nil }
        let previousIndex = (currentIndex ?? items.count) - 1
        guard previousIndex >= 0 || wrap else { return nil }
        currentIndex = previousIndex >= 0 ? previousIndex : items.count - 1
        return currentItem
    }

    public mutating func remove(id: UUID) {
        remove(ids: [id])
    }

    /// Removes a batch once, keeping the current media's identity when it survives.
    /// If it is removed, prefer its next surviving successor, then its predecessor.
    @discardableResult
    public mutating func remove(ids: Set<UUID>) -> Int {
        let oldItems = items
        let selected = currentItem?.id
        let oldIndex = currentIndex
        items.removeAll { ids.contains($0.id) }
        let removed = oldItems.count - items.count
        guard removed > 0 else { return 0 }
        let replacement: UUID?
        if let selected, !ids.contains(selected) {
            replacement = selected
        } else if let oldIndex {
            replacement = oldItems.dropFirst(oldIndex + 1).first { !ids.contains($0.id) }?.id
                ?? oldItems.prefix(oldIndex).last { !ids.contains($0.id) }?.id
        } else {
            replacement = nil
        }
        currentIndex = replacement.flatMap { id in items.firstIndex { $0.id == id } }
        return removed
    }

    public mutating func shuffle() {
        let selected = currentItem?.id
        items.shuffle()
        currentIndex = selected.flatMap { id in items.firstIndex { $0.id == id } }
    }
    public mutating func sortByTitle() {
        let selected = currentItem?.id
        items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        currentIndex = selected.flatMap { id in items.firstIndex { $0.id == id } }
    }
    public mutating func move(id: UUID, to destination: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let selected = currentItem?.id
        let item = items.remove(at: index)
        items.insert(item, at: min(items.count, max(0, destination)))
        currentIndex = selected.flatMap { id in items.firstIndex { $0.id == id } }
    }

    /// The insertion boundary belongs to the queue before removing the moving rows.
    /// Moving rows retain queue order, independently of selection or provider order.
    @discardableResult
    public mutating func move(ids: Set<UUID>, toInsertionIndex destination: Int) -> Bool {
        guard !ids.isEmpty, (0...items.count).contains(destination),
              ids.isSubset(of: Set(items.map(\.id))) else { return false }
        let selected = currentItem?.id
        let insertion = destination - items.prefix(destination).filter { ids.contains($0.id) }.count
        let moving = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        items.insert(contentsOf: moving, at: insertion)
        currentIndex = selected.flatMap { id in items.firstIndex { $0.id == id } }
        return true
    }

    @discardableResult
    public mutating func move(ids: Set<UUID>, to target: PlaylistMoveTarget) -> Bool {
        let destination: Int
        switch target {
        case .beginning: destination = 0
        case .end: destination = items.count
        case .before(let id), .after(let id):
            guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
            if case .after = target { destination = index + 1 } else { destination = index }
        }
        return move(ids: ids, toInsertionIndex: destination)
    }
}

/// Version 2 keeps stable item IDs and original-page preferences. Legacy
/// url/selectedIndex documents are decoded without fabricating old UUID history.
public struct PlaybackQueueDocument: Codable, Sendable {
    public let items: [MediaItem]
    public let selectedIndex: Int?
    public init(items: [MediaItem], selectedIndex: Int?) {
        self.items = items
        self.selectedIndex = selectedIndex.flatMap { items.indices.contains($0) ? $0 : nil }
    }
    private enum CodingKeys: String, CodingKey { case version, items, urls, selectedIndex }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let version = try values.decodeIfPresent(Int.self, forKey: .version), version != 2 { throw WebMediaError.invalidQueue }
        let selected = try values.decodeIfPresent(Int.self, forKey: .selectedIndex)
        let incoming: [MediaItem]
        if values.contains(.items) { incoming = try values.decode([MediaItem].self, forKey: .items) }
        else { incoming = try values.decode([URL].self, forKey: .urls).map { MediaItem(url: $0) } }
        guard incoming.count <= 10_000 else { throw WebMediaError.invalidQueue }
        var urls = Set<URL>(), ids = Set<UUID>(), kept: [MediaItem] = [], translatedIndex: Int?
        for (index, item) in incoming.enumerated() {
            let address = item.url.absoluteString
            guard item.url.user == nil, item.url.password == nil,
                  !WebMediaDocument.hasControls(address),
                  !(address.removingPercentEncoding.map(WebMediaDocument.hasControls) ?? true) else { continue }
            if urls.contains(item.url) {
                if index == selected { translatedIndex = kept.firstIndex(where: { $0.url == item.url }) }
                continue
            }
            guard ids.insert(item.id).inserted else { throw WebMediaError.invalidQueue }
            urls.insert(item.url)
            if index == selected { translatedIndex = kept.count }
            kept.append(item)
        }
        self.items = kept; self.selectedIndex = translatedIndex
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(2, forKey: .version)
        try values.encode(items, forKey: .items)
        // Older releases decode URLs only. Mirror original identities for
        // rollback; current releases always treat the items as authoritative.
        try values.encode(items.map(\.url), forKey: .urls)
        try values.encodeIfPresent(selectedIndex, forKey: .selectedIndex)
    }
}

public enum PlaylistMoveTarget: Equatable {
    case beginning
    case end
    case before(UUID)
    case after(UUID)

    /// A filtered table's bottom boundary means after its last visible media,
    /// preserving hidden rows beyond it. Other boundaries are UUID anchors.
    public static func visibleInsertion(ids: [UUID], row: Int) -> Self? {
        guard !ids.isEmpty, Set(ids).count == ids.count, (0...ids.count).contains(row) else { return nil }
        return row < ids.count ? .before(ids[row]) : .after(ids[ids.count - 1])
    }
}
