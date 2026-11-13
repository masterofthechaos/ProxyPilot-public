import Foundation
import Testing
@testable import ProxyPilotCore

@Suite struct RequestAttributionTests {
    @Test func acceptsKnownClientsWithUUID() {
        let id = "00000000-0000-0000-0000-000000000123"
        #expect(RequestAttribution.validated(client: "repogps", sessionID: id) == .init(client: "repogps", sessionID: id))
        #expect(RequestAttribution.validated(client: " RepoGPS ", sessionID: id)?.client == "repogps")
        #expect(RequestAttribution.validated(client: "Xcode-Agent", sessionID: id)?.client == "xcode-agent")
        #expect(RequestAttribution.validated(client: "epiphyte", sessionID: id)?.client == "epiphyte")
        #expect(RequestAttribution.validated(client: "unknown", sessionID: id) == nil)
        #expect(RequestAttribution.validated(client: "repogps", sessionID: "not-a-uuid") == nil)
        #expect(RequestAttribution.validated(client: nil, sessionID: id) == nil)
        #expect(RequestAttribution.validated(headers: ["x-proxypilot-client": "repogps", "X-PROXYPILOT-SESSION-ID": id])?.sessionID == id)
    }

    @Test func sessionStatsUsesScopedAttributionAndFallsBack() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let stats = SessionStats(sessionReportURL: url, sessionSource: "cli", sessionID: "daemon")
        await stats.record(model: "first", promptTokens: 1, completionTokens: 2, durationMs: 3)
        let attributed = RequestAttribution(client: "repogps", sessionID: "00000000-0000-0000-0000-000000000123")
        await RequestAttributionContext.$current.withValue(attributed) {
            await stats.record(model: "second", promptTokens: 1, completionTokens: 2, durationMs: 3)
        }
        let events = try SessionReportStore.readEvents(from: url)
        #expect(events[0].source == "cli")
        #expect(events[0].sessionID == "daemon")
        #expect(events[1].source == "repogps")
        #expect(events[1].sessionID == attributed.sessionID)
    }
}
