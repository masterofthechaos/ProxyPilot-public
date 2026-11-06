import Foundation
import ProxyPilotCore

/// All-time usage aggregate derived from the persisted session-report store.
///
/// Unlike `SessionHistorySession` (one proxy run), this flattens every
/// `SessionReportEvent` ever recorded into a single all-time rollup: token
/// totals, model and source distribution, session count, longest/busiest
/// session, latency, cache hit rate, and daily token buckets for the usage
/// chart. It is a pure value type computed by `build(from:)`.
struct AllTimeUsage: Equatable, Sendable {
    /// One traffic origin (gui / cli / mcp) with its share of requests and tokens.
    struct SourceShare: Equatable, Sendable {
        let source: String
        let requestCount: Int
        let totalTokens: Int
    }

    /// Compact per-session facts used for longest/busiest highlights.
    struct SessionStat: Equatable, Sendable {
        let id: String
        let source: String
        let startedAt: Date?
        let endedAt: Date?
        let requestCount: Int
        let totalTokens: Int

        /// Wall-clock span from the first to last recorded request. Sessions
        /// with a single request have a duration of 0.
        var durationSeconds: TimeInterval {
            guard let startedAt, let endedAt else { return 0 }
            return endedAt.timeIntervalSince(startedAt)
        }
    }

    /// One calendar day's token + request totals, for the usage line chart.
    struct DailyTokenBucket: Equatable, Sendable {
        /// Start-of-day date (timezone depends on the calendar passed to `build`).
        let day: Date
        let totalTokens: Int
        let requestCount: Int
    }

    let startedAt: Date?
    let endedAt: Date?
    let requestCount: Int
    let sessionCount: Int

    let totalPromptTokens: Int
    let totalCompletionTokens: Int
    let totalTokens: Int

    let totalPromptCacheHitTokens: Int
    let totalPromptCacheMissTokens: Int
    let totalPromptCacheWriteTokens: Int
    let cacheAccountingAvailable: Bool
    let cacheHitRate: Double?
    var cacheObservedRequests: Int = 0

    let modelDistribution: [SessionHistorySession.ModelCount]
    let sourceShares: [SourceShare]

    let p50Latency: TimeInterval?
    let p95Latency: TimeInterval?
    let maxLatency: TimeInterval?
    let avgLatency: TimeInterval?

    let longestSession: SessionStat?
    let busiestSession: SessionStat?
    let averageRequestsPerSession: Double?
    let averageSessionDurationSeconds: TimeInterval?

    let dailyTokenBuckets: [DailyTokenBucket]

    let totalTokensFormatted: String

    var isEmpty: Bool { requestCount == 0 }

    static let empty = AllTimeUsage(
        startedAt: nil,
        endedAt: nil,
        requestCount: 0,
        sessionCount: 0,
        totalPromptTokens: 0,
        totalCompletionTokens: 0,
        totalTokens: 0,
        totalPromptCacheHitTokens: 0,
        totalPromptCacheMissTokens: 0,
        totalPromptCacheWriteTokens: 0,
        cacheAccountingAvailable: false,
        cacheHitRate: nil,
        modelDistribution: [],
        sourceShares: [],
        p50Latency: nil,
        p95Latency: nil,
        maxLatency: nil,
        avgLatency: nil,
        longestSession: nil,
        busiestSession: nil,
        averageRequestsPerSession: nil,
        averageSessionDurationSeconds: nil,
        dailyTokenBuckets: [],
        totalTokensFormatted: "0"
    )

    /// Build an all-time rollup from persisted session-report events.
    ///
    /// `calendar` defaults to a Gregorian calendar (system timezone snapshot);
    /// tests pass a fixed-timezone calendar so daily buckets are deterministic.
    static func build(
        from events: [SessionReportEvent],
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> AllTimeUsage {
        guard !events.isEmpty else { return .empty }

        let sessions = SessionHistorySession.build(from: events)
        let requests = sessions.flatMap(\.requests)

        var startedAt: Date?
        var endedAt: Date?
        var totalPromptTokens = 0
        var totalCompletionTokens = 0
        var totalPromptCacheHitTokens = 0
        var totalPromptCacheMissTokens = 0
        var totalPromptCacheWriteTokens = 0
        var modelCounts: [String: Int] = [:]
        var sourceRequestCounts: [String: Int] = [:]
        var sourceTokenTotals: [String: Int] = [:]
        var durations: [TimeInterval] = []
        durations.reserveCapacity(requests.count)
        var dailyTokens: [Date: Int] = [:]
        var dailyRequests: [Date: Int] = [:]

        for request in requests {
            if let earliest = startedAt {
                if request.timestamp < earliest { startedAt = request.timestamp }
            } else {
                startedAt = request.timestamp
            }
            if let latest = endedAt {
                if request.timestamp > latest { endedAt = request.timestamp }
            } else {
                endedAt = request.timestamp
            }
            totalPromptTokens += request.promptTokens
            totalCompletionTokens += request.completionTokens
            totalPromptCacheHitTokens += request.promptCacheHitTokens ?? 0
            totalPromptCacheMissTokens += request.promptCacheMissTokens ?? 0
            totalPromptCacheWriteTokens += request.promptCacheWriteTokens ?? 0
            modelCounts[request.model, default: 0] += 1
            durations.append(request.durationSeconds)

            if let day = calendar.dateInterval(of: .day, for: request.timestamp)?.start {
                let requestTokens = request.promptTokens + request.completionTokens
                dailyTokens[day, default: 0] += requestTokens
                dailyRequests[day, default: 0] += 1
            }
        }

        for session in sessions {
            sourceRequestCounts[session.source, default: 0] += session.requestCount
            sourceTokenTotals[session.source, default: 0] += session.totalTokens
        }

        let totalTokens = totalPromptTokens + totalCompletionTokens
        let measured = requests.filter { $0.promptCacheHitTokens != nil && $0.promptCacheMissTokens != nil }
        let measuredHits = measured.reduce(0) { $0 + ($1.promptCacheHitTokens ?? 0) }
        let cacheHitTotal = measuredHits + measured.reduce(0) { $0 + ($1.promptCacheMissTokens ?? 0) }
        let cacheHitRate = cacheHitTotal > 0
            ? Double(measuredHits) / Double(cacheHitTotal)
            : nil

        let modelDistribution = modelCounts
            .map { SessionHistorySession.ModelCount(model: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.model < $1.model
            }

        let sourceShares = sourceRequestCounts
            .map { source, count in
                SourceShare(
                    source: source,
                    requestCount: count,
                    totalTokens: sourceTokenTotals[source] ?? 0
                )
            }
            .sorted {
                if $0.requestCount != $1.requestCount { return $0.requestCount > $1.requestCount }
                return $0.source < $1.source
            }

        let dailyTokenBuckets = dailyTokens
            .map { day, tokens in
                DailyTokenBucket(
                    day: day,
                    totalTokens: tokens,
                    requestCount: dailyRequests[day] ?? 0
                )
            }
            .sorted { $0.day < $1.day }

        let sessionStats = sessions.map { session in
            SessionStat(
                id: session.id,
                source: session.source,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                requestCount: session.requestCount,
                totalTokens: session.totalTokens
            )
        }
        let longestSession = sessionStats.max {
            $0.durationSeconds < $1.durationSeconds
                || ($0.durationSeconds == $1.durationSeconds && $0.requestCount < $1.requestCount)
        }
        let busiestSession = sessionStats.max {
            $0.requestCount < $1.requestCount
                || ($0.requestCount == $1.requestCount && $0.totalTokens < $1.totalTokens)
        }

        let averageRequestsPerSession: Double? = sessions.isEmpty
            ? nil
            : Double(requests.count) / Double(sessions.count)
        let averageSessionDurationSeconds: TimeInterval? = sessions.isEmpty
            ? nil
            : sessionStats.map(\.durationSeconds).reduce(0, +) / Double(sessions.count)

        return AllTimeUsage(
            startedAt: startedAt,
            endedAt: endedAt,
            requestCount: requests.count,
            sessionCount: sessions.count,
            totalPromptTokens: totalPromptTokens,
            totalCompletionTokens: totalCompletionTokens,
            totalTokens: totalTokens,
            totalPromptCacheHitTokens: totalPromptCacheHitTokens,
            totalPromptCacheMissTokens: totalPromptCacheMissTokens,
            totalPromptCacheWriteTokens: totalPromptCacheWriteTokens,
            cacheAccountingAvailable: requests.contains { $0.promptCacheHitTokens != nil || $0.promptCacheMissTokens != nil || $0.promptCacheWriteTokens != nil },
            cacheHitRate: cacheHitRate,
            cacheObservedRequests: requests.filter { $0.promptCacheHitTokens != nil || $0.promptCacheMissTokens != nil || $0.promptCacheWriteTokens != nil }.count,
            modelDistribution: modelDistribution,
            sourceShares: sourceShares,
            p50Latency: percentile(durations, percentile: 0.5),
            p95Latency: percentile(durations, percentile: 0.95),
            maxLatency: durations.max(),
            avgLatency: durations.isEmpty
                ? nil
                : durations.reduce(0, +) / Double(durations.count),
            longestSession: longestSession,
            busiestSession: busiestSession,
            averageRequestsPerSession: averageRequestsPerSession,
            averageSessionDurationSeconds: averageSessionDurationSeconds,
            dailyTokenBuckets: dailyTokenBuckets,
            totalTokensFormatted: formatTokens(totalTokens)
        )
    }

    private static func formatTokens(_ totalTokens: Int) -> String {
        if totalTokens >= 1_000_000 {
            return String(format: "%.1fM", Double(totalTokens) / 1_000_000)
        }
        if totalTokens >= 1_000 {
            return String(format: "%.1fK", Double(totalTokens) / 1_000)
        }
        return "\(totalTokens)"
    }

    /// Linear-interpolation percentile, copied from `SessionHistorySession` so all-time
    /// percentiles stay statistically comparable to per-session ones.
    private static func percentile(_ values: [TimeInterval], percentile: Double) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
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
