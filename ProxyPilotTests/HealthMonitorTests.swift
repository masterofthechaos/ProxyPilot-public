import XCTest
@testable import ProxyPilot

@MainActor
final class HealthMonitorTests: XCTestCase {
    func testAttemptRecoverySucceedsOnSecondAttempt() async {
        let monitor = HealthMonitor()
        var stateUpdates: [RecoveryState] = []
        var attempts: [Int] = []

        let success = await monitor.attemptRecovery(delays: [0, 0], onState: { state in
            stateUpdates.append(state)
        }, operation: { attempt in
            attempts.append(attempt)
            return attempt == 2
        })

        XCTAssertTrue(success)
        XCTAssertEqual(attempts, [1, 2])
        XCTAssertTrue(stateUpdates.contains(.recovered))
    }
}
