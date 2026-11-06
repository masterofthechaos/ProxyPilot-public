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

    @Test func ollamaAutoRemovesExactLeadingAnthropicBillingHeaderLine() throws {
        let body = Data(#"{"model":"qwen3-coder","messages":[{"role":"system","content":"x-anthropic-billing-header: cc_version=2.1.118.147; cc_entrypoint=sdk-cli; cch=203d1;\nYou are a coding agent."},{"role":"user","content":"Keep this cch=12345 text."}]}"#.utf8)

        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: body,
            provider: .ollama,
            model: "qwen3-coder",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        #expect(mutation.applied)
        #expect(mutation.strategy == "local_anthropic_billing_header_removed")
        let messages = try decodedMessages(from: mutation.body)
        #expect(messages[0]["content"] as? String == "You are a coding agent.")
        #expect(messages[1]["content"] as? String == "Keep this cch=12345 text.")
    }

    @Test func lmStudioAutoRemovesCRLFTerminatedLeadingAnthropicBillingHeaderLine() throws {
        let body = Data(#"{"model":"local-model","messages":[{"role":"system","content":"x-anthropic-billing-header: cc_version=2.1.118.147; cc_entrypoint=sdk-cli; cch=abcde;\r\nStable instructions."}]}"#.utf8)

        let mutation = PromptCacheAdapter.mutate(
            path: "/chat/completions",
            headers: originalHeaders,
            body: body,
            provider: .lmStudio,
            model: "local-model",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        #expect(mutation.applied)
        let messages = try decodedMessages(from: mutation.body)
        #expect(messages[0]["content"] as? String == "Stable instructions.")
    }

    @Test func localAutoPreservesNonLeadingAnthropicBillingHeaderText() {
        let body = Data(#"{"model":"qwen3-coder","messages":[{"role":"system","content":"Stable instructions.\nx-anthropic-billing-header: cc_version=2.1; cch=abcde;"}]}"#.utf8)

        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: body,
            provider: .ollama,
            model: "qwen3-coder",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        #expect(!mutation.applied)
        #expect(mutation.body == body)
    }

    @Test func localAutoPreservesUserRoleBillingHeaderAndArbitraryCCHText() {
        let body = Data(#"{"model":"qwen3-coder","messages":[{"role":"system","content":"Keep arbitrary cch=abcde text."},{"role":"user","content":"x-anthropic-billing-header: cc_version=2.1; cch=12345;\nThis is user content."}]}"#.utf8)

        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: body,
            provider: .ollama,
            model: "qwen3-coder",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        #expect(!mutation.applied)
        #expect(mutation.body == body)
    }

    @Test func observeOnlyPreservesLeadingAnthropicBillingHeader() {
        let body = Data(#"{"model":"qwen3-coder","messages":[{"role":"system","content":"x-anthropic-billing-header: cc_version=2.1; cch=abcde;\nStable instructions."}]}"#.utf8)

        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: body,
            provider: .ollama,
            model: "qwen3-coder",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .observeOnly)
        )

        #expect(!mutation.applied)
        #expect(mutation.body == body)
    }

    @Test func offModePreservesLeadingAnthropicBillingHeader() {
        let body = Data(#"{"model":"qwen3-coder","messages":[{"role":"system","content":"x-anthropic-billing-header: cc_version=2.1; cch=abcde;\nStable instructions."}]}"#.utf8)

        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: body,
            provider: .ollama,
            model: "qwen3-coder",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: false, mode: .off)
        )

        #expect(!mutation.applied)
        #expect(mutation.body == body)
    }

    @Test func cloudProviderPreservesLeadingAnthropicBillingHeader() throws {
        let content = "x-anthropic-billing-header: cc_version=2.1; cch=abcde;\nStable instructions."
        let body = Data(#"{"model":"gpt-5.1","messages":[{"role":"system","content":"x-anthropic-billing-header: cc_version=2.1; cch=abcde;\nStable instructions."}]}"#.utf8)

        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/chat/completions",
            headers: originalHeaders,
            body: body,
            provider: .openAI,
            model: "gpt-5.1",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        #expect(mutation.applied)
        #expect(mutation.strategy == "prompt_cache_key")
        let messages = try decodedMessages(from: mutation.body)
        #expect(messages[0]["content"] as? String == content)
    }

    @Test func anthropicPassthroughPathPreservesLeadingBillingHeader() {
        let body = Data(#"{"model":"qwen3-coder","system":"x-anthropic-billing-header: cc_version=2.1; cch=abcde;\nStable instructions.","messages":[{"role":"user","content":"hi"}]}"#.utf8)

        let mutation = PromptCacheAdapter.mutate(
            path: "/v1/messages",
            headers: originalHeaders,
            body: body,
            provider: .ollama,
            model: "qwen3-coder",
            sessionID: "session-a",
            configuration: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        #expect(!mutation.applied)
        #expect(mutation.body == body)
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

    private func decodedMessages(from body: Data) throws -> [[String: Any]] {
        let request = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require(request["messages"] as? [[String: Any]])
    }
}

@Suite("OpenRouter cache policy")
struct OpenRouterCachePolicyTests {
    private func mutate(_ json: String, session: String = "session-a", headers: [(String, String)] = [], mode: PromptCachingMode = .computeCacheHints) -> PromptCacheMutation {
        PromptCacheAdapter.mutate(path: "/v1/chat/completions", headers: headers, body: Data(json.utf8), provider: .openRouter, model: nil, sessionID: session, configuration: .init(isEnabled: true, mode: mode))
    }

    @Test func automaticAffinityIsOpaqueStableAndSessionScoped() throws {
        let input = #"{"model":"qwen/model","messages":[{"role":"user","content":"hi"}]}"#
        let a = mutate(input)
        let repeatA = mutate(input)
        let b = mutate(input, session: "session-b")
        let root = try #require(JSONSerialization.jsonObject(with: a.body) as? [String: Any])
        let key = try #require(root["session_id"] as? String)
        #expect(a.body == repeatA.body)
        #expect(a.body != b.body)
        #expect(key.hasPrefix("pp_"))
        #expect(!key.contains("session-a"))
        #expect(key.count <= 256)
        #expect(root["cache_control"] == nil)
        #expect(root["prompt_cache_key"] == nil)
        #expect(a.strategy == "openrouter_session_affinity")
    }

    @Test func anthropicAddsAutomaticPolicyWithoutChangingMessages() throws {
        let input = #"{"model":"anthropic/claude-test","messages":[{"role":"user","content":"hi"}]}"#
        let result = mutate(input)
        let root = try #require(JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        #expect((root["cache_control"] as? [String: String]) == ["type": "ephemeral"])
        #expect((root["messages"] as? [[String: String]]) == [["role": "user", "content": "hi"]])
        #expect(result.strategy == "openrouter_session_affinity+anthropic_auto_cache_control")
        #expect(result.applied)
    }

    @Test func callerSessionAndExplicitBreakpointsRemainUnchanged() throws {
        let input = #"{"model":"anthropic/claude-test","session_id":"caller","prompt_cache_key":"caller-key","messages":[{"role":"user","content":[{"type":"text","text":"hi","cache_control":{"type":"ephemeral","ttl":"1h"}}]}]}"#
        let result = mutate(input)
        #expect(result.body == Data(input.utf8))
        #expect(!result.applied)
        #expect(result.strategy == "existing_openrouter_cache_hints")
    }

    @Test func callerSessionHeaderAndBodyPrecedenceRemainUnchanged() throws {
        let input = #"{"model":"qwen/model","session_id":"body-wins"}"#
        let result = mutate(input, headers: [("X-Session-ID", "header")])
        #expect(result.body == Data(input.utf8))
        #expect(result.headers.first?.1 == "header")
        let headerOnly = #"{"model":"qwen/model"}"#
        #expect(mutate(headerOnly, headers: [("X-Session-ID", "header")]).body == Data(headerOnly.utf8))
    }

    @Test func offAndObserveDoNotAlterCallerBytes() {
        let input = #"{ "model": "anthropic/claude-test", "cache_control": null }"#
        for mode in [PromptCachingMode.off, .observeOnly] {
            let result = mutate(input, mode: mode)
            #expect(result.body == Data(input.utf8))
            #expect(!result.applied)
        }
    }

    @Test func attributedSessionIdentityAndOutcomeAreRequestScoped() async {
        let firstID = UUID().uuidString.lowercased()
        let secondID = UUID().uuidString.lowercased()
        let results = await withTaskGroup(of: String.self, returning: Set<String>.self) { group in
            for id in [firstID, secondID] {
                group.addTask {
                    await RequestAttributionContext.$current.withValue(.validated(client: "repogps", sessionID: id)) {
                        await PromptCacheRequestContext.$current.withValue(PromptCacheRequestContext()) {
                            let identity = PromptCacheRequestContext.sessionID(fallback: "daemon")
                            PromptCacheRequestContext.current?.record(.init(body: Data(), applied: true, strategy: id))
                            await Task.yield()
                            #expect(PromptCacheRequestContext.current?.outcome?.strategy == id)
                            return identity
                        }
                    }
                }
            }
            var identities = Set<String>()
            for await result in group { identities.insert(result) }
            return identities
        }
        #expect(results == [firstID, secondID])
        #expect(PromptCacheRequestContext.sessionID(fallback: "daemon") == "daemon")
        #expect(PromptCacheRequestContext.current == nil)
    }

    @Test func legacyRecordKeepsUnknownAdapterOutcome() throws {
        let old = Data(#"{"timestamp":0,"model":"old","promptTokens":10,"completionTokens":1,"durationSeconds":1,"path":"/v1/chat/completions","wasStreaming":false}"#.utf8)
        let decoded = try JSONDecoder().decode(RequestRecord.self, from: old)
        #expect(decoded.promptCacheStrategy == nil)
        #expect(decoded.promptCacheApplied == nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(encoded["promptCacheApplied"] == nil)
    }
}
