import XCTest
import ProxyPilotCore
@testable import ProxyPilot

final class UpstreamModelTests: XCTestCase {
    // MARK: - contextFormatted

    func testContextFormattedNil() {
        let model = UpstreamModel.idOnly("test-model")
        XCTAssertNil(model.contextFormatted)
    }

    func testContextFormattedZero() {
        let model = UpstreamModel(id: "m", contextLength: 0, promptPricePer1M: nil, completionPricePer1M: nil)
        XCTAssertNil(model.contextFormatted)
    }

    func testContextFormattedSmall() {
        let model = UpstreamModel(id: "m", contextLength: 512, promptPricePer1M: nil, completionPricePer1M: nil)
        XCTAssertEqual(model.contextFormatted, "512")
    }

    func testContextFormattedThousands() {
        let model = UpstreamModel(id: "m", contextLength: 4096, promptPricePer1M: nil, completionPricePer1M: nil)
        XCTAssertEqual(model.contextFormatted, "4.1K")
    }

    func testContextFormattedEvenThousands() {
        let model = UpstreamModel(id: "m", contextLength: 8000, promptPricePer1M: nil, completionPricePer1M: nil)
        XCTAssertEqual(model.contextFormatted, "8K")
    }

    func testContextFormatted128K() {
        let model = UpstreamModel(id: "m", contextLength: 128_000, promptPricePer1M: nil, completionPricePer1M: nil)
        XCTAssertEqual(model.contextFormatted, "128K")
    }

    func testContextFormatted1M() {
        let model = UpstreamModel(id: "m", contextLength: 1_000_000, promptPricePer1M: nil, completionPricePer1M: nil)
        XCTAssertEqual(model.contextFormatted, "1M")
    }

    func testContextFormatted2M() {
        let model = UpstreamModel(id: "m", contextLength: 2_000_000, promptPricePer1M: nil, completionPricePer1M: nil)
        XCTAssertEqual(model.contextFormatted, "2M")
    }

    // MARK: - pricingTier

    func testPricingTierUnknownWhenNil() {
        let model = UpstreamModel.idOnly("m")
        XCTAssertEqual(model.pricingTier, .unknown)
    }

    func testPricingTierFree() {
        let model = UpstreamModel(id: "m", contextLength: nil, promptPricePer1M: 0, completionPricePer1M: 0)
        XCTAssertEqual(model.pricingTier, .free)
        XCTAssertEqual(model.pricingTier.label, "Free")
    }

    func testPricingTierBudget() {
        let model = UpstreamModel(id: "m", contextLength: nil, promptPricePer1M: 0.5, completionPricePer1M: 1.0)
        XCTAssertEqual(model.pricingTier, .budget)
        XCTAssertEqual(model.pricingTier.label, "$")
    }

    func testPricingTierStandard() {
        let model = UpstreamModel(id: "m", contextLength: nil, promptPricePer1M: 3.0, completionPricePer1M: 6.0)
        XCTAssertEqual(model.pricingTier, .standard)
        XCTAssertEqual(model.pricingTier.label, "$$")
    }

    func testPricingTierPremium() {
        let model = UpstreamModel(id: "m", contextLength: nil, promptPricePer1M: 15.0, completionPricePer1M: 60.0)
        XCTAssertEqual(model.pricingTier, .premium)
        XCTAssertEqual(model.pricingTier.label, "$$$")
    }

    func testPricingTierUnknownLabel() {
        XCTAssertEqual(PricingTier.unknown.label, "")
    }

    func testEstimatedCostUSDUsesPromptAndCompletionPricing() throws {
        let model = UpstreamModel(id: "m", contextLength: nil, promptPricePer1M: 2.0, completionPricePer1M: 6.0)
        let cost = try XCTUnwrap(model.estimatedCostUSD(promptTokens: 1_000, completionTokens: 500))
        XCTAssertEqual(cost, 0.005, accuracy: 0.000001)
    }

    func testEstimatedCostUSDNilWithoutPricingMetadata() {
        let model = UpstreamModel.idOnly("m")
        XCTAssertNil(model.estimatedCostUSD(promptTokens: 100, completionTokens: 100))
    }

    func testEstimatedCostUSDUsesExplicitCacheSplitWhenPricingRequiresIt() throws {
        let model = UpstreamModel(
            id: "m",
            contextLength: nil,
            promptPricePer1M: 0.14,
            completionPricePer1M: 0.28,
            promptCacheHitPricePer1M: 0.0028,
            promptCacheMissPricePer1M: 0.14
        )

        let cost = try XCTUnwrap(model.estimatedCostUSD(
            promptTokens: 1_000_000,
            completionTokens: 1_000_000,
            promptCacheHitTokens: 250_000,
            promptCacheMissTokens: 750_000
        ))
        XCTAssertEqual(cost, 0.3857, accuracy: 0.000001)
    }

    func testEstimatedCostUSDFallsBackToStandardPricingWhenCacheSplitMissing() throws {
        // When cache pricing is configured but call-site lacks a hit/miss split,
        // we fall back to standard prompt/completion pricing rather than returning nil.
        // This keeps providers like DeepSeek priced when upstream reports only aggregate
        // prompt token counts.
        let model = UpstreamModel(
            id: "m",
            contextLength: nil,
            promptPricePer1M: 0.14,
            completionPricePer1M: 0.28,
            promptCacheHitPricePer1M: 0.0028,
            promptCacheMissPricePer1M: 0.14
        )
        let cost = try XCTUnwrap(model.estimatedCostUSD(
            promptTokens: 1_000_000,
            completionTokens: 1_000_000
        ))
        XCTAssertEqual(cost, 0.42, accuracy: 0.000001)
    }

    func testEstimatedCostUSDPricesCacheWritesOnceWithinTheMissSplit() throws {
        // Normalized misses include creation tokens. The full cache-write rate
        // replaces their ordinary input charge.
        let model = UpstreamModel(
            id: "m",
            contextLength: nil,
            promptPricePer1M: 3.0,
            completionPricePer1M: 15.0,
            promptCacheHitPricePer1M: 0.3,
            promptCacheMissPricePer1M: 3.0,
            promptCacheWritePricePer1M: 3.75
        )

        let cost = try XCTUnwrap(model.estimatedCostUSD(
            promptTokens: 1_000_000,
            completionTokens: 1_000_000,
            promptCacheHitTokens: 400_000,
            promptCacheMissTokens: 600_000,
            promptCacheWriteTokens: 200_000
        ))
        // hit 0.12 + ordinary miss 1.20 + write 0.75 + completion 15.00
        XCTAssertEqual(cost, 17.07, accuracy: 0.000001)
    }

    func testEstimatedCostUSDOmitsCacheWriteCostWhenWriteTokensAreMissing() throws {
        // A provider that prices cache writes but reports no write tokens for this
        // request must not be charged for creation it never performed.
        let model = UpstreamModel(
            id: "m",
            contextLength: nil,
            promptPricePer1M: 3.0,
            completionPricePer1M: 15.0,
            promptCacheHitPricePer1M: 0.3,
            promptCacheMissPricePer1M: 3.0,
            promptCacheWritePricePer1M: 3.75
        )

        let cost = try XCTUnwrap(model.estimatedCostUSD(
            promptTokens: 1_000_000,
            completionTokens: 1_000_000,
            promptCacheHitTokens: 400_000,
            promptCacheMissTokens: 600_000
        ))
        // hit 0.12 + miss 1.80 + completion 15.00, no write term
        XCTAssertEqual(cost, 16.92, accuracy: 0.000001)
    }

    func testEstimatedCostUSDMatchesOpenRouterColdAndWarmReceipts() throws {
        let model = UpstreamModel(id: "fixture", contextLength: nil, promptPricePer1M: 1,
            completionPricePer1M: 5, promptCacheHitPricePer1M: 0.05, promptCacheWritePricePer1M: 1.25)
        let cold = try XCTUnwrap(model.estimatedCostUSD(promptTokens: 3867, completionTokens: 5,
            promptCacheHitTokens: 0, promptCacheMissTokens: 3867, promptCacheWriteTokens: 3864))
        XCTAssertEqual(cold, 0.004858, accuracy: 0.0000000001)
        let warm = try XCTUnwrap(model.estimatedCostUSD(promptTokens: 3867, completionTokens: 5,
            promptCacheHitTokens: 3864, promptCacheMissTokens: 3, promptCacheWriteTokens: 0))
        XCTAssertEqual(warm, 0.0002212, accuracy: 0.0000000001)
    }

    func testEstimatedCostUSDUsesNormalizedNativeAnthropicMisses() throws {
        let data = Data(#"{"usage":{"input_tokens":300,"cache_creation_input_tokens":75,"cache_read_input_tokens":200,"output_tokens":40}}"#.utf8)
        let usage = try XCTUnwrap(AnthropicTranslator.anthropicPassthroughUsage(from: data))
        XCTAssertEqual(usage.promptCacheMissTokens, 375)
        let model = UpstreamModel(id: "fixture", contextLength: nil, promptPricePer1M: 3,
            completionPricePer1M: 15, promptCacheHitPricePer1M: 0.3, promptCacheWritePricePer1M: 3.75)
        let cost = try XCTUnwrap(model.estimatedCostUSD(promptTokens: try XCTUnwrap(usage.promptTokens),
            completionTokens: try XCTUnwrap(usage.completionTokens), promptCacheHitTokens: usage.promptCacheHitTokens,
            promptCacheMissTokens: usage.promptCacheMissTokens, promptCacheWriteTokens: usage.promptCacheWriteTokens))
        XCTAssertEqual(cost, 0.00184125, accuracy: 0.0000000001)
    }

    func testEstimatedCostUSDDistinguishesMissingAndFreeWritePricing() throws {
        for (writePrice, expected) in [(nil as Double?, 0.003892), (0.0, 0.000028), (1.25, 0.004858)] {
            let model = UpstreamModel(id: "fixture", contextLength: nil, promptPricePer1M: 1,
                completionPricePer1M: 5, promptCacheWritePricePer1M: writePrice)
            let cost = try XCTUnwrap(model.estimatedCostUSD(promptTokens: 3867, completionTokens: 5,
                promptCacheHitTokens: 0, promptCacheMissTokens: 3867, promptCacheWriteTokens: 3864))
            XCTAssertEqual(cost, expected, accuracy: 0.0000000001)
        }
    }

    func testExactoVariantCarriesCacheWritePricingForward() {
        let model = UpstreamModel(
            id: "m",
            contextLength: nil,
            promptPricePer1M: 3.0,
            completionPricePer1M: 15.0,
            promptCacheHitPricePer1M: 0.3,
            promptCacheMissPricePer1M: 3.0,
            promptCacheWritePricePer1M: 3.75
        )
        XCTAssertEqual(model.exactoVariant.promptCacheWritePricePer1M, 3.75)
    }

    func testPricingPerMillionLabelFormatsPromptAndCompletion() {
        let model = UpstreamModel(id: "m", contextLength: nil, promptPricePer1M: 0.5, completionPricePer1M: 2.0)
        XCTAssertEqual(model.pricingPerMillionLabel, "In $0.500/M · Out $2.00/M")
    }

    // MARK: - capabilities

    func testCapabilitiesReasoning() {
        let model = UpstreamModel.idOnly("openai/o1-preview")
        XCTAssertTrue(model.capabilities.contains(.reasoning))
    }

    func testCapabilitiesDeepseekR1() {
        let model = UpstreamModel.idOnly("deepseek/deepseek-r1")
        XCTAssertTrue(model.capabilities.contains(.reasoning))
    }

    func testCapabilitiesVision() {
        let model = UpstreamModel(id: "opaque", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil, inputModalities: ["text", "image"])
        XCTAssertTrue(model.capabilities.contains(.vision))
    }

    func testCapabilitiesCoding() {
        let model = UpstreamModel.idOnly("qwen/qwen-2.5-coder-32b")
        XCTAssertTrue(model.capabilities.contains(.coding))
    }

    func testCapabilitiesDeepseekV3Coding() {
        let model = UpstreamModel.idOnly("deepseek-ai/DeepSeek-V3")
        XCTAssertTrue(model.capabilities.contains(.coding))
    }

    func testCapabilitiesNoMatch() {
        let model = UpstreamModel.idOnly("anthropic/claude-3.5-sonnet")
        XCTAssertTrue(model.capabilities.isEmpty)
    }

    func testCapabilitiesMultiple() {
        // Vision comes from advertised input modalities.
        let model = UpstreamModel(id: "opaque", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil, inputModalities: ["text", "image"])
        XCTAssertTrue(model.capabilities.contains(.vision))
        XCTAssertFalse(model.capabilities.contains(.coding))
    }

    func testCapabilitiesToolCallingFromSupportedParameters() {
        let model = UpstreamModel(
            id: "anthropic/claude-sonnet-4.5",
            contextLength: nil,
            promptPricePer1M: nil,
            completionPricePer1M: nil,
            supportedParameters: ["tools"]
        )
        XCTAssertTrue(model.supportsToolCalling)
        XCTAssertTrue(model.capabilities.contains(.toolCalling))
    }

    func testExactoVariantAppendsSuffixAndPreservesMetadata() {
        let model = UpstreamModel(
            id: "anthropic/claude-sonnet-4.5",
            contextLength: 200_000,
            promptPricePer1M: 3.0,
            completionPricePer1M: 15.0,
            supportedParameters: ["tools"]
        )
        let exacto = model.exactoVariant

        XCTAssertEqual(exacto.id, "anthropic/claude-sonnet-4.5:exacto")
        XCTAssertEqual(exacto.contextLength, 200_000)
        XCTAssertEqual(exacto.promptPricePer1M, 3.0)
        XCTAssertEqual(exacto.completionPricePer1M, 15.0)
        XCTAssertEqual(exacto.supportedParameters, Set(["tools"]))
    }

    // MARK: - idOnly

    func testIdOnlyHasNilMetadata() {
        let model = UpstreamModel.idOnly("test")
        XCTAssertEqual(model.id, "test")
        XCTAssertNil(model.contextLength)
        XCTAssertNil(model.promptPricePer1M)
        XCTAssertNil(model.completionPricePer1M)
        XCTAssertTrue(model.supportedParameters.isEmpty)
    }
}
