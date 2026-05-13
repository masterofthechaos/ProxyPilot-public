import Foundation
import ProxyPilotCore

enum AgentPreflightService {
    static func report(
        port: UInt16,
        provider rawProvider: String,
        model: String?
    ) async -> (AgentPreflightPayload, [NextAction]) {
        let upstream = UpstreamProvider(rawValue: rawProvider) ?? ProxyPilotDefaults.defaultXcodeProvider
        let secrets = SecretsProviderFactory.make()
        let stored = upstream.secretKey.flatMap { try? secrets.exists(key: $0) } ?? false
        let authRequired = upstream.requiresAPIKey
        let probe = await CLIProxyRuntime.probeProxy(on: port)
        let config = XcodeConfigManager.status()

        var blockers: [AgentError] = []
        var actions: [NextAction] = []

        if authRequired && !stored {
            blockers.append(AgentError(
                code: "E004",
                message: "No API key found for provider \(upstream.rawValue).",
                suggestion: "Store a key before starting ProxyPilot for this provider.",
                recoverable: true
            ))
            actions.append(NextAction(
                id: "auth_set_\(upstream.rawValue)",
                kind: .mcpTool,
                tool: "auth_set",
                arguments: [
                    "provider": .string(upstream.rawValue),
                    "allow_secret_write": .bool(true),
                ],
                destructive: false
            ))
        }

        if !probe.reachable {
            actions.append(NextAction(
                id: "start_proxy",
                kind: .mcpTool,
                tool: "proxy_start",
                arguments: [
                    "provider": .string(upstream.rawValue),
                    "port": .int(Int(port)),
                ],
                destructive: false
            ))
        }

        if !config.isInstalled {
            actions.append(NextAction(
                id: "install_xcode_config",
                kind: .mcpTool,
                tool: "xcode_config_install",
                arguments: ["port": .int(Int(port))],
                destructive: false
            ))
        }

        let payload = AgentPreflightPayload(
            ready: blockers.isEmpty && probe.reachable && config.isInstalled,
            provider: upstream.rawValue,
            model: model ?? upstream.defaultAgentModel,
            auth: .init(required: authRequired, stored: stored, provider: upstream.rawValue),
            proxy: .init(
                running: probe.reachable,
                port: Int(port),
                effectiveStatus: probe.reachable ? "running" : "stopped",
                errorMessage: probe.errorMessage
            ),
            xcodeConfig: .init(
                installed: config.isInstalled,
                baseURL: config.configuredBaseURL,
                requiresXcodeRestart: config.isInstalled
            ),
            blockers: blockers
        )

        return (payload, actions)
    }
}
