import ArgumentParser
import Foundation
import ProxyPilotCore

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Check the proxy server status."
    )

    @Option(name: .shortAndLong, help: "Port to probe for health check.")
    var port: UInt16 = 4000

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    @Flag(name: .long, help: "Exit non-zero unless the proxy is reachable.")
    var requireRunning: Bool = false

    mutating func run() async throws {
        let probe = await CLIProxyRuntime.probeProxy(on: port)
        let managedPid = PidFile.read()
        let managed = managedPid != nil
        let discovered = managed ? [] : CLIProxyRuntime.discoverStartProcesses(on: port)
        let discoveredPid = discovered.first?.pid
        let effectiveStatus: String
        if managed && probe.reachable {
            effectiveStatus = "running"
        } else if managed {
            effectiveStatus = "running_unhealthy"
        } else if !discovered.isEmpty && probe.reachable {
            effectiveStatus = "running_discovered"
        } else if !discovered.isEmpty {
            effectiveStatus = "running_unhealthy_discovered"
        } else if probe.reachable {
            effectiveStatus = "running_unmanaged"
        } else {
            effectiveStatus = "stopped"
        }
        let owner: String
        if managed {
            owner = "cli"
        } else if !discovered.isEmpty {
            owner = "cli_discovered"
        } else if probe.reachable {
            owner = "external_or_gui"
        } else {
            owner = "none"
        }

        if requireRunning && !probe.reachable {
            OutputFormatter.error(
                command: "status",
                code: "E020_PROXY_STOPPED",
                message: "ProxyPilot is not reachable on 127.0.0.1:\(port).",
                suggestion: "Run 'proxypilot start --port \(port)' or 'proxypilot setup xcode'.",
                json: json,
                nextActions: [
                    NextAction(
                        id: "start_proxy",
                        kind: .cli,
                        command: "proxypilot start --port \(port)",
                        destructive: false
                    ),
                ]
            )
            throw ExitCode(3)
        }

        let payload = StatusPayload(
            running: effectiveStatus != "stopped",
            process: .init(managed: managed || !discovered.isEmpty, pid: (managedPid ?? discoveredPid).map(Int.init), owner: owner),
            http: .init(reachable: probe.reachable, port: Int(port), modelsCount: probe.modelCount, errorMessage: probe.errorMessage),
            effectiveStatus: effectiveStatus
        )

        let humanMessage: String
        switch effectiveStatus {
        case "running":
            let pidText = managedPid.map { "PID \($0), " } ?? ""
            let modelText = probe.modelCount.map { "\n  Models available: \($0)" } ?? ""
            humanMessage = "ProxyPilot is running (\(pidText)port \(port))\(modelText)"
        case "running_unhealthy":
            let errorText = probe.errorMessage.map { "\n  Probe error: \($0)" } ?? ""
            humanMessage = "ProxyPilot has a managed PID file but did not respond on port \(port).\(errorText)"
        case "running_unmanaged":
            let modelText = probe.modelCount.map { " (\($0) models)" } ?? ""
            humanMessage = "ProxyPilot is responding on port \(port)\(modelText), but no CLI PID file was found. Owner: external_or_gui."
        case "running_discovered":
            let pidText = discoveredPid.map { "PID \($0), " } ?? ""
            let modelText = probe.modelCount.map { "\n  Models available: \($0)" } ?? ""
            humanMessage = "ProxyPilot is running (\(pidText)port \(port)), discovered from the process list without PID file.\(modelText)"
        case "running_unhealthy_discovered":
            let pidText = discoveredPid.map { "PID \($0), " } ?? ""
            let errorText = probe.errorMessage.map { "\n  Probe error: \($0)" } ?? ""
            humanMessage = "ProxyPilot process was discovered (\(pidText)port \(port)) but /v1/models did not respond.\(errorText)"
        default:
            let errorText = probe.errorMessage.map { "\n  Probe error: \($0)" } ?? ""
            humanMessage = "ProxyPilot is not running.\(errorText)"
        }

        OutputFormatter.success(
            command: "status",
            data: payload,
            humanMessage: humanMessage,
            json: json
        )
    }
}
