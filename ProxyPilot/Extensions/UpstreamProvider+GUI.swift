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
        case .ollama, .lmStudio: return nil
        }
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
        case .ollama, .lmStudio: return nil
        }
    }
}
