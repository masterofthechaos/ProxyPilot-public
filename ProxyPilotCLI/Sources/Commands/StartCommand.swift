#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
import Foundation
import ProxyPilotCore

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the proxy server."
    )

    @Option(name: .shortAndLong, help: "Port to listen on.")
    var port: UInt16 = 4000

    @Option(name: .long, help: "Upstream provider (openai, groq, zai, openrouter, xai, chutes, google, minimax, ollama, lmstudio).")
    var provider: String = "openai"

    @Option(name: .long, help: "Override the upstream API base URL (e.g. http://localhost:11434/v1).")
    var upstreamUrl: String?

    @Option(name: .long, help: "Upstream API key. Falls back to keychain/secrets store if omitted.")
    var key: String?

    @Flag(name: .long, help: "Read a single API key line from stdin.")
    var keyStdin: Bool = false

    @Option(name: .long, help: "Upstream model(s) to route requests to, comma-separated (e.g. 'gpt-4o,claude-3-opus'). First model is preferred for Anthropic translation.")
    var model: String?

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    @Flag(name: .long, help: "Run in background (writes PID file).")
    var daemon: Bool = false

    mutating func run() async throws {
        // Validate provider
        guard let upstreamProvider = UpstreamProvider(rawValue: provider) else {
            OutputFormatter.error(
                code: "E001",
                message: "Unknown provider: \(provider)",
                suggestion: "Valid: \(UpstreamProvider.allCases.map(\.rawValue).joined(separator: ", "))",
                json: json
            )
            throw ExitCode.failure
        }

        // Check if already running
        if let existingPid = PidFile.read() {
            OutputFormatter.error(
                code: "E002",
                message: "ProxyPilot is already running (PID \(existingPid)).",
                suggestion: "Run 'proxypilot stop' first, or 'proxypilot status' to check.",
                json: json
            )
            throw ExitCode.failure
        }

        let inlineKey: String?
        do {
            inlineKey = try CLIProxyRuntime.readInlineKey(key: key, keyStdin: keyStdin)
        } catch {
            OutputFormatter.error(
                code: "E042",
                message: "Failed to read API key input: \(error.localizedDescription)",
                suggestion: "Use --key <value> or provide a single key line with --key-stdin.",
                json: json
            )
            throw ExitCode.failure
        }

        // Daemon: spawn a detached child process that runs the proxy
        if daemon {
            let launchResult: DaemonLaunchResult
            do {
                launchResult = try await CLIProxyRuntime.launchDaemon(
                    port: port,
                    provider: provider,
                    upstreamUrl: upstreamUrl,
                    key: inlineKey,
                    model: model,
                    json: json
                )
            } catch {
                OutputFormatter.error(
                    code: "E012",
                    message: "Daemon process failed to become ready.",
                    suggestion: "Check /tmp/proxypilot_builtin_proxy.log for details.",
                    json: json
                )
                throw ExitCode.failure
            }

            OutputFormatter.success(
                data: [
                    "status": "started",
                    "pid": "\(launchResult.pid)",
                    "port": "\(port)",
                    "provider": upstreamProvider.rawValue,
                    "daemon": "true",
                    "managed": launchResult.managed,
                ],
                humanMessage: "ProxyPilot daemon started (PID \(launchResult.pid), port \(port) -> \(upstreamProvider.title), \(launchResult.managed ? "managed" : "unmanaged"))",
                json: json
            )
            throw ExitCode.success
        }

        // Resolve API key: flag > env > secrets store
        let secrets = SecretsProviderFactory.make()
        let secretKey = upstreamProvider.secretKey
        let apiKey: String? = if let inlineKey {
            inlineKey
        } else if let secretKey {
            ProcessInfo.processInfo.environment[secretKey]
                ?? (try? secrets.get(key: secretKey))
        } else {
            nil
        }

        // Warn if no API key and provider requires one
        let effectiveBaseURL = upstreamUrl ?? upstreamProvider.defaultAPIBaseURL
        if apiKey == nil && !upstreamProvider.isLocal && !isLocalhostURL(effectiveBaseURL) {
            OutputFormatter.error(
                code: "E004",
                message: "No API key found for provider \(upstreamProvider.rawValue).",
                suggestion: "Run 'proxypilot auth set --provider \(upstreamProvider.rawValue)', pass --key, or set \(secretKey ?? "the provider env var").",
                json: json
            )
            throw ExitCode.failure
        }

        let modelList = model?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let allowedModels: Set<String> = modelList.isEmpty ? [] : Set(modelList)
        let config = ProxyConfiguration(
            port: port,
            upstreamProvider: upstreamProvider,
            upstreamAPIBaseURL: upstreamUrl,
            upstreamAPIKey: apiKey,
            allowedModels: allowedModels,
            preferredAnthropicUpstreamModel: modelList.first ?? "",
            googleThoughtSignatureStore: upstreamProvider == .google ? GoogleThoughtSignatureStore() : nil
        )

        let server = NIOProxyServer()
        let actualPort: UInt16
        do {
            actualPort = try await server.start(config: config)
        } catch {
            OutputFormatter.error(
                code: "E003",
                message: "Failed to start server: \(error)",
                suggestion: "Check if port \(port) is already in use.",
                json: json
            )
            throw ExitCode.failure
        }

        // Write PID file so stop/status can find us.
        if !daemon {
            PidFile.write(pid: ProcessInfo.processInfo.processIdentifier)
        }

        let modelDisplay = model ?? "(all)"
        OutputFormatter.success(
            data: [
                "status": "running",
                "port": "\(actualPort)",
                "provider": upstreamProvider.rawValue,
                "model": modelDisplay,
                "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            ],
            humanMessage: "ProxyPilot running on port \(actualPort) -> \(upstreamProvider.title) [\(modelDisplay)] (PID \(ProcessInfo.processInfo.processIdentifier))",
            json: json
        )

        // Park the process until interrupted.
        // Uses withUnsafeContinuation (not withCheckedContinuation) because
        // the continuation intentionally never resumes — the process exits
        // via signal handler. Checked variant emits a runtime warning.
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in
            signal(SIGINT) { _ in
                PidFile.remove()
                _exit(0)
            }
            signal(SIGTERM) { _ in
                PidFile.remove()
                _exit(0)
            }
        }
    }
}
