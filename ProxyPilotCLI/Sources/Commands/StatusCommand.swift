import ArgumentParser
import Foundation

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Check the proxy server status."
    )

    @Option(name: .shortAndLong, help: "Port to probe for health check.")
    var port: UInt16 = 4000

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    mutating func run() async throws {
        let probe = await CLIProxyRuntime.probeProxy(on: port)

        guard let pid = PidFile.read() else {
            if probe.reachable {
                var data: [String: Any] = [
                    "status": "running_unmanaged",
                    "port": "\(port)",
                    "managed": false,
                ]
                if let modelCount = probe.modelCount {
                    data["models"] = "\(modelCount)"
                }
                OutputFormatter.success(
                    data: data,
                    humanMessage: "ProxyPilot is responding on port \(port), but no PID file was found. The instance is running unmanaged.",
                    json: json
                )
                return
            }

            OutputFormatter.success(
                data: ["status": "stopped"],
                humanMessage: "ProxyPilot is not running.",
                json: json
            )
            return
        }

        var statusData: [String: Any] = [
            "status": "running",
            "pid": "\(pid)",
            "port": "\(port)",
            "managed": true,
        ]
        var humanParts = ["ProxyPilot is running (PID \(pid), port \(port))"]

        if let count = probe.modelCount {
            statusData["models"] = "\(count)"
            humanParts.append("  Models available: \(count)")
        }

        OutputFormatter.success(
            data: statusData,
            humanMessage: humanParts.joined(separator: "\n"),
            json: json
        )
    }
}
