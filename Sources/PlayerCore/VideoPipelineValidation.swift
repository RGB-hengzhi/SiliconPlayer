import Foundation
import CoreFoundation

public enum VideoPipelineValidationError: Error { case invalidReceipt, unsupportedVersion }

/// Facts emitted by the pinned GL renderer. Neither configuration readback nor
/// performance labels can construct a positive compile/execution receipt.
public struct VideoPipelineValidation: Sendable {
    public struct Hook: Sendable {
        public let path: String
        public let description: String
        public let point: String
        public let submitted: Bool
    }
    public struct Render: Sendable {
        public let generation: Int64
        public let sequence: Int64
        public let frameID: UInt64
        public let completed: Bool
        public let hasFrame: Bool
        public let processed: Bool
        public let offscreen: Bool
        public let success: Bool
        public let brokenFrame: Bool
        public let shaderError: Bool
        public let resourceError: Bool
        public let overflow: Bool
        public let hooks: [Hook]
        fileprivate var validOutput: Bool {
            completed && hasFrame && success && !offscreen && !brokenFrame
                && !shaderError && !resourceError && !overflow
        }
    }
    public let generation: Int64
    public let sequence: Int64
    public let lastFailureSequence: Int64
    public let overflow: Bool
    public let configuredShaders: [String]
    public let current: Render
    public let lastSuccessfulProcessed: Render

    private static func integer(_ value: Any?) throws -> Int64 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              number.int64Value >= 0, number.stringValue == String(number.int64Value) else {
            throw VideoPipelineValidationError.invalidReceipt
        }
        return number.int64Value
    }
    private static func flag(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw VideoPipelineValidationError.invalidReceipt
        }
        return number.boolValue
    }
    private static func text(_ value: Any?, maximum: Int) throws -> String {
        guard let value = value as? String, value.utf8.count <= maximum,
              !value.utf8.contains(0) else { throw VideoPipelineValidationError.invalidReceipt }
        return value
    }
    private static func render(_ value: Any?) throws -> Render {
        guard let object = value as? [String: Any], Set(object.keys) == Set([
            "generation", "sequence", "frame-id", "completed", "has-frame", "processed-frame",
            "offscreen", "success", "broken-frame", "shader-error", "resource-error", "overflow", "hooks"]),
              let rows = object["hooks"] as? [[String: Any]], rows.count <= 64 else {
            throw VideoPipelineValidationError.invalidReceipt
        }
        let rawID = try text(object["frame-id"], maximum: 20)
        guard let frameID = UInt64(rawID), String(frameID) == rawID else {
            throw VideoPipelineValidationError.invalidReceipt
        }
        let hooks = try rows.map { row -> Hook in
            guard Set(row.keys) == Set(["path", "desc", "hook", "submitted"]) else {
                throw VideoPipelineValidationError.invalidReceipt
            }
            return Hook(path: try text(row["path"], maximum: 4096),
                        description: try text(row["desc"], maximum: 128),
                        point: try text(row["hook"], maximum: 32), submitted: try flag(row["submitted"]))
        }
        return Render(generation: try integer(object["generation"]), sequence: try integer(object["sequence"]),
            frameID: frameID, completed: try flag(object["completed"]), hasFrame: try flag(object["has-frame"]),
            processed: try flag(object["processed-frame"]), offscreen: try flag(object["offscreen"]),
            success: try flag(object["success"]), brokenFrame: try flag(object["broken-frame"]),
            shaderError: try flag(object["shader-error"]), resourceError: try flag(object["resource-error"]),
            overflow: try flag(object["overflow"]), hooks: hooks)
    }
    public static func parse(_ object: [String: Any]) throws -> Self {
        guard Set(object.keys) == Set(["version", "generation", "sequence", "last-failure-sequence",
            "overflow", "configured-shaders", "current", "last-successful-processed"]) else {
            throw VideoPipelineValidationError.invalidReceipt
        }
        guard try integer(object["version"]) == 1 else { throw VideoPipelineValidationError.unsupportedVersion }
        guard let paths = object["configured-shaders"] as? [String], paths.count <= 64 else {
            throw VideoPipelineValidationError.invalidReceipt
        }
        for path in paths { _ = try text(path, maximum: 4096) }
        return Self(generation: try integer(object["generation"]), sequence: try integer(object["sequence"]),
            lastFailureSequence: try integer(object["last-failure-sequence"]), overflow: try flag(object["overflow"]),
            configuredShaders: paths, current: try render(object["current"]),
            lastSuccessfulProcessed: try render(object["last-successful-processed"]))
    }
    /// The host separately requires its exact completed Surface/context/ticket,
    /// output parameters and a same-handle event drain followed by fresh checks.
    public func hasCurrentRenderFailure(sequenceAfter before: Int64, paths: [String]) -> Bool {
        before >= 0 && sequence > before && generation > 0 && !overflow
            && configuredShaders == paths && lastFailureSequence == sequence
            && current.sequence == sequence && current.generation == generation
            && current.completed && current.hasFrame && !current.offscreen && !current.overflow
            && !current.success && (current.shaderError || current.resourceError || current.brokenFrame)
    }

    /// Success still requires a real same-generation processed display receipt.
    public func confirmed(sequenceAfter before: Int64, paths: [String], descriptions: [String]) -> [String]? {
        let processed = lastSuccessfulProcessed
        guard before >= 0, sequence > before, generation > 0, !overflow,
              configuredShaders == paths, paths.count == descriptions.count,
              current.sequence == sequence, current.generation == generation, current.validOutput,
              processed.sequence > lastFailureSequence, processed.sequence <= sequence,
              processed.generation == generation, processed.validOutput, processed.processed,
              processed.hooks.count == paths.count else { return nil }
        for index in paths.indices {
            let hook = processed.hooks[index]
            guard hook.path == paths[index], hook.description == descriptions[index],
                  hook.point == "MAIN", hook.submitted else { return nil }
        }
        return processed.hooks.map { "user shader: " + $0.description + " [" + $0.point + "] " + $0.path }
    }
}
