import Foundation
import Testing
@testable import ProxyPilotCore

@Suite("ContextCompactionAdapter")
struct ContextCompactionAdapterTests {
    private let ruleset = ContextCompactionEngineTests.syntheticRuleset()
    private var wall: String { ContextCompactionEngineTests.syntheticBody }
    private var expectedCompactedBody: String {
        ContextCompactionEngineTests.wallHeader + "## Alpha (condensed)\n## Beta (condensed)\n## Gamma (condensed)\n"
    }

    // MARK: - Gating

    @Test func disabledConfigurationPassesThrough() {
        let mutation = ContextCompactionAdapter.compactAnthropicSystem(
            wall, provider: .ollama,
            configuration: .disabled, ruleset: ruleset, cache: ContextCompactionCache()
        )
        #expect(!mutation.applied)
        #expect(mutation.system == nil)
        #expect(mutation.strategy == "disabled")
    }

    @Test func cloudProviderIsUnsupported() {
        let mutation = ContextCompactionAdapter.compactAnthropicSystem(
            wall, provider: .zAI,
            configuration: .enabled, ruleset: ruleset, cache: ContextCompactionCache()
        )
        #expect(!mutation.applied)
        #expect(mutation.strategy == "unsupported_provider")
    }

    @Test func localHelperProvidersThatForwardToCloudAreUnsupported() {
        // 9Router is local, but proxies to cloud inference — compaction targets
        // true local runtimes only.
        let mutation = ContextCompactionAdapter.compactAnthropicSystem(
            wall, provider: .nineRouter,
            configuration: .enabled, ruleset: ruleset, cache: ContextCompactionCache()
        )
        #expect(mutation.strategy == "unsupported_provider")
    }

    @Test func supportsContextCompactionTruthTable() {
        for provider in UpstreamProvider.allCases {
            let expected = provider == .ollama || provider == .lmStudio
            #expect(provider.supportsContextCompaction == expected, "\(provider.rawValue)")
        }
    }

    @Test func missingSystemPassesThrough() {
        let mutation = ContextCompactionAdapter.compactAnthropicSystem(
            nil, provider: .ollama,
            configuration: .enabled, ruleset: ruleset, cache: ContextCompactionCache()
        )
        #expect(mutation.strategy == "no_system")
    }

    // MARK: - Compaction

    @Test func recognizedWallIsCompactedForOllama() {
        let mutation = ContextCompactionAdapter.compactAnthropicSystem(
            wall, provider: .ollama,
            configuration: .enabled, ruleset: ruleset, cache: ContextCompactionCache()
        )
        #expect(mutation.applied)
        #expect(mutation.strategy == "compacted_v1")
        #expect(mutation.system == expectedCompactedBody)
        #expect(mutation.originalUTF8Bytes == wall.utf8.count)
        #expect(mutation.compactedUTF8Bytes == expectedCompactedBody.utf8.count)
        #expect(mutation.compactedUTF8Bytes < mutation.originalUTF8Bytes)
    }

    @Test func billingPreambleIsReattachedUnchanged() {
        let billing = "x-anthropic-billing-header: plan=pro; cch=fff000\n"
        let mutation = ContextCompactionAdapter.compactAnthropicSystem(
            billing + wall, provider: .lmStudio,
            configuration: .enabled, ruleset: ruleset, cache: ContextCompactionCache()
        )
        #expect(mutation.applied)
        #expect(mutation.system == billing + expectedCompactedBody)
    }

    @Test func secondIdenticalWallHitsCache() {
        let cache = ContextCompactionCache()
        let first = ContextCompactionAdapter.compactAnthropicSystem(
            wall, provider: .ollama,
            configuration: .enabled, ruleset: ruleset, cache: cache
        )
        let second = ContextCompactionAdapter.compactAnthropicSystem(
            wall, provider: .ollama,
            configuration: .enabled, ruleset: ruleset, cache: cache
        )
        #expect(first.strategy == "compacted_v1")
        #expect(second.strategy == "cache_hit_v1")
        #expect(second.system == first.system)
    }

    @Test func rotatingBillingValueStillHitsCache() {
        let cache = ContextCompactionCache()
        _ = ContextCompactionAdapter.compactAnthropicSystem(
            "x-anthropic-billing-header: cch=aaa\n" + wall, provider: .ollama,
            configuration: .enabled, ruleset: ruleset, cache: cache
        )
        let second = ContextCompactionAdapter.compactAnthropicSystem(
            "x-anthropic-billing-header: cch=bbb\n" + wall, provider: .ollama,
            configuration: .enabled, ruleset: ruleset, cache: cache
        )
        #expect(second.strategy == "cache_hit_v1")
        #expect(second.system == "x-anthropic-billing-header: cch=bbb\n" + expectedCompactedBody)
    }

    @Test func unrecognizedTextPassesThroughAndCachesVerdict() {
        let cache = ContextCompactionCache()
        let unknown = String(repeating: "Some other agent's prompt.\n", count: 200)
        let first = ContextCompactionAdapter.compactAnthropicSystem(
            unknown, provider: .ollama,
            configuration: .enabled, ruleset: ruleset, cache: cache
        )
        let second = ContextCompactionAdapter.compactAnthropicSystem(
            unknown, provider: .ollama,
            configuration: .enabled, ruleset: ruleset, cache: cache
        )
        #expect(first.strategy == "fingerprint_miss")
        #expect(first.system == nil)
        #expect(second.strategy == "fingerprint_miss")
        #expect(second.notes.contains("cached_verdict"))
    }

    // MARK: - System block arrays

    @Test func systemBlockArrayIsJoinedLikeTheTranslator() {
        // Split the wall so that joining the blocks with "\n" (the
        // translator's separator) reproduces the exact wall text: the first
        // block drops its trailing newline, which the join restores.
        let blocks: [[String: Any]] = [
            ["type": "text", "text": String((ContextCompactionEngineTests.wallHeader + ContextCompactionEngineTests.alphaSection).dropLast())],
            ["type": "text", "text": ContextCompactionEngineTests.betaSection + ContextCompactionEngineTests.gammaSection],
        ]
        let joined = ContextCompactionAdapter.flattenedSystemText(blocks)
        #expect(joined == wall)

        let mutation = ContextCompactionAdapter.compactAnthropicSystem(
            blocks, provider: .ollama,
            configuration: .enabled, ruleset: ruleset, cache: ContextCompactionCache()
        )
        #expect(mutation.applied)
        #expect(mutation.system == expectedCompactedBody)
    }

    // MARK: - Translator integration

    @Test func compactionThenTranslationLeavesMessagesAndToolsUntouched() throws {
        var request: [String: Any] = [
            "model": "claude-test",
            "system": wall,
            "messages": [
                ["role": "user", "content": "Fix the build error in main.swift"],
            ],
            "tools": [
                ["name": "str_replace", "description": "Edit a file", "input_schema": ["type": "object"]],
            ],
            "max_tokens": 512,
        ]

        let mutation = ContextCompactionAdapter.compactAnthropicSystem(
            request["system"], provider: .ollama,
            configuration: .enabled, ruleset: ruleset, cache: ContextCompactionCache()
        )
        if mutation.applied, let system = mutation.system {
            request["system"] = system
        }

        let translated = AnthropicTranslator.requestToOpenAI(request)
        let messages = try #require(translated["messages"] as? [[String: Any]])

        #expect(messages.first?["role"] as? String == "system")
        #expect(messages.first?["content"] as? String == expectedCompactedBody)
        #expect(messages.last?["role"] as? String == "user")
        #expect(messages.last?["content"] as? String == "Fix the build error in main.swift")
        let tools = try #require(translated["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
    }

    @Test func passthroughMutationLeavesOriginalRequestValueIntact() {
        var request: [String: Any] = ["system": "short prompt", "messages": []]
        let mutation = ContextCompactionAdapter.compactAnthropicSystem(
            request["system"], provider: .ollama,
            configuration: .enabled, ruleset: ruleset, cache: ContextCompactionCache()
        )
        if mutation.applied, let system = mutation.system {
            request["system"] = system
        }
        #expect(request["system"] as? String == "short prompt")
    }
}
