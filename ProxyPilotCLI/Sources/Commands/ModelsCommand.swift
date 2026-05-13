import ArgumentParser
import Foundation
import ProxyPilotCore

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "List available models from an upstream provider."
    )

    @Option(name: .long, help: "Upstream provider (\(UpstreamProvider.cliOptionsDescription)).")
    var provider: String = ProxyPilotDefaults.defaultCLIProvider.rawValue

    @Option(name: .long, help: "Override the upstream API base URL.")
    var url: String?

    @Option(name: .long, help: "Upstream API key. Falls back to keychain/secrets store if omitted.")
    var key: String?

    @Option(name: .long, help: "Filter: exacto, verified, tool-calling, or chat.")
    var filter: String?

    @Flag(name: .long, help: "Emit model metadata objects instead of simple model IDs.")
    var metadata: Bool = false

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    mutating func run() async throws {
        let filterValidation = MCPArgumentValidator.modelFilter(filter, tool: "models")
        guard case .success(let validatedFilter) = filterValidation else {
            if case .failure(let code, let message) = filterValidation {
                OutputFormatter.error(
                    command: "models",
                    code: code,
                    message: message,
                    json: json
                )
            } else {
                OutputFormatter.error(
                    command: "models",
                    code: "E034",
                    message: "Invalid model filter.",
                    json: json
                )
            }
            throw ExitCode.failure
        }

        guard let upstream = UpstreamProvider(rawValue: provider) else {
            OutputFormatter.error(
                command: "models",
                code: "E001",
                message: "Unknown provider: \(provider)",
                suggestion: "Valid: \(UpstreamProvider.allCases.map(\.rawValue).joined(separator: ", "))",
                json: json
            )
            throw ExitCode.failure
        }

        // Resolve API key
        let secrets = SecretsProviderFactory.make()
        let secretKeyName = upstream.secretKey
        let apiKey: String? = if let key {
            key
        } else if let secretKeyName {
            ProcessInfo.processInfo.environment[secretKeyName]
                ?? (try? secrets.get(key: secretKeyName))
        } else {
            nil
        }

        let baseURL = url ?? upstream.defaultAPIBaseURL

        // Allow nil key for local providers
        if apiKey == nil && !upstream.isLocal && !isLocalhostURL(baseURL) {
            OutputFormatter.error(
                command: "models",
                code: "E004",
                message: "No API key found for provider \(upstream.rawValue).",
                suggestion: "Run 'proxypilot auth set --provider \(upstream.rawValue)', pass --key, or set \(secretKeyName ?? "the provider env var").",
                json: json
            )
            throw ExitCode.failure
        }

        var models: [String]
        do {
            models = try await ModelDiscovery.fetchModels(
                provider: upstream,
                baseURL: baseURL,
                apiKey: apiKey
            )
        } catch {
            OutputFormatter.error(
                command: "models",
                code: "E005",
                message: "Failed to fetch models: \(error)",
                suggestion: "Check your API key and provider URL.",
                json: json
            )
            throw ExitCode.failure
        }

        let needsVerified = metadata || validatedFilter == "verified"
        let verified: VerifiedModels
        if needsVerified {
            let verifiedURL = URL(string: "https://micah.chat/proxypilot/verified-models.json")!
            let entries = await VerifiedModels.fetchRemote(from: verifiedURL)
            verified = VerifiedModels(entries: entries)
        } else {
            verified = VerifiedModels(entries: [])
        }

        let summaries = ModelSummaryBuilder.summaries(ids: models, verified: verified)
        let filtered = ModelSummaryBuilder.apply(filter: validatedFilter, ids: models, summaries: summaries, verified: verified)
        models = filtered.0
        let modelSummaries = filtered.1

        if json {
            OutputFormatter.success(
                command: "models",
                data: ModelsPayload(
                    provider: upstream.rawValue,
                    count: metadata ? modelSummaries.count : models.count,
                    models: metadata ? nil : models,
                    modelSummaries: metadata ? modelSummaries : nil
                ),
                humanMessage: "",
                json: true
            )
        } else {
            if metadata {
                if modelSummaries.isEmpty {
                    print("No models found.")
                } else {
                    for (i, model) in modelSummaries.enumerated() {
                        let caps = model.capabilities.isEmpty ? "no known caps" : model.capabilities.joined(separator: ", ")
                        print("  \(i + 1). \(model.id) [\(caps)]")
                    }
                    print("\n\(modelSummaries.count) models available.")
                }
            } else if models.isEmpty {
                print("No models found.")
            } else {
                for (i, model) in models.enumerated() {
                    print("  \(i + 1). \(model)")
                }
                print("\n\(models.count) models available.")
            }
        }
    }

    private struct ModelsPayload: Encodable {
        let provider: String
        let count: Int
        let models: [String]?
        let modelSummaries: [ModelSummary]?

        enum CodingKeys: String, CodingKey {
            case provider
            case count
            case models
            case modelSummaries = "model_summaries"
        }
    }
}
