import ArgumentParser
import Foundation
import ProxyPilotCore

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the proxy server (foreground) or start an MCP server over stdio."
    )

    @Option(name: .shortAndLong, help: "Port to listen on.")
    var port: UInt16 = 4000

    @Option(name: .long, help: "Upstream provider (openai, groq, zai, openrouter, xai, chutes, google, deepseek, mistral, minimax, minimax-cn, ollama, lmstudio).")
    var provider: String = "openai"

    @Option(name: .long, help: "Override the upstream API base URL (e.g. http://localhost:11434/v1).")
    var upstreamUrl: String?

    @Option(name: .long, help: "Upstream API key.")
    var key: String?

    @Flag(name: .long, help: "Run as MCP server over stdio instead of HTTP proxy.")
    var mcp: Bool = false

    @Flag(name: .long, help: "Emit JSON output (ignored in MCP mode).")
    var json: Bool = false

    mutating func run() async throws {
        if mcp {
            try await startMCPMode()
        } else {
            try await startProxyMode()
        }
    }

    // MARK: - Foreground proxy mode

    private func startProxyMode() async throws {
        guard let upstreamProvider = UpstreamProvider(rawValue: provider) else {
            OutputFormatter.error(
                code: "E001",
                message: "Unknown provider: \(provider)",
                suggestion: "Valid: \(UpstreamProvider.allCases.map(\.rawValue).joined(separator: ", "))",
                json: json
            )
            throw ExitCode.failure
        }

        let secrets = SecretsProviderFactory.make()
        let secretKey = upstreamProvider.secretKey
        let apiKey: String? = if let key {
            key
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

        let config = ProxyConfiguration(
            port: port,
            upstreamProvider: upstreamProvider,
            upstreamAPIBaseURL: upstreamUrl,
            upstreamAPIKey: apiKey,
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

        PidFile.write(pid: ProcessInfo.processInfo.processIdentifier)

        OutputFormatter.success(
            data: [
                "status": "running",
                "port": "\(actualPort)",
                "provider": upstreamProvider.rawValue,
            ],
            humanMessage: "ProxyPilot serving on port \(actualPort) -> \(upstreamProvider.title)",
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

    // MARK: - MCP stdio mode

    private func startMCPMode() async throws {
        try await MCPServerSetup.run(port: port, provider: provider, key: key, upstreamURL: upstreamUrl)
    }
}
