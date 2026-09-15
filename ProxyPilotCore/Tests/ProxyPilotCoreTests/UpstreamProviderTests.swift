import Foundation
import Testing
@testable import ProxyPilotCore

@Suite("UpstreamProvider")
struct UpstreamProviderTests {
    @Test func moonshotCredentialsAndNativeModelGate() {
        let provider = UpstreamProvider.moonshot
        #expect(provider.requiresAPIKey)
        #expect(provider.secretKey == "MOONSHOT_API_KEY")
        #expect(provider.defaultAPIBaseURL == "https://api.moonshot.ai/v1")
        #expect(provider.anthropicPassthroughBaseURL(from: provider.defaultAPIBaseURL) == "https://api.moonshot.ai/anthropic")
        #expect(ProxyConfiguration(upstreamProvider: provider, preferredAnthropicUpstreamModel: "kimi-k3").isAnthropicPassthroughActive)
        #expect(!ProxyConfiguration(upstreamProvider: provider, miniMaxRoutingMode: .anthropicPassthrough, preferredAnthropicUpstreamModel: "kimi-k2.6").isAnthropicPassthroughActive)
    }

    @Test func moonshotPreservesNativeThinkingAndTools() throws {
        let messages: [[String: Any]] = [["role": "assistant", "content": [
            ["type": "thinking", "thinking": "reason", "signature": "sig"],
            ["type": "tool_use", "id": "call_1", "name": "read", "input": ["path": "a"]]
        ]]]
        var request: [String: Any] = ["model": "kimi-k3", "messages": messages, "max_tokens": 100,
            "temperature": 0.2, "thinking": ["type": "adaptive"], "output_config": ["effort": "high"]]
        AnthropicTranslator.sanitizeAnthropicPassthroughRequest(&request, for: .moonshot)
        #expect(request["temperature"] == nil)
        #expect(request["thinking"] == nil)
        #expect(request["max_tokens"] as? Int == 100)
        #expect((request["output_config"] as? [String: String])?["effort"] == "high")
        #expect(NSDictionary(dictionary: ["messages": request["messages"]!]).isEqual(to: ["messages": messages]))
        var chat: [String: Any] = ["model": "kimi-k3", "max_completion_tokens": 100, "temperature": 0.3, "thinking": ["type": "disabled"], "reasoning_effort": "high"]
        AnthropicTranslator.stripUnsupportedParameters(&chat, for: .moonshot)
        AnthropicTranslator.applyParameterRewrites(&chat, for: .moonshot)
        #expect(chat["max_tokens"] as? Int == 100)
        #expect(chat["temperature"] == nil)
        #expect(chat["thinking"] == nil)
        #expect(chat["reasoning_effort"] as? String == "high")
    }

    @Test func ollamaIsLocal() { #expect(UpstreamProvider.ollama.isLocal == true) }
    @Test func lmStudioIsLocal() { #expect(UpstreamProvider.lmStudio.isLocal == true) }
    @Test func nineRouterIsLocal() { #expect(UpstreamProvider.nineRouter.isLocal == true) }
    @Test func cloudProvidersAreNotLocal() {
        for provider in [UpstreamProvider.zAI, .openRouter, .openAI, .xAI, .chutes, .groq, .google, .deepSeek, .mistral, .miniMax, .miniMaxCN, .qwen] {
            #expect(provider.isLocal == false)
        }
    }
    @Test func localProvidersDoNotRequireAPIKey() {
        #expect(UpstreamProvider.ollama.requiresAPIKey == false)
        #expect(UpstreamProvider.lmStudio.requiresAPIKey == false)
        #expect(UpstreamProvider.nineRouter.requiresAPIKey == false)
    }
    @Test func cloudProvidersRequireAPIKey() {
        #expect(UpstreamProvider.openAI.requiresAPIKey == true)
    }
    @Test func secretKeyMappingForCloudProviders() {
        #expect(UpstreamProvider.openAI.secretKey == SecretKey.openAIAPIKey)
        #expect(UpstreamProvider.groq.secretKey == SecretKey.groqAPIKey)
        #expect(UpstreamProvider.zAI.secretKey == SecretKey.zaiAPIKey)
        #expect(UpstreamProvider.openRouter.secretKey == SecretKey.openRouterAPIKey)
        #expect(UpstreamProvider.xAI.secretKey == SecretKey.xAIAPIKey)
        #expect(UpstreamProvider.chutes.secretKey == SecretKey.chutesAPIKey)
        #expect(UpstreamProvider.google.secretKey == SecretKey.googleAPIKey)
        #expect(UpstreamProvider.qwen.secretKey == SecretKey.qwenAPIKey)
        #expect(UpstreamProvider.nineRouter.secretKey == SecretKey.nineRouterAPIKey)
    }
    @Test func secretKeyMappingForLocalProvidersIsNil() {
        #expect(UpstreamProvider.ollama.secretKey == nil)
        #expect(UpstreamProvider.lmStudio.secretKey == nil)
    }
    @Test func ollamaDefaultURL() { #expect(UpstreamProvider.ollama.defaultAPIBaseURL == "http://localhost:11434/v1") }
    @Test func lmStudioDefaultURL() { #expect(UpstreamProvider.lmStudio.defaultAPIBaseURL == "http://localhost:1234/v1") }
    @Test func nineRouterDefaultURL() { #expect(UpstreamProvider.nineRouter.defaultAPIBaseURL == "http://localhost:20128/v1") }
    @Test func googleDefaultURL() { #expect(UpstreamProvider.google.defaultAPIBaseURL == "https://generativelanguage.googleapis.com/v1beta/openai") }
    @Test func qwenDefaultURL() { #expect(UpstreamProvider.qwen.defaultAPIBaseURL == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1") }
    @Test func ollamaTitle() { #expect(UpstreamProvider.ollama.title == "Ollama") }
    @Test func lmStudioTitle() { #expect(UpstreamProvider.lmStudio.title == "LM Studio") }
    @Test func nineRouterTitle() { #expect(UpstreamProvider.nineRouter.title == "9Router") }
    @Test func googleUsesProviderSpecificChatPath() {
        #expect(UpstreamProvider.google.chatCompletionsPath == "/chat/completions")
        #expect(UpstreamProvider.openAI.chatCompletionsPath == "/chat/completions")
        #expect(UpstreamProvider.google.modelsPath == "/models")
    }

    // MARK: - URL Construction Regression Tests (v1.4.0a)

    @Test func allProvidersChatURLsAreValid() {
        for provider in UpstreamProvider.allCases {
            let base = provider.defaultAPIBaseURL
            let path = provider.chatCompletionsPath
            let urlString = base + path
            #expect(
                URL(string: urlString) != nil,
                "Provider \(provider.rawValue) produces invalid URL: \(urlString)"
            )
        }
    }

    @Test func noProviderHasDoubledPathSegments() {
        for provider in UpstreamProvider.allCases {
            let urlString = provider.defaultAPIBaseURL + provider.chatCompletionsPath
            #expect(
                !urlString.contains("/v1/v1"),
                "Provider \(provider.rawValue) has doubled /v1/v1: \(urlString)"
            )
            #expect(
                !urlString.contains("/v4/v1"),
                "Provider \(provider.rawValue) has /v4/v1 mismatch: \(urlString)"
            )
        }
    }

    @Test func chatCompletionsPathDoesNotIncludeVersionPrefix() {
        for provider in UpstreamProvider.allCases {
            #expect(
                provider.chatCompletionsPath == "/chat/completions",
                "Provider \(provider.rawValue) chatCompletionsPath should be /chat/completions, got \(provider.chatCompletionsPath)"
            )
        }
    }

    @Test func allProvidersChatURLsEndWithChatCompletions() {
        for provider in UpstreamProvider.allCases {
            let urlString = provider.defaultAPIBaseURL + provider.chatCompletionsPath
            #expect(
                urlString.hasSuffix("/chat/completions"),
                "Provider \(provider.rawValue) URL doesn't end with /chat/completions: \(urlString)"
            )
        }
    }

    // MARK: - New Provider Tests (v1.4.9)

    @Test func deepSeekSecretKey() {
        #expect(UpstreamProvider.deepSeek.secretKey == SecretKey.deepSeekAPIKey)
    }
    @Test func mistralSecretKey() {
        #expect(UpstreamProvider.mistral.secretKey == SecretKey.mistralAPIKey)
    }
    @Test func deepSeekDefaultURL() {
        #expect(UpstreamProvider.deepSeek.defaultAPIBaseURL == "https://api.deepseek.com/v1")
    }
    @Test func mistralDefaultURL() {
        #expect(UpstreamProvider.mistral.defaultAPIBaseURL == "https://api.mistral.ai/v1")
    }
    @Test func deepSeekTitle() { #expect(UpstreamProvider.deepSeek.title == "DeepSeek") }
    @Test func mistralTitle() { #expect(UpstreamProvider.mistral.title == "Mistral") }

    @Test func mistralParameterRewritesContainsSeedAndMaxTokens() {
        let rewrites = UpstreamProvider.mistral.parameterRewrites
        #expect(rewrites["seed"] == "random_seed")
        #expect(rewrites["max_completion_tokens"] == "max_tokens")
    }
    @Test func openAIParameterRewritesIsEmpty() {
        #expect(UpstreamProvider.openAI.parameterRewrites.isEmpty)
    }
    @Test func deepSeekParameterRewritesIsEmpty() {
        #expect(UpstreamProvider.deepSeek.parameterRewrites.isEmpty)
    }
    @Test func miniMaxTemperatureRange() {
        let range = UpstreamProvider.miniMax.temperatureRange
        #expect(range != nil)
        #expect(range?.lowerBound == 0.01)
        #expect(range?.upperBound == 1.0)
    }
    @Test func nonMiniMaxProvidersHaveNilTemperatureRange() {
        for provider in UpstreamProvider.allCases where !provider.isMiniMax {
            #expect(provider.temperatureRange == nil, "\(provider.rawValue) should have nil temperatureRange")
        }
    }
    @Test func miniMaxSecretKey() {
        #expect(UpstreamProvider.miniMax.secretKey == SecretKey.minimaxAPIKey)
    }
    @Test func miniMaxDefaultURL() {
        #expect(UpstreamProvider.miniMax.defaultAPIBaseURL == "https://api.minimax.io/v1")
    }
    @Test func miniMaxTitle() { #expect(UpstreamProvider.miniMax.title == "MiniMax") }
    @Test func miniMaxIsPreview() { #expect(UpstreamProvider.miniMax.isPreview == true) }
    @Test func nonPreviewProviders() {
        for provider in UpstreamProvider.allCases where !provider.isMiniMax {
            #expect(provider.isPreview == false, "\(provider.rawValue) should not be preview")
        }
    }
    @Test func miniMaxHasFallbackModels() {
        let fallback = UpstreamProvider.miniMax.fallbackModelIDs
        #expect(fallback != nil)
        #expect(fallback?.contains("MiniMax-M2.7") == true)
        #expect(fallback?.contains("MiniMax-M2.5") == true)
    }
    @Test func miniMaxHasChinaEndpointPreset() {
        #expect(UpstreamProvider.miniMax.alternateAPIBaseURLs.contains("https://api.minimaxi.com/v1"))
    }
    @Test func nonMiniMaxProvidersHaveNoFallbackModels() {
        for provider in UpstreamProvider.allCases where !provider.isMiniMax {
            #expect(provider.fallbackModelIDs == nil, "\(provider.rawValue) should have nil fallbackModelIDs")
        }
    }
    @Test func temperatureClampForMiniMax() {
        var request: [String: Any] = ["model": "MiniMax-M2.5", "temperature": 0.0]
        AnthropicTranslator.clampTemperature(&request, for: .miniMax)
        #expect(request["temperature"] as? Double == 0.01)

        request["temperature"] = 2.0
        AnthropicTranslator.clampTemperature(&request, for: .miniMax)
        #expect(request["temperature"] as? Double == 1.0)

        request["temperature"] = 0.5
        AnthropicTranslator.clampTemperature(&request, for: .miniMax)
        #expect(request["temperature"] as? Double == 0.5)
    }

    // MARK: - MiniMax CN Tests (v1.4.12)

    @Test func miniMaxCNSecretKey() {
        #expect(UpstreamProvider.miniMaxCN.secretKey == SecretKey.minimaxCNAPIKey)
    }
    @Test func miniMaxCNDefaultURL() {
        #expect(UpstreamProvider.miniMaxCN.defaultAPIBaseURL == "https://api.minimaxi.com/v1")
    }
    @Test func miniMaxCNTitle() { #expect(UpstreamProvider.miniMaxCN.title == "MiniMax CN") }
    @Test func miniMaxCNIsPreview() { #expect(UpstreamProvider.miniMaxCN.isPreview == true) }
    @Test func miniMaxCNTemperatureRange() {
        let range = UpstreamProvider.miniMaxCN.temperatureRange
        #expect(range != nil)
        #expect(range?.lowerBound == 0.01)
        #expect(range?.upperBound == 1.0)
    }
    @Test func miniMaxCNHasFallbackModels() {
        let fallback = UpstreamProvider.miniMaxCN.fallbackModelIDs
        #expect(fallback != nil)
        #expect(fallback?.contains("MiniMax-M2.7") == true)
        #expect(fallback?.contains("MiniMax-M2.5") == true)
    }
    @Test func miniMaxCNHasNoAlternateURLs() {
        #expect(UpstreamProvider.miniMaxCN.alternateAPIBaseURLs.isEmpty)
    }
    @Test func isMiniMaxReturnsTrueForBothVariants() {
        #expect(UpstreamProvider.miniMax.isMiniMax == true)
        #expect(UpstreamProvider.miniMaxCN.isMiniMax == true)
    }
    @Test func isMiniMaxReturnsFalseForOtherProviders() {
        for provider in UpstreamProvider.allCases where !provider.isMiniMax {
            #expect(provider.isMiniMax == false, "\(provider.rawValue) should not be isMiniMax")
        }
    }
    @Test func temperatureClampForMiniMaxCN() {
        var request: [String: Any] = ["model": "MiniMax-M2.5", "temperature": 0.0]
        AnthropicTranslator.clampTemperature(&request, for: .miniMaxCN)
        #expect(request["temperature"] as? Double == 0.01)

        request["temperature"] = 2.0
        AnthropicTranslator.clampTemperature(&request, for: .miniMaxCN)
        #expect(request["temperature"] as? Double == 1.0)
    }

    // MARK: - Anthropic Passthrough URL (v1.4.15)

    @Test func anthropicPassthroughURLForGlobal() {
        let url = UpstreamProvider.miniMax.anthropicPassthroughBaseURL(from: "https://api.minimax.io/v1")
        #expect(url == "https://api.minimax.io/anthropic")
    }
    @Test func anthropicPassthroughURLForCN() {
        let url = UpstreamProvider.miniMaxCN.anthropicPassthroughBaseURL(from: "https://api.minimaxi.com/v1")
        #expect(url == "https://api.minimaxi.com/anthropic")
    }
    @Test func anthropicPassthroughURLForDeepSeek() {
        let url = UpstreamProvider.deepSeek.anthropicPassthroughBaseURL(from: "https://api.deepseek.com/v1")
        #expect(url == "https://api.deepseek.com/anthropic")
    }
    @Test func anthropicPassthroughURLLeavesExistingAnthropicBaseUntouched() {
        let url = UpstreamProvider.deepSeek.anthropicPassthroughBaseURL(from: "https://api.deepseek.com/anthropic")
        #expect(url == "https://api.deepseek.com/anthropic")
    }
    @Test func anthropicPassthroughURLReturnsNilForNonMiniMax() {
        #expect(UpstreamProvider.openAI.anthropicPassthroughBaseURL(from: "https://api.openai.com/v1") == nil)
    }
    @Test func miniMaxRoutingModeDefaultIsStandard() {
        let config = ProxyConfiguration()
        #expect(config.miniMaxRoutingMode == .standard)
    }
    @Test func isAnthropicPassthroughActiveWhenEnabled() {
        let config = ProxyConfiguration(
            upstreamProvider: .miniMax,
            miniMaxRoutingMode: .anthropicPassthrough
        )
        #expect(config.isAnthropicPassthroughActive == true)
    }
    @Test func isAnthropicPassthroughActiveForDeepSeekByDefault() {
        let config = ProxyConfiguration(upstreamProvider: .deepSeek)
        #expect(config.isAnthropicPassthroughActive == true)
    }
    @Test func isAnthropicPassthroughInactiveForNonMiniMax() {
        let config = ProxyConfiguration(
            upstreamProvider: .openAI,
            miniMaxRoutingMode: .anthropicPassthrough
        )
        #expect(config.isAnthropicPassthroughActive == false)
    }
    @Test func isAnthropicPassthroughInactiveInStandardMode() {
        let config = ProxyConfiguration(
            upstreamProvider: .miniMax,
            miniMaxRoutingMode: .standard
        )
        #expect(config.isAnthropicPassthroughActive == false)
    }
}
