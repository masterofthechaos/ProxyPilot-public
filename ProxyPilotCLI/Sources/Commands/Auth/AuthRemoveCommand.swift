#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
import Foundation
import ProxyPilotCore

struct AuthRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Delete a stored upstream API key."
    )

    @Option(name: .long, help: "Upstream provider to remove key for.")
    var provider: String

    @Flag(name: .long, help: "Skip confirmation prompt.")
    var yes: Bool = false

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    mutating func run() async throws {
        guard let upstreamProvider = UpstreamProvider(rawValue: provider) else {
            OutputFormatter.error(
                code: "E001",
                message: "Unknown provider: \(provider)",
                suggestion: "Valid: \(UpstreamProvider.allCases.map(\.rawValue).joined(separator: ", "))",
                json: json
            )
            throw ExitCode.failure
        }

        guard upstreamProvider.requiresAPIKey else {
            OutputFormatter.error(
                code: "E041",
                message: "Provider \(upstreamProvider.rawValue) does not require an API key.",
                suggestion: "Local providers (ollama, lmstudio) do not need auth setup.",
                json: json
            )
            throw ExitCode.failure
        }

        guard let secretKeyName = upstreamProvider.secretKey else {
            OutputFormatter.error(
                code: "E041",
                message: "Provider \(upstreamProvider.rawValue) does not require an API key.",
                suggestion: "Choose a cloud provider (openai, groq, zai, openrouter, xai, chutes, google, deepseek, mistral, minimax).",
                json: json
            )
            throw ExitCode.failure
        }

        if !yes && !json {
            if isatty(STDIN_FILENO) != 1 {
                OutputFormatter.error(
                    code: "E042",
                    message: "Confirmation prompt requires a TTY.",
                    suggestion: "Re-run with --yes for non-interactive usage.",
                    json: json
                )
                throw ExitCode.failure
            }

            print("Remove stored API key for \(upstreamProvider.rawValue)? [y/N]: ", terminator: "")
            fflush(stdout)
            let response = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if response != "y" && response != "yes" {
                OutputFormatter.success(
                    data: ["status": "cancelled", "provider": upstreamProvider.rawValue],
                    humanMessage: "Cancelled key removal for \(upstreamProvider.rawValue).",
                    json: json
                )
                return
            }
        }

        let secrets = SecretsProviderFactory.make()

        do {
            try secrets.delete(key: secretKeyName)
        } catch {
            OutputFormatter.error(
                code: "E045",
                message: "Failed to delete API key for provider \(upstreamProvider.rawValue): \(error.localizedDescription)",
                suggestion: "Verify secrets store permissions and retry.",
                json: json
            )
            throw ExitCode.failure
        }

        let backend = authBackendInfo(for: secrets)

        var data: [String: Any] = [
            "status": "removed",
            "provider": upstreamProvider.rawValue,
            "backend": backend.label,
        ]
        if let filePath = backend.filePath {
            data["path"] = filePath
            OutputFormatter.success(
                data: data,
                humanMessage: "Removed API key for \(upstreamProvider.rawValue) from file backend at \(filePath).",
                json: json
            )
        } else {
            OutputFormatter.success(
                data: data,
                humanMessage: "Removed API key for \(upstreamProvider.rawValue) from \(backend.label) backend.",
                json: json
            )
        }
    }
}
