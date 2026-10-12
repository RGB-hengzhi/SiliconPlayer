import AppKit

/// An explicit output request. Reference scRGB is also usable for numerical tests
/// on VirtualSDR; it never asserts physical HDR or measured display luminance.
enum MetalOutputRequest: Equatable {
    case sdr
    case scRGBReference(peakNits: Double)
}

@MainActor
final class MetalOutputLease {
    // The owned registry must keep this exact Core holder alive when a view
    // fails during init. A weak holder would discard restoration ownership.
    private let player: PlayerModel
    let identity = UUID()
    func owns(_ candidate: PlayerModel) -> Bool { player === candidate }
    private let request: MetalOutputRequest
    private let initialCore: OpaquePointer?
    private var lastBase: [String: String] = [:]
    private var uncertainMutation = false
    private var original: [String: String] = [:]
    private var installed: [String: String] = [:]
    private var active = false
    private(set) var firstError: String?
    private(set) var revision: UInt64 = 0
    private let keys = ["target-prim", "target-peak", "target-trc"]

    init(player: PlayerModel, request: MetalOutputRequest) {
        self.player = player; self.request = request; initialCore = player.handle
    }
    /// Caller suspends render requests across this MainActor property transaction.
    /// The bridge never calls client setters on its render queue.
    func reconcile() -> Bool {
        guard MetalRenderOwnership.acceptsNewWork else { return fail("视频输出正在关闭") }
        guard initialCore != nil, player.handle == initialCore, !player.liveASRCoreClosed else { return fail("播放核心已关闭或已替换") }
        let base = ["target-prim": player.settings.processing.forceSDR ? "bt.709" : "auto",
                    "target-trc": player.settings.processing.forceSDR ? "srgb" : "auto"]
        let current = Dictionary(uniqueKeysWithValues: keys.map { ($0, player.string($0)) })
        guard current.values.allSatisfy({ !$0.isEmpty }) else { return fail("输出色彩属性不可读取") }
        if !active { original = current; installed = current; active = true; lastBase = base }
        else {
            // applySettings can legitimately restore its two base properties.
            // A script/custom property outside our lease/base is a competing owner.
            for key in keys where current[key] != installed[key] {
                guard key != "target-peak", current[key] == base[key] else {
                    return fail("输出色彩设置已由其他控制器改变")
                }
                original[key] = base[key]
            }
        }
        if base != lastBase {
            for key in base.keys { original[key] = base[key] }
            lastBase = base
        }
        let desired: [String: String]
        switch request {
        case .sdr: desired = ["target-prim": "bt.709", "target-peak": "auto", "target-trc": "srgb"]
        case .scRGBReference(let peak):
            guard peak.isFinite, peak.rounded() == peak, peak >= 80, peak <= 10_000 else { return fail("参考输出亮度超出范围") }
            desired = player.settings.processing.forceSDR
                ? ["target-prim": "bt.709", "target-peak": "auto", "target-trc": "srgb"]
                : ["target-prim": "bt.709", "target-peak": String(Int(peak)), "target-trc": "scrgb"]
        }
        if keys.allSatisfy({ equivalent(key: $0, actual: current[$0] ?? "", expected: desired[$0] ?? "") }) {
            installed = current; return true
        }
        guard revision < UInt64.max else { return fail("输出色彩事务序号已达上限") }
        var changed: [String] = []
        for key in keys where !equivalent(key: key, actual: current[key] ?? "", expected: desired[key] ?? "") {
            guard let value = desired[key] else { return fail("输出色彩计划不完整") }
            let status = player.setChecked(key, value)
            if status >= 0 { installed[key] = value; changed.append(key) }
            let actual = player.string(key)
            guard status >= 0, equivalent(key: key, actual: actual, expected: value) else {
                if status >= 0 && !equivalent(key: key, actual: actual, expected: value) { uncertainMutation = true }
                // Restore only writes acknowledged in this transaction and still owned.
                for old in changed.reversed() {
                    guard let own = installed[old], let previous = current[old],
                          equivalent(key: old, actual: player.string(old), expected: own) else {
                        uncertainMutation = true; continue
                    }
                    if player.setChecked(old, previous) >= 0,
                       equivalent(key: old, actual: player.string(old), expected: previous) { installed[old] = previous }
                    else { uncertainMutation = true }
                }
                return fail("输出色彩事务未能确认")
            }
        }
        installed = Dictionary(uniqueKeysWithValues: keys.map { ($0, player.string($0)) })
        active = true; revision += 1; return true
    }
    /// Restore independently owned values; never overwrite a later competing edit.
    /// True requires actual getter confirmation. It does not assert all GPU work completed.
    func restore() -> Bool {
        guard active else { return true }
        // A changed/nil handle is not proof that the original Core died.
        guard initialCore != nil, player.handle == initialCore else { return fail("原播放核心身份尚未确认") }
        if player.liveASRCoreClosed {
            // This flag is set only by the real SHUTDOWN event of this handle.
            active = false; uncertainMutation = false
            return true
        }
        var confirmed = true
        for key in keys.reversed() {
            guard let own = installed[key], let value = original[key] else { confirmed = false; continue }
            if equivalent(key: key, actual: player.string(key), expected: own) {
                if player.setChecked(key, value) < 0 || !equivalent(key: key, actual: player.string(key), expected: value) {
                    confirmed = false
                }
            } // A later independent edit survives lease retirement.
        }
        if uncertainMutation {
            confirmed = confirmed && keys.allSatisfy { key in
                equivalent(key: key, actual: player.string(key), expected: original[key] ?? "")
            }
        }
        if confirmed { active = false; uncertainMutation = false }
        else { _ = fail("输出色彩恢复尚未确认") }
        return confirmed
    }
    var diagnostics: [String: Any] {
        ["active": active, "revision": revision, "uncertainMutation": uncertainMutation, "original": original, "installed": installed,
         "firstError": firstError as Any? ?? NSNull(), "physicalHDRClaim": false,
         "scRGBUnits": "1.0 = 80 cd/m2; internal libplacebo NORM white = 203 cd/m2"]
    }
    private func equivalent(key: String, actual: String, expected: String) -> Bool {
        if key == "target-peak", let a = (actual == "auto" ? 0 : Double(actual)),
           let b = (expected == "auto" ? 0 : Double(expected)) { return a == b }
        return actual == expected
    }
    private func fail(_ text: String) -> Bool { if firstError == nil { firstError = text }; return false }
}
