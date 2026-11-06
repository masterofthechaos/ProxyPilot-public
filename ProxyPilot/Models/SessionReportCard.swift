import Foundation
import ProxyPilotCore

@MainActor
final class SessionReportCard: ObservableObject {
    nonisolated init() {}

    struct RequestRecord: Sendable, Identifiable {
        let id: UUID
        let timestamp: Date
        let model: String
        let requestedModel: String?
        let providerReportedCostUSD: Double?
        let serverToolCalls: [TutorServerToolReceipt]?
        let promptTokens: Int
        let completionTokens: Int
        let promptCacheHitTokens: Int?
        let promptCacheMissTokens: Int?
        let promptCacheWriteTokens: Int?
        let durationSeconds: TimeInterval
        let path: String
        let wasStreaming: Bool
        var providerIdentifier: String?
        var promptCachingMode: String?
        var contextCompactionEnabled: Bool?
        var translationMode: String?
        var promptCacheStrategy: String?
        var promptCacheApplied: Bool?

        var totalTokens: Int { promptTokens + completionTokens }

        var hasTokenTelemetry: Bool {
            promptTokens > 0
                || completionTokens > 0
                || promptCacheHitTokens != nil
                || promptCacheMissTokens != nil
                || promptCacheWriteTokens != nil
        }

        init(
            id: UUID = UUID(),
            timestamp: Date,
            model: String,
            promptTokens: Int,
            completionTokens: Int,
            promptCacheHitTokens: Int? = nil,
            promptCacheMissTokens: Int? = nil,
            promptCacheWriteTokens: Int? = nil,
            durationSeconds: TimeInterval,
            path: String,
            wasStreaming: Bool,
            providerIdentifier: String? = nil,
            requestedModel: String? = nil,
            providerReportedCostUSD: Double? = nil,
            serverToolCalls: [TutorServerToolReceipt]? = nil,
            promptCachingMode: String? = nil,
            contextCompactionEnabled: Bool? = nil,
            translationMode: String? = nil,
            promptCacheStrategy: String? = nil,
            promptCacheApplied: Bool? = nil
        ) {
            self.id = id
            self.timestamp = timestamp
            self.model = model
            self.requestedModel = requestedModel
            self.providerReportedCostUSD = providerReportedCostUSD
            self.serverToolCalls = serverToolCalls
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.promptCacheHitTokens = promptCacheHitTokens
            self.promptCacheMissTokens = promptCacheMissTokens
            self.promptCacheWriteTokens = promptCacheWriteTokens
            self.durationSeconds = durationSeconds
            self.path = path
            self.wasStreaming = wasStreaming
            self.providerIdentifier = providerIdentifier
            self.promptCachingMode = promptCachingMode
            self.contextCompactionEnabled = contextCompactionEnabled
            self.translationMode = translationMode
            self.promptCacheStrategy = promptCacheStrategy
            self.promptCacheApplied = promptCacheApplied
        }
    }

    private static func guiRecord(_ entry: ProxyPilotCore.RequestRecord, id: UUID = UUID()) -> RequestRecord {
        RequestRecord(
            id: id, timestamp: entry.timestamp, model: entry.model,
            promptTokens: entry.promptTokens, completionTokens: entry.completionTokens,
            promptCacheHitTokens: entry.promptCacheHitTokens,
            promptCacheMissTokens: entry.promptCacheMissTokens,
            promptCacheWriteTokens: entry.promptCacheWriteTokens,
            durationSeconds: entry.durationSeconds, path: entry.path,
            wasStreaming: entry.wasStreaming, providerIdentifier: entry.providerIdentifier,
            requestedModel: entry.requestedModel, providerReportedCostUSD: entry.providerReportedCostUSD,
            serverToolCalls: entry.serverToolCalls, promptCachingMode: entry.promptCachingMode,
            contextCompactionEnabled: entry.contextCompactionEnabled, translationMode: entry.translationMode,
            promptCacheStrategy: entry.promptCacheStrategy, promptCacheApplied: entry.promptCacheApplied
        )
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

    /// Unbounded monotonic count of every request ever recorded this session.
    ///
    /// `requests` is intentionally bounded at `maxRetainedRequests` (500) to keep
    /// the live in-memory history, latency percentiles, cost matching, and Recent
    /// Requests list bounded (see DEVLOG v1.4.8 / v1.11.1). Deriving the *total*
    /// request count from `requests.count` silently pinned it at 500 once a
    /// session exceeded the retained window, so Home and the menu bar reported
    /// "500" forever even as the session kept climbing. This counter is the
    /// disambiguation: it counts every request, independent of the display buffer.
    private var totalRequestCount: Int = 0

    var totalRequests: Int { totalRequestCount }

    var totalPromptTokens: Int {
        requests.reduce(0) { $0 + $1.promptTokens }
    }

    var totalCompletionTokens: Int {
        requests.reduce(0) { $0 + $1.completionTokens }
    }

    var totalTokens: Int { totalPromptTokens + totalCompletionTokens }

    var totalPromptCacheHitTokens: Int {
        requests.reduce(0) { $0 + ($1.promptCacheHitTokens ?? 0) }
    }

    var totalPromptCacheMissTokens: Int {
        requests.reduce(0) { $0 + ($1.promptCacheMissTokens ?? 0) }
    }

    var totalPromptCacheWriteTokens: Int {
        requests.reduce(0) { $0 + ($1.promptCacheWriteTokens ?? 0) }
    }

    var cacheHitRate: Double? {
        let paired = requests.compactMap { record -> (hit: Int, miss: Int)? in
            guard let hit = record.promptCacheHitTokens, let miss = record.promptCacheMissTokens else { return nil }
            return (max(0, hit), max(0, miss))
        }
        let hit = paired.reduce(0) { $0 + $1.hit }
        let total = paired.reduce(0) { $0 + $1.hit + $1.miss }
        guard total > 0 else { return nil }
        return Double(hit) / Double(total)
    }

    var cacheAccountingAvailable: Bool {
        requests.contains { $0.promptCacheHitTokens != nil || $0.promptCacheMissTokens != nil || $0.promptCacheWriteTokens != nil }
    }

    var tokenAccountingAvailable: Bool {
        requests.contains { $0.hasTokenTelemetry }
    }

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

    // Event IDs outlive the retained display rows so a later journal reread cannot
    // count a GUI-served request twice after the 500-row display window rolls.
    private var recordedRequestIDs = Set<UUID>()

    private func recordEntries(_ entries: [RequestRecord]) {
        let fresh = entries.filter { recordedRequestIDs.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        if firstRequestTimestamp == nil { firstRequestTimestamp = fresh.first?.timestamp }
        totalRequestCount += fresh.count
        // Publish once per import batch, retaining the original UI performance
        // contract even when an archive contains hundreds of records.
        requests = Array((requests + fresh).suffix(Self.maxRetainedRequests))
    }

    func record(_ entry: RequestRecord) {
        recordEntries([entry])
    }

    func record(_ entry: ProxyPilotCore.RequestRecord) {
        recordEntries([Self.guiRecord(entry)])
    }

    func record(_ entries: [ProxyPilotCore.RequestRecord]) {
        recordEntries(entries.map { Self.guiRecord($0) })
    }

    func record(_ event: SessionReportEvent) {
        record(events: [event])
    }

    func record(events: [SessionReportEvent]) {
        recordEntries(events.map { Self.guiRecord($0.record, id: $0.id) })
    }

    func reset() {
        requests.removeAll()
        recordedRequestIDs.removeAll()
        firstRequestTimestamp = nil
        totalRequestCount = 0
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
