import ArgumentParser
import Foundation
import ProxyPilotCore

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
        let message: String
        if status.isInstalled {
            let baseURL = status.configuredBaseURL ?? "(unknown)"
            message = "Xcode config is installed.\nsettings.json: \(status.settingsExists ? "present" : "missing")\ndefaults override: \(status.defaultsOverrideExists ? "present" : "missing")\nANTHROPIC_BASE_URL: \(baseURL)"
        } else {
            message = "Xcode config is not installed."
        }

        OutputFormatter.success(
            command: "config status",
            data: ConfigStatusPayload(
                status: status.isInstalled ? "installed" : "not-installed",
                installed: status.isInstalled,
                settingsPath: XcodeConfigManager.settingsFileURL.path,
                settingsFilePresent: status.settingsExists,
                defaultsOverridePresent: status.defaultsOverrideExists,
                baseURL: status.configuredBaseURL
            ),
            humanMessage: message,
            json: json
        )
        #else
        OutputFormatter.error(
            command: "config status",
            code: "E034",
            message: "'proxypilot config status' is only supported on macOS.",
            suggestion: nil,
            json: json
        )
        throw ExitCode.failure
        #endif
    }

    private struct ConfigStatusPayload: Encodable {
        let status: String
        let installed: Bool
        let settingsPath: String
        let settingsFilePresent: Bool
        let defaultsOverridePresent: Bool
        let baseURL: String?

        enum CodingKeys: String, CodingKey {
            case status
            case installed
            case settingsPath = "settings_path"
            case settingsFilePresent = "settings_file_present"
            case defaultsOverridePresent = "defaults_override_present"
            case baseURL = "base_url"
        }
    }
}
