import CryptoKit
import Darwin
import Foundation

/// Docs draft. Expensive hashes run in a cancellable detached utility task.
/// No spawn, network download, HOME override or development-path fallback.
enum LiveASRToolsResolver {
    private static let profile = "zipformer-zh-int8-2025-06-30/sherpa-1.13.8/cpu2/spcm-v1"
    private static let pcmSource = "b5c433c24d2ef4605b71ecd0f394f2fb6f22eda3fc8b0b3ed263e4ca76a79d43"
    private static let recognizerSource = "3fe36bf2c56766eca53ad5cbc539e34929fadd7623aa86dfa346d025864e6388"
    private static let knownModels: [String: (Int64, String)] = [
        "encoder.int8.onnx": (161_141_793, "5ac51e27981bb4dab01bb9be4958453ba50c3b61c063ddda0eab23fd3671aa4f"),
        "decoder.onnx": (5_165_083, "06522ad63cec0fdf6809f4e1db9bb4f7d710c34582e3b35db62ac60eccafac7e"),
        "joiner.int8.onnx": (1_033_416, "b34584dc6f561089e1d747fedebb3765f2caa72c927ef54d7ca55e5ae40a814b"),
        "tokens.txt": (20_628, "6193c7ea1c96d0d9a1e9652789b40d13a8a913b434a5451e93158f5a09fd6652")
    ]
    private static let pcmLibraries = [
        "libSvtAv1Enc.4.dylib", "libavcodec.63.dylib", "libavformat.63.dylib", "libavutil.61.dylib",
        "libbrotlicommon.1.dylib", "libbrotlidec.1.dylib", "libbrotlienc.1.dylib", "libdav1d.7.dylib",
        "libjxl.0.11.dylib", "libjxl_cms.0.11.dylib", "libjxl_threads.0.11.dylib", "libogg.0.dylib",
        "libsharpyuv.0.dylib", "libsoxr.0.dylib", "libspeex.1.dylib", "libswresample.7.dylib",
        "libvorbis.0.dylib", "libvorbisenc.2.dylib", "libwebp.7.dylib", "libwebpmux.3.dylib"
    ]
    private static let serviceLibraries = ["libsherpa-onnx-c-api.dylib", "libsherpa-onnx-cxx-api.dylib", "libonnxruntime.dylib"]

    static func resolve(bundleURL: URL, modelDirectory: URL? = nil) async throws -> LiveASRToolsConfiguration {
        guard bundleURL.isFileURL, let bundle = Bundle(url: bundleURL) else {
            throw LiveASRFailure("实时字幕需要有效的本地应用包")
        }
        return try await resolve(bundle: bundle, modelDirectory: modelDirectory)
    }

    static func resolve(bundle: Bundle = .main, modelDirectory: URL? = nil) async throws -> LiveASRToolsConfiguration {
        guard let resources = bundle.resourceURL else { throw LiveASRFailure("应用内缺少实时字幕工具目录") }
        let root = resources.standardizedFileURL
        let selected = modelDirectory?.standardizedFileURL
        let task = Task.detached(priority: .utility) {
            try resolveFiles(resources: root, selectedModelDirectory: selected)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private struct FileRow: Decodable {
        let path: String
        let bytes: Int64
        let sha256: String
        let ABI: ABIRecord?
    }
    private struct ABIRecord: Decodable {
        let architecture: String
        let loads: [String]
        let rpaths: [String]
        let minimumOS: [String]
    }
    private struct RuntimeManifest: Decodable {
        let schema: Int
        let profileID: String
        let pcmHelperSourceSHA256: String
        let recognizerHelperSourceSHA256: String
        let decoderLibraryABI: String
        let files: [FileRow]
        let features: Features
        let `protocol`: WireProtocol
        struct WireProtocol: Decodable { let name: String; let version: Int; let headerBytes: Int }
        struct Features: Decodable {
            let gracefulInputLimit: Capability
            let firstRealBlockHold: Capability?
            let exactSourceRange: Capability?
            struct Capability: Decodable { let verified: Bool; let evidence: FileRow? }
        }
    }
    private struct ModelManifest: Decodable {
        let schema: Int
        let profileID: String
        let files: [FileRow]
        let configuration: Configuration
        struct Configuration: Decodable {
            let sampleRate: Int; let featureDimension: Int; let threads: Int
            let provider: String; let modelingUnit: String; let decodingMethod: String
        }
    }
    private struct GracefulEvidence: Decodable {
        let schema: Int; let status: String
        let pcmBinarySHA256: String; let pcmSourceSHA256: String
        let inputsUnchanged: Bool; let driverNaturalExitCode: Int; let forcedCleanup: Bool
        let defaults: Defaults; let gracefulCases: [CaseResult]
        let firstBlockHoldCases: [CaseResult]?
        let rangeCases: [CaseResult]?
        struct Defaults: Decodable { let uniqueCases: Int; let passed: Int; let failed: Int }
        struct CaseResult: Decodable { let id: String; let passed: Bool }
    }

    private static func resolveFiles(resources: URL, selectedModelDirectory: URL?) throws -> LiveASRToolsConfiguration {
        try Task.checkCancellation()
        let contents = resources.deletingLastPathComponent()
        let asr = try child(root: resources, relative: "LiveASR")
        let runtimeURL = try child(root: asr, relative: "runtime-manifest.json")
        let runtime: RuntimeManifest = try decode(runtimeURL)
        guard runtime.schema == 1, runtime.profileID == profile,
              runtime.pcmHelperSourceSHA256 == pcmSource, runtime.recognizerHelperSourceSHA256 == recognizerSource,
              runtime.decoderLibraryABI == "avformat63/avcodec63/avutil61/swresample7",
              runtime.protocol.name == "SPCM", runtime.protocol.version == 1, runtime.protocol.headerBytes == 112 else {
            throw LiveASRFailure("实时字幕工具版本或流协议不匹配")
        }
        let pcmPath = "Resources/LiveASR/Helpers/media-pcm-pts"
        let recognizerPath = "Resources/LiveASR/Helpers/online-asr-service"
        var expectedPaths = Set(pcmLibraries.map { "Frameworks/" + $0 })
        expectedPaths.formUnion(serviceLibraries.map { "Resources/LiveASR/Helpers/runtime-libs/" + $0 })
        expectedPaths.formUnion([pcmPath, recognizerPath, "Resources/Tools/ffprobe"])
        guard runtime.files.count == expectedPaths.count, Set(runtime.files.map(\.path)) == expectedPaths else {
            throw LiveASRFailure("实时字幕工具依赖清单缺失、重复或含未知文件")
        }
        for row in runtime.files {
            let url = try child(root: contents, relative: row.path)
            try verify(url, row: row, maximum: 128 * 1024 * 1024, requireMachO: true)
            guard let abi = row.ABI, abi.architecture == "arm64", !abi.minimumOS.isEmpty,
                  abi.loads.allSatisfy({ $0.hasPrefix("@rpath/") || $0.hasPrefix("@loader_path/")
                    || $0.hasPrefix("/usr/lib/") || $0.hasPrefix("/System/Library/") }) else {
                throw LiveASRFailure("实时字幕依赖含不支持的架构或开发路径")
            }
            if row.path == pcmPath && abi.rpaths != ["@executable_path/../../../Frameworks"] {
                throw LiveASRFailure("音频解码工具的依赖路径不匹配")
            }
            if row.path == recognizerPath && abi.rpaths != ["@executable_path/runtime-libs"] {
                throw LiveASRFailure("语音识别工具的依赖路径不匹配")
            }
        }
        let pcm = try child(root: contents, relative: pcmPath)
        let recognizer = try child(root: contents, relative: recognizerPath)
        let ffprobe = try child(root: resources, relative: "Tools/ffprobe")
        guard access(pcm.path, X_OK) == 0, access(recognizer.path, X_OK) == 0, access(ffprobe.path, X_OK) == 0 else {
            throw LiveASRFailure("实时字幕工具不能执行，请重新构建或安装应用")
        }
        let modelRoot: URL
        if let selectedModelDirectory { modelRoot = selectedModelDirectory }
        else { modelRoot = try child(root: asr, relative: "Model") }
        guard modelRoot.isFileURL, !modelRoot.path.contains("\0") else { throw LiveASRFailure("请选择本地模型目录") }
        let modelURL = try child(root: modelRoot, relative: "model-manifest.json")
        let model: ModelManifest = try decode(modelURL)
        let c = model.configuration
        guard model.schema == 1, model.profileID == profile, model.files.count == knownModels.count,
              Set(model.files.map(\.path)) == Set(knownModels.keys),
              c.sampleRate == 16000, c.featureDimension == 80, c.threads == 2, c.provider == "cpu",
              c.modelingUnit == "cjkchar", c.decodingMethod == "greedy_search" else {
            throw LiveASRFailure("模型文件或识别配置不匹配")
        }
        for row in model.files {
            guard let known = knownModels[row.path], row.bytes == known.0, row.sha256 == known.1 else {
                throw LiveASRFailure("该模型不是已验证的中文流式模型")
            }
            try verify(try child(root: modelRoot, relative: row.path), row: row,
                       maximum: 192 * 1024 * 1024, requireMachO: false)
        }
        var supportsLimit = false
        let capability = runtime.features.gracefulInputLimit
        if capability.verified {
            guard let row = capability.evidence, row.path == "graceful-limit-evidence.json" else {
                throw LiveASRFailure("识别输入限额的实际验证记录缺失")
            }
            let url = try child(root: asr, relative: row.path)
            try verify(url, row: row, maximum: 2 * 1024 * 1024, requireMachO: false)
            let evidence: GracefulEvidence = try decode(url)
            let ids: Set<String> = ["one-second-whole-chunk", "exact-one-second-eof", "invalid-limits",
                "resampler-drain-limit", "source-mutation", "cancel-backpressure"]
            guard evidence.schema == 1, evidence.status == "passed", evidence.pcmSourceSHA256 == pcmSource,
                  evidence.pcmBinarySHA256 == runtime.files.first(where: { $0.path == pcmPath })?.sha256,
                  evidence.inputsUnchanged, evidence.driverNaturalExitCode == 0, !evidence.forcedCleanup,
                  evidence.defaults.uniqueCases == 13, evidence.defaults.passed == 13, evidence.defaults.failed == 0,
                  evidence.gracefulCases.count == ids.count, Set(evidence.gracefulCases.map(\.id)) == ids,
                  evidence.gracefulCases.allSatisfy(\.passed) else {
                throw LiveASRFailure("识别输入限额未通过完整的实际验证")
            }
            supportsLimit = true
        } else if capability.evidence != nil {
            throw LiveASRFailure("识别工具限额清单状态不一致")
        }
        var supportsFirstBlock = false
        if let first = runtime.features.firstRealBlockHold {
            if first.verified {
                guard supportsLimit, let row = first.evidence, row.path == "graceful-limit-evidence.json" else {
                    throw LiveASRFailure("短 WAV 首块握手的实际验证记录缺失")
                }
                let url = try child(root: asr, relative: row.path)
                try verify(url, row: row, maximum: 2 * 1024 * 1024, requireMachO: false)
                let evidence: GracefulEvidence = try decode(url)
                let ids: Set<String> = ["short-one-sample-hold", "short-one-block-seek", "hold-cancel",
                    "hold-explicit-limit", "hold-control-negative", "hold-invalid-flag"]
                guard evidence.schema == 1, evidence.status == "passed", evidence.pcmSourceSHA256 == pcmSource,
                      evidence.pcmBinarySHA256 == runtime.files.first(where: { $0.path == pcmPath })?.sha256,
                      evidence.inputsUnchanged, evidence.driverNaturalExitCode == 0, !evidence.forcedCleanup,
                      let cases = evidence.firstBlockHoldCases, cases.count == ids.count,
                      Set(cases.map(\.id)) == ids, cases.allSatisfy(\.passed) else {
                    throw LiveASRFailure("短 WAV 首块握手未通过完整的实际验证")
                }
                supportsFirstBlock = true
            } else if first.evidence != nil {
                throw LiveASRFailure("短 WAV 握手清单状态不一致")
            }
        }
        var supportsRange = false
        if let range = runtime.features.exactSourceRange {
            if range.verified {
                guard supportsLimit, supportsFirstBlock, let row = range.evidence,
                      row.path == "graceful-limit-evidence.json" else {
                    throw LiveASRFailure("精确源区间的实际验证记录缺失")
                }
                let url = try child(root: asr, relative: row.path)
                try verify(url, row: row, maximum: 2 * 1024 * 1024, requireMachO: false)
                let evidence: GracefulEvidence = try decode(url)
                let ids: Set<String> = ["aac-fresh-origin-exact-range", "pcm-exact-range-controls"]
                guard evidence.schema == 1, evidence.status == "passed", evidence.pcmSourceSHA256 == pcmSource,
                      evidence.pcmBinarySHA256 == runtime.files.first(where: { $0.path == pcmPath })?.sha256,
                      evidence.inputsUnchanged, evidence.driverNaturalExitCode == 0, !evidence.forcedCleanup,
                      let cases = evidence.rangeCases, cases.count == ids.count,
                      Set(cases.map(\.id)) == ids, cases.allSatisfy(\.passed) else {
                    throw LiveASRFailure("精确源区间未通过完整的实际验证")
                }
                supportsRange = true
            } else if range.evidence != nil {
                throw LiveASRFailure("精确源区间清单状态不一致")
            }
        }
        try Task.checkCancellation()
        return LiveASRToolsConfiguration(pcmDecoderURL: pcm, recognizerServiceURL: recognizer, ffprobeURL: ffprobe,
            modelDirectory: modelRoot, encoderModelURL: try child(root: modelRoot, relative: "encoder.int8.onnx"),
            decoderModelURL: try child(root: modelRoot, relative: "decoder.onnx"),
            joinerModelURL: try child(root: modelRoot, relative: "joiner.int8.onnx"),
            tokensURL: try child(root: modelRoot, relative: "tokens.txt"), runtimeManifestURL: runtimeURL,
            modelManifestURL: modelURL, profileID: profile, pcmHelperSourceSHA256: pcmSource,
            supportsGracefulInputLimit: supportsLimit, supportsFirstBlockHold: supportsFirstBlock, supportsExactSourceRange: supportsRange)
    }

    private static func child(root: URL, relative: String) throws -> URL {
        guard root.isFileURL, !root.path.contains("\0"), !relative.isEmpty,
              !root.pathComponents.contains(where: { $0.hasPrefix("._") }),
              !relative.hasPrefix("/"), !relative.contains("\0") else { throw LiveASRFailure("工具路径无效") }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix("._") }) else { throw LiveASRFailure("工具路径越界") }
        var cursor = root.standardizedFileURL
        var initial = stat()
        guard lstat(cursor.path, &initial) == 0, initial.st_mode & S_IFMT == S_IFDIR else {
            throw LiveASRFailure("实时字幕工具或模型目录不存在")
        }
        for part in parts {
            cursor.appendPathComponent(String(part))
            var attributes = stat()
            guard lstat(cursor.path, &attributes) == 0, attributes.st_mode & S_IFMT != S_IFLNK else {
                throw LiveASRFailure("工具文件缺失或含符号链接")
            }
        }
        return cursor
    }

    private static func decode<T: Decodable>(_ url: URL) throws -> T {
        let data = try readFile(url, maximum: 2 * 1024 * 1024, collect: true).data
        var keys = JSONKeyChecker(bytes: Array(data))
        try keys.check()
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw LiveASRFailure("实时字幕清单格式无效：\(url.lastPathComponent)") }
    }

    /// Bounded structural pass rejects duplicate decoded keys, including escaped
    /// aliases. JSONDecoder then validates primitive syntax and typed fields.
    private struct JSONKeyChecker {
        let bytes: [UInt8]
        var index = 0
        mutating func check() throws {
            try value(depth: 0); whitespace()
            guard index == bytes.count else { throw LiveASRFailure("清单含多余 JSON 数据") }
        }
        mutating func whitespace() {
            while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func expect(_ byte: UInt8) throws {
            whitespace()
            guard index < bytes.count, bytes[index] == byte else { throw LiveASRFailure("清单 JSON 结构无效") }
            index += 1
        }
        mutating func string() throws -> String {
            whitespace(); let start = index; try expect(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 {
                    guard index - start <= 65_536 else { throw LiveASRFailure("清单文字超过范围") }
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                    catch { throw LiveASRFailure("清单字符串编码无效") }
                }
                if byte == 92 {
                    guard index < bytes.count else { throw LiveASRFailure("清单转义不完整") }
                    index += 1
                }
            }
            throw LiveASRFailure("清单字符串不完整")
        }
        mutating func value(depth: Int) throws {
            guard depth <= 24 else { throw LiveASRFailure("清单嵌套超过范围") }
            whitespace()
            guard index < bytes.count else { throw LiveASRFailure("清单 JSON 不完整") }
            if bytes[index] == 123 {
                index += 1; whitespace(); var seen = Set<String>()
                if index < bytes.count && bytes[index] == 125 { index += 1; return }
                while true {
                    let key = try string()
                    guard seen.insert(key).inserted, seen.count <= 1024 else { throw LiveASRFailure("清单键重复或超出范围") }
                    try expect(58); try value(depth: depth + 1); whitespace()
                    if index < bytes.count && bytes[index] == 125 { index += 1; return }
                    try expect(44)
                }
            } else if bytes[index] == 91 {
                index += 1; whitespace(); var count = 0
                if index < bytes.count && bytes[index] == 93 { index += 1; return }
                while true {
                    count += 1
                    guard count <= 4096 else { throw LiveASRFailure("清单数组超过范围") }
                    try value(depth: depth + 1); whitespace()
                    if index < bytes.count && bytes[index] == 93 { index += 1; return }
                    try expect(44)
                }
            } else if bytes[index] == 34 {
                _ = try string()
            } else {
                let start = index
                while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                guard index > start else { throw LiveASRFailure("清单值无效") }
            }
        }
    }

    private static func verify(_ url: URL, row: FileRow, maximum: Int64, requireMachO: Bool) throws {
        guard row.bytes > 0, row.bytes <= maximum,
              row.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw LiveASRFailure("实时字幕文件校验信息无效")
        }
        let result = try readFile(url, maximum: maximum, collect: false)
        guard result.bytes == row.bytes, result.sha256 == row.sha256 else {
            throw LiveASRFailure("实时字幕文件已变更：\(url.lastPathComponent)")
        }
        if requireMachO {
            let p = Array(result.prefix)
            guard p.count >= 8, Array(p[0..<4]) == [0xcf, 0xfa, 0xed, 0xfe],
                  Array(p[4..<8]) == [0x0c, 0x00, 0x00, 0x01] else { throw LiveASRFailure("实时字幕工具需要 Apple Silicon 架构") }
        }
    }

    private struct ReadResult { let bytes: Int64; let sha256: String; let prefix: Data; let data: Data }
    private static func readFile(_ url: URL, maximum: Int64, collect: Bool) throws -> ReadResult {
        try Task.checkCancellation()
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LiveASRFailure("无法读取实时字幕文件：\(url.lastPathComponent)") }
        defer { _ = Darwin.close(descriptor) }
        var before = stat(); var filesystem = statfs()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= maximum, fstatfs(descriptor, &filesystem) == 0,
              filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw LiveASRFailure("请选择有效的本地实时字幕文件") }
        var hash = SHA256(); var total: Int64 = 0; var prefix = Data(); var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw LiveASRFailure("实时字幕文件读取失败") }
            if count == 0 { break }
            total += Int64(count)
            guard total <= maximum else { throw LiveASRFailure("实时字幕文件超出大小限制") }
            let block = Data(buffer.prefix(count)); hash.update(data: block)
            if prefix.count < 16 { prefix.append(block.prefix(16 - prefix.count)) }
            if collect { data.append(block) }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, total == before.st_size,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw LiveASRFailure("校验时文件发生变化，请重试") }
        return ReadResult(bytes: total, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), prefix: prefix, data: data)
    }
}
