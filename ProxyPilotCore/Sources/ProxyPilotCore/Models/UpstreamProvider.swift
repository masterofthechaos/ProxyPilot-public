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
        case .miniMax:    return "https://api.minimaxi.com/v1"
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
        default:
            return []
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
        case .miniMax:    return SecretKey.miniMaxAPIKey
        case .ollama, .lmStudio:
            return nil
        }
    }
}
