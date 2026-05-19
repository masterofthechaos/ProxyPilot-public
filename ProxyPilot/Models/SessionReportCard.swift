import Foundation
import ProxyPilotCore

@MainActor
final class SessionReportCard: ObservableObject {
    nonisolated init() {}

    struct RequestRecord: Sendable, Identifiable {
        let id: UUID
        let timestamp: Date
        let model: String
        let promptTokens: Int
        let completionTokens: Int
        let promptCacheHitTokens: Int?
        let promptCacheMissTokens: Int?
        let durationSeconds: TimeInterval
        let path: String
        let wasStreaming: Bool

        var totalTokens: Int { promptTokens + completionTokens }

        init(
            id: UUID = UUID(),
            timestamp: Date,
            model: String,
            promptTokens: Int,
            completionTokens: Int,
            promptCacheHitTokens: Int? = nil,
            promptCacheMissTokens: Int? = nil,
            durationSeconds: TimeInterval,
            path: String,
            wasStreaming: Bool
        ) {
            self.id = id
            self.timestamp = timestamp
            self.model = model
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.promptCacheHitTokens = promptCacheHitTokens
            self.promptCacheMissTokens = promptCacheMissTokens
            self.durationSeconds = durationSeconds
            self.path = path
            self.wasStreaming = wasStreaming
        }
    }

    struct LatencySummary: Sendable {
        let average: TimeInterval
        let p50: TimeInterval
        let p95: TimeInterval
        let max: TimeInterval
    }

    struct ModelLatencySummary: Identifiable, Sendable {
        var id: String { model }
        let model: String
        let requestCount: Int
        let average: TimeInterval
        let p50: TimeInterval
        let p95: TimeInterval
        let max: TimeInterval
    }

    private static let maxRetainedRequests = 500

    @Published private(set) var requests: [RequestRecord] = []
    private var firstRequestTimestamp: Date?

    var totalRequests: Int { requests.count }

    var totalPromptTokens: Int {
        requests.reduce(0) { $0 + $1.promptTokens }
    }

    var totalCompletionTokens: Int {
        requests.reduce(0) { $0 + $1.completionTokens }
    }

    var totalTokens: Int { totalPromptTokens + totalCompletionTokens }

    var modelDistribution: [(model: String, count: Int)] {
        let grouped = Dictionary(grouping: requests, by: \.model)
        return grouped.map { (model: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    var averageRequestDuration: TimeInterval? {
        latencySummary?.average
    }

    var sessionStartTime: Date? { firstRequestTimestamp }

    var averagePromptTokensPerRequest: Double? {
        guard !requests.isEmpty else { return nil }
        return Double(totalPromptTokens) / Double(requests.count)
    }

    var averageCompletionTokensPerRequest: Double? {
        guard !requests.isEmpty else { return nil }
        return Double(totalCompletionTokens) / Double(requests.count)
    }

    var latencySummary: LatencySummary? {
        let durations = requests.map(\.durationSeconds)
        return Self.buildLatencySummary(from: durations)
    }

    var modelLatencyBreakdown: [ModelLatencySummary] {
        let grouped = Dictionary(grouping: requests, by: \.model)
        return grouped.compactMap { model, records in
            let durations = records.map(\.durationSeconds)
            guard let summary = Self.buildLatencySummary(from: durations) else { return nil }
            return ModelLatencySummary(
                model: model,
                requestCount: records.count,
                average: summary.average,
                p50: summary.p50,
                p95: summary.p95,
                max: summary.max
            )
        }
        .sorted {
            if $0.p95 != $1.p95 { return $0.p95 > $1.p95 }
            if $0.requestCount != $1.requestCount { return $0.requestCount > $1.requestCount }
            return $0.model < $1.model
        }
    }

    var totalTokensFormatted: String {
        if totalTokens >= 1_000_000 {
            return String(format: "%.1fM", Double(totalTokens) / 1_000_000)
        }
        if totalTokens >= 1_000 {
            return String(format: "%.1fK", Double(totalTokens) / 1_000)
        }
        return "\(totalTokens)"
    }

    func record(_ entry: RequestRecord) {
        if firstRequestTimestamp == nil {
            firstRequestTimestamp = entry.timestamp
        }
        requests.append(entry)
        let overflow = requests.count - Self.maxRetainedRequests
        if overflow > 0 {
            requests.removeFirst(overflow)
        }
    }

    func record(_ entry: ProxyPilotCore.RequestRecord) {
        record(RequestRecord(
            timestamp: entry.timestamp,
            model: entry.model,
            promptTokens: entry.promptTokens,
            completionTokens: entry.completionTokens,
            promptCacheHitTokens: entry.promptCacheHitTokens,
            promptCacheMissTokens: entry.promptCacheMissTokens,
            durationSeconds: entry.durationSeconds,
            path: entry.path,
            wasStreaming: entry.wasStreaming
        ))
    }

    func reset() {
        requests.removeAll()
        firstRequestTimestamp = nil
    }

    private static func buildLatencySummary(from durations: [TimeInterval]) -> LatencySummary? {
        guard !durations.isEmpty else { return nil }
        let average = durations.reduce(0.0, +) / Double(durations.count)
        return LatencySummary(
            average: average,
            p50: percentile(durations, percentile: 0.50),
            p95: percentile(durations, percentile: 0.95),
            max: durations.max() ?? 0
        )
    }

    private static func percentile(_ values: [TimeInterval], percentile: Double) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }

        let clamped = min(max(percentile, 0), 1)
        let position = clamped * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))

        if lower == upper { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] + ((sorted[upper] - sorted[lower]) * weight)
    }
}
