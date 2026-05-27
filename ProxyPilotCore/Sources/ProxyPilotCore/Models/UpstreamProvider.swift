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
    case miniMaxCN  = "minimax-cn"
    case qwen       = "qwen"
    case githubCopilot = "github-copilot"
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
        case .miniMaxCN:  return "MiniMax CN"
        case .qwen:       return "Qwen"
        case .githubCopilot: return "GitHub Copilot"
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
        case .miniMaxCN:  return "https://api.minimaxi.com/v1"
        case .qwen:       return "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .githubCopilot: return "http://127.0.0.1:8080/v1"
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
        case .miniMax, .miniMaxCN:
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
        case .miniMax, .miniMaxCN: return 0.01...1.0
        default: return nil
        }
    }

    /// Whether this provider is in preview (may have incomplete API compatibility).
    public var isPreview: Bool {
        switch self {
        case .miniMax, .miniMaxCN: return true
        default: return false
        }
    }

    /// Hardcoded model IDs for providers whose `/v1/models` endpoint may be absent.
    public var fallbackModelIDs: [String]? {
        switch self {
        case .miniMax, .miniMaxCN:
            return [
                "MiniMax-M2.7",
                "MiniMax-M2.7-highspeed",
                "MiniMax-M2.5",
                "MiniMax-M2.5-highspeed",
                "MiniMax-M2.1",
                "MiniMax-M2.1-highspeed",
                "MiniMax-M2"
            ]
        default: return nil
        }
    }

    /// Provider-published metadata for models whose `/models` response only
    /// returns ids. Pricing is used for local session-cost estimates.
    public func knownModelMetadata(for id: String, now: Date = Date()) -> UpstreamModel? {
        let hasExactoSuffix = id.lowercased().hasSuffix(":exacto")
        let baseID = hasExactoSuffix ? String(id.dropLast(":exacto".count)) : id
        let lower = baseID.lowercased()

        guard self == .deepSeek else { return nil }

        let model: UpstreamModel?
        switch lower {
        case "deepseek-v4-flash", "deepseek-chat", "deepseek-reasoner":
            model = UpstreamModel(
                id: baseID,
                contextLength: 1_000_000,
                promptPricePer1M: 0.14,
                completionPricePer1M: 0.28,
                promptCacheHitPricePer1M: 0.0028,
                promptCacheMissPricePer1M: 0.14,
                supportedParameters: ["tools", "tool_choice", "response_format"]
            )
        case "deepseek-v4-pro":
            let discounted = Self.isDeepSeekV4ProDiscountActive(now: now)
            model = UpstreamModel(
                id: baseID,
                contextLength: 1_000_000,
                promptPricePer1M: discounted ? 0.435 : 1.74,
                completionPricePer1M: discounted ? 0.87 : 3.48,
                promptCacheHitPricePer1M: discounted ? 0.003625 : 0.0145,
                promptCacheMissPricePer1M: discounted ? 0.435 : 1.74,
                supportedParameters: ["tools", "tool_choice", "response_format"]
            )
        default:
            model = nil
        }

        guard let model else { return nil }
        return hasExactoSuffix ? model.exactoVariant : model
    }

    private static func isDeepSeekV4ProDiscountActive(now: Date) -> Bool {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 5
        components.day = 31
        components.hour = 15
        components.minute = 59
        components.second = 0
        guard let discountEnd = components.date else { return false }
        return now <= discountEnd
    }

    /// Alternate API base URLs that are officially supported for the provider.
    public var alternateAPIBaseURLs: [String] {
        switch self {
        case .miniMax:
            return ["https://api.minimaxi.com/v1"]
        case .miniMaxCN:
            return []
        default:
            return []
        }
    }

    /// Whether this provider runs on the local machine (no cloud API).
    public var isLocal: Bool {
        switch self {
        case .githubCopilot, .ollama, .lmStudio: return true
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
        case .miniMaxCN:  return SecretKey.minimaxCNAPIKey
        case .qwen:       return SecretKey.qwenAPIKey
        case .githubCopilot, .ollama, .lmStudio:
            return nil
        }
    }

    /// Whether this provider is a MiniMax variant (global or CN).
    public var isMiniMax: Bool {
        self == .miniMax || self == .miniMaxCN
    }

    /// Whether this provider has an official Anthropic-compatible endpoint that
    /// can receive `/v1/messages` requests directly.
    public var supportsAnthropicPassthrough: Bool {
        isMiniMax || self == .deepSeek
    }

    /// Whether `/v1/messages` should use the provider's Anthropic-compatible
    /// endpoint without requiring a user-facing routing-mode toggle.
    public var usesAnthropicPassthroughByDefault: Bool {
        self == .deepSeek
    }

    /// Derives the Anthropic passthrough base URL from the OpenAI-compat base URL.
    /// Returns nil for providers that don't support Anthropic passthrough.
    ///
    /// Example: `https://api.minimax.io/v1` → `https://api.minimax.io/anthropic`
    public func anthropicPassthroughBaseURL(from openAIBaseURL: String) -> String? {
        var base = openAIBaseURL
        while base.hasSuffix("/") { base.removeLast() }

        guard supportsAnthropicPassthrough else { return nil }
        if base.hasSuffix("/anthropic") {
            return base
        }
        if base.hasSuffix("/v1") {
            return String(base.dropLast(3)) + "/anthropic"
        }
        // Fallback: append /anthropic if the URL doesn't end with /v1
        return base + "/anthropic"
    }

    /// Parameters to strip from Anthropic-format requests before forwarding to
    /// provider `/anthropic` endpoints.
    public var unsupportedAnthropicParameters: [String] {
        switch self {
        case .miniMax, .miniMaxCN:
            return [
                "top_k",
                "stop_sequences",
                "service_tier",
                "mcp_servers",
                "container",
                "context_management"
            ]
        case .deepSeek:
            return [
                "top_k",
                "service_tier",
                "mcp_servers",
                "container",
                "metadata",
                "context_management"
            ]
        default:
            return []
        }
    }
}
