import ArgumentParser
import Foundation
import ProxyPilotCore

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "List available models from an upstream provider."
    )

    @Option(name: .long, help: "Upstream provider (openai, groq, zai, openrouter, xai, chutes, google, deepseek, mistral, minimax, minimax-cn, ollama, lmstudio).")
    var provider: String = "openai"

    @Option(name: .long, help: "Override the upstream API base URL.")
    var url: String?

    @Option(name: .long, help: "Upstream API key. Falls back to keychain/secrets store if omitted.")
    var key: String?

    @Option(name: .long, help: "Filter: 'exacto' for OpenRouter :exacto models, 'verified' for ProxyPilot Verified models.")
    var filter: String?

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    mutating func run() async throws {
        guard let upstream = UpstreamProvider(rawValue: provider) else {
            OutputFormatter.error(
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
                code: "E005",
                message: "Failed to fetch models: \(error)",
                suggestion: "Check your API key and provider URL.",
                json: json
            )
            throw ExitCode.failure
        }

        // Apply filters
        if filter == "exacto" {
            models = ModelDiscovery.filterExacto(models)
        } else if filter == "verified" {
            let verifiedURL = URL(string: "https://micah.chat/proxypilot/verified-models.json")!
            let entries = await VerifiedModels.fetchRemote(from: verifiedURL)
            let verified = VerifiedModels(entries: entries)
            models = ModelDiscovery.filterVerified(models, verified: verified)
        }

        if json {
            OutputFormatter.success(
                data: ["models": models, "count": models.count],
                humanMessage: "",
                json: true
            )
        } else {
            if models.isEmpty {
                print("No models found.")
            } else {
                for (i, model) in models.enumerated() {
                    print("  \(i + 1). \(model)")
                }
                print("\n\(models.count) models available.")
            }
        }
    }
}
