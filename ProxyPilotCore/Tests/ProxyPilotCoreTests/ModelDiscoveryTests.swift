import XCTest
@testable import ProxyPilotCore

final class ModelDiscoveryTests: XCTestCase {
    func testAdvertisedModalitiesRoundTripAndUnknownRemainDistinct() throws {
        let data = Data(#"{"data":[{"id":"opaque","context_length":32000,"architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"top_provider":{"max_completion_tokens":2048}},{"id":"gemini-unknown"},{"id":"vision-text-only","architecture":{"input_modalities":["text"]}}]}"#.utf8)
        let models = try ModelDiscovery.parseModelMetadata(from: data)
        let opaque = try XCTUnwrap(models.first { $0.id == "opaque" })
        XCTAssertTrue(opaque.capabilities.contains(.vision))
        XCTAssertEqual(opaque.maximumOutputTokens, 2048)
        XCTAssertEqual(opaque.exactoVariant.inputModalities, ["text", "image"])
        XCTAssertEqual(try JSONDecoder().decode(UpstreamModel.self, from: JSONEncoder().encode(opaque)), opaque)
        XCTAssertNil(models.first { $0.id == "gemini-unknown" }?.inputModalities)
        XCTAssertFalse(models.first { $0.id == "vision-text-only" }!.capabilities.contains(.vision))
    }

    func testSharedCatalogSeparatesEndpointsAndPreservesFreshness() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let time = Date(timeIntervalSince1970: 100)
        try ModelCatalogStore.save([.idOnly("one")], provider: "custom", endpoint: "https://one/v1/", now: time, root: root)
        XCTAssertEqual(ModelCatalogStore.load(provider: "custom", endpoint: "https://one/v1", root: root)?.fetchedAt, time)
        XCTAssertNil(ModelCatalogStore.load(provider: "custom", endpoint: "https://two/v1", root: root))
    }

    func testCacheCoverageKeepsUnknownAndPartialCountersOutOfRate() {
        func record(_ hit: Int?, _ miss: Int?) -> RequestRecord {
            RequestRecord(model: "fixture", promptTokens: 100, completionTokens: 0,
                promptCacheHitTokens: hit, promptCacheMissTokens: miss,
                durationSeconds: 1, path: "/v1/chat/completions", wasStreaming: false)
        }
        let usage = AttributedSessionTelemetry.aggregate(records: [record(80,20), record(0,0), record(nil,nil), record(100,nil)])
        XCTAssertEqual(usage.cacheObservedRequests, 3)
        XCTAssertEqual(usage.promptCacheHitTokens, 180)
        XCTAssertEqual(usage.cacheHitRate, 0.8)
        XCTAssertTrue(AttributedSessionTelemetry.aggregate(records: [record(0,0)]).cacheAccountingAvailable)
        XCTAssertNil(AttributedSessionTelemetry.aggregate(records: [record(100,nil)]).cacheHitRate)
    }

    func testCatalogResolutionPreservesExactoAndKnownFields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let row = UpstreamModel(id: "opaque", contextLength: 32000, promptPricePer1M: nil, completionPricePer1M: nil, inputModalities: ["text", "image"])
        try ModelCatalogStore.save([row], provider: "openrouter", endpoint: "fixture", root: root)
        let snapshot = ModelCatalogStore.load(provider: "openrouter", endpoint: "fixture", root: root)
        let variant = ModelCatalogStore.model(id: "opaque:exacto", provider: .openRouter, snapshot: snapshot)
        XCTAssertEqual(variant?.id, "opaque:exacto")
        XCTAssertEqual(variant?.inputModalities, ["text", "image"])
        try ModelCatalogStore.save([.idOnly("deepseek-chat")], provider: "deepseek", endpoint: "fixture", root: root)
        let deepseek = ModelCatalogStore.model(id: "deepseek-chat", provider: .deepSeek,
            snapshot: ModelCatalogStore.load(provider: "deepseek", endpoint: "fixture", root: root))
        XCTAssertEqual(deepseek?.contextLength, UpstreamProvider.deepSeek.knownModelMetadata(for: "deepseek-chat")?.contextLength)
        XCTAssertNotNil(deepseek?.promptPricePer1M)
    }

    func testParseModelsResponseExtractsIDs() throws {
        let json = """
        {
            "data": [
                {"id": "gpt-4o", "object": "model"},
                {"id": "gpt-3.5-turbo", "object": "model"}
            ]
        }
        """.data(using: .utf8)!

        let ids = try ModelDiscovery.parseModelIDs(from: json)
        XCTAssertEqual(ids, ["gpt-3.5-turbo", "gpt-4o"])
    }

    func testParseModelsResponseEmptyData() throws {
        let json = """
        {"data": []}
        """.data(using: .utf8)!

        let ids = try ModelDiscovery.parseModelIDs(from: json)
        XCTAssertTrue(ids.isEmpty)
    }

    func testParseModelsResponseInvalidJSON() {
        let json = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try ModelDiscovery.parseModelIDs(from: json))
    }

    func testFilterExactoModelsReturnsExplicitVirtualVariants() {
        let models = ["gpt-4o", "anthropic/claude-3:exacto", "google/gemini-2", "anthropic/claude-3"]
        let filtered = ModelDiscovery.filterExacto(models)
        XCTAssertEqual(filtered, ["gpt-4o:exacto", "anthropic/claude-3:exacto", "google/gemini-2:exacto"])
    }

    func testFilterVerifiedModels() {
        let models = ["gpt-4o", "claude-3-opus", "llama-3"]
        let verified = VerifiedModels(entries: [
            VerifiedModelEntry(id: "claude-3-opus", note: nil)
        ])
        let filtered = ModelDiscovery.filterVerified(models, verified: verified)
        XCTAssertEqual(filtered, ["claude-3-opus"])
    }

    func testModelSummaryBuilderInfersToolCallingSupport() {
        let summaries = ModelSummaryBuilder.summaries(ids: ["gpt-5.1"], verified: VerifiedModels(entries: []))
        XCTAssertEqual(summaries.first?.toolCalling.supported, true)
        XCTAssertEqual(summaries.first?.toolCalling.confidence, "inferred")
        XCTAssertEqual(summaries.first?.recommendedForXcodeAgent, true)
    }

    func testModelSummaryBuilderExcludesLegacyInstructFromXcodeRecommendation() {
        let summaries = ModelSummaryBuilder.summaries(ids: ["gpt-3.5-turbo-instruct"], verified: VerifiedModels(entries: []))
        XCTAssertEqual(summaries.first?.recommendedForXcodeAgent, false)
    }

    func testNormalizeDiscoveryBaseURLStripsModelsPathSuffix() {
        // Prevents /v1/models + /models → /v1/models/models double-pathing.
        XCTAssertEqual(ModelDiscovery.normalizeDiscoveryBaseURL("http://127.0.0.1:11434/v1/models"), "http://127.0.0.1:11434/v1")
        XCTAssertEqual(ModelDiscovery.normalizeDiscoveryBaseURL("http://127.0.0.1:11434/models"), "http://127.0.0.1:11434")
        XCTAssertEqual(ModelDiscovery.normalizeDiscoveryBaseURL("http://127.0.0.1:11434/v1"), "http://127.0.0.1:11434/v1")
        XCTAssertEqual(ModelDiscovery.normalizeDiscoveryBaseURL("http://127.0.0.1:11434/v1/"), "http://127.0.0.1:11434/v1")
        XCTAssertEqual(ModelDiscovery.normalizeDiscoveryBaseURL("https://api.openai.com/v1"), "https://api.openai.com/v1")
    }
}
