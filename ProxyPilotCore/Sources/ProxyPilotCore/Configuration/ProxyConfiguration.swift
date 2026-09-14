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
    public let maxRequestBodyBytes: Int
    public let anthropicTranslatorMode: AnthropicTranslatorMode
    public let miniMaxRoutingMode: MiniMaxRoutingMode
    public let preferredAnthropicUpstreamModel: String
    public let sessionStats: SessionStats?
    public let googleThoughtSignatureStore: GoogleThoughtSignatureStore?
    /// Resolved on every request so logging preferences changed while the proxy
    /// is running (enable/disable, retention, CLI/MCP scope) take effect live
    /// instead of being frozen at proxy start.
    public let inputOutputLoggerProvider: (@Sendable () -> InputOutputLoggingRecorder?)?
    public var inputOutputLogger: InputOutputLoggingRecorder? { inputOutputLoggerProvider?() }
    public let promptCaching: PromptCachingConfiguration
    public let contextCompaction: ContextCompactionConfiguration
    public let sessionID: String

    /// Protected routes must authenticate whenever an upstream credential would
    /// be exercised, even if a caller forgot to set the explicit preference.
    public var requiresAuthForProtectedRoutes: Bool {
        LocalProxyCredential.requiresAuthentication(
            explicitlyRequired: requiresAuth,
            upstreamAPIKey: upstreamAPIKey
        )
    }

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 4000,
        upstreamProvider: UpstreamProvider = .openAI,
        upstreamAPIBaseURL: String? = nil,
        upstreamAPIKey: String? = nil,
        masterKey: String? = nil,
        allowedModels: Set<String> = [],
        requiresAuth: Bool = false,
        maxRequestBodyBytes: Int = 10 * 1024 * 1024,
        anthropicTranslatorMode: AnthropicTranslatorMode = .hardened,
        miniMaxRoutingMode: MiniMaxRoutingMode = .standard,
        preferredAnthropicUpstreamModel: String = "",
        sessionStats: SessionStats? = nil,
        googleThoughtSignatureStore: GoogleThoughtSignatureStore? = nil,
        inputOutputLoggerProvider: (@Sendable () -> InputOutputLoggingRecorder?)? = nil,
        promptCaching: PromptCachingConfiguration = .default,
        contextCompaction: ContextCompactionConfiguration = .disabled,
        sessionID: String = UUID().uuidString
    ) {
        self.host = host
        self.port = port
        self.upstreamProvider = upstreamProvider
        self.upstreamAPIBaseURL = upstreamAPIBaseURL ?? upstreamProvider.defaultAPIBaseURL
        self.upstreamAPIKey = upstreamAPIKey
        self.masterKey = masterKey
        self.allowedModels = allowedModels
        self.requiresAuth = requiresAuth
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.anthropicTranslatorMode = anthropicTranslatorMode
        self.miniMaxRoutingMode = miniMaxRoutingMode
        self.preferredAnthropicUpstreamModel = preferredAnthropicUpstreamModel
        self.sessionStats = sessionStats
        self.googleThoughtSignatureStore = googleThoughtSignatureStore
        self.inputOutputLoggerProvider = inputOutputLoggerProvider
        self.promptCaching = promptCaching
        self.contextCompaction = contextCompaction
        self.sessionID = sessionID
    }

    /// Convenience initializer for callers that already hold a resolved recorder
    /// (tests, and any host that manages recorder lifetime itself). The recorder
    /// is wrapped in a constant provider, so it is *not* re-resolved per request —
    /// prefer the `inputOutputLoggerProvider:` initializer for live pickup.
    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 4000,
        upstreamProvider: UpstreamProvider = .openAI,
        upstreamAPIBaseURL: String? = nil,
        upstreamAPIKey: String? = nil,
        masterKey: String? = nil,
        allowedModels: Set<String> = [],
        requiresAuth: Bool = false,
        maxRequestBodyBytes: Int = 10 * 1024 * 1024,
        anthropicTranslatorMode: AnthropicTranslatorMode = .hardened,
        miniMaxRoutingMode: MiniMaxRoutingMode = .standard,
        preferredAnthropicUpstreamModel: String = "",
        sessionStats: SessionStats? = nil,
        googleThoughtSignatureStore: GoogleThoughtSignatureStore? = nil,
        inputOutputLogger: InputOutputLoggingRecorder?,
        promptCaching: PromptCachingConfiguration = .default,
        contextCompaction: ContextCompactionConfiguration = .disabled,
        sessionID: String = UUID().uuidString
    ) {
        let provider: (@Sendable () -> InputOutputLoggingRecorder?)?
        if let inputOutputLogger {
            provider = { inputOutputLogger }
        } else {
            provider = nil
        }
        self.init(
            host: host,
            port: port,
            upstreamProvider: upstreamProvider,
            upstreamAPIBaseURL: upstreamAPIBaseURL,
            upstreamAPIKey: upstreamAPIKey,
            masterKey: masterKey,
            allowedModels: allowedModels,
            requiresAuth: requiresAuth,
            maxRequestBodyBytes: maxRequestBodyBytes,
            anthropicTranslatorMode: anthropicTranslatorMode,
            miniMaxRoutingMode: miniMaxRoutingMode,
            preferredAnthropicUpstreamModel: preferredAnthropicUpstreamModel,
            sessionStats: sessionStats,
            googleThoughtSignatureStore: googleThoughtSignatureStore,
            inputOutputLoggerProvider: provider,
            promptCaching: promptCaching,
            contextCompaction: contextCompaction,
            sessionID: sessionID
        )
    }

    /// Whether Anthropic passthrough is active for the current provider.
    public var isAnthropicPassthroughActive: Bool {
        upstreamProvider.usesAnthropicPassthroughByDefault
            || (miniMaxRoutingMode == .anthropicPassthrough && upstreamProvider.supportsAnthropicPassthrough)
    }
}

/// Translation mode for the Anthropic ↔ OpenAI converter.
public enum AnthropicTranslatorMode: String, Sendable {
    case hardened
    case legacyFallback
}

/// Routing mode for MiniMax providers.
public enum MiniMaxRoutingMode: String, Sendable {
    /// Route through OpenAI-compatible `/v1/chat/completions` with Anthropic translation.
    case standard
    /// Forward `/v1/messages` directly to MiniMax's `/anthropic` endpoint.
    case anthropicPassthrough
}
