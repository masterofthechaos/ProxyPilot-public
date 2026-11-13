#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Same immutable upstream release used by RepoGPS; no dependency on its mutable install.
public struct AgentRuntimeRelease: Equatable, Sendable {
    public struct Archive: Equatable, Sendable {
        public let url: URL
        public let sha256: String
        public init(url: URL, sha256: String) { self.url = url; self.sha256 = sha256 }
    }
    public let engineVersion: String
    public let archives: [String: Archive]
    public init(engineVersion: String, archives: [String: Archive]) {
        self.engineVersion = engineVersion; self.archives = archives
    }
    public static let pinned = AgentRuntimeRelease(engineVersion: "1.18.4", archives: [
        "arm64": Archive(url: URL(string: "https://github.com/anomalyco/opencode/releases/download/v1.18.4/opencode-darwin-arm64.zip")!, sha256: "04fb881b632b323c712dfda6dcbbc6fce736394f07ba76176e52d6665925d4e6"),
        "x86_64": Archive(url: URL(string: "https://github.com/anomalyco/opencode/releases/download/v1.18.4/opencode-darwin-x64-baseline.zip")!, sha256: "80a20e20a1b99cbe9e544f9f450d9b7bd758ed2c76c4f4c5d28b9f74aeca322e"),
    ])
}

public struct AgentRuntimeManifest: Codable, Equatable, Sendable {
    public static let currentSchema = 2
    public let schema: Int
    public let engine: String
    public let engineVersion: String
    public let architecture: String
    public let archiveSHA256: String
    public let executableSHA256: String
    public let installedAt: Date
    public init(schema: Int = currentSchema, engine: String = "opencode", engineVersion: String,
                architecture: String, archiveSHA256: String, executableSHA256: String, installedAt: Date = Date()) {
        self.schema = schema; self.engine = engine; self.engineVersion = engineVersion
        self.architecture = architecture; self.archiveSHA256 = archiveSHA256
        self.executableSHA256 = executableSHA256; self.installedAt = installedAt
    }
}

public enum AgentRuntimeStatus: Equatable, Sendable {
    case notInstalled
    case ready(AgentRuntimeManifest)
    case stale(reason: String, manifest: AgentRuntimeManifest?)
    case corrupt(reason: String, manifest: AgentRuntimeManifest?)
    public var isReady: Bool { if case .ready = self { return true }; return false }
}

public enum AgentRuntimeManagerError: LocalizedError, Equatable {
    case unsupportedPlatform
    case unsupportedArchitecture(String)
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case installedRuntimeInvalid(String)
    case atomicInstallFailed(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform: "Managed ProxyPilot Agent installation is supported on macOS only."
        case .unsupportedArchitecture(let a): "No managed OpenCode runtime is available for architecture \(a)."
        case .downloadFailed(let d): "Could not download OpenCode: \(d)"
        case .checksumMismatch(let e, let a): "OpenCode archive integrity mismatch (expected \(e), got \(a))."
        case .extractionFailed(let d): "Could not extract OpenCode: \(d)"
        case .installedRuntimeInvalid(let d): "The managed OpenCode runtime is incomplete: \(d)"
        case .atomicInstallFailed(let d): "Could not activate OpenCode: \(d)"
        }
    }
}

public struct AgentRuntimeManager: Sendable {
    public let layout: ManagedAgentRuntimeLayout
    public let release: AgentRuntimeRelease
    public let architecture: String
    public var manifestURL: URL { layout.root.appendingPathComponent("proxypilot-runtime.json") }
    public init(layout: ManagedAgentRuntimeLayout = .standard(), release: AgentRuntimeRelease = .pinned,
                architecture: String = AgentRuntimeManager.currentArchitecture) {
        self.layout = layout; self.release = release; self.architecture = architecture
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
        guard fileManager.fileExists(atPath: layout.root.path) else { return .notInstalled }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: manifestURL) else {
            return .corrupt(reason: "Runtime manifest is missing or unreadable.", manifest: nil)
        }
        // Recognize old Claude manifests without deleting their runtime or sessions.
        guard let manifest = try? decoder.decode(AgentRuntimeManifest.self, from: data) else {
            return .stale(reason: "Install the OpenCode runtime for ProxyPilot Agent.", manifest: nil)
        }
        guard manifest.schema == AgentRuntimeManifest.currentSchema, manifest.engine == "opencode",
              manifest.engineVersion == release.engineVersion, manifest.architecture == architecture,
              manifest.archiveSHA256 == release.archives[architecture]?.sha256 else {
            return .stale(reason: "Installed runtime does not match the pinned OpenCode release.", manifest: manifest)
        }
        guard fileManager.isExecutableFile(atPath: layout.engineExecutable.path),
              let hash = try? Self.sha256(of: layout.engineExecutable), hash == manifest.executableSHA256 else {
            return .corrupt(reason: "Managed OpenCode executable is missing or its hash changed.", manifest: manifest)
        }
        return .ready(manifest)
    }
    public func install() async throws -> AgentRuntimeManifest {
        #if os(macOS)
        if case .ready(let manifest) = status() { return manifest }
        guard let archive = release.archives[architecture] else {
            throw AgentRuntimeManagerError.unsupportedArchitecture(architecture)
        }
        let fm = FileManager.default, parent = layout.root.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = parent.appendingPathComponent(".opencode-install-\(UUID().uuidString)")
        let zip = parent.appendingPathComponent(".opencode-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: stage); try? fm.removeItem(at: zip) }
        do {
            let (temp, response) = try await URLSession.shared.download(from: archive.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw AgentRuntimeManagerError.downloadFailed("The server did not return HTTP 200.")
            }
            try fm.moveItem(at: temp, to: zip)
        } catch let error as AgentRuntimeManagerError { throw error }
        catch { throw AgentRuntimeManagerError.downloadFailed(error.localizedDescription) }
        let hash = try Self.sha256(of: zip)
        guard hash == archive.sha256 else { throw AgentRuntimeManagerError.checksumMismatch(expected: archive.sha256, actual: hash) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.run("/usr/bin/unzip", ["-q", zip.path, "-d", stage.path])
        let engine = stage.appendingPathComponent("opencode")
        guard fm.isExecutableFile(atPath: engine.path) else {
            throw AgentRuntimeManagerError.installedRuntimeInvalid("The archive contains no OpenCode executable.")
        }
        // Xcode executes this separately from the signed app. Sign before hashing.
        try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", engine.path])
        let manifest = AgentRuntimeManifest(engineVersion: release.engineVersion, architecture: architecture,
            archiveSHA256: hash, executableSHA256: try Self.sha256(of: engine))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestPath = stage.appendingPathComponent("proxypilot-runtime.json")
        try encoder.encode(manifest).write(to: manifestPath, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestPath.path)
        // Verify the staged payload before moving the previous installation.
        let staged = AgentRuntimeManager(layout: .init(root: stage, configDirectory: layout.configDirectory), release: release, architecture: architecture)
        guard staged.status().isReady else { throw AgentRuntimeManagerError.installedRuntimeInvalid("Staged verification failed.") }
        let backup = parent.appendingPathComponent(".opencode-backup-\(UUID().uuidString)")
        let hadExisting = fm.fileExists(atPath: layout.root.path)
        do {
            if hadExisting { try fm.moveItem(at: layout.root, to: backup) }
            try fm.moveItem(at: stage, to: layout.root)
            guard status().isReady else { throw AgentRuntimeManagerError.installedRuntimeInvalid("Activated verification failed.") }
            if hadExisting { try? fm.removeItem(at: backup) }
        } catch {
            if fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: layout.root); try? fm.moveItem(at: backup, to: layout.root)
            }
            throw AgentRuntimeManagerError.atomicInstallFailed(error.localizedDescription)
        }
        return manifest
        #else
        throw AgentRuntimeManagerError.unsupportedPlatform
        #endif
    }
    public func remove(fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: layout.root.path) { try fileManager.removeItem(at: layout.root) }
    }
    static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
    private static func run(_ path: String, _ arguments: [String]) throws {
        // File-backed output avoids a full pipe deadlock during extraction/signing.
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("pp-runtime-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: logURL) }
        let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = log; process.standardError = log
        process.environment = ["PATH": "/usr/bin:/bin"]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AgentRuntimeManagerError.extractionFailed(String(decoding: try Data(contentsOf: logURL).suffix(4096), as: UTF8.self))
        }
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
