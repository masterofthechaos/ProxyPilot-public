import XCTest
@testable import ProxyPilot

final class DiagnosticsServiceTests: XCTestCase {
    func testRedactSecretsMasksBearerAndApiKeys() {
        let input = "Authorization: Bearer abc123\nx-api-key: secret123\n{\"api_key\":\"xyz\"}"
        let redacted = DiagnosticsService.redactSecrets(in: input)

        XCTAssertFalse(redacted.contains("abc123"))
        XCTAssertFalse(redacted.contains("secret123"))
        XCTAssertFalse(redacted.contains("\"xyz\""))
        XCTAssertTrue(redacted.contains("Bearer ***"))
    }

    func testRedactSecretsMasksMultipleBearerTokens() {
        let input = "Authorization: Bearer first-token\nAuthorization: Bearer second-token"
        let redacted = DiagnosticsService.redactSecrets(in: input)

        XCTAssertEqual(redacted, "Authorization: Bearer ***\nAuthorization: Bearer ***")
        XCTAssertFalse(redacted.contains("first-token"))
        XCTAssertFalse(redacted.contains("second-token"))
    }
}
