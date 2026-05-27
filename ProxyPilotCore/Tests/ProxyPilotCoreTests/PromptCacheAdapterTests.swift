import Foundation
import Testing
@testable import ProxyPilotCore

@Suite("PromptCacheAdapter")
struct PromptCacheAdapterTests {
    private let jsonBody = Data(#"{"model":"test-model","messages":[{"role":"user","content":"hi"}]}"#.utf8)
    private let originalHeaders = [
        ("Content-Type", "application/json"),
        ("Accept", "text/event-stream"),
        ("X-Test-Header", "keep-me")
    ]

    @Test func passThroughPreservesHeaders() {
        let mutation = PromptCacheMutation.passThrough(body: jsonBody, headers: originalHeaders)

        #expect(mutation.body == jsonBody)
        #expect(!mutation.applied)
        expectHeaders(mutation.headers, equal: originalHeaders)
    }

    @Test func observeOnlyPreservesHeaders() {
        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: jsonBody,
            provider: .openAI,
            model: "gpt-5.1",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .observeOnly)
        )

        #expect(mutation.body == jsonBody)
        #expect(!mutation.applied)
        expectHeaders(mutation.headers, equal: originalHeaders)
    }

    @Test func offModePreservesHeaders() {
        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: jsonBody,
            provider: .openAI,
            model: "gpt-5.1",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .off)
        )

        #expect(mutation.body == jsonBody)
        #expect(!mutation.applied)
        expectHeaders(mutation.headers, equal: originalHeaders)
    }

    @Test func disabledConfigurationPreservesHeaders() {
        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: jsonBody,
            provider: .openAI,
            model: "gpt-5.1",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: false, mode: .computeCacheHints)
        )

        #expect(mutation.body == jsonBody)
        #expect(!mutation.applied)
        expectHeaders(mutation.headers, equal: originalHeaders)
    }

    @Test func blockedProviderPreservesHeaders() {
        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: jsonBody,
            provider: .google,
            model: "gemini-3.1-pro-preview",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        #expect(mutation.body == jsonBody)
        #expect(!mutation.applied)
        #expect(mutation.strategy == "blocked")
        expectHeaders(mutation.headers, equal: originalHeaders)
    }

    @Test func zAIObserveOnlyPreservesHeadersAndBody() {
        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: jsonBody,
            provider: .zAI,
            model: "glm-5.1",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .observeOnly)
        )

        #expect(mutation.body == jsonBody)
        #expect(!mutation.applied)
        expectHeaders(mutation.headers, equal: originalHeaders)
    }

    @Test func zAIAutoCanonicalizesJSONWithoutInventingCacheKeys() throws {
        let firstBody = Data(#"{"messages":[{"content":{"b":2,"a":1},"role":"user"}],"model":"glm-5.1"}"#.utf8)
        let secondBody = Data(#"{"model":"glm-5.1","messages":[{"role":"user","content":{"a":1,"b":2}}]}"#.utf8)
        let configuration = PromptCachingConfiguration(
            isEnabled: true,
            mode: .computeCacheHints,
            canonicalizeJSONForCache: true
        )

        let first = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: firstBody,
            provider: .zAI,
            model: "glm-5.1",
            sessionID: "session-a",
            configuration: configuration
        )
        let second = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: secondBody,
            provider: .zAI,
            model: "glm-5.1",
            sessionID: "session-a",
            configuration: configuration
        )

        #expect(first.applied)
        #expect(first.strategy == "json_canonicalization")
        #expect(first.body == second.body)
        expectHeaders(first.headers, equal: originalHeaders)

        let mutated = try #require(JSONSerialization.jsonObject(with: first.body) as? [String: Any])
        #expect(mutated["prompt_cache_key"] == nil)
        #expect(!first.headers.contains { $0.0.lowercased() == "x-grok-conv-id" })
    }

    @Test func observeOnlyIgnoresCanonicalizationRequest() {
        let body = Data(#"{"z":1,"a":2}"#.utf8)
        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: body,
            provider: .zAI,
            model: "glm-5.1",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(
                isEnabled: true,
                mode: .observeOnly,
                canonicalizeJSONForCache: true
            )
        )

        #expect(mutation.body == body)
        #expect(!mutation.applied)
        expectHeaders(mutation.headers, equal: originalHeaders)
    }

    @Test func offModeIgnoresCanonicalizationRequest() {
        let body = Data(#"{"z":1,"a":2}"#.utf8)
        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: body,
            provider: .zAI,
            model: "glm-5.1",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(
                isEnabled: true,
                mode: .off,
                canonicalizeJSONForCache: true
            )
        )

        #expect(mutation.body == body)
        #expect(!mutation.applied)
        expectHeaders(mutation.headers, equal: originalHeaders)
    }

    @Test func openAIComputeHintsInjectStablePromptCacheKey() throws {
        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: jsonBody,
            provider: .openAI,
            model: "gpt-5.1",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        #expect(mutation.applied)
        #expect(mutation.strategy == "prompt_cache_key")
        expectHeaders(mutation.headers, equal: originalHeaders)

        let mutated = try #require(JSONSerialization.jsonObject(with: mutation.body) as? [String: Any])
        #expect(mutated["prompt_cache_key"] as? String == "048778bd77d4e0fa4f53c104_2")
        #expect(mutated["model"] as? String == "test-model")
        #expect((mutated["messages"] as? [[String: Any]])?.first?["content"] as? String == "hi")
    }

    @Test func openAIExistingPromptCacheKeyIsPreserved() throws {
        let body = Data(#"{"model":"test-model","prompt_cache_key":"caller-key","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: body,
            provider: .openAI,
            model: "gpt-5.1",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        #expect(!mutation.applied)
        #expect(mutation.strategy == "existing_prompt_cache_key")
        expectHeaders(mutation.headers, equal: originalHeaders)
        let mutated = try #require(JSONSerialization.jsonObject(with: mutation.body) as? [String: Any])
        #expect(mutated["prompt_cache_key"] as? String == "caller-key")
    }

    @Test func mistralComputeHintsInjectPromptCacheKey() throws {
        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: jsonBody,
            provider: .mistral,
            model: "mistral-large-latest",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        #expect(mutation.applied)
        #expect(mutation.strategy == "prompt_cache_key")
        let mutated = try #require(JSONSerialization.jsonObject(with: mutation.body) as? [String: Any])
        #expect(mutated["prompt_cache_key"] as? String == "e477e6827f862b65a9690b8f_3")
    }

    @Test func xAIChatCompletionsInjectsConversationHeader() {
        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: jsonBody,
            provider: .xAI,
            model: "grok-4",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        #expect(mutation.applied)
        #expect(mutation.strategy == "x-grok-conv-id")
        #expect(mutation.body == jsonBody)
        #expect(mutation.headers.contains { $0.0 == "x-grok-conv-id" && $0.1 == "90f67fda88acbac6f54ceaea_1" })
        #expect(mutation.headers.filter { $0.0.lowercased() == "x-grok-conv-id" }.count == 1)
    }

    @Test func googleComputeHintsStayBlocked() {
        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: jsonBody,
            provider: .google,
            model: "gemini-3.1-pro-preview",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        #expect(!mutation.applied)
        #expect(mutation.strategy == "blocked")
        #expect(!mutation.notes.isEmpty)
        expectHeaders(mutation.headers, equal: originalHeaders)
    }

    @Test func miniMaxAnthropicPassthroughInjectsCacheControl() throws {
        let body = Data(#"{"model":"MiniMax-M2","max_tokens":128,"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/messages",
            headers: originalHeaders,
            body: body,
            provider: .miniMax,
            model: "MiniMax-M2",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        #expect(mutation.applied)
        #expect(mutation.strategy == "anthropic_cache_control")
        expectHeaders(mutation.headers, equal: originalHeaders)

        let mutated = try #require(JSONSerialization.jsonObject(with: mutation.body) as? [String: Any])
        let cacheControl = try #require(mutated["cache_control"] as? [String: Any])
        #expect(cacheControl["type"] as? String == "ephemeral")
    }

    @Test func miniMaxExistingAnthropicCacheControlIsPreserved() throws {
        let body = Data(#"{"model":"MiniMax-M2","cache_control":{"type":"ephemeral"},"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/messages",
            headers: originalHeaders,
            body: body,
            provider: .miniMax,
            model: "MiniMax-M2",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        #expect(!mutation.applied)
        #expect(mutation.strategy == "existing_anthropic_cache_control")
        #expect(mutation.body == body)
        expectHeaders(mutation.headers, equal: originalHeaders)
    }

    @Test func deepSeekAnthropicPassthroughDoesNotInjectCacheControl() throws {
        let body = Data(#"{"model":"deepseek-v4-flash","max_tokens":128,"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/messages",
            headers: originalHeaders,
            body: body,
            provider: .deepSeek,
            model: "deepseek-v4-flash",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        #expect(!mutation.applied)
        #expect(mutation.strategy == "unsupported")
        #expect(mutation.body == body)
        expectHeaders(mutation.headers, equal: originalHeaders)
    }

    private func expectHeaders(
        _ actual: [(String, String)],
        equal expected: [(String, String)],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        for (index, expectedHeader) in expected.enumerated() {
            guard index < actual.count else { return }
            #expect(actual[index].0 == expectedHeader.0, sourceLocation: sourceLocation)
            #expect(actual[index].1 == expectedHeader.1, sourceLocation: sourceLocation)
        }
    }
}
