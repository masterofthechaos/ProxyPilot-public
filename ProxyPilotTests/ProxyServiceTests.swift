import XCTest
@testable import ProxyPilot

@MainActor
final class ProxyServiceTests: XCTestCase {
    func testReadLogTailFromSpecificFileReturnsSuffix() throws {
        let service = ProxyService(homeDirectory: FileManager.default.temporaryDirectory)
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxypilot-test-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logURL) }

        try "0123456789".write(to: logURL, atomically: true, encoding: .utf8)

        let tail = service.readLogTail(from: logURL, maxBytes: 4)
        XCTAssertEqual(tail, "6789")
    }

    func testReadLogTailFromMissingFileReturnsEmptyString() {
        let service = ProxyService(homeDirectory: FileManager.default.temporaryDirectory)
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxypilot-missing-\(UUID().uuidString).log")
        XCTAssertEqual(service.readLogTail(from: logURL), "")
    }

    // MARK: - /v1/models pricing decode

    private func decodeModelsPayload(_ json: String) throws -> OpenAIModelsResponse {
        try JSONDecoder().decode(OpenAIModelsResponse.self, from: XCTUnwrap(json.data(using: .utf8)))
    }

    func testUpstreamModelsDecodesOpenRouterCachePricingPerMillion() throws {
        // Shape taken from OpenRouter's /api/v1/models: prices are decimal strings in
        // USD per single token.
        let decoded = try decodeModelsPayload("""
        {"data": [{
            "id": "google/gemini-3.5-flash",
            "context_length": 1048576,
            "pricing": {
                "prompt": "0.0000003",
                "completion": "0.0000025",
                "input_cache_read": "0.000000075",
                "input_cache_write": "0.0000003833"
            },
            "supported_parameters": ["tools"]
        }]}
        """)

        let model = try XCTUnwrap(ProxyService.upstreamModels(from: decoded, provider: .openRouter).first)
        XCTAssertEqual(try XCTUnwrap(model.promptPricePer1M), 0.30, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(model.completionPricePer1M), 2.50, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(model.promptCacheHitPricePer1M), 0.075, accuracy: 0.000001)
        // `prompt` is the uncached input price, so it doubles as the miss price.
        XCTAssertEqual(try XCTUnwrap(model.promptCacheMissPricePer1M), 0.30, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(model.promptCacheWritePricePer1M), 0.3833, accuracy: 0.000001)
    }

    func testUpstreamModelsLeavesCacheSplitNilWhenProviderReportsNoCacheReadPrice() throws {
        // Without a cache-read price the hit/miss pair is meaningless, and populating
        // the miss price alone would flip pricingPerMillionLabel into its
        // "cached · uncached" form for a model that does no caching.
        let decoded = try decodeModelsPayload("""
        {"data": [{
            "id": "some/uncached-model",
            "context_length": 32768,
            "pricing": {"prompt": "0.000002", "completion": "0.000006"}
        }]}
        """)

        let model = try XCTUnwrap(ProxyService.upstreamModels(from: decoded, provider: .openRouter).first)
        XCTAssertEqual(try XCTUnwrap(model.promptPricePer1M), 2.0, accuracy: 0.000001)
        XCTAssertNil(model.promptCacheHitPricePer1M)
        XCTAssertNil(model.promptCacheMissPricePer1M)
        XCTAssertNil(model.promptCacheWritePricePer1M)
        XCTAssertEqual(model.pricingPerMillionLabel, "In $2.00/M · Out $6.00/M")
    }

    func testUpstreamModelsCachePricingReachesTheCostEstimate() throws {
        // The end-to-end point of the decode: cached reads must be billed at the cache
        // rate, not the full uncached prompt rate.
        let decoded = try decodeModelsPayload("""
        {"data": [{
            "id": "google/gemini-3.5-flash",
            "pricing": {
                "prompt": "0.0000003",
                "completion": "0.0000025",
                "input_cache_read": "0.000000075"
            }
        }]}
        """)

        let model = try XCTUnwrap(ProxyService.upstreamModels(from: decoded, provider: .openRouter).first)
        let cost = try XCTUnwrap(model.estimatedCostUSD(
            promptTokens: 1_000_000,
            completionTokens: 0,
            promptCacheHitTokens: 800_000,
            promptCacheMissTokens: 200_000
        ))
        // 0.8M cached at $0.075/M + 0.2M uncached at $0.30/M = 0.06 + 0.06
        XCTAssertEqual(cost, 0.12, accuracy: 0.000001)
        // The no-cache formula would have charged the full prompt rate on all 1M.
        XCTAssertNotEqual(cost, 0.30, accuracy: 0.000001)
    }

    func testNormalizedUpstreamBaseStripsChatCompletionsSuffix() throws {
        let input = try XCTUnwrap(URL(string: "https://openrouter.ai/api/v1/chat/completions"))
        let normalized = ProxyService.normalizedUpstreamAPIBase(input)
        XCTAssertEqual(normalized.absoluteString, "https://openrouter.ai/api/v1")
    }

    func testNormalizedUpstreamBaseStripsModelsSuffix() throws {
        let input = try XCTUnwrap(URL(string: "https://openrouter.ai/api/v1/models"))
        let normalized = ProxyService.normalizedUpstreamAPIBase(input)
        XCTAssertEqual(normalized.absoluteString, "https://openrouter.ai/api/v1")
    }

    func testNormalizedUpstreamBasePreservesAlreadyValidBase() throws {
        let input = try XCTUnwrap(URL(string: "https://api.z.ai/api/coding/paas/v4"))
        let normalized = ProxyService.normalizedUpstreamAPIBase(input)
        XCTAssertEqual(normalized.absoluteString, "https://api.z.ai/api/coding/paas/v4")
    }

    func testNormalizedUpstreamBasePreservesGoogleOpenAICompatBase() throws {
        let input = try XCTUnwrap(URL(string: "https://generativelanguage.googleapis.com/v1beta/openai"))
        let normalized = ProxyService.normalizedUpstreamAPIBase(input)
        XCTAssertEqual(normalized.absoluteString, "https://generativelanguage.googleapis.com/v1beta/openai")
    }

    func testNormalizedUpstreamBaseDropsQueryAndFragment() throws {
        let input = try XCTUnwrap(URL(string: "https://openrouter.ai/api/v1/chat/completions?foo=bar#frag"))
        let normalized = ProxyService.normalizedUpstreamAPIBase(input)
        XCTAssertEqual(normalized.absoluteString, "https://openrouter.ai/api/v1")
    }

}
