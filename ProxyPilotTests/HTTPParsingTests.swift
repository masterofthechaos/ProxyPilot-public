import XCTest
@testable import ProxyPilot

final class HTTPParsingTests: XCTestCase {
    func testLimitStatusCodeReturns413ForLargeHeader() {
        let status = LocalProxyServer.limitStatusCode(
            headerBytes: LocalProxyServer.maxHeaderBytes + 1,
            bodyBytes: 10,
            activeConnections: 0
        )
        XCTAssertEqual(status, 413)
    }

    func testLimitStatusCodeReturns413ForLargeBody() {
        let status = LocalProxyServer.limitStatusCode(
            headerBytes: 10,
            bodyBytes: LocalProxyServer.maxBodyBytes + 1,
            activeConnections: 0
        )
        XCTAssertEqual(status, 413)
    }

    func testLimitStatusCodeReturns429WhenConcurrentLimitHit() {
        let status = LocalProxyServer.limitStatusCode(
            headerBytes: 10,
            bodyBytes: 10,
            activeConnections: LocalProxyServer.maxConcurrentConnections
        )
        XCTAssertEqual(status, 429)
    }

    func testLimitStatusCodeReturnsNilWithinLimits() {
        let status = LocalProxyServer.limitStatusCode(headerBytes: 128, bodyBytes: 512, activeConnections: 2)
        XCTAssertNil(status)
    }
}
