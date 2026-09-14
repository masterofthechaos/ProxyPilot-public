import ArgumentParser
import Foundation
import ProxyPilotCore

struct TelemetryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "telemetry", abstract: "Report attributed usage for one client session.")
    @Option(name: .long) var client: String
    @Option(name: .long) var sessionId: String
    @Flag(name: .long) var json = false
    func run() throws {
        guard let attribution = RequestAttribution.validated(client: client, sessionID: sessionId) else { throw ValidationError("Only client=repogps with a valid UUID session-id is supported") }
        let events = try SessionReportStore.readEvents().filter {
            $0.source.caseInsensitiveCompare(attribution.client) == .orderedSame
                && $0.sessionID.caseInsensitiveCompare(attribution.sessionID) == .orderedSame
        }
        let telemetry = AttributedSessionTelemetry.aggregate(records: events.map(\.record))
        let modelBreakdown = Dictionary(grouping: events, by: { $0.record.model }).mapValues(Self.breakdown)
        let roleBreakdown = Dictionary(grouping: events, by: { $0.role ?? "unavailable_legacy" }).mapValues(Self.breakdown)
        let reportedCost = events.compactMap(\.record.providerReportedCostUSD).reduce(0, +)
        let reportedCostAvailable = events.contains { $0.record.providerReportedCostUSD != nil }
        let estimates = events.compactMap { event -> Double? in
            guard event.record.providerReportedCostUSD == nil,
                  let providerID = event.record.providerIdentifier,
                  let provider = UpstreamProvider(rawValue: providerID),
                  let metadata = provider.knownModelMetadata(for: event.record.model) else { return nil }
            return metadata.estimatedCostUSD(
                promptTokens: event.record.promptTokens,
                completionTokens: event.record.completionTokens,
                promptCacheHitTokens: event.record.promptCacheHitTokens,
                promptCacheMissTokens: event.record.promptCacheMissTokens,
                promptCacheWriteTokens: event.record.promptCacheWriteTokens
            )
        }
        let estimatedCost = estimates.reduce(0, +)
        let providerCostValue: Any = reportedCostAvailable ? reportedCost : NSNull()
        let estimatedCostValue: Any = estimates.isEmpty ? NSNull() : estimatedCost
        var payload: [String: Any] = [
            "schema_version": 2,
            "client": attribution.client,
            "session_id": attribution.sessionID,
            "requests": telemetry.requests,
            "prompt_tokens": telemetry.promptTokens,
            "completion_tokens": telemetry.completionTokens,
            "total_tokens": telemetry.totalTokens,
            "models": telemetry.models,
            "model_breakdown": modelBreakdown,
            "role_breakdown": roleBreakdown,
            "legacy_role_breakdown_available": !events.contains { $0.role == nil },
            "cache_accounting_available": telemetry.cacheAccountingAvailable,
            "cost": [
                "provider_reported_usd": providerCostValue,
                "estimated_usd": estimatedCostValue,
                "provenance": reportedCostAvailable ? "mixed_or_provider_reported" : (estimates.isEmpty ? "unavailable" : "provider_known_catalog_estimate"),
            ],
        ]
        if let averageLatencyMs = telemetry.averageLatencyMs { payload["average_latency_ms"] = averageLatencyMs }
        if telemetry.cacheAccountingAvailable {
            payload["prompt_cache_hit_tokens"] = telemetry.promptCacheHitTokens
            payload["prompt_cache_miss_tokens"] = telemetry.promptCacheMissTokens
            payload["prompt_cache_write_tokens"] = telemetry.promptCacheWriteTokens
            if let rate = telemetry.cacheHitRate { payload["cache_hit_rate"] = rate }
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]); print(String(decoding: data, as: UTF8.self))
    }

    private static func breakdown(_ events: [SessionReportEvent]) -> [String: Any] {
        [
            "requests": events.count,
            "prompt_tokens": events.reduce(0) { $0 + $1.record.promptTokens },
            "completion_tokens": events.reduce(0) { $0 + $1.record.completionTokens },
            "total_tokens": events.reduce(0) { $0 + $1.record.promptTokens + $1.record.completionTokens },
            "returned_models": Dictionary(grouping: events, by: { $0.record.model }).mapValues(\.count),
        ]
    }
}
