import ArgumentParser
import Foundation
import ProxyPilotCore

struct ConfigRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove ProxyPilot Xcode Agent config and restore default Xcode routing."
    )

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    mutating func run() async throws {
        #if os(macOS)
        do {
            let removal = try XcodeConfigManager.remove()
            let changed = removal.settingsRemoved || removal.defaultsOverrideRemoved
            let statusValue = changed ? "removed" : "not-installed"
            let message = changed
                ? "Xcode config removed. If Xcode is open, quit and relaunch Xcode for changes to take effect."
                : "Xcode config was not installed. No changes made."

            OutputFormatter.success(
                command: "config remove",
                data: ConfigRemovePayload(
                    status: statusValue,
                    installed: removal.status.isInstalled,
                    settingsRemoved: removal.settingsRemoved,
                    defaultsOverrideRemoved: removal.defaultsOverrideRemoved,
                    settingsPath: XcodeConfigManager.settingsFileURL.path
                ),
                humanMessage: message,
                json: json
            )
        } catch {
            OutputFormatter.error(
                command: "config remove",
                code: "E032",
                message: "Failed to remove Xcode config: \(error.localizedDescription)",
                suggestion: "Check file permissions under ~/Library/Developer/Xcode/CodingAssistant.",
                json: json
            )
            throw ExitCode.failure
        }
        #else
        OutputFormatter.error(
            command: "config remove",
            code: "E034",
            message: "'proxypilot config remove' is only supported on macOS.",
            suggestion: nil,
            json: json
        )
        throw ExitCode.failure
        #endif
    }

    private struct ConfigRemovePayload: Encodable {
        let status: String
        let installed: Bool
        let settingsRemoved: Bool
        let defaultsOverrideRemoved: Bool
        let settingsPath: String

        enum CodingKeys: String, CodingKey {
            case status
            case installed
            case settingsRemoved = "settings_removed"
            case defaultsOverrideRemoved = "defaults_override_removed"
            case settingsPath = "settings_path"
        }
    }
}
