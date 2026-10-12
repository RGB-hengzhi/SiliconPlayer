import Foundation
import CoreFoundation

/// Dedicated fixed-source progress parser. Caller supplies the exact registered
/// child reader's WindowID; this cannot infer a window from repeated source PTS.
struct LiveASRLinearInputProgress {
    let window: LiveASRLinearWindowID
    let ticket: LiveASRWireTicket
    let sequence: UInt64
    let streamGeneration: UInt64
    let acceptedSamples: UInt64
    let firstInputSequence: UInt64
    let lastInputSequence: UInt64
    let wallSeconds: Double
    let monotonicSeconds: Double

    static func decode(_ line: Data, from window: LiveASRLinearWindowID) throws -> Self {
        let keys: Set<String> = ["sequence", "wall_seconds", "monotonic_seconds", "event", "epoch", "timing_segment",
            "item", "stream_index", "stream_generation", "accepted_samples", "padding_samples",
            "first_input_sequence", "last_input_sequence", "live_recognizers", "live_streams", "reason"]
        guard !line.isEmpty, line.count <= 2048,
              let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              Set(object.keys) == keys,
              object["event"] as? String == "input_accepted",
              object["reason"] as? String == "actual_C_API_accept_complete_record" else {
            throw LiveASRFailure("输入进度不是固定C服务的有界回执")
        }
        func uint(_ name: String) throws -> UInt64 {
            guard let number = object[name] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: number.objCType)),
                  let value = UInt64(number.stringValue) else {
                throw LiveASRFailure("输入进度整数类型或范围无效")
            }
            return value
        }
        let epoch = try uint("epoch"), item = try uint("item"), index = try uint("stream_index")
        let sequence = try uint("sequence"), generation = try uint("stream_generation")
        let accepted = try uint("accepted_samples"), first = try uint("first_input_sequence")
        let last = try uint("last_input_sequence")
        guard epoch > 0, item > 0, index <= 4096, sequence > 0, generation > 0,
              accepted > 0, accepted <= 1920000, first > 0, last >= first,
              try uint("padding_samples") == 0, try uint("live_recognizers") == 1,
              try uint("live_streams") == 1,
              let wall = object["wall_seconds"] as? NSNumber,
              CFGetTypeID(wall) != CFBooleanGetTypeID(), wall.doubleValue.isFinite,
              wall.doubleValue >= 0, let monotonic = object["monotonic_seconds"] as? NSNumber,
              CFGetTypeID(monotonic) != CFBooleanGetTypeID(), monotonic.doubleValue.isFinite,
              monotonic.doubleValue > 0 else { throw LiveASRFailure("输入进度未证明真实无padding的当前服务输入") }
        return Self(window: window, ticket: LiveASRWireTicket(epoch: epoch,
            timingSegment: try uint("timing_segment"), itemSerial: item, streamIndex: UInt32(index)),
            sequence: sequence, streamGeneration: generation, acceptedSamples: accepted,
            firstInputSequence: first, lastInputSequence: last, wallSeconds: wall.doubleValue, monotonicSeconds: monotonic.doubleValue)
    }
    func apply(to ownership: inout LiveASRLinearOwnership) throws {
        try ownership.actualAccepted(window, ticket: ticket, generation: streamGeneration,
            eventSequence: sequence, samples: acceptedSamples,
            first: firstInputSequence, last: lastInputSequence, padding: 0)
    }
}
