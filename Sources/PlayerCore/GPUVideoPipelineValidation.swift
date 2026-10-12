import Foundation
import CoreFoundation

/// The C7 gpu-next receipt is distinct from the original GL receipt. The
/// common fields still use the original strict parser without changing it.
public struct GPUVideoPipelineValidation: Sendable {
    public let pipeline: VideoPipelineValidation
    public let api: String
    public let startAttempted: Bool
    public let targetAcquired: Bool
    public let startReturn: Int64
    public let renderAttempted: Bool
    public let renderSucceeded: Bool
    public let submitAttempted: Bool
    public let submitReturn: Int64
    public let rendererErrors: Int64
    public let dispatchCount: Int64
    private static let common = Set(["version", "generation", "sequence", "last-failure-sequence",
        "overflow", "configured-shaders", "current", "last-successful-processed"])
    private static let extra = Set(["api", "hook-evidence", "start-attempted", "target-acquired", "start-return",
        "render-attempted", "render-succeeded", "submit-attempted", "submit-return", "renderer-errors",
        "dispatch-count", "download-attempted", "download-succeeded", "screenshot-scaled", "screenshot-subs",
        "screenshot-osd", "screenshot-native-csp", "screenshot-high-bit-depth"])
    public static func parse(_ object: [String: Any]) throws -> Self {
        guard Set(object.keys) == common.union(extra), object["api"] as? String == "metal",
              object["hook-evidence"] as? String == "successful-libplacebo-dispatch-steps" else {
            throw VideoPipelineValidationError.invalidReceipt
        }
        let base = try VideoPipelineValidation.parse(object.filter { common.contains($0.key) })
        for key in ["download-attempted", "download-succeeded", "screenshot-scaled", "screenshot-subs",
                    "screenshot-osd", "screenshot-native-csp", "screenshot-high-bit-depth"] {
            _ = try MetalProofScalar.flag(object[key])
        }
        let errors = try MetalProofScalar.integer(object["renderer-errors"])
        let dispatches = try MetalProofScalar.integer(object["dispatch-count"])
        guard errors >= 0, dispatches >= 0 else { throw VideoPipelineValidationError.invalidReceipt }
        return Self(pipeline: base, api: "metal",
            startAttempted: try MetalProofScalar.flag(object["start-attempted"]),
            targetAcquired: try MetalProofScalar.flag(object["target-acquired"]),
            startReturn: try MetalProofScalar.integer(object["start-return"]),
            renderAttempted: try MetalProofScalar.flag(object["render-attempted"]),
            renderSucceeded: try MetalProofScalar.flag(object["render-succeeded"]),
            submitAttempted: try MetalProofScalar.flag(object["submit-attempted"]),
            submitReturn: try MetalProofScalar.integer(object["submit-return"]),
            rendererErrors: errors, dispatchCount: dispatches)
    }
    public func hasCurrentRenderFailure(sequenceAfter before: Int64, paths: [String]) -> Bool {
        let p = pipeline
        guard p.sequence > before, p.generation > 0, p.configuredShaders == paths,
              p.current.sequence == p.sequence, p.current.generation == p.generation,
              p.current.completed, !p.current.offscreen else { return false }
        return p.lastFailureSequence == p.sequence || p.overflow || p.current.overflow
            || p.current.brokenFrame || p.current.shaderError || p.current.resourceError
            || rendererErrors != 0 || (startAttempted && (startReturn < 0 || !targetAcquired))
            || (renderAttempted && !renderSucceeded) || (submitAttempted && submitReturn < 0)
    }
    private static func valid(_ r: VideoPipelineValidation.Render) -> Bool {
        r.completed && r.hasFrame && r.success && !r.offscreen && !r.brokenFrame
            && !r.shaderError && !r.resourceError && !r.overflow
    }
    /// Native stage identity comes from fixed libplacebo MAIN -> PL_HOOK_RGB
    /// (1<<8). Each successful dispatch may contain several actual steps;
    /// require ordered path groups and an actual DESC step for each resource.
    public func confirmed(after before: Self, paths: [String], descriptions: [String]) -> [String]? {
        let p = pipeline, old = before.pipeline, processed = p.lastSuccessfulProcessed
        guard p.sequence > old.sequence, p.generation >= old.generation, p.generation > 0,
              !p.overflow, p.configuredShaders == paths, paths.count == descriptions.count,
              p.current.sequence == p.sequence, p.current.generation == p.generation,
              Self.valid(p.current), startAttempted, targetAcquired, startReturn >= 0,
              renderAttempted, renderSucceeded, submitAttempted, submitReturn >= 0, rendererErrors == 0,
              processed.generation == p.generation, processed.sequence > p.lastFailureSequence,
              processed.sequence <= p.sequence, processed.processed, Self.valid(processed) else { return nil }
        // A changed configuration cannot borrow a cached result from before
        // this ticket. An unchanged same-generation pipeline may reuse only
        // its recorded successful processed source, followed by a new display.
        if old.configuredShaders != paths || old.generation != p.generation {
            guard p.generation > old.generation, processed.sequence > old.sequence else { return nil }
        }
        var groups: [(String, [VideoPipelineValidation.Hook])] = []
        for hook in processed.hooks {
            guard hook.submitted, hook.point == "pl-stage-256" else { return nil }
            if groups.last?.0 == hook.path {
                groups[groups.count - 1].1.append(hook)
            } else { groups.append((hook.path, [hook])) }
        }
        guard groups.map(\.0) == paths else { return nil }
        for index in paths.indices {
            guard groups[index].1.contains(where: { $0.description == descriptions[index] }) else { return nil }
        }
        return processed.hooks.map { "user shader: " + $0.description + " [" + $0.point + "] " + $0.path }
    }
}

private enum MetalProofScalar {
    static func integer(_ value: Any?) throws -> Int64 {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: n.objCType)),
              n.stringValue == String(n.int64Value) else { throw VideoPipelineValidationError.invalidReceipt }
        return n.int64Value
    }
    static func flag(_ value: Any?) throws -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            throw VideoPipelineValidationError.invalidReceipt
        }
        return n.boolValue
    }
    static func time(_ value: Any?) throws -> TimeInterval {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue > 0 else { throw VideoPipelineValidationError.invalidReceipt }
        return n.doubleValue
    }
}

/// Values copied from the real observed CAMetalDrawable and render call. This
/// type never advances RenderProgress or manufactures a GL completion time.
public struct MetalShaderDrawableReceipt: Sendable {
    public let ticket: UUID
    public let rendererID: UUID
    public let attemptSequence: UInt64
    public let acquisitionSequence: UInt64
    public let updateFlags: UInt64
    public let width: Int
    public let height: Int
    public let requestedAt: TimeInterval
    public let apiReturnedAt: TimeInterval
    public let reportedSwapAt: TimeInterval
    public let callbackObservedAt: TimeInterval
    public let presentedTime: TimeInterval
    public static func parse(_ row: [String: Any]) throws -> Self {
        guard let ticketText = row["ticket"] as? String, let ticket = UUID(uuidString: ticketText),
              let rendererText = row["rendererID"] as? String, let renderer = UUID(uuidString: rendererText),
              try MetalProofScalar.flag(row["associatedRenderAttempt"]),
              try MetalProofScalar.flag(row["forced"]),
              try MetalProofScalar.flag(row["presentedCallback"]),
              try MetalProofScalar.flag(row["presentedTimeFinite"]),
              !(try MetalProofScalar.flag(row["callbackAfterClose"])),
              try MetalProofScalar.integer(row["apiReturn"]) == 0 else {
            throw VideoPipelineValidationError.invalidReceipt
        }
        let attempt = try MetalProofScalar.integer(row["attemptSequence"])
        let acquisition = try MetalProofScalar.integer(row["acquisitionSequence"])
        let flags = try MetalProofScalar.integer(row["updateFlags"])
        let w = try MetalProofScalar.integer(row["textureWidth"]), h = try MetalProofScalar.integer(row["textureHeight"])
        let rw = try MetalProofScalar.time(row["requestedWidth"]), rh = try MetalProofScalar.time(row["requestedHeight"])
        let requested = try MetalProofScalar.time(row["requestedAt"]), started = try MetalProofScalar.time(row["attemptStartedAt"])
        let acquired = try MetalProofScalar.time(row["acquiredAt"]), returned = try MetalProofScalar.time(row["apiReturnedAt"])
        let swap = try MetalProofScalar.time(row["reportedSwapAt"]), callback = try MetalProofScalar.time(row["callbackObservedAt"])
        let presented = try MetalProofScalar.time(row["presentedTime"])
        guard attempt > 0, acquisition > 0, flags >= 0, (1...16384).contains(w), (1...16384).contains(h),
              Double(w) == rw, Double(h) == rh, requested <= started, started <= acquired,
              acquired <= returned, returned <= swap, acquired <= callback else {
            throw VideoPipelineValidationError.invalidReceipt
        }
        return Self(ticket: ticket, rendererID: renderer, attemptSequence: UInt64(attempt),
            acquisitionSequence: UInt64(acquisition), updateFlags: UInt64(flags), width: Int(w), height: Int(h),
            requestedAt: requested, apiReturnedAt: returned, reportedSwapAt: swap,
            callbackObservedAt: callback, presentedTime: presented)
    }
    public func matches(ticket: UUID, renderer: UUID, requestedAfter: TimeInterval) -> Bool {
        self.ticket == ticket && rendererID == renderer && requestedAt >= requestedAfter
    }
}
