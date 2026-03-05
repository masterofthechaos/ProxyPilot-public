import Foundation

enum XcodeConfigManager {
    static let xcodeDefaultsDomain = "com.apple.dt.Xcode"
    static let xcodeAgentAPIKeyOverrideKey = "IDEChatClaudeAgentAPIKeyOverride"

    struct Status: Sendable {
        let settingsExists: Bool
        let defaultsOverrideExists: Bool
        let configuredBaseURL: String?

        var isInstalled: Bool {
            settingsExists || defaultsOverrideExists
        }
    }

    struct RemovalResult: Sendable {
        let settingsRemoved: Bool
        let defaultsOverrideRemoved: Bool
        let status: Status
    }

    enum ManagerError: LocalizedError {
        case defaultsFailed(command: String, output: String)

        var errorDescription: String? {
            switch self {
            case .defaultsFailed(let command, let output):
                if output.isEmpty {
                    return "defaults command failed: \(command)"
                }
                return "defaults command failed (\(command)): \(output)"
            }
        }
    }

    static var configDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig", isDirectory: true)
    }

    static var settingsFileURL: URL {
        configDirectoryURL.appendingPathComponent("settings.json")
    }

    static func status() -> Status {
        Status(
            settingsExists: FileManager.default.fileExists(atPath: settingsFileURL.path),
            defaultsOverrideExists: hasDefaultsOverride(),
            configuredBaseURL: readConfiguredBaseURL()
        )
    }

    static func install(port: UInt16) throws -> Status {
        try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)

        let settingsContent = """
        {
          "env": {
            "ANTHROPIC_AUTH_TOKEN": "proxypilot",
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)"
          }
        }
        """

        try settingsContent.write(to: settingsFileURL, atomically: true, encoding: .utf8)
        try writeDefaultsOverride()
        return status()
    }

    static func remove() throws -> RemovalResult {
        let fileManager = FileManager.default
        let settingsExisted = fileManager.fileExists(atPath: settingsFileURL.path)
        if settingsExisted {
            try fileManager.removeItem(at: settingsFileURL)
        }

        let defaultsExisted = hasDefaultsOverride()
        if defaultsExisted {
            try deleteDefaultsOverride()
        }

        return RemovalResult(
            settingsRemoved: settingsExisted,
            defaultsOverrideRemoved: defaultsExisted,
            status: status()
        )
    }

    private static func hasDefaultsOverride() -> Bool {
        let domain = UserDefaults.standard.persistentDomain(forName: xcodeDefaultsDomain)
        return domain?[xcodeAgentAPIKeyOverrideKey] != nil
    }

    private static func readConfiguredBaseURL() -> String? {
        guard let data = try? Data(contentsOf: settingsFileURL),
              let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let env = root["env"] as? [String: Any],
              let baseURL = env["ANTHROPIC_BASE_URL"] as? String else {
            return nil
        }
        return baseURL
    }

    private static func writeDefaultsOverride() throws {
        let command = ["write", xcodeDefaultsDomain, xcodeAgentAPIKeyOverrideKey, " "]
        let result = try runDefaults(arguments: command)
        guard result.status == 0 else {
            throw ManagerError.defaultsFailed(command: command.joined(separator: " "), output: result.stderr)
        }
    }

    private static func deleteDefaultsOverride() throws {
        let command = ["delete", xcodeDefaultsDomain, xcodeAgentAPIKeyOverrideKey]
        let result = try runDefaults(arguments: command)
        guard result.status == 0 else {
            let lower = result.stderr.lowercased()
            if lower.contains("does not exist") || lower.contains("not found") {
                return
            }
            throw ManagerError.defaultsFailed(command: command.joined(separator: " "), output: result.stderr)
        }
    }

    private static func runDefaults(arguments: [String]) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(decoding: stderrData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, stderrText)
    }
}
