import ArgumentParser
import Foundation

struct ConfigInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install Xcode Agent config so Xcode routes through ProxyPilot."
    )

    @Option(name: .shortAndLong, help: "Proxy port for ANTHROPIC_BASE_URL.")
    var port: UInt16 = 4000

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    mutating func run() async throws {
        #if os(macOS)
        guard (1024...65535).contains(Int(port)) else {
            OutputFormatter.error(
                code: "E030",
                message: "Invalid port \(port) for Xcode config.",
                suggestion: "Use a port in the range 1024-65535.",
                json: json
            )
            throw ExitCode.failure
        }

        do {
            let status = try XcodeConfigManager.install(port: port)
            let proxyReachable = await isProxyReachable(on: port)
            let warningSuffix = proxyReachable
                ? ""
                : "\nWARNING: No proxy responded on 127.0.0.1:\(port). Start one with 'proxypilot start --port \(port)'."

            OutputFormatter.success(
                data: [
                    "status": "installed",
                    "installed": status.isInstalled,
                    "port": "\(port)",
                    "settings_path": XcodeConfigManager.settingsFileURL.path,
                    "settings_file_present": status.settingsExists,
                    "defaults_override_present": status.defaultsOverrideExists,
                    "proxy_reachable": proxyReachable,
                ],
                humanMessage: "Xcode config installed. Routing to 127.0.0.1:\(port).\(warningSuffix)\nIf Xcode is open, quit and relaunch Xcode for changes to take effect.",
                json: json
            )
        } catch {
            OutputFormatter.error(
                code: "E031",
                message: "Failed to install Xcode config: \(error.localizedDescription)",
                suggestion: "Check that ~/Library/Developer/Xcode/CodingAssistant is writable.",
                json: json
            )
            throw ExitCode.failure
        }
        #else
        OutputFormatter.error(
            code: "E034",
            message: "'proxypilot config install' is only supported on macOS.",
            suggestion: nil,
            json: json
        )
        throw ExitCode.failure
        #endif
    }

    #if os(macOS)
    private func isProxyReachable(on port: UInt16) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...499).contains(http.statusCode)
        } catch {
            return false
        }
    }
    #endif
}
