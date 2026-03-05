import ArgumentParser
import Foundation
import ProxyPilotCore

struct AuthStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show stored API key presence for one provider or all providers."
    )

    @Option(name: .long, help: "Upstream provider to check (optional).")
    var provider: String?

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    mutating func run() async throws {
        let secrets = SecretsProviderFactory.make()

        if let provider {
            guard let upstreamProvider = UpstreamProvider(rawValue: provider) else {
                OutputFormatter.error(
                    code: "E001",
                    message: "Unknown provider: \(provider)",
                    suggestion: "Valid: \(UpstreamProvider.allCases.map(\.rawValue).joined(separator: ", "))",
                    json: json
                )
                throw ExitCode.failure
            }

            let statusPayload: [String: Any]
            let message: String
            if upstreamProvider.requiresAPIKey, let secretKey = upstreamProvider.secretKey {
                let exists: Bool
                do {
                    exists = try secrets.exists(key: secretKey)
                } catch {
                    OutputFormatter.error(
                        code: "E044",
                        message: "Failed to read auth status for provider \(upstreamProvider.rawValue): \(error.localizedDescription)",
                        suggestion: "Verify secrets store accessibility and retry.",
                        json: json
                    )
                    throw ExitCode.failure
                }
                let backend = authBackendInfo(for: secrets)

                let statusText = exists ? "stored" : "not_set"
                statusPayload = [
                    "provider": upstreamProvider.rawValue,
                    "status": statusText,
                    "stored": exists,
                    "backend": backend.label,
                ]
                message = "\(upstreamProvider.rawValue): \(statusText) (\(backend.label))"
            } else {
                statusPayload = [
                    "provider": upstreamProvider.rawValue,
                    "status": "not_required",
                    "stored": false,
                    "backend": "none",
                ]
                message = "\(upstreamProvider.rawValue): not_required (no API key needed)"
            }

            var data = statusPayload
            let backend = authBackendInfo(for: secrets)
            if let filePath = backend.filePath {
                data["path"] = filePath
            }
            OutputFormatter.success(data: data, humanMessage: message, json: json)
            return
        }

        var rows: [[String: Any]] = []
        var humanLines: [String] = ["provider       status         backend"]
        humanLines.append("-------------- ------------- --------")

        for upstreamProvider in UpstreamProvider.allCases {
            if upstreamProvider.requiresAPIKey, let secretKey = upstreamProvider.secretKey {
                let exists: Bool
                do {
                    exists = try secrets.exists(key: secretKey)
                } catch {
                    OutputFormatter.error(
                        code: "E044",
                        message: "Failed to read auth status for provider \(upstreamProvider.rawValue): \(error.localizedDescription)",
                        suggestion: "Verify secrets store accessibility and retry.",
                        json: json
                    )
                    throw ExitCode.failure
                }
                let backend = authBackendInfo(for: secrets)

                let statusText = exists ? "stored" : "not_set"
                rows.append([
                    "provider": upstreamProvider.rawValue,
                    "status": statusText,
                    "stored": exists,
                    "backend": backend.label,
                ])
                humanLines.append(
                    "\(pad(upstreamProvider.rawValue, to: 14)) \(pad(statusText, to: 13)) \(backend.label)"
                )
            } else {
                rows.append([
                    "provider": upstreamProvider.rawValue,
                    "status": "not_required",
                    "stored": false,
                    "backend": "none",
                ])
                humanLines.append(
                    "\(pad(upstreamProvider.rawValue, to: 14)) \(pad("not_required", to: 13)) none"
                )
            }
        }

        let backend = authBackendInfo(for: secrets)
        var data: [String: Any] = ["providers": rows]
        if let filePath = backend.filePath {
            data["path"] = filePath
        }
        OutputFormatter.success(
            data: data,
            humanMessage: humanLines.joined(separator: "\n"),
            json: json
        )
    }

    private func pad(_ value: String, to width: Int) -> String {
        guard value.count < width else { return value }
        return value + String(repeating: " ", count: width - value.count)
    }
}
