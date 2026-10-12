import AppKit

/// MainActor owns every color lease before view init can mutate a Core. A
/// failed init has no view, but remains a real retryable owned registry entry.
/// This registry is bounded; it never discards a failed resource to make room.
@MainActor
enum MetalRenderOwnership {
    private static var accepting = true
    private static var leases: [UUID: MetalOutputLease] = [:]
    private static var hosts: [UUID: MPVVideoHost] = [:]
    private static let capacity = 64
    static var acceptsNewWork: Bool { accepting }
    static var hasOwnedResources: Bool { !leases.isEmpty || !hosts.isEmpty }
    static var terminationConfirmed: Bool { !accepting && !hasOwnedResources }

    static func prepareForCreation(player: PlayerModel) -> Bool {
        guard accepting else { return false }
        for (id, lease) in Array(leases) where lease.owns(player) {
            if let host = hosts[id] {
                guard host.closeRenderer() else { return false }
            } else {
                guard release(lease) else { return false }
            }
        }
        return !leases.values.contains { $0.owns(player) }
    }
    static func reserve(player: PlayerModel, request: MetalOutputRequest) throws -> MetalOutputLease {
        guard accepting, prepareForCreation(player: player), leases.count < capacity else {
            throw MetalViewCreationError(message: "视频输出仍有未释放的设置或渲染上下文", canFallbackToGL: false)
        }
        let lease = MetalOutputLease(player: player, request: request)
        leases[lease.identity] = lease // Before the first mutation / init throw.
        return lease
    }
    static func attach(host: MPVVideoHost, leaseID: UUID) -> Bool {
        guard leases[leaseID] != nil, hosts[leaseID] == nil else { return false }
        hosts[leaseID] = host // Keep an already-created resource even if closing.
        return accepting // Caller then really closes/retires, never drops owner.
    }
    @discardableResult static func release(_ lease: MetalOutputLease) -> Bool {
        guard leases[lease.identity] === lease else { return false }
        guard lease.restore() else { return false }
        // Removal requires exact actual restore or same-Core SHUTDOWN receipt.
        leases.removeValue(forKey: lease.identity)
        hosts.removeValue(forKey: lease.identity)
        return true
    }
    /// Must run after dirty-document approval and before any cleanup await.
    static func beginTermination() { accepting = false }

    static func shutdownForTermination(timeout: TimeInterval) async -> Bool {
        guard !accepting, timeout.isFinite, timeout >= 0, timeout <= 10 else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            // Snapshot exact entries; closeRenderer removes only its lease id.
            // An active context must be released before its color is restored.
            for (_, host) in Array(hosts) { _ = host.closeRenderer() }
            for (id, lease) in Array(leases) where hosts[id] == nil { _ = release(lease) }
            if terminationConfirmed { return true }
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            do { try await Task.sleep(nanoseconds: 25_000_000) }
            catch { return false } // Exact unreleased ownership remains stored.
        } while !accepting
        return false
    }
    /// Restores creation acceptance only. Existing failed owners stay retained;
    /// prepareForCreation still requires their real retirement before reuse.
    static func resumeAfterCancelledTermination() { accepting = true }
    static var diagnostics: [String: Any] {
        ["accepting": accepting, "leaseCount": leases.count, "hostCount": hosts.count,
         "capacity": capacity, "terminationConfirmed": terminationConfirmed,
         "leases": leases.keys.sorted { $0.uuidString < $1.uuidString }.map { id in
             ["id": id.uuidString, "rendererAttached": hosts[id] != nil,
              "actualColor": leases[id]?.diagnostics ?? [:]] as [String: Any]
         }]
    }
}
