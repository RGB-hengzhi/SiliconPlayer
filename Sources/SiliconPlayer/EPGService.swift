import AppKit
import Combine
import Foundation
#if canImport(PlayerCore)
import PlayerCore
#endif
import Darwin

struct EPGScheduledProgramme {
    let programme: EPGProgramme
    let end: Date?
    let endWasInferred: Bool
}

/// Uses original M3U media URLs/tvg-id and the source transport of this session.
@MainActor
final class EPGService: ObservableObject {
    private final class WeakService { weak var value: EPGService?; init(_ value: EPGService) { self.value = value } }
    private static var registry: [UUID: WeakService] = [:]
    private let registryID = UUID()
    static var hasActiveJobs: Bool { registry.values.contains { $0.value?.hasOwnedJobs == true } }
    /// Returns false on deadline; the caller must not report completed cleanup.
    @discardableResult
    static func shutdownAll(timeout: TimeInterval = 2) async -> Bool {
        let services = registry.values.compactMap(\.value)
        for service in services { service.dismiss() }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while services.contains(where: \.hasOwnedJobs) {
            if Date() >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        registry = registry.filter { $0.value.value != nil }
        return true
    }
    @Published var address = ""
    @Published private(set) var isBusy = false
    @Published private(set) var status = "主动读取 XMLTV 节目单后查看节目。"
    @Published private(set) var error: String?
    @Published private(set) var document: XMLTVDocument?
    @Published private(set) var committedSource: URL?
    @Published private(set) var channels: [EPGChannelReference]
    @Published private(set) var mapping = EPGChannelMapping()
    @Published private(set) var logoEnabled = false
    @Published private(set) var logoRequestEpoch = UUID()
    @Published private(set) var logoRevision = 0
    @Published private(set) var logoPending = 0
    @Published private(set) var logoNotice: String?
    @Published private(set) var logoRequestsAuthorized = false

    private var transport: any EPGSourceTransport
    private let logoCache: EPGLogoCache
    private let limits: XMLTVLimits
    private let preferences: EPGPreferencesStore?
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?
    private var parseTask: Task<XMLTVDocument, Error>?
    private var ownedLoads: [UUID: Task<Void, Never>] = [:]
    private var ownedLogos: [UUID: Task<EPGLogoThumbnail, Error>] = [:]
    private var hasOwnedJobs: Bool { !ownedLoads.isEmpty || !ownedLogos.isEmpty }
    private let maximumMemoryBytes = 4 * 1024 * 1024
    private let maximumMemoryEntries = 64
    private let maximumLogoFlights = 32
    private var memory: [String: MemoryEntry] = [:]
    private var memoryClock: UInt64 = 0
    private struct MemoryEntry { let image: NSImage; let cost: Int; var accessed: UInt64 }
    private struct Flight {
        let id: UUID
        let epoch: UUID
        let task: Task<EPGLogoThumbnail, Error>
        var consumers: Set<UUID>
    }
    private var flights: [String: Flight] = [:]
    private var refreshLogos = false
    private var refreshedLogoKeys = Set<String>()

    init(channels: [EPGChannelReference], transport: any EPGSourceTransport,
         logoCache: EPGLogoCache, limits: XMLTVLimits = .init(), preferences: EPGPreferencesStore? = nil) {
        self.channels = Self.uniqueChannels(channels)
        self.transport = transport; self.logoCache = logoCache; self.limits = limits; self.preferences = preferences
        if channels.count > 10_000 { self.error = "频道列表超过 10,000 条，未载入频道。" }
        if let preferences {
            do {
                let restored = try preferences.load()
                address = restored.sourceAddress ?? ""; mapping = EPGChannelMapping(explicitOverrides: restored.manualMappings)
                logoEnabled = restored.logosEnabled
            } catch { self.error = "节目单偏好未能恢复，仍使用当前设置。" }
        }
        // Restoring a checked logo preference never authorizes a network request.
        Self.registry = Self.registry.filter { $0.value.value != nil }
        Self.registry[registryID] = WeakService(self)
    }

    func setChannels(_ values: [EPGChannelReference]) {
        guard values.count <= 10_000 else { error = "频道列表超过 10,000 条，保留此前频道。"; return }
        let candidate = Self.uniqueChannels(values)
        guard candidate != channels else { return }
        channels = candidate
        invalidateLogoRequests(clearMemory: true)
    }
    private static func uniqueChannels(_ values: [EPGChannelReference]) -> [EPGChannelReference] {
        var seen = Set<String>()
        // Model limits also bound untrusted channel-list scale at the UI adapter.
        guard values.count <= 10_000 else { return [] }
        return values.filter { seen.insert($0.stableKey).inserted }
    }
    func setMapping(_ channel: EPGChannelReference, channelID: String?) {
        guard channels.contains(where: { $0.stableKey == channel.stableKey }) else { return }
        var candidate = mapping
        if let channelID {
            guard document?.channelIDs.contains(channelID) == true else { return }
            candidate.explicitOverrides[channel.stableKey] = channelID
        } else { candidate.explicitOverrides.removeValue(forKey: channel.stableKey) }
        do { try savePreferences(mappings: candidate.explicitOverrides) }
        catch { self.error = "频道匹配未能保存，仍保留原设置。"; return }
        mapping = candidate
        invalidateLogoRequests(clearMemory: false)
    }
    func mappingResult(_ channel: EPGChannelReference) -> EPGMappingResult {
        guard let document else { return .unmapped }
        return mapping.resolve(channel, document: document)
    }
    func mappedID(_ channel: EPGChannelReference) -> String? {
        if case .matched(let id, _) = mappingResult(channel) { return id }
        return nil
    }
    func daySchedule(_ channel: EPGChannelReference, on day: Date, calendar: Calendar = .current) -> [EPGScheduledProgramme] {
        guard let id = mappedID(channel), let values = document?.programmes[id],
              let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        var result: [EPGScheduledProgramme] = []
        var groupStart: Date?, nextStart: Date?
        for programme in values.reversed() {
            if groupStart != programme.start { nextStart = groupStart; groupStart = programme.start }
            let end = programme.explicitEnd ?? nextStart
            let intersects = end.map { $0 > interval.start } ?? (programme.start >= interval.start)
            if programme.start < interval.end, intersects {
                result.append(EPGScheduledProgramme(programme: programme, end: end,
                                                   endWasInferred: programme.explicitEnd == nil && end != nil))
            }
        }
        return result.reversed()
    }
    func nowAndNext(_ channel: EPGChannelReference, at date: Date) -> EPGNowNext? {
        guard let id = mappedID(channel) else { return nil }
        return document?.nowAndNext(channelID: id, at: date)
    }

    /// Editing the draft source cancels its outstanding load. The committed
    /// source remains explicit in the view and never masquerades as this draft.
    func addressEdited() {
        guard isBusy else { return }
        cancelLoad(message: document == nil ? "已取消读取。" : "地址已更改，仍显示原节目单。")
    }
    func loadRemote() {
        do {
            let url = try EPGAddress.validated(address)
            startLoad(source: url) { [transport] in try await transport.document(at: url) }
        } catch {
            cancelLoad(message: document == nil ? "尚未读取节目单。" : "读取未开始，仍显示原节目单。")
            self.error = Self.message(error)
        }
    }
    func loadLocal(_ url: URL) {
        guard url.isFileURL else { error = "请选择本机 XMLTV 文件。"; return }
        let maximumBytes = limits.maximumBytes
        startLoad(source: url.standardizedFileURL) {
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                // Reject FIFO/device/directory before any potentially blocking
                // read; regular-file input is read in small bounded chunks.
                let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { throw EPGServiceError.invalidAddress }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var information = stat()
                guard fstat(descriptor, &information) == 0, information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw XMLTVError.malformedXML(0) }
                guard maximumBytes > 0, maximumBytes < Int.max else { throw XMLTVError.invalidLimits }
                var data = Data()
                while data.count <= maximumBytes {
                    try Task.checkCancellation()
                    let chunk = try handle.read(upToCount: min(64 * 1024, maximumBytes + 1 - data.count)) ?? Data()
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }
                try Task.checkCancellation()
                guard data.count <= maximumBytes else { throw XMLTVError.tooLarge }
                return EPGHTTPPayload(data: data, finalURL: url.standardizedFileURL)
            }
            return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        }
    }
    private func startLoad(source: URL, fetch: @escaping @Sendable () async throws -> EPGHTTPPayload) {
        cancelLoad(message: "")
        guard ownedLoads.count < 16 else { error = "此前请求仍在收尾，请稍后重试。"; return }
        let request = UUID(); generation = request
        isBusy = true; error = nil; status = "正在读取节目单…"
        let parserLimits = limits
        loadTask = Task { [weak self] in
            defer { self?.ownedLoads.removeValue(forKey: request) }
            do {
                let payload = try await fetch()
                try Task.checkCancellation()
                guard let self, self.generation == request else { return }
                guard payload.data.count <= parserLimits.maximumBytes else { throw XMLTVError.tooLarge }
                self.status = "正在解析节目单…"
                let worker = Task.detached(priority: .utility) {
                    try XMLTVDocument.parse(payload.data, sourceURL: payload.finalURL, limits: parserLimits,
                                            isCancelled: { Task.isCancelled })
                }
                self.parseTask = worker
                let candidate = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard self.generation == request else { return }
                let sourceSaved = try self.savePreferences(source: source.absoluteString)
                // Both data and source are replaced together only after success.
                self.document = candidate; self.committedSource = source
                self.logoRequestsAuthorized = self.logoEnabled
                self.isBusy = false; self.parseTask = nil; self.loadTask = nil
                self.invalidateLogoRequests(clearMemory: true)
                self.status = "已读取 \(candidate.channelIDs.count) 个频道、\(candidate.programmes.values.reduce(0) { $0 + $1.count }) 条节目。"
                if !sourceSaved { self.status += " 本次来源含认证参数，地址未保存。" }
            } catch {
                guard let self, self.generation == request else { return }
                self.isBusy = false; self.parseTask = nil; self.loadTask = nil
                if error is CancellationError || (error as? XMLTVError) == .cancelled {
                    self.status = self.document == nil ? "已取消读取。" : "已取消，保留原节目单。"
                } else {
                    self.error = Self.message(error)
                    self.status = self.document == nil ? "节目单未能读取。" : "读取失败，仍显示原节目单。"
                }
            }
        }
        if let loadTask { ownedLoads[request] = loadTask }
    }
    private func cancelLoad(message: String) {
        generation = UUID(); loadTask?.cancel(); parseTask?.cancel()
        for task in ownedLoads.values { task.cancel() }
        loadTask = nil; parseTask = nil; isBusy = false; error = nil
        if !message.isEmpty { status = message }
    }
    func cancel() {
        cancelLoad(message: document == nil ? "已取消读取。" : "已取消，保留原节目单。")
        invalidateLogoRequests(clearMemory: false)
    }
    func setSourceTransport(_ transport: any EPGSourceTransport) { cancel(); self.transport = transport }
    func dismiss() { cancel(); transport = transport.clearingCredentials() }
    private static func message(_ error: Error) -> String {
        // Network errors never reveal the raw source/query or credentials.
        if let error = error as? XMLTVError { return error.localizedDescription }
        if let error = error as? EPGServiceError { return error.localizedDescription }
        if let error = error as? EPGPreferencesError { return error.localizedDescription }
        return "节目单请求失败，请检查地址、权限或网络后重试。"
    }

    func setLogoEnabled(_ enabled: Bool) {
        guard logoEnabled != enabled else { return }
        do { try savePreferences(logosEnabled: enabled) }
        catch { self.error = "台标偏好未能保存，仍保留原设置。"; return }
        logoEnabled = enabled; refreshLogos = false
        logoRequestsAuthorized = enabled
        invalidateLogoRequests(clearMemory: !enabled)
    }
    func refreshVisibleLogos() {
        guard logoEnabled else { return }
        logoRequestsAuthorized = true
        refreshLogos = true
        invalidateLogoRequests(clearMemory: false)
    }
    private func invalidateLogoRequests(clearMemory: Bool) {
        for flight in flights.values { flight.task.cancel() }
        for task in ownedLogos.values { task.cancel() }
        flights.removeAll(); logoPending = 0; logoRequestEpoch = UUID(); logoNotice = nil
        refreshedLogoKeys.removeAll()
        if clearMemory { memory.removeAll(); logoRevision += 1 }
    }
    func logoURL(_ channel: EPGChannelReference) -> URL? {
        let mapped = mappedID(channel).flatMap { document?.channels[$0]?.logoURL }
        for candidate in [channel.logoURL, mapped].compactMap({ $0 }) {
            if let clean = try? EPGAddress.validated(candidate.absoluteString) { return clean }
        }
        return nil
    }
    func logoImage(_ channel: EPGChannelReference) -> NSImage? {
        guard logoEnabled, let key = logoURL(channel)?.absoluteString, var value = memory[key] else { return nil }
        memoryClock &+= 1; value.accessed = memoryClock; memory[key] = value
        return value.image
    }
    func requestLogo(_ channel: EPGChannelReference) async {
        guard logoEnabled, logoRequestsAuthorized, !Task.isCancelled, let url = logoURL(channel) else { return }
        let key = url.absoluteString
        if memory[key] != nil, !refreshLogos || refreshedLogoKeys.contains(key) { return }
        let epoch = logoRequestEpoch, consumer = UUID()
        let flight: Flight
        if var existing = flights[key], existing.epoch == epoch {
            existing.consumers.insert(consumer); flights[key] = existing; flight = existing
        } else {
            guard flights.count < maximumLogoFlights else { logoNotice = "可见台标较多，稍后滚动或刷新重试。"; return }
            let cache = logoCache, refresh = refreshLogos && !refreshedLogoKeys.contains(key)
            let flightID = UUID()
            let task = Task { [weak self] in
                defer { self?.ownedLogos.removeValue(forKey: flightID) }
                return try await cache.thumbnail(at: url, refresh: refresh)
            }
            ownedLogos[flightID] = task
            flight = Flight(id: flightID, epoch: epoch, task: task, consumers: [consumer])
            flights[key] = flight; logoPending = flights.count
        }
        defer { releaseConsumer(key: key, flightID: flight.id, consumer: consumer) }
        do {
            let thumbnail = try await withTaskCancellationHandler { try await flight.task.value } onCancel: {
                Task { @MainActor [weak self] in self?.releaseConsumer(key: key, flightID: flight.id, consumer: consumer) }
            }
            try Task.checkCancellation()
            guard logoEnabled, logoRequestEpoch == epoch else { return }
            refreshedLogoKeys.insert(key)
            if memory[key] == nil || refreshLogos {
                guard let image = NSImage(data: thumbnail.png) else { throw EPGServiceError.invalidImage }
                putImage(image, cost: thumbnail.memoryCost, key: key)
            }
            if thumbnail.usedPreviousCache { logoNotice = "部分台标更新失败，保留此前缓存图片。" }
        } catch {
            guard !Task.isCancelled, logoRequestEpoch == epoch else { return }
            refreshedLogoKeys.insert(key)
            if !(error is CancellationError) { logoNotice = "部分台标未能读取，频道仍可播放。" }
        }
    }
    private func releaseConsumer(key: String, flightID: UUID, consumer: UUID) {
        guard var flight = flights[key], flight.id == flightID else { return }
        flight.consumers.remove(consumer)
        if flight.consumers.isEmpty { flight.task.cancel(); flights.removeValue(forKey: key) }
        else { flights[key] = flight }
        logoPending = flights.count
    }
    private func putImage(_ image: NSImage, cost: Int, key: String) {
        guard cost <= maximumMemoryBytes else { return }
        memoryClock &+= 1
        memory[key] = MemoryEntry(image: image, cost: cost, accessed: memoryClock)
        var total = memory.values.reduce(0) { $0 + $1.cost }
        while total > maximumMemoryBytes || memory.count > maximumMemoryEntries {
            guard let victim = memory.min(by: { $0.value.accessed < $1.value.accessed }) else { break }
            total -= victim.value.cost; memory.removeValue(forKey: victim.key)
        }
        logoRevision += 1
    }
    // Exact accounting is exposed for bounded-cache tests, not product UI.
    var memoryImageCount: Int { memory.count }
    var memoryImageBytes: Int { memory.values.reduce(0) { $0 + $1.cost } }
    @discardableResult
    private func savePreferences(source: String? = nil, mappings: [String: String]? = nil, logosEnabled: Bool? = nil) throws -> Bool {
        guard let preferences else { return true }
        var candidate = preferences.value
        var sourceSaved = true
        if let source, let url = URL(string: source) {
            sourceSaved = EPGPreferences.sourceMayBePersisted(url)
            if sourceSaved { candidate.sourceAddress = source }
        }
        if let mappings { candidate.manualMappings = mappings }
        if let logosEnabled { candidate.logosEnabled = logosEnabled }
        if candidate != preferences.value { try preferences.save(candidate) }
        return sourceSaved
    }
}
