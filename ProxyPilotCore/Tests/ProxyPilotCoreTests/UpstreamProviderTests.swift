import Foundation
import Testing
@testable import ProxyPilotCore

@Suite("UpstreamProvider")
struct UpstreamProviderTests {
    @Test func ollamaIsLocal() { #expect(UpstreamProvider.ollama.isLocal == true) }
    @Test func lmStudioIsLocal() { #expect(UpstreamProvider.lmStudio.isLocal == true) }
    @Test func cloudProvidersAreNotLocal() {
        for provider in [UpstreamProvider.zAI, .openRouter, .openAI, .xAI, .chutes, .groq, .google] {
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
}
