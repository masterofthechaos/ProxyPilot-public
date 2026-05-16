import Foundation
import ProxyPilotCore

struct CLIStartModelResolution: Equatable {
    let models: [String]
    let wasDiscoveredFromUpstream: Bool
}

enum CLIStartModelResolver {
    enum ResolutionError: Error, Equatable, LocalizedError {
        case noModelsDiscovered(provider: UpstreamProvider, baseURL: String)

        var errorDescription: String? {
            switch self {
            case .noModelsDiscovered(let provider, let baseURL):
                return "No \(provider.title) models were discovered at \(baseURL)."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .noModelsDiscovered(let provider, _):
                if provider == .ollama {
                    return "Pull a model on the Ollama server, verify OLLAMA_HOST exposes it on the LAN, or pass --model <id>."
                }
                return "Load a model in \(provider.title), verify the local server is reachable, or pass --model <id>."
            }
        }
    }

    typealias DiscoverModels = (UpstreamProvider, String, String?) async throws -> [String]

    static func resolve(
        rawModels: String?,
        provider: UpstreamProvider,
        upstreamURL: String?,
        apiKey: String?,
        discoverModels: @escaping DiscoverModels = { provider, baseURL, apiKey in
            try await ModelDiscovery.fetchModels(provider: provider, baseURL: baseURL, apiKey: apiKey)
        }
    ) async throws -> CLIStartModelResolution {
        let explicitModels = parsedModelList(rawModels)
        if !explicitModels.isEmpty {
            return CLIStartModelResolution(models: explicitModels, wasDiscoveredFromUpstream: false)
        }

        if let fallback = provider.fallbackModelIDs, !fallback.isEmpty {
            return CLIStartModelResolution(models: fallback, wasDiscoveredFromUpstream: false)
        }

        guard provider.isLocal else {
            return CLIStartModelResolution(models: [], wasDiscoveredFromUpstream: false)
        }

        let baseURL = normalizedBaseURL(upstreamURL, provider: provider)
        let discovered = try await discoverModels(provider, baseURL, apiKey)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !discovered.isEmpty else {
            throw ResolutionError.noModelsDiscovered(provider: provider, baseURL: baseURL)
        }

        return CLIStartModelResolution(models: discovered, wasDiscoveredFromUpstream: true)
    }

    private static func parsedModelList(_ rawModels: String?) -> [String] {
        rawModels?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    private static func normalizedBaseURL(_ upstreamURL: String?, provider: UpstreamProvider) -> String {
        let trimmed = upstreamURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? provider.defaultAPIBaseURL : trimmed
    }
}
