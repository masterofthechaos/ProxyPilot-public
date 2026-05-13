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

    @Option(name: .long, help: "Upstream provider (\(UpstreamProvider.cliOptionsDescription)).")
    var provider: String

    @Flag(name: .long, help: "Skip confirmation prompt.")
    var yes: Bool = false

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    mutating func run() async throws {
        guard let upstreamProvider = UpstreamProvider(rawValue: provider) else {
            OutputFormatter.error(
                command: "auth remove",
                code: "E001",
                message: "Unknown provider: \(provider)",
                suggestion: "Valid: \(UpstreamProvider.allCases.map(\.rawValue).joined(separator: ", "))",
                json: json
            )
            throw ExitCode.failure
        }

        guard upstreamProvider.requiresAPIKey else {
            OutputFormatter.error(
                command: "auth remove",
                code: "E041",
                message: "Provider \(upstreamProvider.rawValue) does not require an API key.",
                suggestion: "Local/helper providers (github-copilot, ollama, lmstudio) do not need auth setup.",
                json: json
            )
            throw ExitCode.failure
        }

        guard let secretKeyName = upstreamProvider.secretKey else {
            OutputFormatter.error(
                command: "auth remove",
                code: "E041",
                message: "Provider \(upstreamProvider.rawValue) does not require an API key.",
                suggestion: "Choose a cloud provider (openai, groq, zai, openrouter, xai, chutes, google, deepseek, mistral, minimax, minimax-cn).",
                json: json
            )
            throw ExitCode.failure
        }

        if !yes && !json {
            if isatty(STDIN_FILENO) != 1 {
                OutputFormatter.error(
                    command: "auth remove",
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
                    command: "auth remove",
                    data: AuthRemovePayload(status: "cancelled", provider: upstreamProvider.rawValue, backend: nil, path: nil),
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
                command: "auth remove",
                code: "E045",
                message: "Failed to delete API key for provider \(upstreamProvider.rawValue): \(error.localizedDescription)",
                suggestion: "Verify secrets store permissions and retry.",
                json: json
            )
            throw ExitCode.failure
        }

        let backend = authBackendInfo(for: secrets)

        let payload = AuthRemovePayload(
            status: "removed",
            provider: upstreamProvider.rawValue,
            backend: backend.label,
            path: backend.filePath
        )
        let humanMessage = backend.filePath.map {
            "Removed API key for \(upstreamProvider.rawValue) from file backend at \($0)."
        } ?? "Removed API key for \(upstreamProvider.rawValue) from \(backend.label) backend."
        OutputFormatter.success(command: "auth remove", data: payload, humanMessage: humanMessage, json: json)
    }
}

private struct AuthRemovePayload: Encodable {
    let status: String
    let provider: String
    let backend: String?
    let path: String?
}
