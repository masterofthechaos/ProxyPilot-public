import Foundation

struct XcodeInstallation: Identifiable, Sendable {
    let id: String
    let path: URL
    let version: String
    let buildNumber: String
    let isBeta: Bool
    let supportsAgenticCoding: Bool
    let claudeBinaryVersion: String?
    let configPath: String
}

final class XcodeDetectionService: Sendable {

    static let minimumAgenticVersion = "26.3"
    static let configRelativePath = "Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig"

    func detectInstallations() async -> [XcodeInstallation] {
        // Combine all discovery methods — mdfind, xcode-select, and hardcoded paths
        var paths = await discoverXcodePaths()
        paths += xcodeSelectPath()
        paths += fallbackPaths()
        // Deduplicate by resolved path
        var seen = Set<String>()
        paths = paths.filter { seen.insert($0.standardizedFileURL.path).inserted }
        return paths.compactMap { parseXcodeBundle(at: $0) }
            .sorted { $0.version > $1.version }
    }

    private func discoverXcodePaths() async -> [URL] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func xcodeSelectPath() -> [URL] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return [] }

        // xcode-select -p returns e.g. /path/to/Xcode.app/Contents/Developer
        // Walk up to find the .app bundle
        var url = URL(fileURLWithPath: output)
        while url.path != "/" {
            if url.pathExtension == "app" {
                return FileManager.default.fileExists(atPath: url.path) ? [url] : []
            }
            url = url.deletingLastPathComponent()
        }
        return []
    }

    private func fallbackPaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/Xcode.app",
            "/Applications/Xcode-beta.app",
            "\(home)/Downloads/Xcode.app",
            "\(home)/Downloads/Xcode-beta.app",
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func parseXcodeBundle(at path: URL) -> XcodeInstallation? {
        let plistURL = path.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }

        guard let bundleID = plist["CFBundleIdentifier"] as? String,
              bundleID == "com.apple.dt.Xcode" else {
            return nil
        }

        let version = plist["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = plist["DTXcodeBuild"] as? String ?? plist["CFBundleVersion"] as? String ?? "?"
        let isBeta = path.lastPathComponent.localizedCaseInsensitiveContains("beta")

        let supportsAgentic = Self.versionCompare(version, isAtLeast: Self.minimumAgenticVersion)
        let claudeVersion = detectClaudeBinaryVersion(for: version)

        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home.appendingPathComponent(Self.configRelativePath).path

        return XcodeInstallation(
            id: path.path,
            path: path,
            version: version,
            buildNumber: build,
            isBeta: isBeta,
            supportsAgenticCoding: supportsAgentic,
            claudeBinaryVersion: claudeVersion,
            configPath: configPath
        )
    }

    private func detectClaudeBinaryVersion(for xcodeVersion: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudePath = home
            .appendingPathComponent("Library/Developer/Xcode/CodingAssistant/Agents/Versions")
            .appendingPathComponent(xcodeVersion)
            .appendingPathComponent("claude")

        if FileManager.default.fileExists(atPath: claudePath.path) {
            return xcodeVersion
        }
        return nil
    }

    static func versionCompare(_ version: String, isAtLeast minimum: String) -> Bool {
        let v1 = version.split(separator: ".").compactMap { Int($0) }
        let v2 = minimum.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(v1.count, v2.count) {
            let a = i < v1.count ? v1[i] : 0
            let b = i < v2.count ? v2[i] : 0
            if a < b { return false }
            if a > b { return true }
        }
        return true
    }
}
