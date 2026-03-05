import Foundation

public enum ModelDiscovery {

    public enum Error: Swift.Error {
        case invalidJSON
        case httpError(statusCode: Int)
        case networkError(Swift.Error)
    }

    /// Parse model IDs from an OpenAI-compatible /v1/models JSON response.
    public static func parseModelIDs(from data: Data) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["data"] as? [[String: Any]] else {
            throw Error.invalidJSON
        }
        return models.compactMap { $0["id"] as? String }.sorted()
    }

    /// Fetch model IDs from an upstream provider.
    public static func fetchModels(baseURL: String, apiKey: String?) async throws -> [String] {
        try await fetchModels(provider: .openAI, baseURL: baseURL, apiKey: apiKey)
    }

    /// Fetch model IDs from an upstream provider using provider-specific auth and route rules.
    public static func fetchModels(
        provider: UpstreamProvider,
        baseURL: String,
        apiKey: String?
    ) async throws -> [String] {
        var normalizedBaseURL = baseURL
        while normalizedBaseURL.hasSuffix("/") {
            normalizedBaseURL.removeLast()
        }
        let urlString = normalizedBaseURL + provider.modelsPath
        guard let components = URLComponents(string: urlString) else { throw Error.invalidJSON }

        guard let url = components.url else { throw Error.invalidJSON }

        var request = URLRequest(url: url, timeoutInterval: 15)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Error.networkError(error)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Error.httpError(statusCode: http.statusCode)
        }

        return try parseModelIDs(from: data)
    }

    /// Filter to only :exacto suffixed models (OpenRouter).
    public static func filterExacto(_ models: [String]) -> [String] {
        models.filter { $0.hasSuffix(":exacto") }
    }

    /// Filter to only verified models.
    public static func filterVerified(_ models: [String], verified: VerifiedModels) -> [String] {
        models.filter { verified.contains($0) }
    }
}
