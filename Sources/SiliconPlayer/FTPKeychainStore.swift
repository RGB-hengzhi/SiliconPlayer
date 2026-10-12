import Foundation
import Security

/// Explicit generic-password records for this product only. No URL credential
/// storage, browser cookies, global SSH files, or other app's items are read.
/// These routines are synchronous native calls and are run on the FTP worker.
/// A UI-fail query is requested. The SDK explicitly limits this guarantee for
/// legacy macOS keychain items: an OS access prompt may still appear. This code
/// never silently claims a query succeeded or that a blocked call was released.
struct FTPKeychainStore: Sendable {
    private let service: String
    init() { service = "local.siliconplayer.explicit-ftp.v1" }
    /// Test-only scope is required from a native check caller; product UI never
    /// chooses a test service or accepts a user-provided arbitrary service.
    init(testScope: UUID) { service = "local.siliconplayer.ftp-native-test." + testScope.uuidString }
    static func validate(username: String, password: String) throws {
        guard !username.isEmpty, username.utf8.count <= 1024, password.utf8.count <= 4096,
              !FTPDirectoryAddress.hasControls(username), !FTPDirectoryAddress.hasControls(password) else { throw FTPBrowserFailure.invalidCredentials }
    }
    private func query(_ address: FTPDirectoryAddress, username: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: address.keychainAccount(username: username),
         kSecAttrSynchronizable as String: false,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    func save(_ address: FTPDirectoryAddress, username: String, password: String) throws {
        try Self.validate(username: username, password: password)
        let q = query(address, username: username)
        let value = Data(password.utf8)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = q; insert[kSecValueData as String] = value
            insert[kSecAttrLabel as String] = "SiliconPlayer explicit FTP credential"
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw FTPBrowserFailure.keychain(status) }
    }
    func read(_ address: FTPDirectoryAddress, username: String) throws -> String? {
        try Self.validate(username: username, password: "")
        var q = query(address, username: username)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw FTPBrowserFailure.keychain(status) }
        guard let data = value as? Data, data.count <= 4096, let password = String(data: data, encoding: .utf8) else { throw FTPBrowserFailure.invalidCredentials }
        try Self.validate(username: username, password: password); return password
    }
    func delete(_ address: FTPDirectoryAddress, username: String) throws {
        try Self.validate(username: username, password: "")
        let status = SecItemDelete(query(address, username: username) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw FTPBrowserFailure.keychain(status) }
    }
}
