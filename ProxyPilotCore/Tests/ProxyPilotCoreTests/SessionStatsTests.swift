import XCTest
@testable import ProxyPilotCore

final class SessionStatsTests: XCTestCase {
    func testRecordRequestUpdatesCountsAndTokens() async {
        let stats = SessionStats()
        await stats.record(model: "gpt-4o", promptTokens: 100, completionTokens: 50, durationMs: 1200)
        await stats.record(model: "gpt-4o", promptTokens: 200, completionTokens: 100, durationMs: 800)
        await stats.record(model: "claude-3", promptTokens: 50, completionTokens: 25, durationMs: 600)

        let snapshot = await stats.snapshot()
        XCTAssertEqual(snapshot.totalRequests, 3)
        XCTAssertEqual(snapshot.totalPromptTokens, 350)
        XCTAssertEqual(snapshot.totalCompletionTokens, 175)
        XCTAssertEqual(snapshot.totalTokens, 525)
        XCTAssertEqual(snapshot.modelDistribution["gpt-4o"], 2)
        XCTAssertEqual(snapshot.modelDistribution["claude-3"], 1)
    }

    func testSnapshotAverageLatency() async {
        let stats = SessionStats()
        await stats.record(model: "m", promptTokens: 0, completionTokens: 0, durationMs: 1000)
        await stats.record(model: "m", promptTokens: 0, completionTokens: 0, durationMs: 2000)

        let snapshot = await stats.snapshot()
        XCTAssertEqual(snapshot.avgLatencyMs, 1500)
    }

    func testEmptySnapshotIsZero() async {
        let stats = SessionStats()
        let snapshot = await stats.snapshot()
        XCTAssertEqual(snapshot.totalRequests, 0)
        XCTAssertEqual(snapshot.totalTokens, 0)
        XCTAssertNil(snapshot.avgLatencyMs)
    }
}
