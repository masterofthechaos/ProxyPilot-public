import Foundation
import Testing
@testable import ProxyPilotCore

@Suite struct BearingsTelemetryTests {
    @Test func navigatorRoleRoundTripsAndLegacyRoleStaysUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("report.jsonl")
        let record = RequestRecord(
            model: "returned-model",
            requestedModel: "requested-model",
            providerReportedCostUSD: 0.012,
            promptTokens: 9,
            completionTokens: 4,
            durationSeconds: 0.1,
            path: "/v1/chat/completions",
            wasStreaming: false,
            providerIdentifier: "openrouter"
        )
        let navigator = SessionReportEvent(
            source: "repogps",
            sessionID: UUID().uuidString,
            role: "navigator",
            record: record
        )
        try SessionReportStore.append(navigator, to: file)
        let encoded = JSONEncoder()
        encoded.dateEncodingStrategy = .iso8601
        var legacy = try encoded.encode(SessionReportEvent(
            schemaVersion: 1,
            source: "repogps",
            sessionID: UUID().uuidString,
            record: record
        ))
        var object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        object.removeValue(forKey: "role")
        legacy = try JSONSerialization.data(withJSONObject: object)
        legacy.append(0x0a)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: legacy)
        let events = try SessionReportStore.readEvents(from: file)
        #expect(events[0].role == "navigator")
        #expect(events[0].record.model == "returned-model")
        #expect(events[0].record.requestedModel == "requested-model")
        #expect(events[0].record.providerReportedCostUSD == 0.012)
        #expect(events[1].role == nil)
    }

    @Test func archiveAndCurrentAreDeduplicatedForDurableTotals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("report.jsonl")
        let archive = root.appendingPathComponent("report.archive.jsonl")
        let olderArchive = root.appendingPathComponent("report.archive.older.jsonl")
        let event = SessionReportEvent(
            source: "repogps",
            sessionID: UUID().uuidString,
            role: "lead",
            record: RequestRecord(model: "m", promptTokens: 1, completionTokens: 2, durationSeconds: 0, path: "/", wasStreaming: false)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(event)
        line.append(0x0a)
        try line.write(to: archive)
        try line.write(to: file)
        let olderEvent = SessionReportEvent(
            source: "repogps",
            sessionID: event.sessionID,
            role: "navigator",
            record: RequestRecord(model: "older", promptTokens: 4, completionTokens: 1, durationSeconds: 0, path: "/", wasStreaming: false)
        )
        var olderLine = try encoder.encode(olderEvent)
        olderLine.append(0x0a)
        try olderLine.write(to: olderArchive)
        let events = try SessionReportStore.readEvents(from: file)
        #expect(events.count == 2)
        #expect(AttributedSessionTelemetry.aggregate(records: events.map(\.record)).totalTokens == 8)
    }
}
