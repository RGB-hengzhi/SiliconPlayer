import Foundation

struct VideoConfigurationDrawableReceipt: Sendable {
    let ticket: UUID
    let rendererID: UUID
    let sequence: UInt64
    let status: Int32
    let width: Int
    let height: Int
    let updateFlags: UInt64
    let forced: Bool
    let completedAt: TimeInterval
}

/// Decode/update-frame progress remains distinct from completed drawable work.
/// Configuration receipts require their exact request ticket and real drawable.
final class RenderProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0
    private var renderAttempts: UInt64 = 0
    private var lastFlags: UInt64 = 0
    private var lastStatus: Int32 = 0
    private var lastForced = false
    private var lastUptime: TimeInterval = 0
    private var configuration: VideoConfigurationDrawableReceipt?
    var diagnosticsSnapshot: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["renderUpdateFrames": count, "successfulOrFailedDrawableCalls": renderAttempts,
                "lastUpdateFlags": lastFlags, "lastRenderStatus": lastStatus,
                "lastForcedRedraw": lastForced, "lastAttemptUptime": lastUptime,
                "configurationTicket": configuration?.ticket.uuidString ?? "",
                "configurationDrawableSequence": configuration?.sequence ?? 0]
    }
    func completedDrawable(status: Int32, flags: UInt64, forced: Bool, width: Int,
                           height: Int, rendererID: UUID, configurationTicket: UUID?) {
        lock.lock(); defer { lock.unlock() }
        guard renderAttempts < UInt64.max else { configuration = nil; return }
        renderAttempts += 1; lastFlags = flags; lastStatus = status; lastForced = forced
        lastUptime = ProcessInfo.processInfo.systemUptime
        if let ticket = configurationTicket {
            configuration = .init(ticket: ticket, rendererID: rendererID, sequence: renderAttempts, status: status,
                width: width, height: height, updateFlags: flags, forced: forced, completedAt: lastUptime)
        }
    }
    func configurationDrawable(ticket: UUID) -> VideoConfigurationDrawableReceipt? {
        lock.lock(); defer { lock.unlock() }
        guard configuration?.ticket == ticket else { return nil }; return configuration
    }
    func retireConfigurationDrawable(ticket: UUID) {
        lock.lock(); defer { lock.unlock() }
        if configuration?.ticket == ticket { configuration = nil }
    }
    var frames: UInt64 { lock.lock(); defer { lock.unlock() }; return count }
    func didRenderFrame() { lock.lock(); count &+= 1; lock.unlock() }
}
