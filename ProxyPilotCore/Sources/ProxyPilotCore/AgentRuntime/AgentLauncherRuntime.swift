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

    public init(reachable: Bool, modelCount: Int?, errorMessage: String?) {
        self.reachable = reachable
        self.modelCount = modelCount
        self.errorMessage = errorMessage
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
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = object["data"] as? [[String: Any]] {
                modelCount = models.count
            } else {
                modelCount = nil
            }
            return ProxyProbeResult(reachable: true, modelCount: modelCount, errorMessage: nil)
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
                modelCount: initialProbe.modelCount
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
                return ProxyDaemonBootstrapResult(outcome: .started, modelCount: lastProbe.modelCount)
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
    public let nodeExecutable: URL
    public let adapterEntryPoint: URL
    public let claudeConfigDirectory: URL

    public init(root: URL, claudeConfigDirectory: URL) {
        self.root = root
        self.nodeExecutable = root.appendingPathComponent("bin/node")
        self.adapterEntryPoint = root.appendingPathComponent(
            "lib/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js"
        )
        self.claudeConfigDirectory = claudeConfigDirectory
    }

    public static func standard(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ManagedAgentRuntimeLayout {
        ManagedAgentRuntimeLayout(
            root: home.appendingPathComponent(".proxypilot/runtime", isDirectory: true),
            claudeConfigDirectory: home.appendingPathComponent(
                ".proxypilot/claude-config", isDirectory: true
            )
        )
    }
}

public enum AgentAdapterLaunchError: LocalizedError, Equatable {
    case nodeMissing(String)
    case adapterMissing(String)
    case claudeConfigUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .nodeMissing(let path):
            return "Managed Node runtime is missing at \(path). Reinstall ProxyPilot Agent support."
        case .adapterMissing(let path):
            return "ProxyPilot Agent adapter is missing at \(path). Reinstall ProxyPilot Agent support."
        case .claudeConfigUnavailable(let path):
            return "Could not prepare the isolated Claude config directory at \(path)."
        }
    }
}

public struct AgentAdapterLaunchPlan: Equatable, Sendable {
    public let executable: URL
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
        guard fileManager.isExecutableFile(atPath: layout.nodeExecutable.path) else {
            throw AgentAdapterLaunchError.nodeMissing(layout.nodeExecutable.path)
        }
        guard fileManager.fileExists(atPath: layout.adapterEntryPoint.path) else {
            throw AgentAdapterLaunchError.adapterMissing(layout.adapterEntryPoint.path)
        }
        do {
            try fileManager.createDirectory(
                at: layout.claudeConfigDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw AgentAdapterLaunchError.claudeConfigUnavailable(layout.claudeConfigDirectory.path)
        }

        var environment = [
            "PATH": "\(layout.root.appendingPathComponent("bin").path):/usr/bin:/bin",
            "HOME": home.path,
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(settings.port)",
            "ANTHROPIC_AUTH_TOKEN": localProxyCredential,
            "CLAUDE_CONFIG_DIR": layout.claudeConfigDirectory.path,
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        ]
        for key in ["TMPDIR", "LANG", "LC_ALL"] {
            if let value = inheritedEnvironment[key], !value.isEmpty {
                environment[key] = value
            }
        }
        if let modelID = settings.modelID?.nonEmptyTrimmed {
            environment["ANTHROPIC_MODEL"] = modelID
        }

        return AgentAdapterLaunchPlan(
            executable: layout.nodeExecutable,
            arguments: [layout.nodeExecutable.path, layout.adapterEntryPoint.path],
            environment: environment
        )
    }
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
