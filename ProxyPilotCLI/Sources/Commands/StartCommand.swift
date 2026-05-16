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
    var port: UInt16 = ProxyPilotDefaults.defaultPort

    @Option(name: .long, help: "Upstream provider (\(UpstreamProvider.cliOptionsDescription)). Omit to choose from configured provider keys.")
    var provider: String?

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
        // Check if already running
        if let existingPid = PidFile.read() {
            OutputFormatter.error(
                command: "start",
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
                command: "start",
                code: "E042",
                message: "Failed to read API key input: \(error.localizedDescription)",
                suggestion: "Use --key <value> or provide a single key line with --key-stdin.",
                json: json
            )
            throw ExitCode.failure
        }

        let secrets = SecretsProviderFactory.make()
        let resolvedCredential = try resolveProviderCredential(inlineKey: inlineKey, secrets: secrets)
        let upstreamProvider = resolvedCredential.provider

        // Daemon: spawn a detached child process that runs the proxy
        if daemon {
            let launchResult: DaemonLaunchResult
            do {
                launchResult = try await CLIProxyRuntime.launchDaemon(
                    port: port,
                    provider: upstreamProvider.rawValue,
                    upstreamUrl: upstreamUrl,
                    key: inlineKey,
                    model: model,
                    json: json
                )
            } catch {
                OutputFormatter.error(
                    command: "start",
                    code: "E012",
                    message: "Daemon process failed to become ready.",
                    suggestion: "Check /tmp/proxypilot_builtin_proxy.log for details.",
                    json: json
                )
                throw ExitCode.failure
            }

            OutputFormatter.success(
                command: "start",
                data: StartPayload(
                    status: "started",
                    pid: Int(launchResult.pid),
                    port: Int(port),
                    provider: upstreamProvider.rawValue,
                    model: model,
                    daemon: true,
                    managed: launchResult.managed
                ),
                humanMessage: "ProxyPilot daemon started (PID \(launchResult.pid), port \(port) -> \(upstreamProvider.title), \(launchResult.managed ? "managed" : "unmanaged"))",
                json: json
            )
            throw ExitCode.success
        }

        let modelResolution: CLIStartModelResolution
        do {
            modelResolution = try await CLIStartModelResolver.resolve(
                rawModels: model,
                provider: upstreamProvider,
                upstreamURL: upstreamUrl,
                apiKey: resolvedCredential.apiKey
            )
        } catch let error as CLIStartModelResolver.ResolutionError {
            OutputFormatter.error(
                command: "start",
                code: "E049",
                message: error.localizedDescription,
                suggestion: error.recoverySuggestion,
                json: json
            )
            throw ExitCode.failure
        } catch {
            OutputFormatter.error(
                command: "start",
                code: "E005",
                message: "Failed to discover upstream models for \(upstreamProvider.rawValue): \(error)",
                suggestion: "Check the upstream URL, verify the server is reachable, or pass --model <id> explicitly.",
                json: json
            )
            throw ExitCode.failure
        }

        let sessionID = UUID().uuidString
        let sessionStats = SessionStats(sessionReportURL: SessionReportStore.defaultURL, sessionSource: "cli", sessionID: sessionID)
        await sessionStats.reset(clearReportStore: false)
        let modelList = modelResolution.models
        let allowedModels: Set<String> = modelList.isEmpty ? [] : Set(modelList)
        let config = ProxyConfiguration(
            port: port,
            upstreamProvider: upstreamProvider,
            upstreamAPIBaseURL: upstreamUrl,
            upstreamAPIKey: resolvedCredential.apiKey,
            allowedModels: allowedModels,
            preferredAnthropicUpstreamModel: modelList.first ?? "",
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
                command: "start",
                code: "E003",
                message: "Failed to start server: \(error)",
                suggestion: CLIProxyRuntime.bindFailureSuggestion(port: port, error: error),
                json: json
            )
            throw ExitCode.failure
        }

        // Write PID file so stop/status can find us.
        if !daemon {
            PidFile.write(pid: ProcessInfo.processInfo.processIdentifier)
        }

        let modelDisplay = model ?? (modelResolution.wasDiscoveredFromUpstream ? "\(modelList.count) discovered model(s)" : "(all)")
        let selectedSuffix = resolvedCredential.selectedFromStoredCredentials ? " (selected from stored provider keys)" : ""
        OutputFormatter.success(
            command: "start",
            data: StartPayload(
                status: "running",
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                port: Int(actualPort),
                provider: upstreamProvider.rawValue,
                model: model,
                daemon: false,
                managed: true
            ),
            humanMessage: "ProxyPilot running on port \(actualPort) -> \(upstreamProvider.title) [\(modelDisplay)] (PID \(ProcessInfo.processInfo.processIdentifier))\(selectedSuffix)",
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

    private func resolveProviderCredential(
        inlineKey: String?,
        secrets: any SecretsProvider
    ) throws -> ResolvedProviderCredential {
        let rawProvider = try selectedProviderFromInteractivePromptIfNeeded(inlineKey: inlineKey, secrets: secrets)
        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: rawProvider,
            explicitKey: inlineKey,
            upstreamURL: upstreamUrl,
            secrets: secrets
        )

        switch resolution {
        case .resolved(let credential):
            return credential
        case .unknownProvider(let raw):
            OutputFormatter.error(
                command: "start",
                code: "E001",
                message: "Unknown provider: \(raw)",
                suggestion: "Valid: \(UpstreamProvider.allCases.map(\.rawValue).joined(separator: ", "))",
                json: json
            )
        case .missingAPIKey(let missingProvider, let secretKeyName):
            OutputFormatter.error(
                command: "start",
                code: "E004",
                message: "No API key found for provider \(missingProvider.rawValue).",
                suggestion: "Run 'proxypilot auth set --provider \(missingProvider.rawValue)', pass --key, or set \(secretKeyName ?? "the provider env var").",
                json: json
            )
        case .selectionRequired(let prompt):
            OutputFormatter.error(
                command: "start",
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

    private func selectedProviderFromInteractivePromptIfNeeded(
        inlineKey: String?,
        secrets: any SecretsProvider
    ) throws -> String? {
        guard provider == nil, inlineKey == nil, !json, stdinIsInteractive else {
            return provider
        }

        let prompt = ProviderCredentialResolver.selectionPrompt(secrets: secrets)
        print(prompt.humanList)
        print("Select a provider or action:", terminator: " ")
        guard let line = readLine(),
              let choiceIndex = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        if let choice = prompt.availableProviders.first(where: { $0.index == choiceIndex }) {
            return choice.provider
        }

        if choiceIndex == prompt.addNewAPIKeyIndex {
            print("Run: proxypilot auth set --provider <provider>")
            throw ExitCode.failure
        }

        if choiceIndex == prompt.addNewProviderIndex {
            print("Custom provider setup is available in the ProxyPilot app. Built-in CLI providers: \(UpstreamProvider.cliOptionsDescription)")
            throw ExitCode.failure
        }

        return nil
    }

    private var stdinIsInteractive: Bool {
        #if canImport(Darwin) || canImport(Glibc)
        isatty(STDIN_FILENO) == 1
        #else
        false
        #endif
    }

    private func selectionNextActions(prompt: ProviderSelectionPrompt) -> [NextAction] {
        var actions = prompt.availableProviders.map { choice in
            NextAction(
                id: "start_with_\(choice.provider)",
                kind: .cli,
                command: "proxypilot start --provider \(choice.provider)",
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

    private struct StartPayload: Encodable {
        let status: String
        let pid: Int
        let port: Int
        let provider: String
        let model: String?
        let daemon: Bool
        let managed: Bool?
    }
}
