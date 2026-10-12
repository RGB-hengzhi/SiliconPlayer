import Foundation

/// XMLTV uses the shared bounded, isolated HTTP client. Session credentials
/// are held in memory and cleared when the EPG window closes.
struct ProductionEPGSourceTransport: EPGSourceTransport {
    let username: String
    let password: String
    init(username: String = "", password: String = "") { self.username = username; self.password = password }
    func clearingCredentials() -> any EPGSourceTransport { ProductionEPGSourceTransport() }
    func document(at url: URL) async throws -> EPGHTTPPayload {
        let clean = try HTTPMediaAddress.validated(url.absoluteString)
        let client = try NetworkHTTPClient(origin: clean, username: username, password: password)
        let (data, responseURL) = try await client.document(at: clean)
        return EPGHTTPPayload(data: data, finalURL: responseURL)
    }
}
