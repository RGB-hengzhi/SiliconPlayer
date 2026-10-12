import Foundation

struct EPGHTTPPayload: Sendable { let data: Data; let finalURL: URL }

protocol EPGSourceTransport: Sendable {
    func document(at url: URL) async throws -> EPGHTTPPayload
    func clearingCredentials() -> any EPGSourceTransport
}
extension EPGSourceTransport {
    func clearingCredentials() -> any EPGSourceTransport { self }
}
protocol EPGLogoTransport: Sendable {
    func logo(at url: URL, maximumBytes: Int) async throws -> Data
}

enum EPGServiceError: Error, LocalizedError {
    case invalidAddress, httpStatus(Int), tooLarge, invalidImage, imageTooLarge, cacheFailure, tooManyRequests
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请输入不含账号密码的完整 HTTP 或 HTTPS 地址。"
        case .httpStatus(let code): return "服务器返回 HTTP \(code)。"
        case .tooLarge: return "台标文件超过下载上限。"
        case .invalidImage: return "台标不是可读取的图片。"
        case .imageTooLarge: return "台标像素尺寸超过上限。"
        case .cacheFailure: return "台标缓存未能更新。"
        case .tooManyRequests: return "台标请求队列已满，请稍后重试。"
        }
    }
}

enum EPGAddress {
    static func validated(_ address: String) throws -> URL {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !(text.removingPercentEncoding ?? text).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              var value = URLComponents(string: text), ["http", "https"].contains(value.scheme?.lowercased() ?? ""),
              value.host?.isEmpty == false, value.user == nil, value.password == nil,
              value.port == nil || (1...65535).contains(value.port!), value.url != nil else { throw EPGServiceError.invalidAddress }
        value.fragment = nil
        return value.url!
    }
}

/// Logo requests never reuse EPG/channel credentials, cookie or credential stores.
final class AnonymousEPGLogoTransport: NSObject, EPGLogoTransport, URLSessionTaskDelegate, @unchecked Sendable {
    func logo(at url: URL, maximumBytes: Int) async throws -> Data {
        let validated = try EPGAddress.validated(url.absoluteString)
        guard maximumBytes > 0, maximumBytes <= 1024 * 1024 else { throw EPGServiceError.tooLarge }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 25
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: validated)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.setValue("SiliconPlayer/EPG", forHTTPHeaderField: "User-Agent")
        return try await withTaskCancellationHandler {
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request, delegate: self)
            guard let http = response as? HTTPURLResponse else { throw EPGServiceError.invalidImage }
            guard (200...299).contains(http.statusCode) else { throw EPGServiceError.httpStatus(http.statusCode) }
            guard http.expectedContentLength <= maximumBytes else { throw EPGServiceError.tooLarge }
            var output = Data()
            if http.expectedContentLength > 0 { output.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                if output.count % 16_384 == 0 { try Task.checkCancellation() }
                guard output.count < maximumBytes else { throw EPGServiceError.tooLarge }
                output.append(byte)
            }
            try Task.checkCancellation()
            return output
        } onCancel: { session.invalidateAndCancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, let clean = try? EPGAddress.validated(url.absoluteString),
              !(task.originalRequest?.url?.scheme == "https" && clean.scheme == "http") else { completionHandler(nil); return }
        var redirected = request; redirected.url = clean
        for header in ["Authorization", "Proxy-Authorization", "Cookie"] { redirected.setValue(nil, forHTTPHeaderField: header) }
        completionHandler(redirected)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .rejectProtectionSpace, nil)
    }
}

actor EPGAsyncLimiter {
    private var available: Int
    private let maximumWaiting: Int
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(limit: Int, maximumWaiting: Int = 32) {
        available = max(1, limit); self.maximumWaiting = max(0, maximumWaiting)
    }
    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 { available -= 1; return }
        guard waiting.count < maximumWaiting else { throw EPGServiceError.tooManyRequests }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    func release() {
        if waiting.isEmpty { available += 1 }
        else { waiting.removeFirst().1.resume() }
    }
}
