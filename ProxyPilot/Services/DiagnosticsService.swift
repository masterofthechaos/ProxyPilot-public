import Foundation

struct DiagnosticsManifest: Codable {
    let appVersion: String
    let buildNumber: String
    let macOSVersion: String
    let mode: String
    let proxyURL: String
    let upstreamBase: String
    let selectedModel: String
    let recentIssueCodes: [String]
    let preflightSnapshot: [PreflightCheckResult]
    let timestamp: Date
}

struct DiagnosticsExportContext {
    let builtInLogURL: URL
    let toolchainLogURL: URL
    let liteLLMLogURL: URL
    let manifest: DiagnosticsManifest
}

final class DiagnosticsService: Sendable {
    func exportBundle(context: DiagnosticsExportContext) async throws -> URL {
        let fm = FileManager.default
        let ts = Int(Date().timeIntervalSince1970)
        let root = fm.temporaryDirectory.appendingPathComponent("ProxyPilot-Diagnostics-\(ts)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try writeRedactedFileIfPresent(source: context.builtInLogURL, destination: root.appendingPathComponent("builtin_proxy.log"))
        try writeRedactedFileIfPresent(source: context.toolchainLogURL, destination: root.appendingPathComponent("toolchain.log"))
        try writeRedactedFileIfPresent(source: context.liteLLMLogURL, destination: root.appendingPathComponent("litellm.log"))

        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifestData = try JSONEncoder.pretty.encode(context.manifest)
        try manifestData.write(to: manifestURL)

        let archiveURL = fm.temporaryDirectory.appendingPathComponent("ProxyPilot-Diagnostics-\(ts).zip")
        try? fm.removeItem(at: archiveURL)

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-qry", archiveURL.path, "."]
        zip.currentDirectoryURL = root

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            zip.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(domain: "ProxyPilot", code: 7001,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create diagnostics archive."]))
                }
            }
            do {
                try zip.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        return archiveURL
    }

    func buildSupportSummary(issueCodes: [String], manifest: DiagnosticsManifest, diagnosticsURL: URL?) -> String {
        let archiveText = diagnosticsURL?.path ?? "(not exported yet)"
        return """
        ProxyPilot Support Summary
        Version: \(manifest.appVersion) (\(manifest.buildNumber))
        macOS: \(manifest.macOSVersion)
        Mode: \(manifest.mode)
        Proxy URL: \(manifest.proxyURL)
        Upstream: \(manifest.upstreamBase)
        Selected Model: \(manifest.selectedModel)
        Recent Issue Codes: \(issueCodes.joined(separator: ", "))
        Diagnostics Archive: \(archiveText)
        """
    }

    private func writeRedactedFileIfPresent(source: URL, destination: URL) throws {
        guard let raw = try? String(contentsOf: source, encoding: .utf8) else { return }
        let redacted = Self.redactSecrets(in: raw)
        try redacted.write(to: destination, atomically: true, encoding: .utf8)
    }

    static func redactSecrets(in text: String) -> String {
        var output = text
        let rules: [(String, String)] = [
            (#"Bearer\s+[A-Za-z0-9._\-]+"#, "Bearer ***"),
            (#"(?i)(x-api-key\s*[:=]\s*)([^\s\"\']+)"#, "$1***"),
            (#"(?i)(api[-_ ]?key\s*[:=]\s*)([^\s\"\']+)"#, "$1***"),
            (#"(?i)(\"api_key\"\s*:\s*\")([^\"]+)(\")"#, "$1***$3")
        ]

        for (pattern, template) in rules {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(output.startIndex..<output.endIndex, in: output)
                output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: template)
            }
        }
        return output
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
