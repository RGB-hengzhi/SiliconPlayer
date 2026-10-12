import AppKit
import Combine
import Foundation
import PlayerCore
import UniformTypeIdentifiers

enum NetworkMediaError: LocalizedError {
    case invalidURL
    case credentialsInURL
    case invalidUsername
    case invalidResponse
    case httpStatus(Int)
    case redirectBlocked
    case documentTooLarge
    case invalidDAV(String)
    case invalidResource

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入完整的 HTTP 或 HTTPS 地址。"
        case .credentialsInURL: return "地址不能包含账号或密码，请在下方独立填写凭据。"
        case .invalidUsername: return "HTTP Basic 账号不能包含冒号。"
        case .invalidResponse: return "服务器没有返回有效 HTTP 响应。"
        case .httpStatus(401): return "服务器要求认证，或账号密码不正确（HTTP 401）。"
        case .httpStatus(403): return "服务器拒绝访问该资源（HTTP 403）。"
        case .httpStatus(404): return "服务器上没有此资源（HTTP 404）。"
        case .httpStatus(405): return "服务器不支持 WebDAV PROPFIND（HTTP 405）。"
        case .httpStatus(let status): return "服务器返回 HTTP \(status)。"
        case .redirectBlocked: return "已拒绝把认证凭据发送到不同服务器、端口或协议的重定向地址。请直接填写目标服务器地址。"
        case .documentTooLarge: return "列表超过 8 MiB 上限，已停止读取。"
        case .invalidDAV(let reason): return "WebDAV 响应无效：\(reason)"
        case .invalidResource: return "资源地址无效，或不属于当前 WebDAV 服务器。"
        }
    }
}

struct WebDAVResource: Identifiable, Hashable {
    var id: String { url.absoluteString }
    let url: URL
    let name: String
    let isCollection: Bool
    let size: Int64?
    let modifiedAt: Date?
}

struct WebDAVListing {
    let directoryURL: URL
    let resources: [WebDAVResource]
}

enum HTTPMediaAddress {
    static func validated(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil,
              let parsed = ChannelDocument.resolveReference(trimmed, relativeTo: URL(string: "http://invalid.local/")!),
              let components = URLComponents(url: parsed, resolvingAgainstBaseURL: true), components.url != nil,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false else { throw NetworkMediaError.invalidURL }
        guard components.user == nil, components.password == nil else { throw NetworkMediaError.credentialsInURL }
        guard !trimmed.contains("\n"), !trimmed.contains("\r"), !trimmed.contains("\u{0000}") else { throw NetworkMediaError.invalidURL }
        var clean = components
        clean.fragment = nil
        guard let result = clean.url, result.port == nil || (1...65535).contains(result.port!) else { throw NetworkMediaError.invalidURL }
        return result
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func effectivePort(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased() && effectivePort(lhs) == effectivePort(rhs)
    }

    static func directory(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        if !components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath += "/" }
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        return components.url ?? url
    }

    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardized.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// An isolated ephemeral client for a single operation. HTTP credentials are
/// never placed in a URL, cookie store, credential store, cache, or log.
final class NetworkHTTPClient: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let origin: URL
    private let authorization: String?
    private let onProgress: (@MainActor (Double?) -> Void)?
    private var session: URLSession!
    private let redirectLock = NSLock()
    private var rejectedRedirect = false
    private let downloadLock = NSLock()
    private var downloadContinuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var downloadCancelled = false
    private static let documentLimit = 8 * 1024 * 1024

    init(origin: URL, username: String = "", password: String = "", resourceTimeout: TimeInterval = 25,
         onProgress: (@MainActor (Double?) -> Void)? = nil) throws {
        self.origin = try HTTPMediaAddress.validated(origin.absoluteString)
        guard !username.contains(":") else { throw NetworkMediaError.invalidUsername }
        authorization = username.isEmpty ? nil : "Basic " + Data((username + ":" + password).utf8).base64EncodedString()
        self.onProgress = onProgress
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let callbacks = OperationQueue()
        callbacks.name = "SiliconPlayer.network-callbacks"
        callbacks.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: callbacks)
    }

    func document(at url: URL, method: String = "GET", body: Data? = nil) async throws -> (Data, URL) {
        let request = try request(for: url, method: method, body: body)
        return try await withTaskCancellationHandler {
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request, delegate: self)
            let http = try validate(response)
            if http.expectedContentLength > Self.documentLimit { throw NetworkMediaError.documentTooLarge }
            var data = Data()
            if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                if data.count % 65_536 == 0 { try Task.checkCancellation() }
                guard data.count < Self.documentLimit else { throw NetworkMediaError.documentTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return (data, http.url ?? url)
        } onCancel: { self.session.invalidateAndCancel() }
    }

    /// Uses URLSession's disk-backed download path, avoiding whole-video RAM
    /// buffering. The caller immediately moves the temporary result to cache.
    func download(at url: URL, to destination: URL) async throws {
        let request = try request(for: url, method: "GET")
        try await withTaskCancellationHandler {
            defer { session.invalidateAndCancel() }
            try Task.checkCancellation()
            // The async completion-handler download path suppresses download
            // delegate progress callbacks. Use a delegate task so percentages
            // reach the UI while the body is being written to disk.
            let (temporaryURL, response): (URL, URLResponse) = try await withCheckedThrowingContinuation { continuation in
                downloadLock.lock()
                guard !downloadCancelled else {
                    downloadLock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                downloadContinuation = continuation
                session.downloadTask(with: request).resume()
                downloadLock.unlock()
            }
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            _ = try validate(response)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: destination)
                throw CancellationError()
            }
        } onCancel: { self.cancelDownload() }
    }

    private func cancelDownload() {
        downloadLock.lock()
        downloadCancelled = true
        let continuation = downloadContinuation
        downloadContinuation = nil
        downloadLock.unlock()
        continuation?.resume(throwing: CancellationError())
        session.invalidateAndCancel()
    }

    private func completeDownload(_ result: Result<(URL, URLResponse), Error>) {
        downloadLock.lock()
        let continuation = downloadContinuation
        downloadContinuation = nil
        downloadLock.unlock()
        if let continuation { continuation.resume(with: result) }
        else if case .success(let (file, _)) = result {
            // A cancellation may already have resumed the awaiting caller.
            try? FileManager.default.removeItem(at: file)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response else { throw NetworkMediaError.invalidResponse }
            _ = try validate(response)
            // URLSession owns location only for the duration of this callback.
            // Retain the body on disk before resuming the async caller.
            let retained = FileManager.default.temporaryDirectory.appendingPathComponent("SiliconPlayerNetwork-\(UUID().uuidString).download")
            try FileManager.default.moveItem(at: location, to: retained)
            completeDownload(.success((retained, response)))
        } catch { completeDownload(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task is URLSessionDownloadTask else { return }
        if let error { completeDownload(.failure(error)) }
        else { completeDownload(.failure(NetworkMediaError.invalidResponse)) }
    }

    private func request(for url: URL, method: String, body: Data? = nil) throws -> URLRequest {
        let validated = try HTTPMediaAddress.validated(url.absoluteString)
        if authorization != nil, !HTTPMediaAddress.sameOrigin(validated, origin) { throw NetworkMediaError.invalidResource }
        var request = URLRequest(url: validated, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("SiliconPlayer/0.2", forHTTPHeaderField: "User-Agent")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if method == "PROPFIND" {
            request.setValue("1", forHTTPHeaderField: "Depth")
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/xml, text/xml", forHTTPHeaderField: "Accept")
        }
        return request
    }

    private func validate(_ response: URLResponse) throws -> HTTPURLResponse {
        redirectLock.lock()
        let redirected = rejectedRedirect
        redirectLock.unlock()
        if redirected { throw NetworkMediaError.redirectBlocked }
        guard let http = response as? HTTPURLResponse else { throw NetworkMediaError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw NetworkMediaError.httpStatus(http.statusCode) }
        return http
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let proposedURL = request.url, let target = try? HTTPMediaAddress.validated(proposedURL.absoluteString) else {
            completionHandler(nil)
            return
        }
        if authorization != nil, !HTTPMediaAddress.sameOrigin(target, origin) {
            redirectLock.lock(); rejectedRedirect = true; redirectLock.unlock()
            completionHandler(nil)
            return
        }
        var redirected = request
        redirected.url = target
        if authorization != nil { redirected.setValue(authorization, forHTTPHeaderField: "Authorization") }
        else { redirected.setValue(nil, forHTTPHeaderField: "Authorization") }
        if task.originalRequest?.httpMethod == "PROPFIND" {
            redirected.httpMethod = "PROPFIND"
            redirected.httpBody = task.originalRequest?.httpBody
            redirected.setValue("1", forHTTPHeaderField: "Depth")
            redirected.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            // Basic is sent explicitly. Do not ask Keychain or persist a
            // credential supplied by the HTTP authentication machinery.
            completionHandler(.rejectProtectionSpace, nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil
        Task { @MainActor [onProgress] in onProgress?(fraction) }
    }

}

/// RFC 4918 multistatus parsing. Only successful DAV: propstat properties are
/// merged. External entities and properties from foreign namespaces are ignored.
final class WebDAVDocumentParser: NSObject, XMLParserDelegate {
    private struct Node { var name: String; var namespace: String?; var text = "" }
    private struct Properties {
        var status: Int?
        var name: String?
        var size: Int64?
        var date: Date?
        var isCollection: Bool?
    }
    private struct Response {
        var href = ""
        var status: Int?
        var successful = false
        var properties = Properties()
    }
    private let baseURL: URL
    private var nodes: [Node] = []
    private var response: Response?
    private var propstat: Properties?
    private var resources: [WebDAVResource] = []
    private var isMultistatus = false
    private var parseFailure: String?

    init(baseURL: URL) { self.baseURL = baseURL }

    static func parse(_ data: Data, baseURL: URL) throws -> WebDAVListing {
        let delegate = WebDAVDocumentParser(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.isMultistatus, delegate.parseFailure == nil else {
            throw NetworkMediaError.invalidDAV(delegate.parseFailure ?? parser.parserError?.localizedDescription ?? "缺少 DAV:multistatus。")
        }
        let directory = HTTPMediaAddress.directory(baseURL)
        var known = Set<URL>()
        let children = delegate.resources.filter {
            HTTPMediaAddress.normalizedPath($0.url) != HTTPMediaAddress.normalizedPath(directory) && known.insert($0.url).inserted
        }.sorted {
            if $0.isCollection != $1.isCollection { return $0.isCollection }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return WebDAVListing(directoryURL: directory, resources: children)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let parent = nodes.last
        nodes.append(Node(name: elementName, namespace: namespaceURI))
        guard namespaceURI == "DAV:" else { return }
        if elementName == "multistatus", nodes.count == 1 { isMultistatus = true }
        else if elementName == "response", parent?.name == "multistatus", parent?.namespace == "DAV:" { response = Response() }
        else if elementName == "propstat", parent?.name == "response", parent?.namespace == "DAV:", response != nil { propstat = Properties() }
        else if elementName == "resourcetype", parent?.name == "prop", parent?.namespace == "DAV:", propstat != nil { propstat?.isCollection = false }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let current = nodes.last, current.namespace == "DAV:",
              ["href", "status", "displayname", "getcontentlength", "getlastmodified"].contains(current.name) else { return }
        let index = nodes.count - 1
        if nodes[index].text.utf8.count + string.utf8.count > 65_536 {
            parseFailure = "单个属性过长。"
            parser.abortParsing()
        } else { nodes[index].text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let node = nodes.popLast(), namespaceURI == "DAV:" else { return }
        let parent = nodes.last
        let grandparent = nodes.dropLast().last
        let propertyParent = parent?.name == "prop" && parent?.namespace == "DAV:"
            && grandparent?.name == "propstat" && grandparent?.namespace == "DAV:"
        let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href" where parent?.name == "response" && parent?.namespace == "DAV:": response?.href = text
        case "status" where parent?.name == "propstat" && parent?.namespace == "DAV:": propstat?.status = Self.statusCode(text)
        case "status" where parent?.name == "response" && parent?.namespace == "DAV:": response?.status = Self.statusCode(text)
        case "displayname" where propertyParent: propstat?.name = text.isEmpty ? nil : text
        case "getcontentlength" where propertyParent:
            if let size = Int64(text), size >= 0 { propstat?.size = size }
        case "getlastmodified" where propertyParent: propstat?.date = Self.httpDate(text)
        case "collection" where parent?.name == "resourcetype" && parent?.namespace == "DAV:"
            && grandparent?.name == "prop" && grandparent?.namespace == "DAV:": propstat?.isCollection = true
        case "propstat" where parent?.name == "response" && parent?.namespace == "DAV:":
            if let values = propstat, let status = values.status, (200...299).contains(status) {
                response?.successful = true
                if let name = values.name { response?.properties.name = name }
                if let size = values.size { response?.properties.size = size }
                if let date = values.date { response?.properties.date = date }
                if let directory = values.isCollection { response?.properties.isCollection = directory }
            }
            propstat = nil
        case "response" where parent?.name == "multistatus" && parent?.namespace == "DAV:":
            if let response { append(response) }
            response = nil
        default: break
        }
    }

    private func append(_ response: Response) {
        if let status = response.status, !(200...299).contains(status) { return }
        guard response.successful || response.status.map({ (200...299).contains($0) }) == true,
              !response.href.isEmpty, let resolved = ChannelDocument.resolveReference(response.href, relativeTo: baseURL),
              let url = try? HTTPMediaAddress.validated(resolved.absoluteString), HTTPMediaAddress.sameOrigin(url, baseURL) else { return }
        let isCollection = response.properties.isCollection ?? url.hasDirectoryPath
        let normalized = isCollection ? HTTPMediaAddress.directory(url) : url
        let name = response.properties.name ?? (normalized.lastPathComponent.isEmpty ? "/" : normalized.lastPathComponent)
        resources.append(WebDAVResource(url: normalized, name: name, isCollection: isCollection, size: response.properties.size, modifiedAt: response.properties.date))
    }

    private static func statusCode(_ value: String) -> Int? {
        let components = value.split(whereSeparator: \.isWhitespace)
        guard components.count >= 2, components[0].uppercased().hasPrefix("HTTP/") else { return nil }
        return Int(components[1])
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

@MainActor
final class NetworkMediaService: ObservableObject {
    @Published var playlistAddress = ""
    @Published var webDAVAddress = ""
    @Published var username = ""
    @Published var password = ""
    @Published private(set) var channels: [MediaChannel] = []
    @Published private(set) var resources: [WebDAVResource] = []
    @Published private(set) var currentDirectoryURL: URL?
    @Published private(set) var isBusy = false
    @Published private(set) var status = "输入 HTTP(S) 频道列表或 WebDAV 地址后连接。"
    @Published private(set) var downloadProgress: Double?
    @Published var error: String?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()

    var usesCredentials: Bool { !username.isEmpty }
    var channelGroups: [String] { Set(channels.map(\.group)).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    var parentDirectoryURL: URL? {
        guard let currentDirectoryURL, HTTPMediaAddress.normalizedPath(currentDirectoryURL) != "/" else { return nil }
        return HTTPMediaAddress.directory(currentDirectoryURL.deletingLastPathComponent())
    }

    func loadChannels() {
        guard !isBusy else { return }
        let address = playlistAddress
        let credentials = (username, password)
        begin("正在读取频道列表…") { token in
            let url = try HTTPMediaAddress.validated(address)
            let client = try NetworkHTTPClient(origin: url, username: credentials.0, password: credentials.1)
            let (data, responseURL) = try await client.document(at: url)
            let document = try ChannelDocument.parse(data: data, baseURL: responseURL)
            try Task.checkCancellation()
            guard self.operationID == token else { return }
            self.channels = document.channels
            self.status = "已读取 \(document.channels.count) 个频道，图标地址仅作为元数据保存。"
        }
    }

    func browse(_ directory: URL? = nil) {
        guard !isBusy else { return }
        let address = directory?.absoluteString ?? webDAVAddress
        let credentials = (username, password)
        begin("正在读取 WebDAV 目录…") { token in
            let url = HTTPMediaAddress.directory(try HTTPMediaAddress.validated(address))
            let client = try NetworkHTTPClient(origin: url, username: credentials.0, password: credentials.1)
            let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
            """
            let (data, responseURL) = try await client.document(at: url, method: "PROPFIND", body: Data(xml.utf8))
            let listing = try WebDAVDocumentParser.parse(data, baseURL: responseURL)
            try Task.checkCancellation()
            guard self.operationID == token else { return }
            self.currentDirectoryURL = listing.directoryURL
            self.webDAVAddress = listing.directoryURL.absoluteString
            self.resources = listing.resources
            self.status = "已读取 \(listing.resources.count) 个文件和文件夹。"
        }
    }

    func download(_ resource: WebDAVResource, onReady: @escaping @MainActor (URL) -> Void) {
        guard !isBusy, !resource.isCollection else { return }
        let credentials = (username, password)
        let current = currentDirectoryURL
        begin("先下载再播放：\(resource.name)", timeoutMessage: "下载等待新数据超时，或达到 24 小时任务时限，已停止。可检查连接后重试。") { [self] token in
            guard let current, HTTPMediaAddress.sameOrigin(resource.url, current) else { throw NetworkMediaError.invalidResource }
            let cache = Self.cacheDirectory
            let filename = Self.cacheFilename(resource.url)
            guard filename != "." && filename != ".." else { throw NetworkMediaError.invalidResource }
            let downloadDirectory = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let destination = downloadDirectory.appendingPathComponent(filename)
            let client = try NetworkHTTPClient(origin: current, username: credentials.0, password: credentials.1, resourceTimeout: 24 * 3600, onProgress: { [weak self] progress in
                guard let self, self.operationID == token else { return }
                self.downloadProgress = progress
            })
            do {
                try await client.download(at: resource.url, to: destination)
                try Task.checkCancellation()
                guard self.operationID == token else { try? FileManager.default.removeItem(at: downloadDirectory); return }
                self.status = "已下载到本机：\(resource.name)"
                self.downloadProgress = 1
                onReady(destination)
            } catch {
                try? FileManager.default.removeItem(at: downloadDirectory)
                throw error
            }
        }
    }

    func importLocalChannels() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "读取本地频道列表"
        panel.allowedContentTypes = ["m3u", "m3u8", "pls"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            channels = try ChannelDocument.read(from: url).channels
            error = nil
            status = "已读取 \(channels.count) 个本地频道。"
        } catch { self.error = error.localizedDescription }
    }

    func exportChannels(_ values: [MediaChannel]? = nil) {
        let exported = values ?? channels
        guard !exported.isEmpty, !isBusy else { return }
        let panel = NSSavePanel()
        panel.title = "保存频道列表为 M3U8"
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u8") ?? .plainText]
        panel.nameFieldStringValue = "SiliconPlayer-channels.m3u8"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ChannelDocument(channels: exported).writeM3U8(to: url)
            error = nil
            status = "已保存 \(exported.count) 个频道，可从播放器的导入播放列表入口读取。"
        } catch { self.error = error.localizedDescription }
    }

    func cancel() {
        operationID = UUID()
        operation?.cancel()
        operation = nil
        isBusy = false
        downloadProgress = nil
        status = "操作已取消。"
    }

    func dismiss() {
        cancel()
        username = ""
        password = ""
    }

    static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiliconPlayer/RemoteCache", isDirectory: true)
    }

    private func begin(_ message: String, timeoutMessage: String = "目录或频道请求超过 25 秒，已停止。请检查服务器地址与连接。",
                       action: @escaping @MainActor (UUID) async throws -> Void) {
        operation?.cancel()
        let token = UUID()
        operationID = token
        isBusy = true
        error = nil
        downloadProgress = nil
        status = message
        operation = Task {
            do { try await action(token) }
            catch {
                guard self.operationID == token else { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled { self.status = "操作已取消。" }
                else if (error as? URLError)?.code == .timedOut { self.error = timeoutMessage }
                else { self.error = error.localizedDescription }
            }
            guard self.operationID == token else { return }
            self.isBusy = false
            self.operation = nil
        }
    }

    private static func cacheFilename(_ url: URL) -> String {
        let raw = url.lastPathComponent.isEmpty ? "remote-media" : url.lastPathComponent
        let safe = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if safe.utf8.count <= 180 { return safe.isEmpty ? "remote-media" : safe }
        let extensionName = url.pathExtension
        var prefix = ""
        for character in (safe as NSString).deletingPathExtension {
            if (prefix + String(character)).utf8.count > 150 { break }
            prefix.append(character)
        }
        return extensionName.isEmpty ? prefix : prefix + "." + String(extensionName.prefix(20))
    }
}
