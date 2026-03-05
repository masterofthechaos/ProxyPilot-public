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
    private let startTime = Date()

    public init() {}

    public func record(model: String, promptTokens: Int, completionTokens: Int, durationMs: Int) {
        requests += 1
        self.promptTokens += promptTokens
        self.completionTokens += completionTokens
        latencySum += durationMs
        modelCounts[model, default: 0] += 1
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
