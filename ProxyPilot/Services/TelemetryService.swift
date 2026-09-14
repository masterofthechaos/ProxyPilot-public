import Foundation
import ProxyPilotCore

struct TelemetryEvent: Codable {
    let name: String
    let timestamp: Date
    let installID: String
    let sessionID: String
    let payload: [String: String]
}

@MainActor
final class TelemetryService {
    static let shared = TelemetryService()

    private enum RemoteDeliveryKind {
        case coreHealth
        case analytics
    }

    private let defaults: UserDefaults
    private let installIDKey = "proxypilot.telemetry.installID"
    private let isMicahInternalInstallKey = "proxypilot.telemetry.isMicah"
    private let crashMarkerURL: URL
    private let localEventLogURL: URL
    private let protectedInternalMarkerURL: URL?
    private let remoteCaptureHook: ((String, [String: String]) -> Void)?
    private let postHogDeliveryEnabled: Bool
    private let postHogAPIKeyProvider: () -> String?
    private let postHogRequestHook: ((URLRequest) -> Void)?
    private var sessionID = UUID().uuidString
    private let analyticsSeenEventIDsKey = "proxypilot.telemetry.analyticsSeenSessionEventIDs.v1"
    private let firstProxiedInferenceTrackedKey = "proxypilot.telemetry.firstProxiedInferenceTracked.v1"
    private static let analyticsSchemaVersion = "2"
    private static let maximumLocalEventLogBytes = 1_024 * 1_024
    private static let maximumSeenSessionEventIDs = 4_096
    private static let alphaRequiredFailureEvents: Set<String> = [
        "preflight_failed",
        "proxy_start_failed",
        "previous_session_may_have_crashed"
    ]

    /// Event-specific payload allowlists are the last line of defense against a
    /// caller accidentally adding prompts, model slugs, URLs, or raw errors.
    /// Provider identifiers are intentionally allowed for pathway maintenance.
    private static let allowedPayloadKeysByEvent: [String: Set<String>] = [
        "proxy_start_clicked": ["mode"],
        "proxy_start_succeeded": ["mode"],
        "proxy_start_failed": ["code", "mode", "issue_actions", "preflight_failure_count", "preflight_failure_ids"],
        "preflight_failed": ["failure_count", "failure_ids", "warning_count", "warning_ids", "fix_actions", "mode", "provider_class", "local_auth_required", "upstream_key_required"],
        "previous_session_may_have_crashed": ["mode", "provider_class"],
        "onboarding_started": [],
        "onboarding_completed": [],
        "first_successful_request": [],
        "proxy_models_fetch_succeeded": [],
        "provider_models_fetch_succeeded": [],
        "upstream_test_succeeded": [],
        "first_proxied_inference_succeeded": ["client_surface", "provider_identifier"],
        "provider_endpoint_failed": ["operation", "code", "provider_class", "provider_release_stage", "default_endpoint", "upstream_key_required"],
        "diagnostics_exported": [],
        "dock_tile_interactive_enabled": [],
        "proxy_pilot_agent_installed": ["registration"],
        "analytics_enabled": ["consent_contract_version", "surface"],
        "feature_used": ["feature", "action", "mode"],
        "proxy_request_failed": ["stage", "error_class", "status_class", "path_category", "provider_identifier", "client_surface", "retryable"],
        "proxy_session_summary": [
            "summary_kind", "proxy_session_id", "client_surface", "provider_identifiers",
            "request_count", "prompt_token_bucket", "completion_token_bucket", "total_token_bucket",
            "latency_p50_bucket", "latency_p95_bucket", "session_span_bucket", "streaming_share_bucket",
            "cache_hit_rate_bucket", "cache_read_token_bucket", "cache_write_token_bucket",
            "path_categories", "prompt_caching_modes", "context_compaction", "translation_modes"
        ]
    ]

    static let defaultProtectedInternalMarkerURL = URL(fileURLWithPath: "/Library/Application Support/ProxyPilot/internal-telemetry-marker")

    init(
        defaults: UserDefaults = .standard,
        baseDirectory: URL? = nil,
        postHogDeliveryEnabled: Bool = TelemetryService.defaultPostHogDeliveryEnabled(),
        protectedInternalMarkerURL: URL? = TelemetryService.defaultProtectedInternalMarkerURL,
        postHogAPIKeyProvider: @escaping () -> String? = {
            Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String
        },
        remoteCaptureHook: ((String, [String: String]) -> Void)? = nil,
        postHogRequestHook: ((URLRequest) -> Void)? = nil
    ) {
        let base = (baseDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("ProxyPilotTelemetry", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        self.defaults = defaults
        crashMarkerURL = base.appendingPathComponent("session.marker")
        localEventLogURL = base.appendingPathComponent("events.ndjson")
        self.protectedInternalMarkerURL = protectedInternalMarkerURL
        self.postHogDeliveryEnabled = postHogDeliveryEnabled
        self.postHogAPIKeyProvider = postHogAPIKeyProvider
        self.remoteCaptureHook = remoteCaptureHook
        self.postHogRequestHook = postHogRequestHook
    }

    static func defaultPostHogDeliveryEnabled(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard environment["XCTestConfigurationFilePath"] == nil else {
            return false
        }

        guard !AppBuildBadge.isAlphaBundle(bundleIdentifier) else {
            return false
        }

        return true
    }

    var installID: String {
        if let existing = defaults.string(forKey: installIDKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: installIDKey)
        return created
    }

    func beginSession() -> Bool {
        let previousSessionLikelyCrashed = FileManager.default.fileExists(atPath: crashMarkerURL.path)
        let markerText = ISO8601DateFormatter().string(from: Date())
        try? markerText.write(to: crashMarkerURL, atomically: true, encoding: .utf8)
        return previousSessionLikelyCrashed
    }

    func endSession() {
        try? FileManager.default.removeItem(at: crashMarkerURL)
    }

    func resetForFreshInstall() {
        defaults.removeObject(forKey: installIDKey)
        defaults.removeObject(forKey: analyticsSeenEventIDsKey)
        defaults.removeObject(forKey: firstProxiedInferenceTrackedKey)
        try? FileManager.default.removeItem(at: crashMarkerURL)
        try? FileManager.default.removeItem(at: localEventLogURL)
        sessionID = UUID().uuidString
    }

    func trackCoreHealthAppOpen(appVersion: String, buildNumber: String) {
        var payload = [
            "app_version": appVersion,
            "build_number": buildNumber
        ]
        if isMicahInternalInstall {
            payload["is_micah"] = "true"
        }

        let event = makeEvent(
            name: "app_opened",
            payload: payload
        )

        persistLocally(event: event)
        sendToPostHog(event: event, delivery: .coreHealth)
    }

    func track(name: String, payload: [String: String] = [:], telemetryOptIn: Bool) {
        let event = makeEvent(name: name, payload: Self.sanitizedPayload(payload, for: name))

        persistLocally(event: event)
        if Self.shouldSendRemoteEvent(
            name: name,
            telemetryOptIn: telemetryOptIn,
            isAlphaBuild: AppBuildBadge.isAlphaBundle(Bundle.main.bundleIdentifier)
        ) {
            sendToPostHog(event: event, delivery: .analytics)
        }
    }

    /// Sends incremental, privacy-bounded summaries for request records written
    /// by GUI, CLI, MCP, and attributed RepoGPS sessions. Specific model slugs
    /// are deliberately never read while constructing these payloads.
    func trackSessionReportEvents(_ events: [SessionReportEvent], telemetryOptIn: Bool) {
        guard telemetryOptIn, !events.isEmpty else { return }

        // Consent is prospective. On the first v2 observation, establish a
        // baseline instead of uploading records that predate this contract.
        if defaults.object(forKey: analyticsSeenEventIDsKey) == nil {
            defaults.set(
                Array(events.suffix(Self.maximumSeenSessionEventIDs)).map { $0.id.uuidString },
                forKey: analyticsSeenEventIDsKey
            )
            return
        }

        let previouslySeen = Set(defaults.stringArray(forKey: analyticsSeenEventIDsKey) ?? [])
        let unseen = events.filter { !previouslySeen.contains($0.id.uuidString) }
        guard !unseen.isEmpty else { return }

        if !defaults.bool(forKey: firstProxiedInferenceTrackedKey), let first = unseen.first {
            track(
                name: "first_proxied_inference_succeeded",
                payload: [
                    "client_surface": Self.normalizedClientSurface(first.source),
                    "provider_identifier": Self.normalizedProviderIdentifier(first.record.providerIdentifier)
                ],
                telemetryOptIn: true
            )
            defaults.set(true, forKey: firstProxiedInferenceTrackedKey)
        }

        for payload in Self.sessionSummaryPayloads(from: unseen) {
            track(name: "proxy_session_summary", payload: payload, telemetryOptIn: true)
        }

        let retainedIDs = Array((previouslySeen.union(unseen.map { $0.id.uuidString })).suffix(Self.maximumSeenSessionEventIDs))
        defaults.set(retainedIDs, forKey: analyticsSeenEventIDsKey)
    }

    static func shouldSendRemoteEvent(name: String, telemetryOptIn: Bool, isAlphaBuild: Bool) -> Bool {
        telemetryOptIn || (isAlphaBuild && alphaRequiredFailureEvents.contains(name))
    }

    private func makeEvent(name: String, payload: [String: String]) -> TelemetryEvent {
        TelemetryEvent(
            name: name,
            timestamp: Date(),
            installID: installID,
            sessionID: sessionID,
            payload: payload
        )
    }

    static func sanitizedPayload(_ payload: [String: String], for eventName: String) -> [String: String] {
        guard let allowedKeys = allowedPayloadKeysByEvent[eventName] else { return [:] }
        return payload.filter { allowedKeys.contains($0.key) }
    }

    static func sessionSummaryPayloads(from events: [SessionReportEvent]) -> [[String: String]] {
        let grouped = Dictionary(grouping: events) { event in
            "\(event.source)|\(event.sessionID.lowercased())"
        }

        return grouped.values.map { group in
            let records = group.map(\.record)
            let promptTokens = records.reduce(0) { $0 + max(0, $1.promptTokens) }
            let completionTokens = records.reduce(0) { $0 + max(0, $1.completionTokens) }
            let cacheReadTokens = records.reduce(0) { $0 + max(0, $1.promptCacheHitTokens ?? 0) + max(0, $1.promptCacheMissTokens ?? 0) }
            let cacheHitTokens = records.reduce(0) { $0 + max(0, $1.promptCacheHitTokens ?? 0) }
            let cacheWriteTokens = records.reduce(0) { $0 + max(0, $1.promptCacheWriteTokens ?? 0) }
            let sortedLatencies = records.map { max(0, $0.durationSeconds) }.sorted()
            let timestamps = records.map(\.timestamp).sorted()
            let streamingCount = records.filter(\.wasStreaming).count

            return [
                "summary_kind": "incremental",
                "proxy_session_id": group[0].sessionID.lowercased(),
                "client_surface": normalizedClientSurface(group[0].source),
                "provider_identifiers": joinedDistinct(records.map { normalizedProviderIdentifier($0.providerIdentifier) }),
                "request_count": String(records.count),
                "prompt_token_bucket": countBucket(promptTokens),
                "completion_token_bucket": countBucket(completionTokens),
                "total_token_bucket": countBucket(promptTokens + completionTokens),
                "latency_p50_bucket": durationBucket(percentile(sortedLatencies, fraction: 0.50)),
                "latency_p95_bucket": durationBucket(percentile(sortedLatencies, fraction: 0.95)),
                "session_span_bucket": durationBucket((timestamps.last?.timeIntervalSince(timestamps.first ?? Date())) ?? 0),
                "streaming_share_bucket": shareBucket(numerator: streamingCount, denominator: records.count),
                "cache_hit_rate_bucket": shareBucket(numerator: cacheHitTokens, denominator: cacheReadTokens),
                "cache_read_token_bucket": countBucket(cacheReadTokens),
                "cache_write_token_bucket": countBucket(cacheWriteTokens),
                "path_categories": joinedDistinct(records.map { pathCategory($0.path) }),
                "prompt_caching_modes": joinedDistinct(records.compactMap(\.promptCachingMode)),
                "context_compaction": joinedDistinct(records.compactMap { $0.contextCompactionEnabled.map(String.init) }),
                "translation_modes": joinedDistinct(records.compactMap(\.translationMode))
            ]
        }
        .sorted { ($0["proxy_session_id"] ?? "") < ($1["proxy_session_id"] ?? "") }
    }

    private static func joinedDistinct(_ values: [String]) -> String {
        Array(Set(values.filter { !$0.isEmpty })).sorted().joined(separator: ",")
    }

    private static func normalizedClientSurface(_ source: String) -> String {
        switch source.lowercased() {
        case "gui", "cli", "mcp", "repogps": return source.lowercased()
        default: return "other"
        }
    }

    private static func normalizedProviderIdentifier(_ raw: String?) -> String {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return "unknown" }
        let supported = Set(UpstreamProvider.allCases.map(\.rawValue)).union(["custom"])
        return supported.contains(raw) ? raw : "other"
    }

    private static func pathCategory(_ path: String) -> String {
        switch path {
        case "/v1/chat/completions": return "chat_completions"
        case "/v1/messages": return "anthropic_messages"
        default: return "other"
        }
    }

    private static func percentile(_ sortedValues: [Double], fraction: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let index = min(sortedValues.count - 1, Int((Double(sortedValues.count - 1) * fraction).rounded()))
        return sortedValues[index]
    }

    private static func durationBucket(_ seconds: Double) -> String {
        switch seconds {
        case ..<0.25: return "lt_250ms"
        case ..<1: return "250ms_to_1s"
        case ..<3: return "1s_to_3s"
        case ..<10: return "3s_to_10s"
        case ..<30: return "10s_to_30s"
        case ..<60: return "30s_to_1m"
        case ..<300: return "1m_to_5m"
        case ..<1_800: return "5m_to_30m"
        default: return "gte_30m"
        }
    }

    private static func countBucket(_ count: Int) -> String {
        switch count {
        case ...0: return "0"
        case 1...99: return "1_to_99"
        case 100...999: return "100_to_999"
        case 1_000...9_999: return "1k_to_9k"
        case 10_000...99_999: return "10k_to_99k"
        case 100_000...999_999: return "100k_to_999k"
        default: return "gte_1m"
        }
    }

    private static func shareBucket(numerator: Int, denominator: Int) -> String {
        guard denominator > 0 else { return "unavailable" }
        let share = Double(numerator) / Double(denominator)
        switch share {
        case 0: return "0"
        case ..<0.25: return "lt_25pct"
        case ..<0.50: return "25_to_49pct"
        case ..<0.75: return "50_to_74pct"
        case ..<1: return "75_to_99pct"
        default: return "100pct"
        }
    }

    private var isMicahInternalInstall: Bool {
        defaults.bool(forKey: isMicahInternalInstallKey) || protectedInternalMarkerIsPresent
    }

    private var protectedInternalMarkerIsPresent: Bool {
        guard let protectedInternalMarkerURL,
              let marker = try? String(contentsOf: protectedInternalMarkerURL, encoding: .utf8) else {
            return false
        }

        return marker
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains("is_micah=true")
    }

    private func persistLocally(event: TelemetryEvent) {
        guard let data = try? JSONEncoder().encode(event),
              let line = String(data: data, encoding: .utf8)?.appending("\n"),
              let lineData = line.data(using: .utf8) else {
            return
        }

        if let size = (try? localEventLogURL.resourceValues(forKeys: [.fileSizeKey]).fileSize),
           size + lineData.count > Self.maximumLocalEventLogBytes {
            try? FileManager.default.removeItem(at: localEventLogURL)
        }

        if FileManager.default.fileExists(atPath: localEventLogURL.path) {
            if let fh = try? FileHandle(forWritingTo: localEventLogURL) {
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: lineData)
                try? fh.close()
            }
        } else {
            try? lineData.write(to: localEventLogURL)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localEventLogURL.path)
    }

    private func sendToPostHog(event: TelemetryEvent, delivery: RemoteDeliveryKind) {
        var properties: [String: String] = event.payload
        switch delivery {
        case .analytics:
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            properties["session_id"] = event.sessionID
            properties["$lib"] = "proxypilot"
            properties["$lib_version"] = version
            properties["$os"] = "macOS"
            properties["analytics_schema_version"] = Self.analyticsSchemaVersion
            properties["app_version"] = version
            properties["build_number"] = build
            properties["release_channel"] = AppBuildBadge.isAlphaBundle(Bundle.main.bundleIdentifier) ? "alpha" : "stable"
        case .coreHealth:
            break
        }

        remoteCaptureHook?(event.name, properties)
        guard postHogDeliveryEnabled else { return }

        guard let apiKey = postHogAPIKeyProvider(),
              !apiKey.isEmpty,
              let url = URL(string: "https://us.i.posthog.com/capture/") else {
            return
        }

        let body: [String: Any] = [
            "api_key": apiKey,
            "event": event.name,
            "distinct_id": event.installID,
            "timestamp": ISO8601DateFormatter().string(from: event.timestamp),
            "properties": properties
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        if let postHogRequestHook {
            postHogRequestHook(request)
            return
        }

        Task.detached {
            for attempt in 0..<3 {
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                        return
                    }
                } catch {
                    // Optional analytics must never interfere with app behavior.
                }
                guard attempt < 2 else { return }
                try? await Task.sleep(for: .milliseconds(250 * (1 << attempt)))
            }
        }
    }
}
