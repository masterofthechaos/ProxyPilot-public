import ArgumentParser
import Foundation

struct ConfigStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether ProxyPilot Xcode Agent config is currently installed."
    )

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    mutating func run() async throws {
        #if os(macOS)
        let status = XcodeConfigManager.status()
        var data: [String: Any] = [
            "status": status.isInstalled ? "installed" : "not-installed",
            "installed": status.isInstalled,
            "settings_path": XcodeConfigManager.settingsFileURL.path,
            "settings_file_present": status.settingsExists,
            "defaults_override_present": status.defaultsOverrideExists,
        ]
        if let baseURL = status.configuredBaseURL {
            data["base_url"] = baseURL
        }

        let message: String
        if status.isInstalled {
            let baseURL = status.configuredBaseURL ?? "(unknown)"
            message = "Xcode config is installed.\nsettings.json: \(status.settingsExists ? "present" : "missing")\ndefaults override: \(status.defaultsOverrideExists ? "present" : "missing")\nANTHROPIC_BASE_URL: \(baseURL)"
        } else {
            message = "Xcode config is not installed."
        }

        OutputFormatter.success(
            data: data,
            humanMessage: message,
            json: json
        )
        #else
        OutputFormatter.error(
            code: "E034",
            message: "'proxypilot config status' is only supported on macOS.",
            suggestion: nil,
            json: json
        )
        throw ExitCode.failure
        #endif
    }
}
