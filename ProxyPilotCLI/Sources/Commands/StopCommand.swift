import ArgumentParser
import Foundation
import ProxyPilotCore

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the running proxy server."
    )

    @Option(name: .shortAndLong, help: "Port to probe when PID state is unavailable.")
    var port: UInt16 = 4000

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    mutating func run() async throws {
        guard let pid = PidFile.read() else {
            let discovered = CLIProxyRuntime.discoverStartProcesses(on: port)
            if !discovered.isEmpty {
                let killed = await stopDiscoveredProcesses(discovered)
                guard !killed.isEmpty else {
                    OutputFormatter.error(
                        command: "stop",
                        code: "E011",
                        message: "Found matching ProxyPilot process(es), but failed to stop them.",
                        suggestion: "Try stopping the original process/session, or kill the reported PID manually.",
                        json: json
                    )
                    throw ExitCode.failure
                }

                OutputFormatter.success(
                    command: "stop",
                    data: StopPayload(status: "stopped_discovered", pid: Int(killed[0])),
                    humanMessage: "ProxyPilot stopped by discovered process PID \(killed[0]).",
                    json: json,
                    nextActions: xcodeConfigNextActions()
                )
                throw ExitCode.success
            }

            let probe = await CLIProxyRuntime.probeProxy(on: port)
            if probe.reachable {
                OutputFormatter.error(
                    command: "stop",
                    code: "E013",
                    message: "ProxyPilot appears to be running on port \(port), but no managed PID file was found.",
                    suggestion: "This instance is running unmanaged. Stop it from the original process/session, or kill it manually before retrying.",
                    json: json
                )
                throw ExitCode.failure
            }

            OutputFormatter.error(
                command: "stop",
                code: "E010",
                message: "No running ProxyPilot instance found.",
                suggestion: "Is the server running? Check with 'proxypilot status'.",
                json: json
            )
            throw ExitCode.failure
        }

        // Send SIGTERM
        let result = kill(pid, SIGTERM)
        guard result == 0 else {
            // Process doesn't exist or we lack permission
            PidFile.remove()
            OutputFormatter.error(
                command: "stop",
                code: "E011",
                message: "Failed to send SIGTERM to PID \(pid) (errno \(errno)).",
                suggestion: "The process may have already exited. PID file cleaned up.",
                json: json
            )
            throw ExitCode.failure
        }

        // Wait briefly for the process to exit (up to 3 seconds)
        var stopped = false
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            if !PidFile.isProcessRunning(pid: pid) {
                stopped = true
                break
            }
        }

        PidFile.remove()

        if stopped {
            OutputFormatter.success(
                command: "stop",
                data: StopPayload(status: "stopped", pid: Int(pid)),
                humanMessage: "ProxyPilot stopped (was PID \(pid)).",
                json: json,
                nextActions: xcodeConfigNextActions()
            )
        } else {
            // Force kill
            kill(pid, SIGKILL)
            PidFile.remove()
            OutputFormatter.success(
                command: "stop",
                data: StopPayload(status: "killed", pid: Int(pid)),
                humanMessage: "ProxyPilot force-killed (PID \(pid)).",
                json: json,
                nextActions: xcodeConfigNextActions()
            )
        }
    }

    private func xcodeConfigNextActions() -> [NextAction] {
        #if os(macOS)
        guard XcodeConfigManager.status().isInstalled else { return [] }
        return [
            NextAction(
                id: "remove_xcode_config",
                kind: .cli,
                command: "proxypilot config remove",
                message: "Xcode config can still point at a stopped proxy.",
                destructive: true
            ),
        ]
        #else
        return []
        #endif
    }

    private struct StopPayload: Encodable {
        let status: String
        let pid: Int
    }

    private func stopDiscoveredProcesses(_ processes: [DiscoveredProxyProcess]) async -> [Int32] {
        var stopped: [Int32] = []
        for process in processes {
            guard kill(process.pid, SIGTERM) == 0 else {
                continue
            }

            var exited = false
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                if !PidFile.isProcessRunning(pid: process.pid) {
                    exited = true
                    break
                }
            }

            if !exited {
                kill(process.pid, SIGKILL)
            }
            stopped.append(process.pid)
        }
        return stopped
    }
}
