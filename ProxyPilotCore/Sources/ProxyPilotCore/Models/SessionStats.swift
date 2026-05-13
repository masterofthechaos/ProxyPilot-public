import Foundation

public actor SessionStats {
    public struct Snapshot: Sendable {
        public let totalRequests: Int
        public let totalPromptTokens: Int
        public let totalCompletionTokens: Int
        public let totalTokens: Int
        public let modelDistribution: [String: Int]
        public let avgLatencyMs: Int?
        public let uptimeSeconds: Int
    }

    private var requests: Int = 0
    private var promptTokens: Int = 0
    private var completionTokens: Int = 0
    private var latencySum: Int = 0
    private var modelCounts: [String: Int] = [:]
    private var startTime = Date()
    private let sessionReportURL: URL?
    private let sessionSource: String
    private let sessionID: String

    public init(
        sessionReportURL: URL? = nil,
        sessionSource: String = "cli",
        sessionID: String = UUID().uuidString
    ) {
        self.sessionReportURL = sessionReportURL
        self.sessionSource = sessionSource
        self.sessionID = sessionID
    }

    public func record(model: String, promptTokens: Int, completionTokens: Int, durationMs: Int) {
        record(RequestRecord(
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            durationSeconds: Double(durationMs) / 1000.0,
            path: "",
            wasStreaming: false
        ))
    }

    public func record(_ record: RequestRecord) {
        requests += 1
        promptTokens += record.promptTokens
        completionTokens += record.completionTokens
        latencySum += Int((record.durationSeconds * 1000.0).rounded())
        modelCounts[record.model, default: 0] += 1

        guard let sessionReportURL else { return }
        let event = SessionReportEvent(
            source: sessionSource,
            sessionID: sessionID,
            record: record
        )
        try? SessionReportStore.append(event, to: sessionReportURL)
    }

    public func reset(clearReportStore: Bool = false) {
        requests = 0
        promptTokens = 0
        completionTokens = 0
        latencySum = 0
        modelCounts = [:]
        startTime = Date()

        if clearReportStore, let sessionReportURL {
            try? SessionReportStore.reset(at: sessionReportURL)
        }
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            totalRequests: requests,
            totalPromptTokens: promptTokens,
            totalCompletionTokens: completionTokens,
            totalTokens: promptTokens + completionTokens,
            modelDistribution: modelCounts,
            avgLatencyMs: requests > 0 ? latencySum / requests : nil,
            uptimeSeconds: Int(Date().timeIntervalSince(startTime))
        )
    }
}
