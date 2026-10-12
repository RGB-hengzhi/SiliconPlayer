import Foundation
import Darwin

/// One failing write(2) receipt; errno is captured before any Swift work.
/// Kept separate from the short user-facing error and all exit ownership gates.
struct LiveASRChildWriteFailure: LocalizedError, Sendable {
    let pid: pid_t
    let role: String
    let errorNumber: Int32
    let offsetBefore: Int
    let attemptedBytes: Int
    let writeReturn: Int
    let observedUptime: Double
    var errorDescription: String? { "\u{5199}\u{5165}\u{8bc6}\u{522b}\u{7ba1}\u{9053}\u{5931}\u{8d25}" }
    var receipt: [String: Any] {
        ["pid": pid, "role": role, "errno": errorNumber,
         "offsetBefore": offsetBefore, "attemptedBytes": attemptedBytes,
         "writeReturn": writeReturn, "hostObservedUptime": observedUptime]
    }
}

/// Used only by one ProcessSession actor; no Process/post-exec setpgid race.
/// The unreaped leader reserves this job's PGID until an exact kernel snapshot
/// proves every member exited. Unknown ownership stays retained, never global.
final class LiveASRChildProcess: @unchecked Sendable {
    let pid: pid_t
    private var input: Int32
    private var output: Int32
    private var diagnostic: Int32
    private(set) var outputEOF = false
    private(set) var diagnosticEOF = false
    private(set) var exitCode: Int32?
    private(set) var reaped = false
    private(set) var forced = false
    private var termAt: Double?
    private var killSent = false
    private var leaderExited = false
    private var exitTrace: [[String: Any]] = []
    private var exitTraceDropped: UInt64 = 0
    private var exitTraceOverflowed = false
    private var lastGroupReceipt: [String: Any]?
    private var confirmedGroupReceipt: [String: Any]?
    private var firstIdentityFailureReceipt: [String: Any]?
    private var reservedPendingAt: Double?
    private var firstReservedPendingReceipt: [String: Any]?
    private let maximumReservedPendingSeconds = 1.0
    private var role = "owned-helper"
    #if LIVE_ASR_OWNED_PROCESS_DIAGNOSTIC
    // Docs-only controlled kernel interleave; release builds have no hook.
    var diagnosticBeforeGroupIdentity: (() -> Void)?
    #endif
    var exitDiagnostics: [String: Any] {
        ["role": role, "pid": pid, "reservedPGID": pid, "leaderExitedWNOWAIT": leaderExited,
         "reaped": reaped, "exitCode": exitCode.map { $0 as Any } ?? NSNull(),
         "stdoutEOF": outputEOF, "stderrEOF": diagnosticEOF, "forcedSignalIssued": forced,
         "traceCapacity": 64, "traceDroppedEvents": exitTraceDropped, "traceCounterOverflowed": exitTraceOverflowed,
         "groupMemberCapacity": 4096, "events": exitTrace, "lastGroupReceipt": lastGroupReceipt as Any? ?? NSNull(),
         "firstIdentityFailureReceipt": firstIdentityFailureReceipt as Any? ?? NSNull(),
         "maximumReservedPendingSeconds": maximumReservedPendingSeconds,
         "firstReservedPendingReceipt": firstReservedPendingReceipt as Any? ?? NSNull(),
         "confirmedQuiescentGroupReceipt": confirmedGroupReceipt as Any? ?? NSNull()]
    }

    init(executable: URL, arguments: [String], workURL: URL, sourceFD: Int32? = nil) throws {
        guard executable.isFileURL, arguments.count <= 64,
              ([executable.path] + arguments).allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 32768 }) else {
            throw LiveASRFailure("辅助进程参数无效")
        }
        func makePipe() throws -> [Int32] {
            var raw: [Int32] = [-1, -1]
            guard pipe(&raw) == 0 else { throw LiveASRFailure("无法创建识别管道") }
            defer { raw.forEach { Darwin.close($0) } }
            var owned: [Int32] = []
            for fd in raw {
                let copied = fcntl(fd, F_DUPFD_CLOEXEC, 20)
                guard copied >= 20 else { owned.forEach { Darwin.close($0) }; throw LiveASRFailure("无法保留识别管道") }
                owned.append(copied)
            }
            return owned
        }
        var fds: [Int32] = []
        defer { fds.forEach { Darwin.close($0) } }
        let stdinPipe = try makePipe(); fds += stdinPipe
        let stdoutPipe = try makePipe(); fds += stdoutPipe
        let stderrPipe = try makePipe(); fds += stderrPipe
        for fd in [stdinPipe[1], stdoutPipe[0], stderrPipe[0]] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
                throw LiveASRFailure("无法设置识别管道边界")
            }
        }
        // Local descriptor option: never change the application's SIGPIPE handler.
        guard fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1) == 0 else { throw LiveASRFailure("无法保护识别输入管道") }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw LiveASRFailure("无法准备识别进程") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw LiveASRFailure("无法准备识别进程组") }
        defer { posix_spawnattr_destroy(&attributes) }
        // Swift worker threads may block termination signals. Set only the
        // child's birth mask so its cooperative signal handler can receive them;
        // never change the application's current thread signal mask.
        var childSignalMask = sigset_t()
        guard sigemptyset(&childSignalMask) == 0,
              posix_spawnattr_setsigmask(&attributes, &childSignalMask) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            throw LiveASRFailure("无法隔离识别进程组")
        }
        for fd in fds { guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw LiveASRFailure("无法隔离识别描述符") } }
        if let sourceFD {
            guard sourceFD >= 20, posix_spawn_file_actions_adddup2(&actions, sourceFD, 3) == 0,
                  posix_spawn_file_actions_addclose(&actions, sourceFD) == 0 else { throw LiveASRFailure("无法传递已打开源文件") }
        }
        // Do not inherit proxy/auth/PYTHON/DYLD/plugin variables or override HOME.
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8", "TMPDIR=\(workURL.path)/"]
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else { throw LiveASRFailure("识别参数分配失败") }
        var spawned: pid_t = 0
        let status = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in
            posix_spawn(&spawned, executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
        } }
        guard status == 0, spawned > 0 else { throw LiveASRFailure("本地识别辅助进程无法启动（\(status)）") }
        pid = spawned; input = stdinPipe[1]; output = stdoutPipe[0]; diagnostic = stderrPipe[0]
        switch executable.lastPathComponent {
        case "ffprobe": role = "source-probe"
        case "media-pcm-pts": role = "decoder"
        case "online-asr-service": role = "recognizer"
        default: role = "owned-diagnostic-helper"
        }
        recordExit("spawn", ["pid": spawned, "reservedPGID": spawned])
        fds.removeAll { $0 == input || $0 == output || $0 == diagnostic }
    }
    deinit { for fd in [input, output, diagnostic] where fd >= 0 { Darwin.close(fd) } }
    func closeInput() { if input >= 0 { Darwin.close(input); input = -1 } }
    /// At most 4 × 16KiB per call. Caller services the other pipe and controls.
    func readOutput() throws -> [Data] { try drain(output, eof: &outputEOF) }
    func readDiagnostic() throws -> [Data] { try drain(diagnostic, eof: &diagnosticEOF) }
    private func drain(_ fd: Int32, eof: inout Bool) throws -> [Data] {
        guard !eof else { return [] }
        var result: [Data] = [], bytes = [UInt8](repeating: 0, count: 16384)
        for _ in 0..<4 {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 { result.append(Data(bytes.prefix(count))) }
            else if count == 0 { eof = true; break }
            else if errno == EAGAIN || errno == EWOULDBLOCK { break }
            else if errno != EINTR { throw LiveASRFailure("读取识别管道失败") }
        }
        return result
    }
    /// Offset persists across calls. A partly written SPCM packet must finish.
    func write(_ data: Data, offset: inout Int) throws {
        guard input >= 0 else { throw LiveASRFailure("识别输入已经关闭") }
        guard offset >= 0, offset <= data.count else { throw LiveASRFailure("识别写入边界无效") }
        guard offset < data.count else { return }
        let (written, code) = data.withUnsafeBytes { bytes in
            let result = Darwin.write(input, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            return (result, result < 0 ? errno : 0)
        }
        if written > 0 { offset += written }
        else if written < 0, code != EINTR, code != EAGAIN, code != EWOULDBLOCK {
            throw LiveASRChildWriteFailure(pid: pid, role: role, errorNumber: code,
                offsetBefore: offset, attemptedBytes: data.count - offset,
                writeReturn: written, observedUptime: ProcessInfo.processInfo.systemUptime)
        }
    }
    /// Sequential kernel receipts are not a single atomic kernel transaction.
    /// WNOWAIT retains the exact child leader, preventing its PID/PGID reuse.
    /// Complete KERN_PROC_PGRP membership plus that reserved leader is required
    /// before reaping or signalling; ESRCH alone is never completion proof.
    func pollExit(cancel: Bool, now: Double) throws {
        guard !reaped else { return }
        if !leaderExited { try refreshLeaderExit(now: now) }
        if !leaderExited && !cancel { return }
        var group = readOwnedGroup(now: now)
        if leaderExited, group.quiescent { try reapConfirmed(group, now: now); return }
        #if LIVE_ASR_OWNED_PROCESS_DIAGNOSTIC
        diagnosticBeforeGroupIdentity?()
        #endif
        errno = 0
        let observedPGID = getpgid(pid), pgidError = observedPGID < 0 ? errno : 0
        recordExit("getpgid", ["return": observedPGID, "errno": pgidError], now: now)
        if observedPGID != pid {
            // A positive different group is a real identity mismatch. Only the
            // actual ESRCH exit race has this alternate reserved-child proof.
            guard observedPGID < 0, pgidError == ESRCH else {
                throw identityFailure("getpgid", code: pgidError, observed: observedPGID)
            }
            let successfullyStillPending = try refreshLeaderExit(now: now)
            group = readOwnedGroup(now: now)
            guard group.complete else {
                throw identityFailure("getpgid/fresh-unconfirmed", code: pgidError, observed: observedPGID)
            }
            if !leaderExited {
                // ESRCH can precede waitable exit. Only actual ret0/siPID0
                // plus this complete exact reserved group allows waiting.
                // EINTR, unknown/missing identity and ECHILD never qualify.
                guard successfullyStillPending, now.isFinite else {
                    throw identityFailure("getpgid/fresh-unconfirmed", code: pgidError, observed: observedPGID)
                }
                let began = reservedPendingAt ?? now
                guard began.isFinite, now >= began, now - began < maximumReservedPendingSeconds else {
                    throw identityFailure("getpgid/reserved-pending-bound", code: pgidError, observed: observedPGID)
                }
                reservedPendingAt = began
                recordExit("reserved-leader-exit-pending", ["members": group.members.count,
                    "successfulWaitidPending": true, "pendingBeganUptime": began,
                    "elapsedSeconds": now - began], now: now)
                if firstReservedPendingReceipt == nil {
                    firstReservedPendingReceipt = ["role": role, "pid": pid, "reservedPGID": pid,
                        "hostObservedUptime": ProcessInfo.processInfo.systemUptime, "pollUptime": now,
                        "events": exitTrace, "groupReceipt": group.value]
                }
                return // Remain unreaped/owned; no signal or completion flag.
            }
            if group.quiescent { try reapConfirmed(group, now: now); return }
            // The exited but unreaped leader is present in a complete snapshot;
            // live members keep this reserved group alive. Do not reap it yet.
            recordExit("reserved-exited-leader-live-group", ["members": group.members.count], now: now)
        }
        guard group.complete else { throw identityFailure("incomplete-group", code: group.error, observed: observedPGID) }
        if termAt == nil {
            if try signalReserved(SIGTERM, group: group, now: now) { termAt = now }
        } else if !killSent, now - termAt! >= 0.3 {
            if try signalReserved(SIGKILL, group: group, now: now) {
                killSent = true; forced = true
            }
        }
    }

    /// True only for this syscall's actual ret0/siPID0, not cached state.
    @discardableResult private func refreshLeaderExit(now: Double) throws -> Bool {
        var info = siginfo_t()
        errno = 0
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        let code = result < 0 ? errno : 0
        recordExit("waitid", ["return": result, "errno": code, "siPID": info.si_pid,
            "siCode": info.si_code, "siStatus": info.si_status], now: now)
        if result == 0, info.si_pid == pid { leaderExited = true }
        else if result == 0, info.si_pid != 0 { throw identityFailure("waitid/unexpected-child", code: 0, observed: info.si_pid) }
        else if result < 0, code != EINTR { throw identityFailure("waitid", code: code, observed: info.si_pid) }
        return result == 0 && info.si_pid == 0 // EINTR is not pending proof.
    }
    private struct GroupReceipt {
        let complete: Bool
        let quiescent: Bool
        let error: Int32
        let members: [[String: Any]]
        let value: [String: Any]
    }
    private func readOwnedGroup(now: Double) -> GroupReceipt {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pid], bytes = 0
        let stride = MemoryLayout<kinfo_proc>.stride
        let sized = mib.withUnsafeMutableBufferPointer { buffer -> (Int32, Int32) in
            errno = 0
            let result = sysctl(buffer.baseAddress, UInt32(buffer.count), nil, &bytes, nil, 0)
            return (result, result < 0 ? errno : 0)
        }
        let sizeResult = sized.0, sizeError = sized.1, sizedBytes = bytes
        var rows: [[String: Any]] = []
        var complete = false, quiescent = false, error = sizeError
        var readResult: Int32 = -1, readError: Int32 = 0
        if sizeResult == 0, bytes > 0, bytes <= 4096 * stride, bytes % stride == 0 {
            var members = [kinfo_proc](repeating: kinfo_proc(), count: min(4096, bytes / stride + 4))
            bytes = members.count * stride
            let read = members.withUnsafeMutableBytes { buffer in mib.withUnsafeMutableBufferPointer { mibBuffer -> (Int32, Int32) in
                errno = 0
                let result = sysctl(mibBuffer.baseAddress, UInt32(mibBuffer.count), buffer.baseAddress, &bytes, nil, 0)
                return (result, result < 0 ? errno : 0)
            } }
            readResult = read.0; readError = read.1; error = readError
            if readResult == 0, bytes > 0, bytes % stride == 0, bytes / stride <= members.count {
                let actual = members.prefix(bytes / stride)
                rows = actual.map { ["pid": $0.kp_proc.p_pid, "pgid": $0.kp_eproc.e_pgid,
                    "stat": Int32($0.kp_proc.p_stat)] as [String: Any] }
                complete = actual.contains(where: { $0.kp_proc.p_pid == pid })
                    && actual.allSatisfy({ $0.kp_eproc.e_pgid == pid && $0.kp_proc.p_pid > 0 })
                    && Set(actual.map { $0.kp_proc.p_pid }).count == actual.count
                quiescent = complete && actual.allSatisfy({ Int32($0.kp_proc.p_stat) == Int32(SZOMB) })
            }
        }
        let value: [String: Any] = ["hostObservedUptime": ProcessInfo.processInfo.systemUptime, "pollUptime": now, "reservedPID": pid, "reservedPGID": pid,
            "sizeReturn": sizeResult, "sizeErrno": sizeError, "sizeBytes": sizedBytes,
            "readReturn": readResult, "readErrno": readError, "readBytes": bytes,
            "memberStride": stride, "members": rows, "complete": complete, "allZombie": quiescent]
        lastGroupReceipt = value
        recordExit("group-snapshot", ["sizeReturn": sizeResult, "sizeErrno": sizeError,
            "readReturn": readResult, "readErrno": readError, "memberCount": rows.count,
            "complete": complete, "allZombie": quiescent], now: now)
        return GroupReceipt(complete: complete, quiescent: quiescent, error: error, members: rows, value: value)
    }
    private func reapConfirmed(_ group: GroupReceipt, now: Double) throws {
        guard !reaped, leaderExited, group.complete, group.quiescent else {
            throw identityFailure("reap-without-strong-proof", code: 0, observed: pid)
        }
        var status: Int32 = 0; errno = 0
        let waited = waitpid(pid, &status, WNOHANG), code = waited < 0 ? errno : 0
        recordExit("waitpid", ["return": waited, "errno": code, "status": status], now: now)
        guard waited == pid else {
            if waited < 0, code != EINTR { throw identityFailure("waitpid", code: code, observed: waited) }
            return // Pending is not completion; the caller retains this child.
        }
        confirmedGroupReceipt = group.value
        exitCode = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        reaped = true; closeInput()
    }
    /// Handles a second possible live→dead interval between the actual group
    /// snapshot and kill. EPERM/ESRCH gets no success flag unless fresh WNOWAIT
    /// plus complete all-zombie membership and exact waitpid actually succeed.
    private func signalReserved(_ value: Int32, group: GroupReceipt, now: Double) throws -> Bool {
        guard !reaped, group.complete else { throw identityFailure("signal-without-owner-proof", code: 0, observed: pid) }
        errno = 0
        let result = kill(-pid, value), code = result < 0 ? errno : 0
        recordExit("kill-group", ["signal": value, "return": result, "errno": code], now: now)
        if result == 0 { return true }
        if code == ESRCH || code == EPERM {
            try refreshLeaderExit(now: now)
            let fresh = readOwnedGroup(now: now)
            if leaderExited, fresh.quiescent { try reapConfirmed(fresh, now: now); return false }
        }
        throw identityFailure("kill-group", code: code, observed: pid)
    }
    private func identityFailure(_ phase: String, code: Int32, observed: pid_t) -> LiveASRFailure {
        let fields: [String: Any] = ["phase": phase, "errno": code, "observed": observed]
        recordExit("identity-failure", fields)
        // Preserve the first failure even when subsequent polling/reaping rolls
        // it out of the 64-event trace. This one receipt remains bounded.
        if firstIdentityFailureReceipt == nil {
            firstIdentityFailureReceipt = ["role": role, "pid": pid, "reservedPGID": pid,
                "phase": phase, "errno": code, "observed": observed,
                "hostObservedUptime": ProcessInfo.processInfo.systemUptime,
                "events": exitTrace, "lastGroupReceipt": lastGroupReceipt as Any? ?? NSNull()]
        }
        return LiveASRFailure("无法确认识别进程组身份")
    }
    private func recordExit(_ event: String, _ fields: [String: Any], now: Double = ProcessInfo.processInfo.systemUptime) {
        var row = fields; row["event"] = event; row["role"] = role; row["reservedPID"] = pid
        row["hostObservedUptime"] = ProcessInfo.processInfo.systemUptime; row["pollUptime"] = now; exitTrace.append(row)
        if exitTrace.count > 64 {
            let excess = exitTrace.count - 64
            let total = exitTraceDropped.addingReportingOverflow(UInt64(excess))
            if total.overflow { exitTraceOverflowed = true } else { exitTraceDropped = total.partialValue }
            exitTrace.removeFirst(excess)
        }
    }

}

struct LiveASRJSONLines {
    private var pending = Data()
    private var total = 0
    let maximumLine: Int
    let maximumTotal: Int
    mutating func append(_ data: Data) throws -> [Data] {
        guard data.count <= 16384, total <= maximumTotal - data.count else { throw LiveASRFailure("识别事件总量超过上限") }
        total += data.count; var result: [Data] = []
        for byte in data {
            if byte == 10 {
                guard !pending.isEmpty else { throw LiveASRFailure("识别事件为空行") }
                result.append(pending); pending = Data()
            } else {
                guard pending.count + 1 < maximumLine else { throw LiveASRFailure("识别事件单行超过上限") }
                pending.append(byte)
            }
        }
        return result
    }
    /// Only after an actual closed prefix/NEXT_WINDOW ACK. Preserve the real
    /// already-read partial JSON line; resetting must never drop its bytes.
    mutating func resetWindowTotalKeepingPartialLine() { total = pending.count }
    func finish() throws { guard pending.isEmpty else { throw LiveASRFailure("识别事件未完整结束") } }
}
