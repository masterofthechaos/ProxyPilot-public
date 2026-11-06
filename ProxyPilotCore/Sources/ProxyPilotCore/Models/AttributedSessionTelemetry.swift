import Foundation

/// Usage totals derived from the durable session report rather than from a single process's
/// in-memory counters.
///
/// `SessionStats` only sees traffic served by the proxy running inside its own process. In the
/// normal deployment the proxy is a separate daemon (or the GUI), so a `serve --mcp` process
/// asked for "session stats" reports zeros no matter how much traffic the user's session
/// actually generated. Every proxy appends to the shared `SessionReportStore`, so aggregating
/// that store is the only view that is correct regardless of which process owns the listener.
public struct AttributedSessionTelemetry: Equatable, Sendable {
    public let requests: Int
    public let promptTokens: Int
    public let completionTokens: Int
    public let models: [String: Int]
    public let averageLatencyMs: Int?
    public let promptCacheHitTokens: Int
    public let promptCacheMissTokens: Int
    public let promptCacheWriteTokens: Int
    public let cacheObservedRequests: Int
    private let rateHitTokens: Int
    private let rateMissTokens: Int
    public let firstRequestAt: Date?
    public let lastRequestAt: Date?

    public var totalTokens: Int { promptTokens + completionTokens }

    public var cacheHitRate: Double? {
        let total = rateHitTokens + rateMissTokens
        return total > 0 ? Double(rateHitTokens) / Double(total) : nil
    }

    /// Mirrors `SessionStats.Snapshot`: absent accounting is reported as "unavailable" rather
    /// than as a zero hit rate, so a caller cannot read silence as a cache miss.
    public var cacheAccountingAvailable: Bool {
        cacheObservedRequests > 0 || promptCacheHitTokens > 0 || promptCacheMissTokens > 0 || promptCacheWriteTokens > 0
    }

    public static let empty = AttributedSessionTelemetry(
        requests: 0,
        promptTokens: 0,
        completionTokens: 0,
        models: [:],
        averageLatencyMs: nil,
        promptCacheHitTokens: 0,
        promptCacheMissTokens: 0,
        promptCacheWriteTokens: 0,
        firstRequestAt: nil,
        lastRequestAt: nil
    )

    public init(
        requests: Int,
        promptTokens: Int,
        completionTokens: Int,
        models: [String: Int],
        averageLatencyMs: Int?,
        promptCacheHitTokens: Int,
        promptCacheMissTokens: Int,
        promptCacheWriteTokens: Int,
        firstRequestAt: Date?,
        lastRequestAt: Date?,
        cacheObservedRequests: Int = 0,
        rateHitTokens: Int? = nil,
        rateMissTokens: Int? = nil
    ) {
        self.cacheObservedRequests = cacheObservedRequests
        self.rateHitTokens = rateHitTokens ?? promptCacheHitTokens
        self.rateMissTokens = rateMissTokens ?? promptCacheMissTokens
        self.requests = requests
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.models = models
        self.averageLatencyMs = averageLatencyMs
        self.promptCacheHitTokens = promptCacheHitTokens
        self.promptCacheMissTokens = promptCacheMissTokens
        self.promptCacheWriteTokens = promptCacheWriteTokens
        self.firstRequestAt = firstRequestAt
        self.lastRequestAt = lastRequestAt
    }

    /// Totals for the events belonging to one attributed client session.
    ///
    /// Stored IDs are lowercased by `RequestAttribution.validated`, while the environment and
    /// the session lease carry the uppercase form, so the comparison must stay case-insensitive.
    public static func aggregate(
        events: [SessionReportEvent],
        matching attribution: RequestAttribution
    ) -> AttributedSessionTelemetry {
        aggregate(records: events.filter {
            $0.source.caseInsensitiveCompare(attribution.client) == .orderedSame
                && $0.sessionID.caseInsensitiveCompare(attribution.sessionID) == .orderedSame
        }.map(\.record))
    }

    public static func aggregate(records: [RequestRecord]) -> AttributedSessionTelemetry {
        guard !records.isEmpty else { return .empty }

        var promptTokens = 0
        var completionTokens = 0
        var models: [String: Int] = [:]
        var latencySum = 0
        var cacheHit = 0
        var cacheMiss = 0
        var cacheWrite = 0
        var earliest: Date?
        var latest: Date?

        for record in records {
            promptTokens += record.promptTokens
            completionTokens += record.completionTokens
            models[record.model, default: 0] += 1
            latencySum += Int((record.durationSeconds * 1000.0).rounded())
            cacheHit += record.promptCacheHitTokens ?? 0
            cacheMiss += record.promptCacheMissTokens ?? 0
            cacheWrite += record.promptCacheWriteTokens ?? 0
            if earliest == nil || record.timestamp < earliest! { earliest = record.timestamp }
            if latest == nil || record.timestamp > latest! { latest = record.timestamp }
        }

        return AttributedSessionTelemetry(
            requests: records.count,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            models: models,
            averageLatencyMs: latencySum / records.count,
            promptCacheHitTokens: cacheHit,
            promptCacheMissTokens: cacheMiss,
            promptCacheWriteTokens: cacheWrite,
            firstRequestAt: earliest,
            lastRequestAt: latest,
            cacheObservedRequests: records.filter { $0.promptCacheHitTokens != nil || $0.promptCacheMissTokens != nil || $0.promptCacheWriteTokens != nil }.count,
            rateHitTokens: records.filter { $0.promptCacheHitTokens != nil && $0.promptCacheMissTokens != nil }.reduce(0) { $0 + ($1.promptCacheHitTokens ?? 0) },
            rateMissTokens: records.filter { $0.promptCacheHitTokens != nil && $0.promptCacheMissTokens != nil }.reduce(0) { $0 + ($1.promptCacheMissTokens ?? 0) }
        )
    }
}

/// Discovers which client session the current process is serving.
///
/// RepoGPS launches `proxypilot serve --mcp` as a child process and exports its session
/// identity in the environment, the same UUID it puts in the `X-ProxyPilot-Session-ID` header
/// on every request it proxies. Reading it here keeps attribution on ProxyPilot's own side of
/// the boundary — no reaching into RepoGPS's private state directory.
public enum ClientSessionEnvironment {
    public static let sessionIDVariable = "RGPS_SESSION_ID"
    public static let clientVariable = "OPENCODE_CLIENT"

    public static func attribution(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RequestAttribution? {
        guard let sessionID = environment[sessionIDVariable] else { return nil }
        // The RGPS_ prefix already identifies the harness; the explicit client variable is only
        // consulted so a future harness can announce a different name.
        return RequestAttribution.validated(
            client: environment[clientVariable] ?? "repogps",
            sessionID: sessionID
        )
    }
}
