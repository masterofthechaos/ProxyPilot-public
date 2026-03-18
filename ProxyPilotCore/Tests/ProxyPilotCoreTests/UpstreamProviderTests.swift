import Foundation
import Testing
@testable import ProxyPilotCore

@Suite("UpstreamProvider")
struct UpstreamProviderTests {
    @Test func ollamaIsLocal() { #expect(UpstreamProvider.ollama.isLocal == true) }
    @Test func lmStudioIsLocal() { #expect(UpstreamProvider.lmStudio.isLocal == true) }
    @Test func cloudProvidersAreNotLocal() {
        for provider in [UpstreamProvider.zAI, .openRouter, .openAI, .xAI, .chutes, .groq, .google, .deepSeek, .mistral, .miniMax] {
            #expect(provider.isLocal == false)
        }
    }
    @Test func localProvidersDoNotRequireAPIKey() {
        #expect(UpstreamProvider.ollama.requiresAPIKey == false)
        #expect(UpstreamProvider.lmStudio.requiresAPIKey == false)
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
    }
    @Test func secretKeyMappingForLocalProvidersIsNil() {
        #expect(UpstreamProvider.ollama.secretKey == nil)
        #expect(UpstreamProvider.lmStudio.secretKey == nil)
    }
    @Test func ollamaDefaultURL() { #expect(UpstreamProvider.ollama.defaultAPIBaseURL == "http://localhost:11434/v1") }
    @Test func lmStudioDefaultURL() { #expect(UpstreamProvider.lmStudio.defaultAPIBaseURL == "http://localhost:1234/v1") }
    @Test func googleDefaultURL() { #expect(UpstreamProvider.google.defaultAPIBaseURL == "https://generativelanguage.googleapis.com/v1beta/openai") }
    @Test func ollamaTitle() { #expect(UpstreamProvider.ollama.title == "Ollama") }
    @Test func lmStudioTitle() { #expect(UpstreamProvider.lmStudio.title == "LM Studio") }
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
        for provider in UpstreamProvider.allCases where provider != .miniMax {
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
        for provider in UpstreamProvider.allCases where provider != .miniMax {
            #expect(provider.isPreview == false, "\(provider.rawValue) should not be preview")
        }
    }
    @Test func miniMaxHasFallbackModels() {
        let fallback = UpstreamProvider.miniMax.fallbackModelIDs
        #expect(fallback != nil)
        #expect(fallback?.contains("MiniMax-M2.5") == true)
    }
    @Test func nonMiniMaxProvidersHaveNoFallbackModels() {
        for provider in UpstreamProvider.allCases where provider != .miniMax {
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
}
