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
        /// `StreamOutcome` raw value; nil for buffered or not-assessed requests.
        var streamOutcome: String?
        /// Why the upstream request failed, when classified. Category and numbers only.
        var upstreamFailure: UpstreamFailure?

        var totalTokens: Int { promptTokens + completionTokens }

        var hasTokenTelemetry: Bool {
            promptTokens > 0
                || completionTokens > 0
                || promptCacheHitTokens != nil
                || promptCacheMissTokens != nil
                || promptCacheWriteTokens != nil
        }

/// False when the provider failed the request or the stream did not
        /// finish.
        var isCompleted: Bool {
            upstreamFailure == nil && (streamOutcome == nil || streamOutcome == StreamOutcome.completed.rawValue)
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
            promptCacheApplied: Bool? = nil,
            streamOutcome: String? = nil,
            upstreamFailure: UpstreamFailure? = nil
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
            self.streamOutcome = streamOutcome
            self.upstreamFailure = upstreamFailure
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
            promptCacheStrategy: entry.promptCacheStrategy, promptCacheApplied: entry.promptCacheApplied,
            streamOutcome: entry.streamOutcome,
            upstreamFailure: entry.upstreamFailure
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

    /// Requests that delivered a complete response. A request the provider
    /// failed, or a stream that was cut off, is recorded but not counted here.
    private var completedRequestCount: Int = 0
    var completedRequests: Int { completedRequestCount }

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

    /// Token totals are known when some request reported usage, or when every
    /// request failed: a failed request used no tokens, which is not the
    /// same as a provider that returned no usage.
    var tokenAccountingAvailable: Bool {
        requests.contains { $0.hasTokenTelemetry }
            || (!requests.isEmpty && requests.allSatisfy { $0.upstreamFailure != nil })
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
        completedRequestCount += fresh.filter(\.isCompleted).count
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
        completedRequestCount = 0
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

/// The one-line token summary on a request row, shared by Home and Session
/// History. A failed request says why it failed.
enum RequestRowSummary {
    static func text(totalTokens: Int, hasTokenTelemetry: Bool, failure: UpstreamFailure?) -> String {
        if let failure {
            let reason = "failed: \(failure.shortDescription)"
            return hasTokenTelemetry ? "\(totalTokens) tok, \(reason)" : reason
        }
        return hasTokenTelemetry ? "\(totalTokens) tok" : "token usage unavailable"
    }
}
