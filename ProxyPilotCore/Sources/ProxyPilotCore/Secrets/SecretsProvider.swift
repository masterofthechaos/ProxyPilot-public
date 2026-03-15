import Foundation

/// Platform-agnostic secret storage.
public protocol SecretsProvider: Sendable {
    func get(key: String) throws -> String?
    func exists(key: String) throws -> Bool
    func set(key: String, value: String) throws
    func delete(key: String) throws
    func list() throws -> [String]
}

public extension SecretsProvider {
    func exists(key: String) throws -> Bool {
        try get(key: key) != nil
    }
}

/// Well-known secret key names (matching existing Keychain account names).
public enum SecretKey {
    public static let zaiAPIKey        = "ZAI_API_KEY"
    public static let openRouterAPIKey = "OPENROUTER_API_KEY"
    public static let openAIAPIKey     = "OPENAI_API_KEY"
    public static let xAIAPIKey        = "XAI_API_KEY"
    public static let chutesAPIKey     = "CHUTES_API_KEY"
    public static let groqAPIKey       = "GROQ_API_KEY"
    public static let googleAPIKey     = "GOOGLE_API_KEY"
    public static let miniMaxAPIKey    = "MINIMAX_API_KEY"
    public static let masterKey        = "LITELLM_MASTER_KEY"
}

public enum SecretsError: Error, Sendable {
    case encodingFailed
    case fileError(String)
}
