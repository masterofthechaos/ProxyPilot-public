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

    @Option(name: .long, help: "Upstream provider (\(UpstreamProvider.cliOptionsDescription)).")
    var provider: String

    @Option(name: .long, help: "API key value (non-interactive). Prefer --stdin because --key can be retained in shell history.")
    var key: String?

    @Flag(name: .long, help: "Read a single API key line from stdin. Recommended for secrets in scripts.")
    var stdin: Bool = false

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    mutating func run() async throws {
        guard let upstreamProvider = UpstreamProvider(rawValue: provider) else {
            OutputFormatter.error(
                command: "auth set",
                code: "E001",
                message: "Unknown provider: \(provider)",
                suggestion: "Valid: \(UpstreamProvider.allCases.map(\.rawValue).joined(separator: ", "))",
                json: json
            )
            throw ExitCode.failure
        }

        guard upstreamProvider.requiresAPIKey else {
            OutputFormatter.error(
                command: "auth set",
                code: "E041",
                message: "Provider \(upstreamProvider.rawValue) does not require an API key.",
                suggestion: "Local/helper providers (github-copilot, ollama, lmstudio) do not need auth setup.",
                json: json
            )
            throw ExitCode.failure
        }

        guard let secretKeyName = upstreamProvider.secretKey else {
            OutputFormatter.error(
                command: "auth set",
                code: "E041",
                message: "Provider \(upstreamProvider.rawValue) does not require an API key.",
                suggestion: "Choose a cloud provider (openai, groq, zai, openrouter, xai, chutes, google, deepseek, mistral, minimax, minimax-cn, qwen).",
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
                    command: "auth set",
                    code: "E042",
                    message: "Failed to read API key from terminal prompt: \(error.localizedDescription)",
                    suggestion: "Use --stdin for non-interactive secrets, or --key only when shell history retention is acceptable.",
                    json: json
                )
                throw ExitCode.failure
            }
        } else {
            OutputFormatter.error(
                command: "auth set",
                code: "E042",
                message: "No API key input provided and stdin is not a TTY.",
                suggestion: "Use --stdin for non-interactive secrets, or --key only when shell history retention is acceptable.",
                json: json
            )
            throw ExitCode.failure
        }

        let trimmed = resolvedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            OutputFormatter.error(
                command: "auth set",
                code: "E040",
                message: "API key is empty or whitespace-only.",
                suggestion: "Pass a valid key with --stdin, or re-enter it interactively.",
                json: json
            )
            throw ExitCode.failure
        }

        if case let .failure(code, message) = APIKeyValidator.validate(trimmed, for: upstreamProvider) {
            OutputFormatter.error(
                command: "auth set",
                code: code,
                message: message,
                suggestion: "Re-enter the full Z.ai API key.",
                json: json
            )
            throw ExitCode.failure
        }

        let secrets = SecretsProviderFactory.make()

        do {
            try secrets.set(key: secretKeyName, value: trimmed)
        } catch {
            OutputFormatter.error(
                command: "auth set",
                code: "E043",
                message: "Failed to write API key for provider \(upstreamProvider.rawValue): \(error.localizedDescription)",
                suggestion: "Verify secrets store permissions and retry.",
                json: json
            )
            throw ExitCode.failure
        }

        let backend = authBackendInfo(for: secrets)

        let payload = AuthMutationPayload(
            status: "stored",
            provider: upstreamProvider.rawValue,
            backend: backend.label,
            path: backend.filePath
        )
        let humanMessage = backend.filePath.map {
            "Stored API key for \(upstreamProvider.rawValue) in file backend at \($0)."
        } ?? "Stored API key for \(upstreamProvider.rawValue) in \(backend.label) backend."
        OutputFormatter.success(command: "auth set", data: payload, humanMessage: humanMessage, json: json)
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

private struct AuthMutationPayload: Encodable {
    let status: String
    let provider: String
    let backend: String
    let path: String?
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
