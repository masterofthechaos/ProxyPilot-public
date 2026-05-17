import Foundation

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
    private static let alphaRequiredFailureEvents: Set<String> = [
        "preflight_failed",
        "proxy_start_failed",
        "previous_session_may_have_crashed"
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
        let event = makeEvent(name: name, payload: payload)

        persistLocally(event: event)
        if Self.shouldSendRemoteEvent(
            name: name,
            telemetryOptIn: telemetryOptIn,
            isAlphaBuild: AppBuildBadge.isAlphaBundle(Bundle.main.bundleIdentifier)
        ) {
            sendToPostHog(event: event, delivery: .analytics)
        }
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

        if FileManager.default.fileExists(atPath: localEventLogURL.path) {
            if let fh = try? FileHandle(forWritingTo: localEventLogURL) {
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: lineData)
                try? fh.close()
            }
        } else {
            try? lineData.write(to: localEventLogURL)
        }
    }

    private func sendToPostHog(event: TelemetryEvent, delivery: RemoteDeliveryKind) {
        var properties: [String: String] = event.payload
        switch delivery {
        case .analytics:
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            properties["session_id"] = event.sessionID
            properties["$lib"] = "proxypilot"
            properties["$lib_version"] = version
            properties["$os"] = "macOS"
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
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
