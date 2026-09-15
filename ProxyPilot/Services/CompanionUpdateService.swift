import Foundation
import CryptoKit
import Darwin

/// Reconciles existing user-installed CLI copies with the signed app payload.
/// Runs after each app launch so Sparkle and manual app replacement behave alike.
enum CompanionUpdateService {
    struct Result: Sendable {
        var updated: [String] = []
        var needsAttention: [String] = []
        var protectedDestinations: [URL] = []
    }

    static func candidates(home: URL) -> [URL] {
        [home.appendingPathComponent(".local/bin/proxypilot"),
         home.appendingPathComponent("bin/proxypilot"),
         URL(fileURLWithPath: "/usr/local/bin/proxypilot"),
         URL(fileURLWithPath: "/opt/homebrew/bin/proxypilot")]
    }

    static func reconcile(source: URL, destinations: [URL], sourceVersion: String) -> Result {
        var result = Result()
        let fm = FileManager.default
        guard let payload = try? Data(contentsOf: source), !payload.isEmpty else {
            result.needsAttention = ["Bundled CLI is unavailable."]
            return result
        }
        let digest = SHA256.hash(data: payload)
        for destination in destinations where fm.isExecutableFile(atPath: destination.path) {
            do {
                let attributes = try fm.attributesOfItem(atPath: destination.path)
                // Package-manager links retain their ownership and update mechanism.
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    if let installed = try? Data(contentsOf: destination), SHA256.hash(data: installed) == digest { continue }
                    result.needsAttention.append("Update the linked CLI using its installer: \(destination.path)")
                    continue
                }
                if let installed = try? Data(contentsOf: destination), SHA256.hash(data: installed) == digest { continue }
                guard let installedVersion = version(at: destination) else {
                    result.needsAttention.append("Could not verify CLI version: \(destination.path)")
                    continue
                }
                if installedVersion.compare(sourceVersion, options: .numeric) == .orderedDescending { continue }
                guard fm.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
                    result.needsAttention.append("Administrator update required: \(destination.path)")
                    result.protectedDestinations.append(destination)
                    continue
                }
                try replace(source: source, destination: destination)
                result.updated.append(destination.path)
            } catch {
                result.needsAttention.append("\(destination.path): \(error.localizedDescription)")
            }
        }
        return result
    }

    static func replace(source: URL, destination: URL) throws {
        let fm = FileManager.default
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".proxypilot-update-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: source, to: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        let expected = SHA256.hash(data: try Data(contentsOf: source))
        guard SHA256.hash(data: try Data(contentsOf: staged)) == expected else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard rename(staged.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard SHA256.hash(data: try Data(contentsOf: destination)) == expected else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    @MainActor
    static func authorizeProtectedUpdates(source: URL, destinations: [URL]) -> String? {
        guard !destinations.isEmpty else { return nil }
        let commands = destinations.map { destination in
            let stage = destination.deletingLastPathComponent().appendingPathComponent(".proxypilot-update-" + UUID().uuidString)
            return "/usr/bin/install -m 755 " + ShellArgumentEscaper.singleQuote(source.path) + " "
                + ShellArgumentEscaper.singleQuote(stage.path) + " && /bin/mv -f "
                + ShellArgumentEscaper.singleQuote(stage.path) + " " + ShellArgumentEscaper.singleQuote(destination.path)
        }.joined(separator: " && ")
        let literal = commands.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        guard let script = NSAppleScript(source: "do shell script \"" + literal + "\" with administrator privileges") else {
            return "Could not prepare administrator authorization."
        }
        script.executeAndReturnError(&error)
        return error?[NSAppleScript.errorMessage] as? String
    }

    private static func version(at executable: URL) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
