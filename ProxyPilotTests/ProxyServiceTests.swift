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
