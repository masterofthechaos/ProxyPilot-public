import XCTest
@testable import ProxyPilot

@MainActor
final class SessionReportCardTests: XCTestCase {

    func testEmptyReportCard() {
        let card = SessionReportCard()
        XCTAssertEqual(card.totalRequests, 0)
        XCTAssertEqual(card.totalPromptTokens, 0)
        XCTAssertEqual(card.totalCompletionTokens, 0)
        XCTAssertEqual(card.totalTokens, 0)
        XCTAssertTrue(card.modelDistribution.isEmpty)
        XCTAssertNil(card.averageRequestDuration)
        XCTAssertNil(card.sessionStartTime)
    }

    func testSingleRequestRecord() {
        let card = SessionReportCard()
        card.record(.init(
            timestamp: Date(), model: "glm-5",
            promptTokens: 100, completionTokens: 50,
            durationSeconds: 1.5, path: "/v1/chat/completions", wasStreaming: false
        ))
        XCTAssertEqual(card.totalRequests, 1)
        XCTAssertEqual(card.totalPromptTokens, 100)
        XCTAssertEqual(card.totalCompletionTokens, 50)
        XCTAssertEqual(card.totalTokens, 150)
    }

    func testMultipleRequestsAccumulate() {
        let card = SessionReportCard()
        card.record(.init(
            timestamp: Date(), model: "glm-5",
            promptTokens: 100, completionTokens: 50,
            durationSeconds: 1.0, path: "/v1/chat/completions", wasStreaming: false
        ))
        card.record(.init(
            timestamp: Date(), model: "gpt-4o",
            promptTokens: 200, completionTokens: 300,
            durationSeconds: 2.0, path: "/v1/messages", wasStreaming: true
        ))
        XCTAssertEqual(card.totalRequests, 2)
        XCTAssertEqual(card.totalPromptTokens, 300)
        XCTAssertEqual(card.totalCompletionTokens, 350)
        XCTAssertEqual(card.totalTokens, 650)
    }

    func testModelDistribution() {
        let card = SessionReportCard()
        let record = { (model: String) in
            SessionReportCard.RequestRecord(
                timestamp: Date(), model: model,
                promptTokens: 10, completionTokens: 5,
                durationSeconds: 0.5, path: "/v1/chat/completions", wasStreaming: false
            )
        }
        card.record(record("glm-5"))
        card.record(record("glm-5"))
        card.record(record("gpt-4o"))

        let dist = card.modelDistribution
        XCTAssertEqual(dist.count, 2)
        XCTAssertEqual(dist[0].model, "glm-5")
        XCTAssertEqual(dist[0].count, 2)
        XCTAssertEqual(dist[1].model, "gpt-4o")
        XCTAssertEqual(dist[1].count, 1)
    }

    func testReset() {
        let card = SessionReportCard()
        card.record(.init(
            timestamp: Date(), model: "glm-5",
            promptTokens: 100, completionTokens: 50,
            durationSeconds: 1.0, path: "/v1/chat/completions", wasStreaming: false
        ))
        XCTAssertEqual(card.totalRequests, 1)

        card.reset()
        XCTAssertEqual(card.totalRequests, 0)
        XCTAssertEqual(card.totalTokens, 0)
        XCTAssertTrue(card.modelDistribution.isEmpty)
    }

    func testTotalTokensFormattedSmall() {
        let card = SessionReportCard()
        card.record(.init(
            timestamp: Date(), model: "test",
            promptTokens: 500, completionTokens: 400,
            durationSeconds: 1.0, path: "/v1/chat/completions", wasStreaming: false
        ))
        XCTAssertEqual(card.totalTokensFormatted, "900")
    }

    func testTotalTokensFormattedK() {
        let card = SessionReportCard()
        card.record(.init(
            timestamp: Date(), model: "test",
            promptTokens: 1000, completionTokens: 500,
            durationSeconds: 1.0, path: "/v1/chat/completions", wasStreaming: false
        ))
        XCTAssertEqual(card.totalTokensFormatted, "1.5K")
    }

    func testTotalTokensFormattedM() {
        let card = SessionReportCard()
        card.record(.init(
            timestamp: Date(), model: "test",
            promptTokens: 1_000_000, completionTokens: 500_000,
            durationSeconds: 1.0, path: "/v1/chat/completions", wasStreaming: false
        ))
        XCTAssertEqual(card.totalTokensFormatted, "1.5M")
    }

    func testAverageRequestDuration() throws {
        let card = SessionReportCard()
        card.record(.init(
            timestamp: Date(), model: "test",
            promptTokens: 10, completionTokens: 5,
            durationSeconds: 1.0, path: "/v1/chat/completions", wasStreaming: false
        ))
        card.record(.init(
            timestamp: Date(), model: "test",
            promptTokens: 10, completionTokens: 5,
            durationSeconds: 3.0, path: "/v1/chat/completions", wasStreaming: false
        ))
        let avg = try XCTUnwrap(card.averageRequestDuration)
        XCTAssertEqual(avg, 2.0, accuracy: 0.001)
    }

    func testLatencySummaryIncludesPercentiles() throws {
        let card = SessionReportCard()
        [0.1, 0.2, 0.3, 1.0, 2.0].forEach { duration in
            card.record(.init(
                timestamp: Date(), model: "model-a",
                promptTokens: 1, completionTokens: 1,
                durationSeconds: duration, path: "/v1/chat/completions", wasStreaming: false
            ))
        }

        let summary = try XCTUnwrap(card.latencySummary)
        XCTAssertEqual(summary.average, 0.72, accuracy: 0.0001)
        XCTAssertEqual(summary.p50, 0.3, accuracy: 0.0001)
        XCTAssertEqual(summary.p95, 1.8, accuracy: 0.0001)
        XCTAssertEqual(summary.max, 2.0, accuracy: 0.0001)
    }

    func testModelLatencyBreakdownSortedByP95Descending() {
        let card = SessionReportCard()

        card.record(.init(
            timestamp: Date(), model: "model-fast",
            promptTokens: 1, completionTokens: 1,
            durationSeconds: 0.2, path: "/v1/chat/completions", wasStreaming: false
        ))
        card.record(.init(
            timestamp: Date(), model: "model-fast",
            promptTokens: 1, completionTokens: 1,
            durationSeconds: 0.4, path: "/v1/chat/completions", wasStreaming: false
        ))
        card.record(.init(
            timestamp: Date(), model: "model-slow",
            promptTokens: 1, completionTokens: 1,
            durationSeconds: 1.0, path: "/v1/chat/completions", wasStreaming: false
        ))
        card.record(.init(
            timestamp: Date(), model: "model-slow",
            promptTokens: 1, completionTokens: 1,
            durationSeconds: 2.0, path: "/v1/chat/completions", wasStreaming: false
        ))

        let breakdown = card.modelLatencyBreakdown
        XCTAssertEqual(breakdown.count, 2)
        XCTAssertEqual(breakdown.first?.model, "model-slow")
        XCTAssertEqual(breakdown.first?.requestCount, 2)
    }

    func testRequestHistoryIsBoundedToMostRecent500() {
        let card = SessionReportCard()
        for index in 0..<510 {
            card.record(.init(
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                model: "model-\(index)",
                promptTokens: 1,
                completionTokens: 1,
                durationSeconds: 0.1,
                path: "/v1/chat/completions",
                wasStreaming: false
            ))
        }

        XCTAssertEqual(card.requests.count, 500)
        XCTAssertEqual(card.requests.first?.model, "model-10")
        XCTAssertEqual(card.sessionStartTime, Date(timeIntervalSince1970: 0))
    }

    func testCacheAccountingAvailableIncludesWriteOnlyTelemetry() {
        let card = SessionReportCard()
        card.record(.init(
            timestamp: Date(),
            model: "model-a",
            promptTokens: 100,
            completionTokens: 20,
            promptCacheWriteTokens: 80,
            durationSeconds: 0.1,
            path: "/v1/chat/completions",
            wasStreaming: false
        ))

        XCTAssertTrue(card.cacheAccountingAvailable)
        XCTAssertEqual(card.totalPromptCacheHitTokens, 0)
        XCTAssertEqual(card.totalPromptCacheMissTokens, 0)
        XCTAssertEqual(card.totalPromptCacheWriteTokens, 80)
        XCTAssertNil(card.cacheHitRate)
    }
}
