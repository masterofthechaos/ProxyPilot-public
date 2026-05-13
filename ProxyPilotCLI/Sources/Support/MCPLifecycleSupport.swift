import Foundation
import ProxyPilotCore

actor LifecycleGate {
    private var busy = false

    func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        while busy {
            try? await Task.sleep(for: .milliseconds(25))
        }
        busy = true
        defer { busy = false }
        return try await operation()
    }
}

enum MCPStatusPortResolver {
    static func probePort(currentPort: UInt16?, requestedPort: UInt16) -> UInt16 {
        currentPort ?? requestedPort
    }
}

struct MCPStopPlan {
    let text: String
    let nextActions: [NextAction]
}

enum MCPStopResponsePlanner {
    static func plan(configInstalled: Bool) -> MCPStopPlan {
        guard configInstalled else {
            return MCPStopPlan(
                text: "ProxyPilot stopped. Xcode config is not installed.",
                nextActions: []
            )
        }

        return MCPStopPlan(
            text: "ProxyPilot stopped. Xcode config is still installed — call xcode_config_remove if you want to restore direct Anthropic routing.",
            nextActions: [
                NextAction(
                    id: "remove_xcode_config",
                    kind: .mcpTool,
                    tool: "xcode_config_remove",
                    message: "Xcode config can still point at a stopped proxy.",
                    destructive: true
                ),
            ]
        )
    }
}

struct SessionStatsToolPayload: Encodable {
    let requests: Int
    let totalTokens: Int
    let promptTokens: Int
    let completionTokens: Int
    let averageLatencyMs: Int?
    let uptimeSeconds: Int
    let models: [String: Int]

    enum CodingKeys: String, CodingKey {
        case requests
        case totalTokens = "total_tokens"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case averageLatencyMs = "average_latency_ms"
        case uptimeSeconds = "uptime_seconds"
        case models
    }
}

