#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ProxyProbeResult: Equatable, Sendable {
    public let reachable: Bool
    public let modelCount: Int?
    public let errorMessage: String?
    public let authenticationRequired: Bool?

    public init(reachable: Bool, modelCount: Int?, errorMessage: String?, authenticationRequired: Bool? = nil) {
        self.reachable = reachable
        self.modelCount = modelCount
        self.errorMessage = errorMessage
        self.authenticationRequired = authenticationRequired
    }
}

public enum LocalProxyProbe {
    public static func probe(on port: UInt16, timeout: TimeInterval = 1.5) async -> ProxyProbeResult {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else {
            return ProxyProbeResult(
                reachable: false,
                modelCount: nil,
                errorMessage: "Invalid local proxy probe URL."
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode
                return ProxyProbeResult(
                    reachable: false,
                    modelCount: nil,
                    errorMessage: status.map { "HTTP \($0) from /v1/models." }
                        ?? "No HTTP response from /v1/models."
                )
            }

            let modelCount: Int?
            var authenticationRequired: Bool?
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = object["data"] as? [[String: Any]] {
                modelCount = models.count
                switch object[LocalProxyCredential.authenticationMetadataKey] as? String {
                case "required": authenticationRequired = true
                case "none": authenticationRequired = false
                default: break
                }
            } else {
                modelCount = nil
            }
            return ProxyProbeResult(reachable: true, modelCount: modelCount, errorMessage: nil, authenticationRequired: authenticationRequired)
        } catch {
            return ProxyProbeResult(
                reachable: false,
                modelCount: nil,
                errorMessage: error.localizedDescription
            )
        }
    }
}

public enum ProxyPilotCLIExecutableLocator {
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentExecutableURL: URL? = Bundle.main.executableURL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates: [URL] = []
        if let override = environment["PROXYPILOT_CLI_PATH"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let currentExecutableURL {
            candidates.append(currentExecutableURL.deletingLastPathComponent().appendingPathComponent("proxypilot"))
        }
        candidates += [
            home.appendingPathComponent(".proxypilot/bin/proxypilot"),
            URL(fileURLWithPath: "/Applications/ProxyPilot.app/Contents/Helpers/proxypilot"),
            URL(fileURLWithPath: "/opt/homebrew/bin/proxypilot"),
            URL(fileURLWithPath: "/usr/local/bin/proxypilot"),
        ]

        var seen = Set<String>()
        return candidates.first { candidate in
            let path = candidate.standardizedFileURL.path
            return seen.insert(path).inserted && fileManager.isExecutableFile(atPath: path)
        }
    }
}

public struct ProxyDaemonBootstrapResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case alreadyRunning
        case started
    }

    public let outcome: Outcome
    public let modelCount: Int?
    public let authenticationRequired: Bool?
}

public enum ProxyDaemonBootstrapError: LocalizedError, Equatable {
    case cliNotFound
    case credentialUnavailable(String)
    case cliFailed(status: Int32, message: String)
    case readinessTimedOut(port: UInt16, detail: String?)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "ProxyPilot CLI was not found. Reinstall ProxyPilot Agent support from the app."
        case .credentialUnavailable(let key):
            return "The selected custom provider credential is unavailable in Keychain (\(key)). Open ProxyPilot and save its API key again."
        case .cliFailed(let status, let message):
            return "ProxyPilot CLI could not start the proxy (exit \(status)): \(message)"
        case .readinessTimedOut(let port, let detail):
            let suffix = detail.map { " Last probe: \($0)" } ?? ""
            return "ProxyPilot did not become reachable on port \(port) in time.\(suffix)"
        }
    }
}

public enum ProxyDaemonBootstrapper {
    public static func commandArguments(
        settings: AgentLaunchSettings,
        credentialViaStandardInput: Bool = false
    ) -> [String] {
        var arguments = ["start", "--daemon", "--port", "\(settings.port)", "--json"]
        if let providerID = settings.providerID?.nonEmptyTrimmed {
            arguments += ["--provider", providerID]
        }
        if let upstreamURL = settings.upstreamURL?.nonEmptyTrimmed {
            arguments += ["--upstream-url", upstreamURL]
        }
        if let modelID = settings.modelID?.nonEmptyTrimmed {
            arguments += ["--model", modelID]
        }
        if credentialViaStandardInput {
            arguments.append("--key-stdin")
        }
        arguments += ["--prompt-caching", settings.promptCachingMode.rawValue]
        return arguments
    }

    public static func ensureRunning(
        settings: AgentLaunchSettings,
        cliURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentExecutableURL: URL? = Bundle.main.executableURL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async throws -> ProxyDaemonBootstrapResult {
        let initialProbe = await LocalProxyProbe.probe(on: settings.port)
        if initialProbe.reachable {
            return ProxyDaemonBootstrapResult(
                outcome: .alreadyRunning,
                modelCount: initialProbe.modelCount,
                authenticationRequired: initialProbe.authenticationRequired
            )
        }

        guard let executable = cliURL ?? ProxyPilotCLIExecutableLocator.locate(
            environment: environment,
            currentExecutableURL: currentExecutableURL,
            home: home
        ) else {
            throw ProxyDaemonBootstrapError.cliNotFound
        }

        let process = Process()
        let output = Pipe()
        let credential: String?
        if let credentialKey = settings.credentialKey?.nonEmptyTrimmed {
            credential = try SecretsProviderFactory.make().get(key: credentialKey)?.nonEmptyTrimmed
            guard credential != nil else {
                throw ProxyDaemonBootstrapError.credentialUnavailable(credentialKey)
            }
        } else {
            credential = nil
        }
        process.executableURL = executable
        process.arguments = commandArguments(
            settings: settings,
            credentialViaStandardInput: credential != nil
        )
        process.standardOutput = output
        process.standardError = output
        process.environment = environment
        let input = credential.map { _ in Pipe() }
        process.standardInput = input
        try process.run()
        if let credential, let input {
            try input.fileHandleForWriting.write(contentsOf: Data("\(credential)\n".utf8))
            try input.fileHandleForWriting.close()
        }
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: outputData.prefix(8_192), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ProxyDaemonBootstrapError.cliFailed(
                status: process.terminationStatus,
                message: message.isEmpty ? "No diagnostic output." : message
            )
        }

        var lastProbe = initialProbe
        for _ in 0..<40 {
            lastProbe = await LocalProxyProbe.probe(on: settings.port, timeout: 0.3)
            if lastProbe.reachable {
                return ProxyDaemonBootstrapResult(outcome: .started, modelCount: lastProbe.modelCount, authenticationRequired: lastProbe.authenticationRequired)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw ProxyDaemonBootstrapError.readinessTimedOut(
            port: settings.port,
            detail: lastProbe.errorMessage
        )
    }
}

public struct ManagedAgentRuntimeLayout: Equatable, Sendable {
    public let root: URL
    public let configDirectory: URL
    public var engineExecutable: URL { root.appendingPathComponent("opencode") }
    public init(root: URL, configDirectory: URL) { self.root = root; self.configDirectory = configDirectory }
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        .init(root: home.appendingPathComponent(".proxypilot/runtime-opencode"),
              configDirectory: home.appendingPathComponent(".proxypilot/xcode-agent"))
    }
}

public enum AgentAdapterLaunchError: LocalizedError, Equatable {
    case engineMissing(String)
    case configUnavailable(String)
    public var errorDescription: String? {
        switch self {
        case .engineMissing(let path): "Managed OpenCode is missing at \(path). Install ProxyPilot Agent support."
        case .configUnavailable(let path): "Could not prepare the Xcode agent configuration at \(path)."
        }
    }
}

public struct AgentAdapterLaunchPlan: Equatable, Sendable {
    public let executable: URL
    /// Includes argv[0] for execve.
    public let arguments: [String]
    public let environment: [String: String]

    public static func make(
        settings: AgentLaunchSettings,
        localProxyCredential: String,
        layout: ManagedAgentRuntimeLayout = .standard(),
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> AgentAdapterLaunchPlan {
        guard fileManager.isExecutableFile(atPath: layout.engineExecutable.path) else {
            throw AgentAdapterLaunchError.engineMissing(layout.engineExecutable.path)
        }
        let profile = layout.configDirectory
        let plugin = profile.appendingPathComponent("attribution.mjs")
        let shell = profile.appendingPathComponent("agent-shell")
        do {
            try fileManager.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Stable native session -> UUID attribution, including across process restarts.
            // Only headers change; the plugin never modifies prompts or tool schemas.
            try attributionPlugin.write(to: plugin, atomically: true, encoding: .utf8)
            try shellWrapper.write(to: shell, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plugin.path)
        } catch { throw AgentAdapterLaunchError.configUnavailable(profile.path) }
        let metadata = settings.modelMetadata
        let supported: Set<String> = ["text", "image", "audio", "video", "pdf"]
        func modalities(_ values: [String]?) -> [String] {
            let filtered = (values ?? ["text"]).filter { supported.contains($0) }
            return filtered.isEmpty ? ["text"] : filtered
        }
        let context = max(1, metadata?.contextLength ?? 200_000)
        let output = min(8_000, max(1, metadata?.maximumOutputTokens ?? 8_000))
        let model: [String: Any] = ["name": "ProxyPilot Active Route", "limit": ["context": context, "output": output],
            "modalities": ["input": modalities(metadata?.inputModalities), "output": modalities(metadata?.outputModalities)]]
        let config: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "model": "proxypilot/\(ActiveModelAlias.id)", "small_model": "proxypilot/\(ActiveModelAlias.id)",
            "autoupdate": false, "share": "disabled", "enabled_providers": ["proxypilot"],
            "plugin": [plugin.absoluteString], "shell": shell.path,
            "agent": ["title": ["disable": true]],
            "provider": ["proxypilot": ["npm": "@ai-sdk/openai-compatible", "name": "ProxyPilot",
                "options": ["baseURL": "http://127.0.0.1:\(settings.port)/v1", "apiKey": localProxyCredential],
                "models": [ActiveModelAlias.id: model]]],
            "permission": ["read": "allow", "edit": "ask", "bash": "ask", "external_directory": "ask"],
        ]
        let content = String(decoding: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]), as: UTF8.self)
        var environment = [
            "PATH": "\(layout.root.path):/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path,
            "XDG_CONFIG_HOME": profile.appendingPathComponent("config").path,
            "XDG_DATA_HOME": profile.appendingPathComponent("data").path,
            "XDG_CACHE_HOME": profile.appendingPathComponent("cache").path,
            "XDG_STATE_HOME": profile.appendingPathComponent("state").path,
            "OPENCODE_CONFIG_DIR": profile.appendingPathComponent("config/opencode").path,
            "OPENCODE_CONFIG_CONTENT": content,
            "OPENCODE_DISABLE_AUTOUPDATE": "1", "OPENCODE_DISABLE_MODELS_FETCH": "1",
            "OPENCODE_DISABLE_DEFAULT_PLUGINS": "1",
            // Preserve the user's shell configuration locations inside approved commands.
            "PROXYPILOT_AGENT_PROFILE": profile.path,
        ]
        for key in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"] {
            environment["PP_AGENT_ORIGINAL_" + key] = inheritedEnvironment[key] ?? ""
        }
        for key in ["TMPDIR", "LANG", "LC_ALL", "DEVELOPER_DIR"] {
            if let value = inheritedEnvironment[key], !value.isEmpty { environment[key] = value }
        }
        return .init(executable: layout.engineExecutable,
            arguments: [layout.engineExecutable.path, "acp", "--hostname", "127.0.0.1"], environment: environment)
    }

    private static let shellWrapper = #"""
    #!/bin/zsh
    restore_xdg() {
      if [[ -n "$2" ]]; then export "$1=$2"; else unset "$1"; fi
    }
    restore_xdg XDG_CONFIG_HOME "$PP_AGENT_ORIGINAL_XDG_CONFIG_HOME"
    restore_xdg XDG_DATA_HOME "$PP_AGENT_ORIGINAL_XDG_DATA_HOME"
    restore_xdg XDG_CACHE_HOME "$PP_AGENT_ORIGINAL_XDG_CACHE_HOME"
    restore_xdg XDG_STATE_HOME "$PP_AGENT_ORIGINAL_XDG_STATE_HOME"
    exec /bin/zsh "$@"
    """#

    public static let attributionPlugin = #"""
    import { createHash } from 'node:crypto';
    export default async () => ({
      'chat.headers': async (input, output) => {
        const hex = createHash('sha256').update('proxypilot-xcode:' + input.sessionID).digest('hex');
        const id = `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20,32)}`;
        output.headers['X-ProxyPilot-Client'] = 'xcode-agent';
        output.headers['X-ProxyPilot-Session-ID'] = id;
      },
    });
    """#
}

public struct AgentLaunchTelemetryEvent: Codable, Equatable, Sendable {
    public let name: String
    public let timestamp: Date
    public let port: UInt16
    public let modelID: String?
    public let upstreamLabel: String?
    public let detail: String?

    public init(
        name: String,
        timestamp: Date = Date(),
        settings: AgentLaunchSettings,
        detail: String? = nil
    ) {
        self.name = name
        self.timestamp = timestamp
        self.port = settings.port
        self.modelID = settings.modelID
        self.upstreamLabel = settings.upstreamLabel
        self.detail = detail
    }
}

public enum AgentLaunchTelemetry {
    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        AgentLaunchSettings.storageURL(environment: environment, home: home)
            .deletingLastPathComponent()
            .appendingPathComponent("agent-launches.ndjson")
    }

    public static func record(
        _ event: AgentLaunchTelemetryEvent,
        to url: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let destination = url ?? defaultURL()
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var data = try JSONEncoder().encode(event)
        data.append(0x0A)
        if !fileManager.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
