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

    func testRecordingRequestAppendsSharedSessionReportEvent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reportURL = directory.appendingPathComponent("session-report.jsonl")

        let stats = SessionStats(
            sessionReportURL: reportURL,
            sessionSource: "cli",
            sessionID: "test-session"
        )
        let timestamp = Date(timeIntervalSince1970: 1_714_000_000)

        await stats.record(RequestRecord(
            timestamp: timestamp,
            model: "glm-5",
            promptTokens: 120,
            completionTokens: 45,
            durationSeconds: 1.25,
            path: "/v1/chat/completions",
            wasStreaming: false
        ))

        let events = try SessionReportStore.readEvents(from: reportURL)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].source, "cli")
        XCTAssertEqual(events[0].sessionID, "test-session")
        XCTAssertEqual(events[0].record.model, "glm-5")
        XCTAssertEqual(events[0].record.promptTokens, 120)
        XCTAssertEqual(events[0].record.completionTokens, 45)
        XCTAssertEqual(events[0].record.durationSeconds, 1.25, accuracy: 0.001)
        XCTAssertEqual(events[0].record.path, "/v1/chat/completions")
        XCTAssertFalse(events[0].record.wasStreaming)
    }
}
