import ArgumentParser
import Foundation

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
                data: [
                    "status": statusValue,
                    "installed": removal.status.isInstalled,
                    "settings_removed": removal.settingsRemoved,
                    "defaults_override_removed": removal.defaultsOverrideRemoved,
                    "settings_path": XcodeConfigManager.settingsFileURL.path,
                ],
                humanMessage: message,
                json: json
            )
        } catch {
            OutputFormatter.error(
                code: "E032",
                message: "Failed to remove Xcode config: \(error.localizedDescription)",
                suggestion: "Check file permissions under ~/Library/Developer/Xcode/CodingAssistant.",
                json: json
            )
            throw ExitCode.failure
        }
        #else
        OutputFormatter.error(
            code: "E034",
            message: "'proxypilot config remove' is only supported on macOS.",
            suggestion: nil,
            json: json
        )
        throw ExitCode.failure
        #endif
    }
}
