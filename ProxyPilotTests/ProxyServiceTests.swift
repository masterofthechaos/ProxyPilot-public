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

    func testGitHubCopilotToolCallProbeRequestUsesStreamingToolCallPayload() throws {
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:8080/v1"))
        let request = try ProxyService.githubCopilotToolCallProbeRequest(apiBase: base, model: "gpt-4.1")

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8080/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Xcode/") == true)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-4.1")
        XCTAssertEqual(json["stream"] as? Bool, true)

        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "proxypilot_probe")
    }

    func testGitHubCopilotToolCallProbeParserDetectsStreamingToolCall() throws {
        let sse = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"proxypilot_probe","arguments":"{\\\"message\\\":"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\\"ok\\\"}"}}]}}]}

        data: [DONE]

        """

        let result = ProxyService.parseGitHubCopilotToolCallProbeResponse(Data(sse.utf8))

        XCTAssertTrue(result.sawToolCall)
        XCTAssertTrue(result.summary.contains("tool call"))
        XCTAssertTrue(result.summary.contains("proxypilot_probe"))
    }
}
