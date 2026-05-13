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
}
