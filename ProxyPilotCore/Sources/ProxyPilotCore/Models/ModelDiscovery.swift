import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ModelDiscovery {

    private final class RejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

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
    /// Strips trailing slashes and known endpoint suffixes so that appending
    /// `provider.modelsPath` never produces a double-path like `/v1/models/models`.
    static func normalizeDiscoveryBaseURL(_ baseURL: String) -> String {
        var normalized = baseURL
        while normalized.hasSuffix("/") { normalized.removeLast() }
        if normalized.hasSuffix("/models") {
            normalized = String(normalized.dropLast("/models".count))
        }
        return normalized
    }

    public static func fetchModels(
        provider: UpstreamProvider,
        baseURL: String,
        apiKey: String?
    ) async throws -> [String] {
        let normalizedBaseURL = normalizeDiscoveryBaseURL(baseURL)
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
            let session = URLSession(
                configuration: .ephemeral,
                delegate: RejectRedirectDelegate(),
                delegateQueue: nil
            )
            defer { session.invalidateAndCancel() }
            (data, response) = try await session.data(for: request)
        } catch {
            throw Error.networkError(error)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if shouldUseFallbackModels(for: provider, statusCode: http.statusCode) {
                return provider.fallbackModelIDs ?? []
            }
            throw Error.httpError(statusCode: http.statusCode)
        }

        let normalized = AnthropicTranslator.normalizeOpenAICompatibleResponse(
            statusCode: 200,
            responseData: data,
            provider: provider
        )
        if normalized.statusCode != 200 {
            throw Error.httpError(statusCode: normalized.statusCode)
        }

        do {
            return try parseModelIDs(from: normalized.data)
        } catch Error.invalidJSON {
            if let fallback = provider.fallbackModelIDs {
                return fallback
            }
            throw Error.invalidJSON
        }
    }

    /// Convert model IDs to explicit OpenRouter :exacto variants.
    ///
    /// OpenRouter now treats :exacto as a virtual suffix instead of listing
    /// separate endpoint records, so callers that only have IDs should preserve
    /// the old CLI/MCP affordance by returning explicit :exacto slugs.
    public static func filterExacto(_ models: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for model in models {
            let base = model.hasSuffix(":exacto") ? String(model.dropLast(":exacto".count)) : model
            let exacto = base + ":exacto"
            if seen.insert(exacto).inserted {
                result.append(exacto)
            }
        }

        return result
    }

    /// Filter to only verified models.
    public static func filterVerified(_ models: [String], verified: VerifiedModels) -> [String] {
        models.filter { verified.contains($0) }
    }

    private static func shouldUseFallbackModels(for provider: UpstreamProvider, statusCode: Int) -> Bool {
        guard provider.fallbackModelIDs != nil else { return false }
        return [404, 405, 410, 501].contains(statusCode)
    }
}
