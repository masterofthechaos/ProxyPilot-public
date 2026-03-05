import Foundation

/// Configuration for the proxy server.
/// Replaces scattered UserDefaults reads with a typed, portable config.
public struct ProxyConfiguration: Sendable {
    public let host: String
    public let port: UInt16
    public let upstreamProvider: UpstreamProvider
    public let upstreamAPIBaseURL: String
    public let upstreamAPIKey: String?
    public let masterKey: String?
    public let allowedModels: Set<String>
    public let requiresAuth: Bool
    public let anthropicTranslatorMode: AnthropicTranslatorMode
    public let preferredAnthropicUpstreamModel: String
    public let sessionStats: SessionStats?
    public let googleThoughtSignatureStore: GoogleThoughtSignatureStore?

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 4000,
        upstreamProvider: UpstreamProvider = .openAI,
        upstreamAPIBaseURL: String? = nil,
        upstreamAPIKey: String? = nil,
        masterKey: String? = nil,
        allowedModels: Set<String> = [],
        requiresAuth: Bool = false,
        anthropicTranslatorMode: AnthropicTranslatorMode = .hardened,
        preferredAnthropicUpstreamModel: String = "",
        sessionStats: SessionStats? = nil,
        googleThoughtSignatureStore: GoogleThoughtSignatureStore? = nil
    ) {
        self.host = host
        self.port = port
        self.upstreamProvider = upstreamProvider
        self.upstreamAPIBaseURL = upstreamAPIBaseURL ?? upstreamProvider.defaultAPIBaseURL
        self.upstreamAPIKey = upstreamAPIKey
        self.masterKey = masterKey
        self.allowedModels = allowedModels
        self.requiresAuth = requiresAuth
        self.anthropicTranslatorMode = anthropicTranslatorMode
        self.preferredAnthropicUpstreamModel = preferredAnthropicUpstreamModel
        self.sessionStats = sessionStats
        self.googleThoughtSignatureStore = googleThoughtSignatureStore
    }
}

/// Translation mode for the Anthropic ↔ OpenAI converter.
public enum AnthropicTranslatorMode: String, Sendable {
    case hardened
    case legacyFallback
}
