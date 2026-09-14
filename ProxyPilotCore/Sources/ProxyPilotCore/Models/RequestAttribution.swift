import Foundation

public struct RequestAttribution: Sendable, Codable, Equatable {
    public let client: String
    public let sessionID: String
    public let role: String

    public init(client: String, sessionID: String, role: String = "lead") {
        self.client = client
        self.sessionID = sessionID
        self.role = role
    }

    public static func validated(client: String?, sessionID: String?, role: String? = nil) -> Self? {
        guard client?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "repogps",
              let rawSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: rawSessionID) else { return nil }
        let normalizedRole = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "lead"
        guard ["lead", "navigator"].contains(normalizedRole) else { return nil }
        return .init(client: "repogps", sessionID: uuid.uuidString.lowercased(), role: normalizedRole)
    }

    public static func validated(headers: [String: String]) -> Self? {
        func value(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
        return validated(
            client: value("X-ProxyPilot-Client"),
            sessionID: value("X-ProxyPilot-Session-ID"),
            role: value("X-ProxyPilot-Role")
        )
    }
}

public enum RequestAttributionContext {
    @TaskLocal public static var current: RequestAttribution?
}
