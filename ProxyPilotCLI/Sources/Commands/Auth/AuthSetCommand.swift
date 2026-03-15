#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
import Foundation
import ProxyPilotCore

struct AuthSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Store an upstream API key."
    )

    @Option(name: .long, help: "Upstream provider (openai, groq, zai, openrouter, xai, chutes, google, minimax).")
    var provider: String

    @Option(name: .long, help: "API key value (non-interactive).")
    var key: String?

    @Flag(name: .long, help: "Read a single API key line from stdin.")
    var stdin: Bool = false

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
                suggestion: "Choose a cloud provider (openai, groq, zai, openrouter, xai, chutes, google, minimax).",
                json: json
            )
            throw ExitCode.failure
        }

        let resolvedInput: String
        if let key {
            resolvedInput = key
        } else if stdin {
            resolvedInput = readLine(strippingNewline: true) ?? ""
        } else if isatty(STDIN_FILENO) == 1 {
            do {
                resolvedInput = try promptForKey(provider: upstreamProvider.rawValue)
            } catch {
                OutputFormatter.error(
                    code: "E042",
                    message: "Failed to read API key from terminal prompt: \(error.localizedDescription)",
                    suggestion: "Use --key or --stdin for non-interactive input.",
                    json: json
                )
                throw ExitCode.failure
            }
        } else {
            OutputFormatter.error(
                code: "E042",
                message: "No API key input provided and stdin is not a TTY.",
                suggestion: "Use --key <value> or --stdin.",
                json: json
            )
            throw ExitCode.failure
        }

        let trimmed = resolvedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            OutputFormatter.error(
                code: "E040",
                message: "API key is empty or whitespace-only.",
                suggestion: "Pass a valid key with --key or re-enter it.",
                json: json
            )
            throw ExitCode.failure
        }

        let secrets = SecretsProviderFactory.make()

        do {
            try secrets.set(key: secretKeyName, value: trimmed)
        } catch {
            OutputFormatter.error(
                code: "E043",
                message: "Failed to write API key for provider \(upstreamProvider.rawValue): \(error.localizedDescription)",
                suggestion: "Verify secrets store permissions and retry.",
                json: json
            )
            throw ExitCode.failure
        }

        let backend = authBackendInfo(for: secrets)

        var data: [String: Any] = [
            "status": "stored",
            "provider": upstreamProvider.rawValue,
            "backend": backend.label,
        ]
        if let filePath = backend.filePath {
            data["path"] = filePath
            OutputFormatter.success(
                data: data,
                humanMessage: "Stored API key for \(upstreamProvider.rawValue) in file backend at \(filePath).",
                json: json
            )
        } else {
            OutputFormatter.success(
                data: data,
                humanMessage: "Stored API key for \(upstreamProvider.rawValue) in \(backend.label) backend.",
                json: json
            )
        }
    }

    private func promptForKey(provider: String) throws -> String {
        let prompt = "Enter API key for \(provider): "

        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: 4096)
        let flags = Int32(RPP_REQUIRE_TTY)
        let pointer = buffer.withUnsafeMutableBufferPointer { rawBuffer -> UnsafeMutablePointer<CChar>? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            return readpassphrase(prompt, baseAddress, rawBuffer.count, flags)
        }
        defer {
            buffer.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                memset(baseAddress, 0, rawBuffer.count)
            }
        }
        guard let pointer else {
            throw AuthPromptError.promptFailed
        }
        return String(cString: pointer)
        #elseif canImport(Glibc)
        guard let pointer = getpass(prompt) else {
            throw AuthPromptError.promptFailed
        }
        let value = String(cString: pointer)
        memset(pointer, 0, strlen(pointer))
        return value
        #else
        throw AuthPromptError.promptUnsupported
        #endif
    }
}

private enum AuthPromptError: LocalizedError {
    case promptFailed
    case promptUnsupported

    var errorDescription: String? {
        switch self {
        case .promptFailed:
            return "Prompt input was unavailable."
        case .promptUnsupported:
            return "Secure interactive prompt is unsupported on this platform."
        }
    }
}
