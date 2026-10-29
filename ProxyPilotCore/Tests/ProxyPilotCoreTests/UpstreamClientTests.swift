import XCTest
@testable import ProxyPilotCore

final class UpstreamClientTests: XCTestCase {
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

}
