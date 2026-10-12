/// Generation guards for asynchronous system-window callbacks. No AppKit or
/// runtime availability is inferred by this model.
public struct SystemPiPLifecycle: Sendable {
    public enum State: String, Sendable { case idle, entering, active, exiting, disabled }
    public private(set) var state: State = .idle
    public private(set) var generation: UInt64?
    public private(set) var terminal = false
    private var serial: UInt64 = 0
    public init() {}
    public mutating func beginEnter() -> UInt64? {
        guard state == .idle, !terminal else { return nil }
        serial &+= 1; generation = serial; state = .entering; return serial
    }
    public mutating func observeStart(_ ticket: UInt64) -> Bool {
        guard generation == ticket, state == .entering else { return false }
        state = .active; return true
    }
    public mutating func beginExit() -> Bool {
        guard state == .entering || state == .active else { return false }
        state = .exiting; return true
    }
    public mutating func close(_ ticket: UInt64) -> Bool {
        guard generation == ticket else { return false }
        generation = nil; state = .idle; return true
    }
    public mutating func disable() { generation = nil; state = .disabled }
    public mutating func cancelForTeardown() { generation = nil; state = .idle }
    public mutating func resetRegistration() -> Bool {
        guard generation == nil, !terminal else { return false }
        state = .idle; return true
    }
    public mutating func beginShutdown() { terminal = true; _ = beginExit() }
    public mutating func cancelShutdownIfSafe() -> Bool {
        guard generation == nil else { return false }
        terminal = false; return true // Preserve serial; old callbacks stay old.
    }
}
