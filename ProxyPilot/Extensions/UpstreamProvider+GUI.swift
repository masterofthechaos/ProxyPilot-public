import Foundation
import ProxyPilotCore

extension UpstreamProvider {

    /// The URL for the provider's API key management page, if applicable.
    var apiKeyPageURL: URL? {
        switch self {
        case .zAI: return URL(string: "https://zai.chat")
        case .openRouter: return URL(string: "https://openrouter.ai/keys")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .xAI: return URL(string: "https://console.x.ai")
        case .chutes: return URL(string: "https://chutes.ai/app/api-keys")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .google: return URL(string: "https://aistudio.google.com/apikey")
        case .deepSeek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .mistral: return URL(string: "https://console.mistral.ai/api-keys")
        case .miniMax: return URL(string: "https://platform.minimax.io")
        case .miniMaxCN: return URL(string: "https://platform.minimaxi.com")
        case .qwen: return Self.qwenInternationalAPIKeyPageURL
        case .githubCopilot: return URL(string: "https://github.com/features/copilot")
        case .ollama, .lmStudio: return nil
        }
    }

    func apiKeyPageURL(apiBaseURL: URL?) -> URL? {
        guard self == .qwen else { return apiKeyPageURL }
        guard apiBaseURL?.host?.lowercased() == "dashscope.aliyuncs.com" else {
            return Self.qwenInternationalAPIKeyPageURL
        }
        return Self.qwenChinaAPIKeyPageURL
    }

    func apiKeyRegionHint(apiBaseURL: URL?) -> String? {
        guard self == .qwen else { return nil }
        if apiBaseURL?.host?.lowercased() == "dashscope.aliyuncs.com" {
            return "China (Beijing) DashScope endpoint selected. Use a China-region Model Studio API key."
        }
        return "International DashScope endpoint selected. Use an Alibaba Cloud Model Studio key from Singapore or another matching non-China region."
    }

    var keychainKey: KeychainService.Key? {
        switch self {
        case .zAI: return .zaiAPIKey
        case .openRouter: return .openRouterAPIKey
        case .openAI: return .openAIAPIKey
        case .xAI: return .xAIAPIKey
        case .chutes: return .chutesAPIKey
        case .groq: return .groqAPIKey
        case .google: return .googleAPIKey
        case .deepSeek: return .deepSeekAPIKey
        case .mistral: return .mistralAPIKey
        case .miniMax: return .minimaxAPIKey
        case .miniMaxCN: return .minimaxCNAPIKey
        case .qwen: return .qwenAPIKey
        case .githubCopilot, .ollama, .lmStudio: return nil
        }
    }

    private static let qwenInternationalAPIKeyPageURL = URL(string: "https://modelstudio.console.alibabacloud.com/?tab=api#/api-key")
    private static let qwenChinaAPIKeyPageURL = URL(string: "https://dashscope.console.aliyun.com/apiKey")
}
