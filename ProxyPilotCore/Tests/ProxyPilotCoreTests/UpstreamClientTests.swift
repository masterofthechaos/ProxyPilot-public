import XCTest
@testable import ProxyPilotCore

final class UpstreamClientTests: XCTestCase {
    func testUpstreamHTTPErrorReportsStatusWithoutEchoingResponseSecrets() {
        let error = UpstreamClient.UpstreamError.httpError(statusCode: 401, body: Data("secret-response".utf8))
        XCTAssertEqual(error.localizedDescription, "Upstream HTTP 401")
        XCTAssertFalse(error.localizedDescription.contains("secret-response"))
    }

    func testBuildUpstreamURLPreservesValidBaseAndPath() throws {
        let config = ProxyConfiguration(upstreamAPIBaseURL: "https://api.example.com/v1/")

        let url = try UpstreamClient.buildUpstreamURL(path: "chat/completions", config: config)

        XCTAssertEqual(url.absoluteString, "https://api.example.com/v1/chat/completions")
    }

    func testBuildUpstreamURLThrowsForInvalidBaseInsteadOfCrashing() {
        let config = ProxyConfiguration(upstreamAPIBaseURL: "://missing-scheme")

        XCTAssertThrowsError(
            try UpstreamClient.buildUpstreamURL(path: "/v1/chat/completions", config: config)
        ) { error in
            guard case ProxyEngineError.invalidUpstreamURL = error else {
                XCTFail("Expected invalidUpstreamURL, got \(error)")
                return
            }
        }
    }

    func testBuildRequestStripsLocalAuthenticationHeaders() throws {
        let config = ProxyConfiguration(
            upstreamAPIBaseURL: "https://api.example.com/v1/",
            upstreamAPIKey: "upstream-key"
        )

        let request = try UpstreamClient.buildRequest(
            path: "/v1/chat/completions",
            method: "POST",
            headers: [
                ("Authorization", "Bearer local-master-key"),
                ("X-Api-Key", "local-master-key"),
                ("Api-Key", "local-master-key"),
                (TutorRequestAdapter.headerName, "local-tutor-envelope"),
                ("X-ProxyPilot-Client", "repogps"),
                ("X-ProxyPilot-Session-ID", "private-logical-session"),
                ("X-ProxyPilot-Role", "navigator"),
                ("X-Session-ID", "caller-affinity"),
                ("Content-Type", "application/json")
            ],
            body: Data(#"{"model":"allowed-model"}"#.utf8),
            config: config
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer upstream-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Api-Key"))
        XCTAssertNil(request.value(forHTTPHeaderField: TutorRequestAdapter.headerName))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-ProxyPilot-Client"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-ProxyPilot-Session-ID"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-ProxyPilot-Role"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Session-ID"), "caller-affinity")
    }
    func testConfiguredTutorTimeoutReachesActualUpstreamRequest() throws {
        let base = ProxyConfiguration(upstreamAPIBaseURL: "https://api.example.com/v1/")
        let configured = base.withUpstreamRequestTimeout(90)
        let request = try UpstreamClient.buildRequest(path: "chat/completions", method: "POST", headers: [], body: nil, config: configured)
        XCTAssertEqual(request.timeoutInterval, 90)
        XCTAssertEqual(base.effectiveUpstreamRequestTimeout, 30)
        XCTAssertEqual(base.withUpstreamRequestTimeout(-1).effectiveUpstreamRequestTimeout, 30)
        XCTAssertEqual(base.withUpstreamRequestTimeout(.infinity).effectiveUpstreamRequestTimeout, 30)
    }

    func testOpenRouterRequestsCarryProxyPilotAttributionOverClientHeaders() throws {
        let config = ProxyConfiguration(upstreamAPIBaseURL: "https://openrouter.ai/api/v1", upstreamAPIKey: "upstream-key")
        let request = try UpstreamClient.buildRequest(
            path: "/v1/chat/completions",
            method: "POST",
            headers: [("X-Title", "SomeClient"), ("HTTP-Referer", "https://client.example")],
            body: Data(#"{"model":"m"}"#.utf8),
            config: config
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "HTTP-Referer"), "https://slicewrite.com/proxypilot")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OpenRouter-Title"), "ProxyPilot")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "ProxyPilot")
    }

    func testNonOpenRouterRequestsDoNotGainAttribution() throws {
        let config = ProxyConfiguration(upstreamAPIBaseURL: "https://api.example.com/v1/", upstreamAPIKey: "upstream-key")
        let request = try UpstreamClient.buildRequest(path: "chat/completions", method: "POST", headers: [], body: nil, config: config)
        XCTAssertNil(request.value(forHTTPHeaderField: "HTTP-Referer"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-OpenRouter-Title"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Title"))
    }

    func testAttributionHostMatching() {
        XCTAssertTrue(OpenRouterAppAttribution.appliesTo(URL(string: "https://openrouter.ai/api/v1/chat/completions")))
        XCTAssertTrue(OpenRouterAppAttribution.appliesTo(URL(string: "https://eu.openrouter.ai/api/v1")))
        XCTAssertFalse(OpenRouterAppAttribution.appliesTo(URL(string: "https://notopenrouter.ai/api")))
        XCTAssertFalse(OpenRouterAppAttribution.appliesTo(URL(string: "https://openrouter.ai.evil.example/api")))
        XCTAssertFalse(OpenRouterAppAttribution.appliesTo(nil))
    }

}
