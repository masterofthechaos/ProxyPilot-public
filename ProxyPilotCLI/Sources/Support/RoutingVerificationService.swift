import Foundation
import ProxyPilotCore

enum RoutingVerificationService {
    static func verify(port: UInt16) async -> (RoutingVerificationPayload, [NextAction]) {
        let probe = await CLIProxyRuntime.probeProxy(on: port)
        let config = XcodeConfigManager.status()
        let configuredPortMatches = config.configuredBaseURL == "http://127.0.0.1:\(port)"

        var actions: [NextAction] = []
        if !probe.reachable {
            actions.append(NextAction(
                id: "start_proxy",
                kind: .mcpTool,
                tool: "proxy_start",
                arguments: ["port": .int(Int(port))],
                destructive: false
            ))
        }
        if !config.isInstalled || !configuredPortMatches {
            actions.append(NextAction(
                id: "install_xcode_config",
                kind: .mcpTool,
                tool: "xcode_config_install",
                arguments: ["port": .int(Int(port))],
                destructive: false
            ))
        }

        return (
            RoutingVerificationPayload(
                localModelsReachable: probe.reachable,
                modelsCount: probe.modelCount,
                localModelsError: probe.errorMessage,
                xcodeConfigInstalled: config.isInstalled,
                configuredBaseURL: config.configuredBaseURL,
                portMatchesConfig: configuredPortMatches,
                upstreamProbePerformed: false
            ),
            actions
        )
    }
}
