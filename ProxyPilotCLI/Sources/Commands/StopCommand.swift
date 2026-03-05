import ArgumentParser
import Foundation

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
            let probe = await CLIProxyRuntime.probeProxy(on: port)
            if probe.reachable {
                OutputFormatter.error(
                    code: "E013",
                    message: "ProxyPilot appears to be running on port \(port), but no managed PID file was found.",
                    suggestion: "This instance is running unmanaged. Stop it from the original process/session, or kill it manually before retrying.",
                    json: json
                )
                throw ExitCode.failure
            }

            OutputFormatter.error(
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
                data: ["status": "stopped", "pid": "\(pid)"],
                humanMessage: "ProxyPilot stopped (was PID \(pid)).",
                json: json
            )
        } else {
            // Force kill
            kill(pid, SIGKILL)
            PidFile.remove()
            OutputFormatter.success(
                data: ["status": "killed", "pid": "\(pid)"],
                humanMessage: "ProxyPilot force-killed (PID \(pid)).",
                json: json
            )
        }
    }
}
