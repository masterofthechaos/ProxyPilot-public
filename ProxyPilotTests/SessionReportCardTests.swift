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
}
