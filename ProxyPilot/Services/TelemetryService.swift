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

    private let defaults = UserDefaults.standard
    private let installIDKey = "proxypilot.telemetry.installID"
    private let crashMarkerURL: URL
    private let localEventLogURL: URL
    private let remoteCaptureHook: ((String, [String: String]) -> Void)?
    private var sessionID = UUID().uuidString

    init(
        baseDirectory: URL? = nil,
        remoteCaptureHook: ((String, [String: String]) -> Void)? = nil
    ) {
        let base = (baseDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("ProxyPilotTelemetry", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        crashMarkerURL = base.appendingPathComponent("session.marker")
        localEventLogURL = base.appendingPathComponent("events.ndjson")
        self.remoteCaptureHook = remoteCaptureHook
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
        let event = makeEvent(
            name: "app_opened",
            payload: [
                "app_version": appVersion,
                "build_number": buildNumber
            ]
        )

        persistLocally(event: event)
        sendToPostHog(event: event, delivery: .coreHealth)
    }

    func track(name: String, payload: [String: String] = [:], telemetryOptIn: Bool) {
        let event = makeEvent(name: name, payload: payload)

        persistLocally(event: event)
        if telemetryOptIn {
            sendToPostHog(event: event, delivery: .analytics)
        }
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

        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String,
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

        Task.detached {
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
