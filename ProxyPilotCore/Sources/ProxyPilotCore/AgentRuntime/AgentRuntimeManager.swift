#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AgentRuntimeRelease: Equatable, Sendable {
    public struct NodeArchive: Equatable, Sendable {
        public let architecture: String
        public let url: URL
        public let sha256: String

        public init(architecture: String, url: URL, sha256: String) {
            self.architecture = architecture
            self.url = url
            self.sha256 = sha256
        }
    }

    public let nodeVersion: String
    public let adapterVersion: String
    public let adapterPackage: String
    public let adapterIntegrity: String
    public let nodeArchives: [String: NodeArchive]

    public static let pinned = AgentRuntimeRelease(
        nodeVersion: "26.3.0",
        adapterVersion: "0.44.0",
        adapterPackage: "@agentclientprotocol/claude-agent-acp",
        adapterIntegrity: "sha512-FWET6TS3XpVgm4xhPtxzPJACNBK+O1rWnZ+6ZDA1vvtxy9KmAu6yGCDSGSsPeArEcouc8u69iuNW4vLaUELNcw==",
        nodeArchives: [
            "arm64": NodeArchive(
                architecture: "arm64",
                url: URL(string: "https://nodejs.org/dist/v26.3.0/node-v26.3.0-darwin-arm64.tar.gz")!,
                sha256: "77ef7f7a15aa757c2ca19d63cf41c8d9eb3b18590ebc6883871310787d8c6b6c"
            ),
            "x86_64": NodeArchive(
                architecture: "x86_64",
                url: URL(string: "https://nodejs.org/dist/v26.3.0/node-v26.3.0-darwin-x64.tar.gz")!,
                sha256: "7453bd54a17bdc656e2e784d702f6eeb224fb517965e6f8c5a31a88c83d3804c"
            ),
        ]
    )

    public init(
        nodeVersion: String,
        adapterVersion: String,
        adapterPackage: String,
        adapterIntegrity: String,
        nodeArchives: [String: NodeArchive]
    ) {
        self.nodeVersion = nodeVersion
        self.adapterVersion = adapterVersion
        self.adapterPackage = adapterPackage
        self.adapterIntegrity = adapterIntegrity
        self.nodeArchives = nodeArchives
    }
}

public struct AgentRuntimeManifest: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public let schema: Int
    public let nodeVersion: String
    public let adapterVersion: String
    public let adapterPackage: String
    public let adapterIntegrity: String
    public let architecture: String
    public let nodeArchiveSHA256: String
    public let nodeExecutableSHA256: String
    public let adapterEntryPointSHA256: String
    public let harnessExecutableSHA256: String
    public let installedAt: Date

    public init(
        schema: Int = currentSchema,
        nodeVersion: String,
        adapterVersion: String,
        adapterPackage: String,
        adapterIntegrity: String,
        architecture: String,
        nodeArchiveSHA256: String,
        nodeExecutableSHA256: String,
        adapterEntryPointSHA256: String,
        harnessExecutableSHA256: String,
        installedAt: Date = Date()
    ) {
        self.schema = schema
        self.nodeVersion = nodeVersion
        self.adapterVersion = adapterVersion
        self.adapterPackage = adapterPackage
        self.adapterIntegrity = adapterIntegrity
        self.architecture = architecture
        self.nodeArchiveSHA256 = nodeArchiveSHA256
        self.nodeExecutableSHA256 = nodeExecutableSHA256
        self.adapterEntryPointSHA256 = adapterEntryPointSHA256
        self.harnessExecutableSHA256 = harnessExecutableSHA256
        self.installedAt = installedAt
    }
}

public enum AgentRuntimeStatus: Equatable, Sendable {
    case notInstalled
    case ready(AgentRuntimeManifest)
    case stale(reason: String, manifest: AgentRuntimeManifest?)
    case corrupt(reason: String, manifest: AgentRuntimeManifest?)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public enum AgentRuntimeManagerError: LocalizedError, Equatable {
    case unsupportedPlatform
    case unsupportedArchitecture(String)
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case npmInstallFailed(String)
    case installedRuntimeInvalid(String)
    case atomicInstallFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Managed ProxyPilot Agent runtime installation is supported on macOS only."
        case .unsupportedArchitecture(let architecture):
            return "No managed Node runtime is available for architecture \(architecture)."
        case .downloadFailed(let detail):
            return "Could not download the managed Node runtime: \(detail)"
        case .checksumMismatch(let expected, let actual):
            return "Managed Node archive failed integrity verification (expected \(expected), got \(actual))."
        case .extractionFailed(let detail):
            return "Could not extract the managed Node runtime: \(detail)"
        case .npmInstallFailed(let detail):
            return "Could not install the pinned ProxyPilot Agent adapter: \(detail)"
        case .installedRuntimeInvalid(let detail):
            return "The staged ProxyPilot Agent runtime is incomplete: \(detail)"
        case .atomicInstallFailed(let detail):
            return "Could not activate the ProxyPilot Agent runtime: \(detail)"
        }
    }
}

public struct AgentRuntimeManager: Sendable {
    public let layout: ManagedAgentRuntimeLayout
    public let release: AgentRuntimeRelease
    public let architecture: String

    public var manifestURL: URL {
        layout.root.appendingPathComponent("proxypilot-runtime.json")
    }

    public var harnessExecutableURL: URL {
        layout.root.appendingPathComponent(
            "lib/node_modules/@agentclientprotocol/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-darwin-\(architecture)/claude"
        )
    }

    public init(
        layout: ManagedAgentRuntimeLayout = .standard(),
        release: AgentRuntimeRelease = .pinned,
        architecture: String = AgentRuntimeManager.currentArchitecture
    ) {
        self.layout = layout
        self.release = release
        self.architecture = architecture
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    public func status(fileManager: FileManager = .default) -> AgentRuntimeStatus {
        guard fileManager.fileExists(atPath: layout.root.path) else {
            return .notInstalled
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? decoder.decode(AgentRuntimeManifest.self, from: data) else {
            return .corrupt(reason: "Runtime manifest is missing or unreadable.", manifest: nil)
        }
        guard manifest.schema == AgentRuntimeManifest.currentSchema else {
            return .stale(reason: "Runtime manifest schema changed.", manifest: manifest)
        }
        guard manifest.nodeVersion == release.nodeVersion,
              manifest.adapterVersion == release.adapterVersion,
              manifest.adapterPackage == release.adapterPackage,
              manifest.adapterIntegrity == release.adapterIntegrity,
              manifest.architecture == architecture else {
            return .stale(reason: "Installed runtime does not match the pinned release.", manifest: manifest)
        }
        guard fileManager.isExecutableFile(atPath: layout.nodeExecutable.path) else {
            return .corrupt(reason: "Managed Node executable is missing.", manifest: manifest)
        }
        guard fileManager.fileExists(atPath: layout.adapterEntryPoint.path) else {
            return .corrupt(reason: "Pinned adapter entry point is missing.", manifest: manifest)
        }
        guard fileManager.isExecutableFile(atPath: harnessExecutableURL.path) else {
            return .corrupt(reason: "Architecture-matched Claude harness is missing.", manifest: manifest)
        }

        do {
            let nodeHash = try Self.sha256(of: layout.nodeExecutable)
            guard nodeHash == manifest.nodeExecutableSHA256 else {
                return .corrupt(reason: "Managed Node executable hash changed.", manifest: manifest)
            }
            let adapterHash = try Self.sha256(of: layout.adapterEntryPoint)
            guard adapterHash == manifest.adapterEntryPointSHA256 else {
                return .corrupt(reason: "Adapter entry-point hash changed.", manifest: manifest)
            }
            let harnessHash = try Self.sha256(of: harnessExecutableURL)
            guard harnessHash == manifest.harnessExecutableSHA256 else {
                return .corrupt(reason: "Claude harness hash changed.", manifest: manifest)
            }
        } catch {
            return .corrupt(reason: "Could not verify installed runtime files.", manifest: manifest)
        }
        return .ready(manifest)
    }

    public func install() async throws -> AgentRuntimeManifest {
        #if os(macOS)
        guard let archive = release.nodeArchives[architecture] else {
            throw AgentRuntimeManagerError.unsupportedArchitecture(architecture)
        }

        let parent = layout.root.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(
            ".runtime-install-\(UUID().uuidString)", isDirectory: true
        )
        let archiveURL = parent.appendingPathComponent(
            ".node-runtime-\(UUID().uuidString).tar.gz"
        )
        let logURL = parent.appendingPathComponent(
            ".runtime-install-\(UUID().uuidString).log"
        )
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: archiveURL)
            try? fileManager.removeItem(at: logURL)
        }

        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: archive.url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw AgentRuntimeManagerError.downloadFailed("The server did not return HTTP 200.")
            }
            try fileManager.moveItem(at: temporaryURL, to: archiveURL)
        } catch let error as AgentRuntimeManagerError {
            throw error
        } catch {
            throw AgentRuntimeManagerError.downloadFailed(error.localizedDescription)
        }

        let archiveHash = try Self.sha256(of: archiveURL)
        guard archiveHash == archive.sha256 else {
            throw AgentRuntimeManagerError.checksumMismatch(
                expected: archive.sha256,
                actual: archiveHash
            )
        }

        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let extraction = try Self.runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archiveURL.path, "--strip-components=1", "-C", staging.path],
            environment: ProcessInfo.processInfo.environment,
            logURL: logURL
        )
        guard extraction.status == 0 else {
            throw AgentRuntimeManagerError.extractionFailed(extraction.output)
        }

        let npm = staging.appendingPathComponent("bin/npm")
        guard fileManager.isExecutableFile(atPath: npm.path) else {
            throw AgentRuntimeManagerError.installedRuntimeInvalid("npm is missing from the Node archive.")
        }
        let npmEnvironment = try Self.hardenedNPMEnvironment(nodeRoot: staging, home: parent)
        let packedAdapterDirectory = staging.appendingPathComponent("proxypilot-adapter-pack", isDirectory: true)
        try fileManager.createDirectory(at: packedAdapterDirectory, withIntermediateDirectories: true)
        let packResult = try Self.runProcess(
            executable: npm,
            arguments: [
                "pack", "--pack-destination", packedAdapterDirectory.path,
                "--ignore-scripts", "--loglevel=error",
                "\(release.adapterPackage)@\(release.adapterVersion)",
            ],
            environment: npmEnvironment,
            logURL: logURL
        )
        guard packResult.status == 0 else {
            throw AgentRuntimeManagerError.npmInstallFailed(packResult.output)
        }
        let packedAdapter = try Self.singlePackedAdapter(in: packedAdapterDirectory)
        let adapterIntegrity = try Self.sha512SRI(of: packedAdapter)
        guard adapterIntegrity == release.adapterIntegrity else {
            throw AgentRuntimeManagerError.npmInstallFailed(
                "Pinned adapter integrity mismatch (expected \(release.adapterIntegrity), got \(adapterIntegrity))."
            )
        }

        let npmResult = try Self.runProcess(
            executable: npm,
            arguments: [
                "install", "--global", "--prefix", staging.path,
                "--omit=dev", "--no-audit", "--no-fund", "--ignore-scripts", "--loglevel=error",
                packedAdapter.path,
            ],
            environment: npmEnvironment,
            logURL: logURL
        )
        guard npmResult.status == 0 else {
            throw AgentRuntimeManagerError.npmInstallFailed(npmResult.output)
        }
        try? fileManager.removeItem(at: packedAdapterDirectory)

        let stagedLayout = ManagedAgentRuntimeLayout(
            root: staging,
            claudeConfigDirectory: layout.claudeConfigDirectory
        )
        let stagedHarness = staging.appendingPathComponent(
            "lib/node_modules/@agentclientprotocol/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-darwin-\(architecture)/claude"
        )
        guard fileManager.isExecutableFile(atPath: stagedLayout.nodeExecutable.path),
              fileManager.fileExists(atPath: stagedLayout.adapterEntryPoint.path),
              fileManager.isExecutableFile(atPath: stagedHarness.path) else {
            throw AgentRuntimeManagerError.installedRuntimeInvalid(
                "Node, \(release.adapterPackage) \(release.adapterVersion), or its architecture-matched harness is missing after install."
            )
        }

        let manifest = AgentRuntimeManifest(
            nodeVersion: release.nodeVersion,
            adapterVersion: release.adapterVersion,
            adapterPackage: release.adapterPackage,
            adapterIntegrity: release.adapterIntegrity,
            architecture: architecture,
            nodeArchiveSHA256: archiveHash,
            nodeExecutableSHA256: try Self.sha256(of: stagedLayout.nodeExecutable),
            adapterEntryPointSHA256: try Self.sha256(of: stagedLayout.adapterEntryPoint),
            harnessExecutableSHA256: try Self.sha256(of: stagedHarness)
        )
        try Self.writeManifest(manifest, to: staging.appendingPathComponent("proxypilot-runtime.json"))
        try activate(staging: staging, fileManager: fileManager)

        guard case .ready(let installedManifest) = status() else {
            throw AgentRuntimeManagerError.installedRuntimeInvalid(
                "Post-install integrity verification failed."
            )
        }
        return installedManifest
        #else
        throw AgentRuntimeManagerError.unsupportedPlatform
        #endif
    }

    public func remove(fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: layout.root.path) {
            try fileManager.removeItem(at: layout.root)
        }
    }

    private func activate(staging: URL, fileManager: FileManager) throws {
        let backup = layout.root.deletingLastPathComponent()
            .appendingPathComponent(".runtime-backup-\(UUID().uuidString)")
        let hadExisting = fileManager.fileExists(atPath: layout.root.path)
        do {
            if hadExisting {
                try fileManager.moveItem(at: layout.root, to: backup)
            }
            try fileManager.moveItem(at: staging, to: layout.root)
            if hadExisting {
                try? fileManager.removeItem(at: backup)
            }
        } catch {
            if !fileManager.fileExists(atPath: layout.root.path),
               fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: layout.root)
            }
            throw AgentRuntimeManagerError.atomicInstallFailed(error.localizedDescription)
        }
    }

    private static func writeManifest(_ manifest: AgentRuntimeManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha512SRI(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return "sha512-" + Data(SHA512.hash(data: data)).base64EncodedString()
    }

    private static func singlePackedAdapter(in directory: URL) throws -> URL {
        let tarballs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "tgz" }
        guard tarballs.count == 1, let tarball = tarballs.first else {
            throw AgentRuntimeManagerError.npmInstallFailed(
                "Expected one packed adapter tarball, found \(tarballs.count)."
            )
        }
        return tarball
    }

    static func hardenedNPMEnvironment(nodeRoot: URL, home: URL) throws -> [String: String] {
        // npm rejects loading one file as both the user and global config.
        // Keep isolated, empty files in staging so ambient configuration cannot
        // redirect the registry or enable install scripts.
        let globalConfig = nodeRoot.appendingPathComponent("proxypilot-global.npmrc")
        let userConfig = nodeRoot.appendingPathComponent("proxypilot-user.npmrc")
        for config in [globalConfig, userConfig] {
            try Data().write(to: config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        }
        return [
            "PATH": "\(nodeRoot.appendingPathComponent("bin").path):/usr/bin:/bin",
            "HOME": home.path,
            "NPM_CONFIG_AUDIT": "false",
            "NPM_CONFIG_FUND": "false",
            "NPM_CONFIG_CACHE": home.appendingPathComponent(".npm-cache", isDirectory: true).path,
            "NPM_CONFIG_GLOBALCONFIG": globalConfig.path,
            "NPM_CONFIG_IGNORE_SCRIPTS": "true",
            "NPM_CONFIG_REGISTRY": "https://registry.npmjs.org/",
            "NPM_CONFIG_USERCONFIG": userConfig.path,
        ]
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        logURL: URL
    ) throws -> (status: Int32, output: String) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        try process.run()
        process.waitUntilExit()
        try log.synchronize()
        let data = (try? Data(contentsOf: logURL)) ?? Data()
        let output = String(decoding: data.suffix(16_384), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }
}

public struct AgentExecutableLinkManager: Sendable {
    public enum LinkStatus: Equatable, Sendable {
        case missing
        case ready
        case staleTarget(String)
    }

    public let binDirectory: URL

    public init(
        binDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".proxypilot/bin", isDirectory: true)
    ) {
        self.binDirectory = binDirectory
    }

    public var launcherURL: URL { binDirectory.appendingPathComponent("proxypilot-agent") }
    public var cliURL: URL { binDirectory.appendingPathComponent("proxypilot") }

    public func launcherStatus(expectedSource: URL, fileManager: FileManager = .default) -> LinkStatus {
        linkStatus(at: launcherURL, expectedSource: expectedSource, fileManager: fileManager)
    }

    public func install(launcherSource: URL, cliSource: URL) throws {
        try installLink(source: launcherSource, destination: launcherURL)
        try installLink(source: cliSource, destination: cliURL)
    }

    public func remove(fileManager: FileManager = .default) throws {
        for url in [launcherURL, cliURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func linkStatus(
        at destination: URL,
        expectedSource: URL,
        fileManager: FileManager
    ) -> LinkStatus {
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: destination.path) else {
            return .missing
        }
        let resolved = URL(fileURLWithPath: target, relativeTo: destination.deletingLastPathComponent())
            .standardizedFileURL
        return resolved == expectedSource.standardizedFileURL ? .ready : .staleTarget(resolved.path)
    }

    private func installLink(source: URL, destination: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: source.path) else {
            throw AgentRuntimeManagerError.installedRuntimeInvalid(
                "Executable source is missing at \(source.path)."
            )
        }
        try fileManager.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = binDirectory.appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(at: temporary, withDestinationURL: source.standardizedFileURL)
        if fileManager.fileExists(atPath: destination.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
    }
}
