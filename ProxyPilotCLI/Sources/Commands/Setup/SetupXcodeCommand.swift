import ArgumentParser
import Foundation
import ProxyPilotCore

struct SetupXcodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode",
        abstract: "Configure ProxyPilot for Xcode Agent routing."
    )

    @Option(name: .shortAndLong, help: "Proxy port for the local listener.")
    var port: UInt16 = ProxyPilotDefaults.defaultPort

    @Option(name: .long, help: "Upstream provider (\(UpstreamProvider.cliOptionsDescription)). Defaults to \(ProxyPilotDefaults.defaultXcodeProvider.rawValue) for Xcode setup.")
    var provider: String = ProxyPilotDefaults.defaultXcodeProvider.rawValue

    @Option(name: .long, help: "Override the upstream API base URL.")
    var upstreamUrl: String?

    @Option(name: .long, help: "Upstream API key value (stored before startup when possible).")
    var key: String?

    @Flag(name: .long, help: "Read a single API key line from stdin.")
    var keyStdin: Bool = false

    @Option(name: .long, help: "Preferred upstream model. Defaults to glm-4.7 for z.ai.")
    var model: String?

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    mutating func run() async throws {
        #if os(macOS)
        guard let upstreamProvider = UpstreamProvider(rawValue: provider) else {
            OutputFormatter.error(
                command: "setup xcode",
                code: "E001",
                message: "Unknown provider: \(provider)",
                suggestion: "Valid: \(UpstreamProvider.allCases.map(\.rawValue).joined(separator: ", "))",
                json: json
            )
            throw ExitCode.failure
        }

        let inlineKey: String?
        do {
            inlineKey = try CLIProxyRuntime.readInlineKey(key: key, keyStdin: keyStdin)
        } catch {
            OutputFormatter.error(
                command: "setup xcode",
                code: "E042",
                message: "Failed to read API key input: \(error.localizedDescription)",
                suggestion: "Use --key <value> or provide a single key line with --key-stdin.",
                json: json
            )
            throw ExitCode.failure
        }

        let chosenModel = resolvedModel(for: upstreamProvider)
        let secrets = SecretsProviderFactory.make()
        var authBackend = authBackendInfo(for: secrets)

        if let inlineKey,
           upstreamProvider.requiresAPIKey,
           let secretKeyName = upstreamProvider.secretKey {
            do {
                try secrets.set(key: secretKeyName, value: inlineKey)
                authBackend = authBackendInfo(for: secrets)
            } catch {
                OutputFormatter.error(
                    command: "setup xcode",
                    code: "E043",
                    message: "Failed to store API key for provider \(upstreamProvider.rawValue): \(error.localizedDescription)",
                    suggestion: "Verify secrets store permissions and retry.",
                    json: json
                )
                throw ExitCode.failure
            }
        }

        let effectiveBaseURL = upstreamUrl ?? upstreamProvider.defaultAPIBaseURL
        let resolvedAPIKey: String?
        if let inlineKey {
            resolvedAPIKey = inlineKey
        } else if let secretKeyName = upstreamProvider.secretKey {
            resolvedAPIKey = ProcessInfo.processInfo.environment[secretKeyName]
                ?? (try? secrets.get(key: secretKeyName))
        } else {
            resolvedAPIKey = nil
        }

        if resolvedAPIKey == nil && !upstreamProvider.isLocal && !isLocalhostURL(effectiveBaseURL) {
            OutputFormatter.error(
                command: "setup xcode",
                code: "E004",
                message: "No API key found for provider \(upstreamProvider.rawValue).",
                suggestion: "Pass --key, use --key-stdin, or run 'proxypilot auth set --provider \(upstreamProvider.rawValue)'.",
                json: json
            )
            throw ExitCode.failure
        }

        let existingProbe = await CLIProxyRuntime.probeProxy(on: port)
        let proxyStatus: String
        let managed: Bool

        if existingProbe.reachable {
            managed = PidFile.read() != nil
            proxyStatus = managed ? "already_running" : "already_running_unmanaged"
        } else {
            let launchResult: DaemonLaunchResult
            do {
                launchResult = try await CLIProxyRuntime.launchDaemon(
                    port: port,
                    provider: upstreamProvider.rawValue,
                    upstreamUrl: upstreamUrl,
                    key: inlineKey,
                    model: chosenModel.isEmpty ? nil : chosenModel,
                    json: false
                )
            } catch {
                OutputFormatter.error(
                    command: "setup xcode",
                    code: "E012",
                    message: "Failed to start ProxyPilot daemon: \(error.localizedDescription)",
                    suggestion: "Check /tmp/proxypilot_builtin_proxy.log for details.",
                    json: json
                )
                throw ExitCode.failure
            }
            managed = launchResult.managed
            proxyStatus = managed ? "started" : "started_unmanaged"
        }

        let configStatus: XcodeConfigManager.Status
        do {
            configStatus = try XcodeConfigManager.install(port: port)
        } catch {
            OutputFormatter.error(
                command: "setup xcode",
                code: "E031",
                message: "Failed to install Xcode config: \(error.localizedDescription)",
                suggestion: "Check that ~/Library/Developer/Xcode/CodingAssistant is writable.",
                json: json
            )
            throw ExitCode.failure
        }

        let finalProbe = await CLIProxyRuntime.probeProxy(on: port)
        guard finalProbe.reachable else {
            OutputFormatter.error(
                command: "setup xcode",
                code: "E012",
                message: "ProxyPilot did not respond on 127.0.0.1:\(port) after setup.",
                suggestion: "Check /tmp/proxypilot_builtin_proxy.log for details.",
                json: json
            )
            throw ExitCode.failure
        }

        let authBackendPayload: String?
        let authPathPayload: String?
        if inlineKey != nil && upstreamProvider.requiresAPIKey {
            authBackendPayload = authBackend.label
            authPathPayload = authBackend.filePath
        } else {
            authBackendPayload = nil
            authPathPayload = nil
        }

        let backendSuffix: String
        if let filePath = authBackend.filePath, inlineKey != nil {
            backendSuffix = " Stored auth in file backend at \(filePath)."
        } else if inlineKey != nil && upstreamProvider.requiresAPIKey {
            backendSuffix = " Stored auth in \(authBackend.label) backend."
        } else {
            backendSuffix = ""
        }

        let modelText = chosenModel.isEmpty ? "(all)" : chosenModel
        let modelsText = finalProbe.modelCount.map { " (\($0) model\($0 == 1 ? "" : "s"))" } ?? ""

        OutputFormatter.success(
            command: "setup xcode",
            data: SetupXcodePayload(
                status: "configured",
                proxyStatus: proxyStatus,
                managed: managed,
                port: Int(port),
                provider: upstreamProvider.rawValue,
                model: chosenModel.isEmpty ? nil : chosenModel,
                settingsPath: XcodeConfigManager.settingsFileURL.path,
                settingsFilePresent: configStatus.settingsExists,
                defaultsOverridePresent: configStatus.defaultsOverrideExists,
                modelsCount: finalProbe.modelCount,
                authBackend: authBackendPayload,
                authPath: authPathPayload,
                defaultProviderDivergesFromCLI: upstreamProvider == ProxyPilotDefaults.defaultXcodeProvider && ProxyPilotDefaults.defaultCLIProvider != ProxyPilotDefaults.defaultXcodeProvider
            ),
            humanMessage: """
            Xcode setup complete.
            Proxy: \(proxyStatus) on 127.0.0.1:\(port) (\(managed ? "managed" : "unmanaged"))
            Upstream: \(upstreamProvider.title) [\(modelText)]
            Xcode config: installed at \(XcodeConfigManager.settingsFileURL.path)
            /v1/models: reachable\(modelsText)
            If Xcode is open, quit and relaunch it to pick up the new routing.\(backendSuffix)
            """,
            json: json
        )
        #else
        OutputFormatter.error(
            command: "setup xcode",
            code: "E034",
            message: "'proxypilot setup xcode' is only supported on macOS.",
            suggestion: nil,
            json: json
        )
        throw ExitCode.failure
        #endif
    }

    private func resolvedModel(for provider: UpstreamProvider) -> String {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }

        return provider.defaultAgentModel ?? ""
    }

    private struct SetupXcodePayload: Encodable {
        let status: String
        let proxyStatus: String
        let managed: Bool
        let port: Int
        let provider: String
        let model: String?
        let settingsPath: String
        let settingsFilePresent: Bool
        let defaultsOverridePresent: Bool
        let modelsCount: Int?
        let authBackend: String?
        let authPath: String?
        let defaultProviderDivergesFromCLI: Bool

        enum CodingKeys: String, CodingKey {
            case status
            case proxyStatus = "proxy_status"
            case managed
            case port
            case provider
            case model
            case settingsPath = "settings_path"
            case settingsFilePresent = "settings_file_present"
            case defaultsOverridePresent = "defaults_override_present"
            case modelsCount = "models_count"
            case authBackend = "auth_backend"
            case authPath = "auth_path"
            case defaultProviderDivergesFromCLI = "default_provider_diverges_from_cli"
        }
    }
}
