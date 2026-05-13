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

    @Flag(name: .long, help: "Verify the selected provider credential against the upstream models endpoint.")
    var verify: Bool = false

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    mutating func run() async throws {
        let secrets = SecretsProviderFactory.make()

        if let provider {
            guard let upstreamProvider = UpstreamProvider(rawValue: provider) else {
                OutputFormatter.error(
                    command: "auth status",
                    code: "E001",
                    message: "Unknown provider: \(provider)",
                    suggestion: "Valid: \(UpstreamProvider.allCases.map(\.rawValue).joined(separator: ", "))",
                    json: json
                )
                throw ExitCode.failure
            }

            let statusPayload: ProviderAuthPayload
            var message: String
            if upstreamProvider.requiresAPIKey, let secretKey = upstreamProvider.secretKey {
                let exists: Bool
                do {
                    exists = try secrets.exists(key: secretKey)
                } catch {
                    OutputFormatter.error(
                        command: "auth status",
                        code: "E044",
                        message: "Failed to read auth status for provider \(upstreamProvider.rawValue): \(error.localizedDescription)",
                        suggestion: "Verify secrets store accessibility and retry.",
                        json: json
                    )
                    throw ExitCode.failure
                }

                let backend = authBackendInfo(for: secrets)
                let statusText = exists ? "stored" : "not_set"
                var verification: AuthVerificationOutcome?
                if verify {
                    verification = await verifyCredential(
                        provider: upstreamProvider,
                        secretKey: secretKey,
                        exists: exists,
                        secrets: secrets
                    )
                }

                statusPayload = ProviderAuthPayload(
                    provider: upstreamProvider.rawValue,
                    status: statusText,
                    stored: exists,
                    backend: backend.label,
                    path: backend.filePath,
                    verified: verification?.verified,
                    verificationStatus: verification?.status,
                    verificationError: verification?.errorMessage,
                    modelCount: verification?.modelCount
                )
                message = "\(upstreamProvider.rawValue): \(statusText) (\(backend.label))"
                if let verification {
                    message += "; verification: \(verification.status)"
                    if let error = verification.errorMessage {
                        message += " - \(error)"
                    }
                }
            } else {
                let verification = verify
                    ? AuthVerificationSupport.outcome(for: upstreamProvider, apiKeyPresent: false, fetchResult: nil)
                    : nil
                statusPayload = ProviderAuthPayload(
                    provider: upstreamProvider.rawValue,
                    status: "not_required",
                    stored: false,
                    backend: "none",
                    path: nil,
                    verified: verification?.verified,
                    verificationStatus: verification?.status,
                    verificationError: verification?.errorMessage,
                    modelCount: verification?.modelCount
                )
                message = "\(upstreamProvider.rawValue): not_required (no API key needed)"
                if let verification {
                    message += "; verification: \(verification.status)"
                }
            }

            OutputFormatter.success(command: "auth status", data: statusPayload, humanMessage: message, json: json)
            return
        }

        if verify {
            OutputFormatter.error(
                command: "auth status",
                code: "E045",
                message: "--verify requires --provider.",
                suggestion: "Run 'proxypilot auth status --provider zai --verify'.",
                json: json
            )
            throw ExitCode.failure
        }

        var rows: [ProviderAuthPayload] = []
        var humanLines: [String] = ["provider       status         backend"]
        humanLines.append("-------------- ------------- --------")
        let backend = authBackendInfo(for: secrets)

        for upstreamProvider in UpstreamProvider.allCases {
            if upstreamProvider.requiresAPIKey, let secretKey = upstreamProvider.secretKey {
                let exists: Bool
                do {
                    exists = try secrets.exists(key: secretKey)
                } catch {
                    OutputFormatter.error(
                        command: "auth status",
                        code: "E044",
                        message: "Failed to read auth status for provider \(upstreamProvider.rawValue): \(error.localizedDescription)",
                        suggestion: "Verify secrets store accessibility and retry.",
                        json: json
                    )
                    throw ExitCode.failure
                }

                let statusText = exists ? "stored" : "not_set"
                rows.append(ProviderAuthPayload(
                    provider: upstreamProvider.rawValue,
                    status: statusText,
                    stored: exists,
                    backend: backend.label,
                    path: nil
                ))
                humanLines.append(
                    "\(pad(upstreamProvider.rawValue, to: 14)) \(pad(statusText, to: 13)) \(backend.label)"
                )
            } else {
                rows.append(ProviderAuthPayload(
                    provider: upstreamProvider.rawValue,
                    status: "not_required",
                    stored: false,
                    backend: "none",
                    path: nil
                ))
                humanLines.append(
                    "\(pad(upstreamProvider.rawValue, to: 14)) \(pad("not_required", to: 13)) none"
                )
            }
        }

        OutputFormatter.success(
            command: "auth status",
            data: ProvidersAuthPayload(providers: rows, path: backend.filePath),
            humanMessage: humanLines.joined(separator: "\n"),
            json: json
        )
    }

    private func pad(_ value: String, to width: Int) -> String {
        guard value.count < width else { return value }
        return value + String(repeating: " ", count: width - value.count)
    }

    private func verifyCredential(
        provider: UpstreamProvider,
        secretKey: String,
        exists: Bool,
        secrets: any SecretsProvider
    ) async -> AuthVerificationOutcome {
        guard exists else {
            return AuthVerificationSupport.outcome(
                for: provider,
                apiKeyPresent: false,
                fetchResult: nil
            )
        }

        let apiKey = ProcessInfo.processInfo.environment[secretKey]
            ?? (try? secrets.get(key: secretKey))

        guard let apiKey, !apiKey.isEmpty else {
            return AuthVerificationSupport.outcome(
                for: provider,
                apiKeyPresent: false,
                fetchResult: nil
            )
        }

        do {
            let models = try await ModelDiscovery.fetchModels(
                provider: provider,
                baseURL: provider.defaultAPIBaseURL,
                apiKey: apiKey
            )
            return AuthVerificationSupport.outcome(
                for: provider,
                apiKeyPresent: true,
                fetchResult: .success(models)
            )
        } catch {
            return AuthVerificationSupport.outcome(
                for: provider,
                apiKeyPresent: true,
                fetchResult: .failure(error)
            )
        }
    }
}
