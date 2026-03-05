#if canImport(Security)
import Foundation
import LocalAuthentication
import Security

extension SecretsError {
    // Only available on platforms where Security framework is present.
    public static func keychainError(_ status: OSStatus) -> SecretsError {
        .fileError("Keychain OSStatus \(status)")
    }
}

/// macOS Keychain-backed secrets provider.
/// Uses the same "proxypilot" service name as the GUI app — shared state.
public struct KeychainSecretsProvider: SecretsProvider {
    private let service: String

    public init(service: String = "proxypilot") {
        self.service = service
    }

    public func get(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound { return nil }
            throw SecretsError.keychainError(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func set(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw SecretsError.encodingFailed
        }
        try? delete(key: key)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String:   data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretsError.keychainError(status)
        }
    }

    public func exists(key: String) throws -> Bool {
        let authContext = LAContext()
        authContext.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authContext,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed, errSecAuthFailed:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw SecretsError.keychainError(status)
        }
    }

    public func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretsError.keychainError(status)
        }
    }

    public func list() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String:       kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status == errSecItemNotFound { return [] }
            throw SecretsError.keychainError(status)
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
#endif
