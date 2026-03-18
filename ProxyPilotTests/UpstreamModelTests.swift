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
        let model = UpstreamModel.idOnly("openai/gpt-4o")
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
        // "4o" triggers vision, model name doesn't trigger others
        let model = UpstreamModel.idOnly("openai/gpt-4o")
        XCTAssertTrue(model.capabilities.contains(.vision))
        XCTAssertFalse(model.capabilities.contains(.coding))
    }

    // MARK: - idOnly

    func testIdOnlyHasNilMetadata() {
        let model = UpstreamModel.idOnly("test")
        XCTAssertEqual(model.id, "test")
        XCTAssertNil(model.contextLength)
        XCTAssertNil(model.promptPricePer1M)
        XCTAssertNil(model.completionPricePer1M)
    }
}
