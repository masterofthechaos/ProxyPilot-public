import Foundation
import LocalAuthentication
import Security

enum KeychainService {
    enum Key: String, CaseIterable {
        case zaiAPIKey = "ZAI_API_KEY"
        case openRouterAPIKey = "OPENROUTER_API_KEY"
        case openAIAPIKey = "OPENAI_API_KEY"
        case xAIAPIKey = "XAI_API_KEY"
        case chutesAPIKey = "CHUTES_API_KEY"
        case groqAPIKey = "GROQ_API_KEY"
        case googleAPIKey = "GOOGLE_API_KEY"
        case miniMaxAPIKey = "MINIMAX_API_KEY"
        case litellmMasterKey = "LITELLM_MASTER_KEY"
    }

    private static let service = "proxypilot"
    private static let legacyService = "litellm-zai"

    /// Migrates keys from the legacy "litellm-zai" service to "proxypilot".
    /// Safe to call multiple times — skips keys that already exist under the new service.
    static func migrateFromLegacyServiceIfNeeded() {
        for key in Key.allCases {
            // Skip if new service already has this key
            if get(key: key) != nil { continue }

            // Check legacy service
            guard let legacyValue = getLegacy(key: key) else { continue }

            // Copy to new service
            try? set(legacyValue, forKey: key)
        }
    }

    /// Returns true when at least one stored key would require user authorization if read.
    /// Uses a non-interactive `LAContext` so this check never triggers system prompts.
    static func requiresAuthorizationForAnyStoredKey() -> Bool {
        for key in Key.allCases {
            if requiresAuthorization(for: key, serviceName: service) { return true }
            if requiresAuthorization(for: key, serviceName: legacyService) { return true }
        }
        return false
    }

    private static func getFromService(key: Key, serviceName: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func getLegacy(key: Key) -> String? {
        getFromService(key: key, serviceName: legacyService)
    }

    static func get(key: Key) -> String? {
        if let value = getFromService(key: key, serviceName: service) {
            return value
        }

        // Lazy one-key migration from legacy service to avoid broad keychain reads on app launch.
        guard let legacyValue = getLegacy(key: key) else { return nil }
        try? set(legacyValue, forKey: key)
        return legacyValue
    }

    static func exists(key: Key) -> Bool {
        existsInService(key: key, serviceName: service)
            || existsInService(key: key, serviceName: legacyService)
    }

    static func set(_ value: String, forKey key: Key) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        try? delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func delete(key: Key) throws {
        var firstError: KeychainError?
        if let error = deleteFromService(key: key, serviceName: service) {
            firstError = error
        }
        if let error = deleteFromService(key: key, serviceName: legacyService), firstError == nil {
            firstError = error
        }
        if let firstError {
            throw firstError
        }
    }

    private static func deleteFromService(key: Key, serviceName: String) -> KeychainError? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return KeychainError.deleteFailed(status)
        }
        return nil
    }

    private static func existsInService(key: Key, serviceName: String) -> Bool {
        let status = nonInteractiveQueryStatus(for: key, serviceName: serviceName)
        return status == errSecSuccess
            || status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
    }

    private static func requiresAuthorization(for key: Key, serviceName: String) -> Bool {
        let status = nonInteractiveQueryStatus(for: key, serviceName: serviceName)
        return status == errSecInteractionNotAllowed || status == errSecAuthFailed
    }

    private static func nonInteractiveQueryStatus(for key: Key, serviceName: String) -> OSStatus {
        let authContext = LAContext()
        authContext.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authContext
        ]

        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result)
    }
}

enum KeychainError: LocalizedError {
    case encodingFailed
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode value for Keychain storage."
        case .saveFailed(let status):
            return "Failed to save to Keychain: \(SecCopyErrorMessageString(status, nil) ?? "Unknown" as CFString)"
        case .deleteFailed(let status):
            return "Failed to delete from Keychain: \(SecCopyErrorMessageString(status, nil) ?? "Unknown" as CFString)"
        }
    }
}
