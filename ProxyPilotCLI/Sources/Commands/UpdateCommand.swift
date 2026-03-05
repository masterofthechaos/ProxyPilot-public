import ArgumentParser
import Foundation

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for and install ProxyPilot CLI updates."
    )

    @Flag(name: .long, help: "Check for updates without installing.")
    var check: Bool = false

    @Option(name: .long, help: "Install a specific version instead of latest (e.g. 1.2.0).")
    var version: String?

    @Option(name: .long, help: "Override install path (default: currently running proxypilot path).")
    var installPath: String?

    @Flag(name: .long, help: "Skip cleanup of legacy versioned binaries in the install directory.")
    var noPrune: Bool = false

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    private static let manifestURL = URL(string: "https://micah.chat/downloads/proxypilot-versions.json")!
    private static let downloadsBaseURL = URL(string: "https://micah.chat/downloads")!
    private static let updateSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    mutating func run() async throws {
        let currentVersion = ProxyPilotCommand.configuration.version

        let manifest: VersionsManifest
        do {
            manifest = try await fetchManifest()
        } catch {
            OutputFormatter.error(
                code: "E020",
                message: "Failed to fetch version manifest: \(error.localizedDescription)",
                suggestion: "Check your network connection and retry.",
                json: json
            )
            throw ExitCode.failure
        }

        let targetVersion = version ?? manifest.latest
        guard let targetComponents = parseVersion(targetVersion) else {
            OutputFormatter.error(
                code: "E021",
                message: "Invalid target version '\(targetVersion)'.",
                suggestion: "Use semantic version format like 1.2.0.",
                json: json
            )
            throw ExitCode.failure
        }

        guard let currentComponents = parseVersion(currentVersion) else {
            OutputFormatter.error(
                code: "E021",
                message: "Current CLI version '\(currentVersion)' is invalid.",
                suggestion: "Reinstall ProxyPilot CLI.",
                json: json
            )
            throw ExitCode.failure
        }

        let comparison = compareVersionComponents(targetComponents, currentComponents)

        if comparison == .orderedSame {
            OutputFormatter.success(
                data: [
                    "status": "up-to-date",
                    "version": currentVersion,
                ],
                humanMessage: "ProxyPilot CLI is already up-to-date (v\(currentVersion)).",
                json: json
            )
            return
        }

        if comparison == .orderedAscending && version == nil {
            OutputFormatter.success(
                data: [
                    "status": "ahead",
                    "installed": currentVersion,
                    "latest": manifest.latest,
                ],
                humanMessage: "Installed version (v\(currentVersion)) is newer than manifest latest (v\(manifest.latest)).",
                json: json
            )
            return
        }

        if check {
            OutputFormatter.success(
                data: [
                    "status": "update-available",
                    "installed": currentVersion,
                    "latest": targetVersion,
                ],
                humanMessage: "Update available: v\(currentVersion) -> v\(targetVersion).",
                json: json
            )
            return
        }

        let installURL: URL
        do {
            installURL = try resolveInstallURL()
        } catch {
            OutputFormatter.error(
                code: "E022",
                message: "Unable to resolve install path: \(error.localizedDescription)",
                suggestion: "Pass --install-path explicitly (for example /usr/local/bin/proxypilot).",
                json: json
            )
            throw ExitCode.failure
        }

        if installURL.path.contains("/Cellar/") || installURL.path.contains("/Homebrew/") {
            OutputFormatter.error(
                code: "E027",
                message: "This install appears to be managed by Homebrew (\(installURL.path)).",
                suggestion: "Use 'brew upgrade proxypilot' instead.",
                json: json
            )
            throw ExitCode.failure
        }

        let installDir = installURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: installDir.path) {
            do {
                try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
            } catch {
                OutputFormatter.error(
                    code: "E022",
                    message: "Cannot create install directory \(installDir.path): \(error.localizedDescription)",
                    suggestion: "Choose a writable directory with --install-path.",
                    json: json
                )
                throw ExitCode.failure
            }
        }

        guard FileManager.default.isWritableFile(atPath: installDir.path) else {
            OutputFormatter.error(
                code: "E022",
                message: "Install directory is not writable: \(installDir.path)",
                suggestion: "Run with sudo or choose a writable --install-path.",
                json: json
            )
            throw ExitCode.failure
        }

        let binaryURL = Self.downloadsBaseURL.appendingPathComponent("proxypilot-v\(targetVersion)")
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proxypilot-update-\(UUID().uuidString)")

        do {
            try await downloadBinary(from: binaryURL, to: tempURL)
        } catch {
            OutputFormatter.error(
                code: "E023",
                message: "Failed to download v\(targetVersion): \(error.localizedDescription)",
                suggestion: "Retry later or verify downloads are reachable.",
                json: json
            )
            throw ExitCode.failure
        }

        do {
            try installBinary(from: tempURL, to: installURL)
        } catch {
            OutputFormatter.error(
                code: "E024",
                message: "Failed to install update to \(installURL.path): \(error.localizedDescription)",
                suggestion: "Retry with sudo or choose a writable --install-path.",
                json: json
            )
            throw ExitCode.failure
        }

        let removedLegacy = noPrune ? [] : pruneLegacyBinaries(in: installDir, activeBinaryName: installURL.lastPathComponent)
        let removedSuffix = removedLegacy.isEmpty
            ? ""
            : "\nRemoved legacy binaries: \(removedLegacy.joined(separator: ", "))"

        OutputFormatter.success(
            data: [
                "status": "updated",
                "from": currentVersion,
                "to": targetVersion,
                "path": installURL.path,
                "removed_legacy_binaries": removedLegacy,
            ],
            humanMessage: "Updated ProxyPilot CLI v\(currentVersion) -> v\(targetVersion) at \(installURL.path)\(removedSuffix)",
            json: json
        )
    }

    private func fetchManifest() async throws -> VersionsManifest {
        let request = URLRequest(url: Self.manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await Self.updateSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw UpdateError.badStatus(http.statusCode)
        }
        return try JSONDecoder().decode(VersionsManifest.self, from: data)
    }

    private func resolveInstallURL() throws -> URL {
        if let installPath, !installPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: installPath).standardizedFileURL.resolvingSymlinksInPath()
        }

        guard let executable = CommandLine.arguments.first else {
            throw UpdateError.cannotResolveInstallPath
        }

        if executable.contains("/") {
            return URL(fileURLWithPath: executable).standardizedFileURL.resolvingSymlinksInPath()
        }

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for segment in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(segment)).appendingPathComponent(executable)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate.standardizedFileURL.resolvingSymlinksInPath()
                }
            }
        }

        throw UpdateError.cannotResolveInstallPath
    }

    private func downloadBinary(from sourceURL: URL, to destinationURL: URL) async throws {
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        let request = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data, response) = try await Self.updateSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw UpdateError.badStatus(http.statusCode)
        }
        guard !data.isEmpty else {
            throw UpdateError.emptyDownload
        }

        try data.write(to: destinationURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
    }

    private func installBinary(from sourceURL: URL, to installURL: URL) throws {
        let fileManager = FileManager.default
        let backupURL = installURL.deletingLastPathComponent()
            .appendingPathComponent(".proxypilot-backup-\(UUID().uuidString)")

        if fileManager.fileExists(atPath: installURL.path) {
            try fileManager.moveItem(at: installURL, to: backupURL)
            do {
                try fileManager.moveItem(at: sourceURL, to: installURL)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installURL.path)
                try? fileManager.removeItem(at: backupURL)
            } catch {
                try? fileManager.removeItem(at: installURL)
                try? fileManager.moveItem(at: backupURL, to: installURL)
                throw error
            }
        } else {
            try fileManager.moveItem(at: sourceURL, to: installURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installURL.path)
        }
    }

    private func pruneLegacyBinaries(in directory: URL, activeBinaryName: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: #"^proxypilot-v[0-9]+(\.[0-9]+)*$"#)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        var removed: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name != activeBinaryName else { continue }
            guard let regex else { continue }
            let range = NSRange(location: 0, length: name.utf16.count)
            guard regex.firstMatch(in: name, options: [], range: range) != nil else { continue }

            do {
                try FileManager.default.removeItem(at: entry)
                removed.append(name)
            } catch {
                continue
            }
        }

        return removed.sorted()
    }

    private func parseVersion(_ version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let core = trimmed.split(separator: "-", maxSplits: 1).first.map(String.init) ?? trimmed
        let parts = core.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        var components: [Int] = []
        for part in parts {
            guard let value = Int(part) else { return nil }
            components.append(value)
        }
        return components
    }

    private func compareVersionComponents(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let length = max(lhs.count, rhs.count)
        for index in 0..<length {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private struct VersionsManifest: Decodable {
        let latest: String
    }

    private enum UpdateError: LocalizedError {
        case invalidResponse
        case badStatus(Int)
        case emptyDownload
        case cannotResolveInstallPath

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid response from update endpoint."
            case .badStatus(let status):
                return "HTTP status \(status)"
            case .emptyDownload:
                return "Downloaded file was empty."
            case .cannotResolveInstallPath:
                return "Could not determine current binary path."
            }
        }
    }
}
