import Foundation

/// Supported upstream LLM providers.
public enum UpstreamProvider: String, CaseIterable, Identifiable, Sendable {
    case zAI        = "zai"
    case openRouter = "openrouter"
    case openAI     = "openai"
    case xAI        = "xai"
    case chutes     = "chutes"
    case groq       = "groq"
    case google     = "google"
    case deepSeek   = "deepseek"
    case mistral    = "mistral"
    case miniMax    = "minimax"
    case ollama     = "ollama"
    case lmStudio   = "lmstudio"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .zAI:        return "z.ai"
        case .openRouter: return "OpenRouter"
        case .openAI:     return "OpenAI"
        case .xAI:        return "xAI (Grok)"
        case .chutes:     return "Chutes"
        case .groq:       return "Groq"
        case .google:     return "Google (Gemini)"
        case .deepSeek:   return "DeepSeek"
        case .mistral:    return "Mistral"
        case .miniMax:    return "MiniMax"
        case .ollama:     return "Ollama"
        case .lmStudio:   return "LM Studio"
        }
    }

    public var defaultAPIBaseURL: String {
        switch self {
        case .zAI:        return "https://api.z.ai/api/coding/paas/v4"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAI:     return "https://api.openai.com/v1"
        case .xAI:        return "https://api.x.ai/v1"
        case .chutes:     return "https://llm.chutes.ai/v1"
        case .groq:       return "https://api.groq.com/openai/v1"
        case .google:     return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepSeek:   return "https://api.deepseek.com/v1"
        case .mistral:    return "https://api.mistral.ai/v1"
        case .miniMax:    return "https://api.minimax.io/v1"
        case .ollama:     return "http://localhost:11434/v1"
        case .lmStudio:   return "http://localhost:1234/v1"
        }
    }

    public var modelsPath: String { "/models" }

    public var chatCompletionsPath: String { "/chat/completions" }

    public var unsupportedOpenAIParameters: [String] {
        switch self {
        case .google:
            return [
                "logprobs",
                "top_logprobs",
                "logit_bias",
                "seed",
                "frequency_penalty",
                "presence_penalty"
            ]
        case .deepSeek:
            return [
                "n",
                "max_completion_tokens",
                "logit_bias",
                "seed",
                "parallel_tool_calls"
            ]
        case .mistral:
            return [
                "logprobs",
                "top_logprobs",
                "logit_bias",
                "stream_options"
            ]
        case .miniMax:
            return [
                "n",
                "response_format",
                "stream_options",
                "function_call"
            ]
        default:
            return []
        }
    }

    /// Parameter keys to rename before forwarding upstream.
    /// For example, Mistral uses `random_seed` instead of `seed`.
    public var parameterRewrites: [String: String] {
        switch self {
        case .mistral:
            return ["seed": "random_seed", "max_completion_tokens": "max_tokens"]
        default:
            return [:]
        }
    }

    /// Valid temperature range for this provider, or nil if no clamping is needed.
    public var temperatureRange: ClosedRange<Double>? {
        switch self {
        case .miniMax: return 0.01...1.0
        default: return nil
        }
    }

    /// Whether this provider is in preview (may have incomplete API compatibility).
    public var isPreview: Bool {
        switch self {
        case .miniMax: return true
        default: return false
        }
    }

    /// Hardcoded model IDs for providers whose `/v1/models` endpoint may be absent.
    public var fallbackModelIDs: [String]? {
        switch self {
        case .miniMax:
            return [
                "MiniMax-M2.5",
                "MiniMax-M2.5-highspeed",
                "MiniMax-M2.1",
                "MiniMax-M2.1-highspeed",
                "MiniMax-M2"
            ]
        default: return nil
        }
    }

    /// Whether this provider runs on the local machine (no cloud API).
    public var isLocal: Bool {
        switch self {
        case .ollama, .lmStudio: return true
        default: return false
        }
    }

    /// Whether this provider requires an API key for authentication.
    public var requiresAPIKey: Bool { !isLocal }

    public var secretKey: String? {
        switch self {
        case .zAI:        return SecretKey.zaiAPIKey
        case .openRouter: return SecretKey.openRouterAPIKey
        case .openAI:     return SecretKey.openAIAPIKey
        case .xAI:        return SecretKey.xAIAPIKey
        case .chutes:     return SecretKey.chutesAPIKey
        case .groq:       return SecretKey.groqAPIKey
        case .google:     return SecretKey.googleAPIKey
        case .deepSeek:   return SecretKey.deepSeekAPIKey
        case .mistral:    return SecretKey.mistralAPIKey
        case .miniMax:    return SecretKey.minimaxAPIKey
        case .ollama, .lmStudio:
            return nil
        }
    }
}
