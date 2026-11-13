import Foundation
import ProxyPilotCore

struct CLIStartModelResolution: Equatable {
    let models: [String]
    let wasDiscoveredFromUpstream: Bool
}

enum CLIStartModelResolver {
    enum ResolutionError: Error, Equatable, LocalizedError {
        case noModelsDiscovered(provider: UpstreamProvider, baseURL: String)
        case unsafeLocalDiscoveryURL(provider: UpstreamProvider, baseURL: String)

        var errorDescription: String? {
            switch self {
            case .noModelsDiscovered(let provider, let baseURL):
                return "No \(provider.title) models were discovered at \(baseURL)."
            case .unsafeLocalDiscoveryURL(let provider, let baseURL):
                return "Refusing to discover \(provider.title) models from unsafe local-provider URL \(baseURL)."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .noModelsDiscovered(let provider, _):
                if provider == .ollama {
                    return "Pull a model on the Ollama server, verify OLLAMA_HOST exposes it on the LAN, or pass --model <id>."
                }
                return "Load a model in \(provider.title), verify the local server is reachable, or pass --model <id>."
            case .unsafeLocalDiscoveryURL:
                return "Use an http(s) URL with no userinfo, query, or fragment, and a loopback or private LAN host; otherwise pass --model <id> to skip discovery."
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

        let baseURL = normalizedBaseURL(upstreamURL, provider: provider)

        guard provider.isLocal || isSafeLocalDiscoveryURL(baseURL) else {
            return CLIStartModelResolution(models: [], wasDiscoveredFromUpstream: false)
        }

        guard isSafeLocalDiscoveryURL(baseURL) else {
            throw ResolutionError.unsafeLocalDiscoveryURL(provider: provider, baseURL: baseURL)
        }

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
        return trimmed.isEmpty ? provider.preferredAPIBaseURL : trimmed
    }

    private static func isSafeLocalDiscoveryURL(_ baseURL: String) -> Bool {
        guard let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return false
        }

        return isLoopbackOrPrivateLANHost(host)
    }

    private static func isLoopbackOrPrivateLANHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" {
            return true
        }

        let ipv6Host = lowered.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ipv6Host == "::1" || ipv6Host.hasPrefix("fe80:") || ipv6Host.hasPrefix("fc") || ipv6Host.hasPrefix("fd") {
            return true
        }

        let octets = lowered.split(separator: ".")
        guard octets.count == 4 else {
            return false
        }

        let parsedOctets = octets.compactMap { UInt8($0) }
        guard parsedOctets.count == 4 else {
            return false
        }

        let first = parsedOctets[0]
        let second = parsedOctets[1]
        return first == 10
            || first == 127
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
            || (first == 169 && second == 254)
    }
}
