import Testing
import Foundation
@testable import ProxyPilotCore

@Suite("VerifiedModels")
struct VerifiedModelsTests {
    @Test func parseValidJSON() throws {
        let json = """
        [
            {"id": "anthropic/claude-sonnet-4-5", "note": "Best for agentic"},
            {"id": "openai/gpt-4o", "note": null}
        ]
        """.data(using: .utf8)!
        let entries = try JSONDecoder().decode([VerifiedModelEntry].self, from: json)
        #expect(entries.count == 2)
        #expect(entries[0].id == "anthropic/claude-sonnet-4-5")
        #expect(entries[0].note == "Best for agentic")
        #expect(entries[1].note == nil)
    }

    @Test func verifiedSetContainsParsedIDs() throws {
        let json = """
        [{"id": "anthropic/claude-sonnet-4-5", "note": null}]
        """.data(using: .utf8)!
        let entries = try JSONDecoder().decode([VerifiedModelEntry].self, from: json)
        let set = VerifiedModels(entries: entries)
        #expect(set.contains("anthropic/claude-sonnet-4-5") == true)
        #expect(set.contains("some/other-model") == false)
    }

    @Test func emptyEntriesProducesEmptySet() {
        let set = VerifiedModels(entries: [])
        #expect(set.contains("anything") == false)
        #expect(set.isEmpty == true)
    }

    @Test func saveCacheAndLoadBack() throws {
        let entries = [VerifiedModelEntry(id: "test/model", note: "test")]
        let tmpDir = FileManager.default.temporaryDirectory
        let cacheURL = tmpDir.appendingPathComponent("test-verified-cache.json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        VerifiedModels.saveCache(entries: entries, to: cacheURL)
        let loaded = VerifiedModels.loadCached(cacheURL: cacheURL, bundleURL: nil)
        #expect(loaded.count == 1)
        #expect(loaded[0].id == "test/model")
    }

    @Test func loadCachedFallsToBundleWhenNoCacheExists() {
        let loaded = VerifiedModels.loadCached(cacheURL: nil, bundleURL: nil)
        #expect(loaded.isEmpty)
    }
}
