import Foundation
import Security

enum SecureCredentialStore {
    private static let credentialService = "com.vbox.clouddrive.credentials"
    private static let credentialAccount = "cloud_drive_credentials_v1"
    private static let tokenService = "com.vbox.clouddrive.tokens"
    private static let tokenAccount = "saved_drive_tokens_v1"

    // MARK: - 通用 Keychain 读写

    static func save(data: Data, service: String, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // 删除旧条目时不应携带 kSecValueData，避免某些系统版本匹配失败
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.keychainError("保存失败，status=\(status)")
        }
    }

    static func load(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AuthError.keychainError("读取失败，status=\(status)")
        }
        return result as? Data
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - 网盘授权凭证（CloudDriveCredential）

    static func save(credentials: [String: CloudDriveCredential]) throws {
        let data = try JSONEncoder().encode(credentials)
        try save(data: data, service: credentialService, account: credentialAccount)
    }

    static func loadCredentials() throws -> [String: CloudDriveCredential]? {
        guard let data = try load(service: credentialService, account: credentialAccount) else { return nil }
        return try JSONDecoder().decode([String: CloudDriveCredential].self, from: data)
    }

    static func deleteCredentials() {
        delete(service: credentialService, account: credentialAccount)
    }

    // MARK: - 手动保存的 Token/Cookie（DriveToken）

    static func save(tokens: [DriveToken]) throws {
        let data = try JSONEncoder().encode(tokens)
        try save(data: data, service: tokenService, account: tokenAccount)
    }

    static func loadTokens() throws -> [DriveToken]? {
        guard let data = try load(service: tokenService, account: tokenAccount) else { return nil }
        return try JSONDecoder().decode([DriveToken].self, from: data)
    }

    static func deleteTokens() {
        delete(service: tokenService, account: tokenAccount)
    }
}
