import ArgumentParser
import Foundation
import ProxyPilotCore

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the proxy server (foreground) or start an MCP server over stdio."
    )

    @Option(name: .shortAndLong, help: "Port to listen on.")
    var port: UInt16 = ProxyPilotDefaults.defaultPort

    @Option(name: .long, help: "Upstream provider (\(UpstreamProvider.cliOptionsDescription)). Omit to choose from configured provider keys.")
    var provider: String?

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
        let secrets = SecretsProviderFactory.make()
        let resolvedCredential = try resolveProviderCredential(secrets: secrets)
        let upstreamProvider = resolvedCredential.provider

        let sessionID = UUID().uuidString
        let sessionStats = SessionStats(sessionReportURL: SessionReportStore.defaultURL, sessionSource: "cli", sessionID: sessionID)
        await sessionStats.reset(clearReportStore: false)
        let config = ProxyConfiguration(
            port: port,
            upstreamProvider: upstreamProvider,
            upstreamAPIBaseURL: upstreamUrl,
            upstreamAPIKey: resolvedCredential.apiKey,
            sessionStats: sessionStats,
            googleThoughtSignatureStore: upstreamProvider == .google ? GoogleThoughtSignatureStore() : nil,
            inputOutputLogger: try? InputOutputLoggingRecorder.productionIfConfigured(source: "cli", sessionID: sessionID)
        )

        let server = NIOProxyServer()
        let actualPort: UInt16
        do {
            actualPort = try await server.start(config: config)
        } catch {
            OutputFormatter.error(
                command: "serve",
                code: "E003",
                message: "Failed to start server: \(error)",
                suggestion: CLIProxyRuntime.bindFailureSuggestion(port: port, error: error),
                json: json
            )
            throw ExitCode.failure
        }

        PidFile.write(pid: ProcessInfo.processInfo.processIdentifier)

        OutputFormatter.success(
            command: "serve",
            data: ServePayload(
                status: "running",
                port: Int(actualPort),
                provider: upstreamProvider.rawValue
            ),
            humanMessage: "ProxyPilot serving on port \(actualPort) -> \(upstreamProvider.title)\(resolvedCredential.selectedFromStoredCredentials ? " (selected from stored provider keys)" : "")",
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

    private func resolveProviderCredential(secrets: any SecretsProvider) throws -> ResolvedProviderCredential {
        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: provider,
            explicitKey: key,
            upstreamURL: upstreamUrl,
            secrets: secrets
        )

        switch resolution {
        case .resolved(let credential):
            return credential
        case .unknownProvider(let raw):
            OutputFormatter.error(
                command: "serve",
                code: "E001",
                message: "Unknown provider: \(raw)",
                suggestion: "Valid: \(UpstreamProvider.allCases.map(\.rawValue).joined(separator: ", "))",
                json: json
            )
        case .missingAPIKey(let missingProvider, let secretKeyName):
            OutputFormatter.error(
                command: "serve",
                code: "E004",
                message: "No API key found for provider \(missingProvider.rawValue).",
                suggestion: "Run 'proxypilot auth set --provider \(missingProvider.rawValue)', pass --key, or set \(secretKeyName ?? "the provider env var").",
                json: json
            )
        case .selectionRequired(let prompt):
            OutputFormatter.error(
                command: "serve",
                code: "E047",
                message: prompt.availableProviders.isEmpty
                    ? "No configured provider API keys were found."
                    : "Choose which configured provider ProxyPilot should use.",
                suggestion: prompt.humanList,
                json: json,
                nextActions: selectionNextActions(prompt: prompt)
            )
        }

        throw ExitCode.failure
    }

    private func selectionNextActions(prompt: ProviderSelectionPrompt) -> [NextAction] {
        var actions = prompt.availableProviders.map { choice in
            NextAction(
                id: "serve_with_\(choice.provider)",
                kind: .cli,
                command: "proxypilot serve --provider \(choice.provider)",
                destructive: false
            )
        }
        actions.append(NextAction(
            id: "auth_set",
            kind: .cli,
            command: "proxypilot auth set --provider <provider>",
            destructive: false
        ))
        return actions
    }

    // MARK: - MCP stdio mode

    private func startMCPMode() async throws {
        try await MCPServerSetup.run(port: port, provider: provider, key: key, upstreamURL: upstreamUrl)
    }

    private struct ServePayload: Encodable {
        let status: String
        let port: Int
        let provider: String
    }
}
