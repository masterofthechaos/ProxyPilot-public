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
}
