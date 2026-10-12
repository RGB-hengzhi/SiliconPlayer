import Foundation

/// Keeps the original one-decoder/one-service factory contract unchanged.
/// A persistent provider is a different owned object; it never emits a fake
/// input-limit completion to make the old pair controller perform a rollover.
@MainActor protocol LiveASRLinearBackendFactory {
    func reserve(_ request: LiveASROpenRequest,
                 acceptance: LiveASRLinearAcceptanceGate,
                 core: @escaping LiveASRLinearProcessSession.CoreProvider,
                 cues: @escaping LiveASRLinearProcessSession.CueConsumer) throws -> LiveASRLinearProcessSession
}

@MainActor final class LiveASRLinearProcessBackendFactory: LiveASRLinearBackendFactory {
    let workRoot: URL
    let capture: Bool
    let configuration: LiveASRLinearProcessSession.ConfigurationProvider
    let providerSourceSHA256: String
    init(workRoot: URL, capture: Bool = false, providerSourceSHA256: String,
         configuration: @escaping LiveASRLinearProcessSession.ConfigurationProvider) {
        self.workRoot = workRoot; self.capture = capture
        self.configuration = configuration; self.providerSourceSHA256 = providerSourceSHA256
    }
    func reserve(_ request: LiveASROpenRequest,
                 acceptance: LiveASRLinearAcceptanceGate,
                 core: @escaping LiveASRLinearProcessSession.CoreProvider,
                 cues: @escaping LiveASRLinearProcessSession.CueConsumer) throws -> LiveASRLinearProcessSession {
        guard acceptance.isOpen, request.sessionID != request.processID, request.itemSerial > 0,
              request.initialEpoch > 0, request.maximumDecodedSeconds == 120,
              request.continuationStart == nil, !request.preparedContinuationTransport,
              !request.exactContinuousSourceRanges, workRoot.isFileURL,
              workRoot.path.hasPrefix("/") else { throw LiveASRFailure("持续解码保留请求无效") }
        // No spawn/hash/directory writes here. The MainActor registers the
        // returned actor before start() can await tools or allocate children.
        return try LiveASRLinearProcessSession(request: request, workRoot: workRoot,
            acceptance: acceptance,
            capture: capture, expectedProviderSourceHash: providerSourceSHA256,
            configurationProvider: configuration, coreProvider: core, cueConsumer: cues)
    }
}
