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

    private let defaults = UserDefaults.standard
    private let installIDKey = "proxypilot.telemetry.installID"
    private let crashMarkerURL: URL
    private let localEventLogURL: URL
    private var sessionID = UUID().uuidString

    private init() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyPilotTelemetry", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        crashMarkerURL = base.appendingPathComponent("session.marker")
        localEventLogURL = base.appendingPathComponent("events.ndjson")
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

    func track(name: String, payload: [String: String] = [:], telemetryOptIn: Bool) {
        let event = TelemetryEvent(
            name: name,
            timestamp: Date(),
            installID: installID,
            sessionID: sessionID,
            payload: payload
        )

        persistLocally(event: event)
        if telemetryOptIn {
            sendToPostHog(event: event)
        }
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

    private func sendToPostHog(event: TelemetryEvent) {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String,
              !apiKey.isEmpty,
              let url = URL(string: "https://us.i.posthog.com/capture/") else {
            return
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        var properties: [String: String] = event.payload
        properties["session_id"] = event.sessionID
        properties["$lib"] = "proxypilot"
        properties["$lib_version"] = version
        properties["$os"] = "macOS"

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
