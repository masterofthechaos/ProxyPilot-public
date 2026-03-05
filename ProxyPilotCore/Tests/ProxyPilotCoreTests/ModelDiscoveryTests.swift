import XCTest
@testable import ProxyPilotCore

final class ModelDiscoveryTests: XCTestCase {
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

    func testFilterExactoModels() {
        let models = ["gpt-4o", "anthropic/claude-3:exacto", "google/gemini-2:exacto", "meta/llama-3"]
        let filtered = ModelDiscovery.filterExacto(models)
        XCTAssertEqual(filtered, ["anthropic/claude-3:exacto", "google/gemini-2:exacto"])
    }

    func testFilterVerifiedModels() {
        let models = ["gpt-4o", "claude-3-opus", "llama-3"]
        let verified = VerifiedModels(entries: [
            VerifiedModelEntry(id: "claude-3-opus", note: nil)
        ])
        let filtered = ModelDiscovery.filterVerified(models, verified: verified)
        XCTAssertEqual(filtered, ["claude-3-opus"])
    }
}
