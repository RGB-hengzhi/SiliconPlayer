import Foundation
import CMPV
import Darwin

extension PlayerModel {
    var explicitScripts: ExplicitScriptController {
        if let explicitScriptController { return explicitScriptController }
        let controller = ExplicitScriptController(
            directory: Self.supportDirectory.appendingPathComponent("ExplicitScripts", isDirectory: true),
            canPersist: { [weak self] in self.map { !$0.profileStoresBlocked } ?? false },
            canExecute: { [weak self] in self?.scriptExecutionAvailable == true },
            submit: { [weak self] args, replyID in
                guard let self, self.scriptExecutionAvailable else { return MPV_ERROR_UNINITIALIZED.rawValue }
                return self.executeAsyncCommand(args, replyID: replyID)
            })
        explicitScriptController = controller
        return controller
    }

    /// Copy the real result before the next mpv_wait_event invalidates storage.
    /// The fixed C implementation emits NODE_MAP/client_id/INT64. Manual text
    /// describing a string result is not used to fabricate or guess an ID.
    static func explicitScriptClientID(from data: UnsafeMutableRawPointer?) -> Int64? {
        guard let result = data?.assumingMemoryBound(to: mpv_event_command.self).pointee.result,
              result.format == MPV_FORMAT_NODE_MAP, let list = result.u.list,
              (1...16).contains(list.pointee.num),
              let keys = list.pointee.keys, let values = list.pointee.values else { return nil }
        var answer: Int64?
        for index in 0..<Int(list.pointee.num) {
            guard let key = keys[index] else { return nil }
            let length = strnlen(key, 64)
            guard length < 64 else { return nil }
            if String(cString: key) == "client_id" {
                guard answer == nil, values[index].format == MPV_FORMAT_INT64,
                      values[index].u.int64 > 0 else { return nil }
                answer = values[index].u.int64
            }
        }
        return answer
    }
}
