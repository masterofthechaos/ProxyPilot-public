import Foundation
import ProxyPilotCore

@MainActor
final class ProxyService {
    struct ProbeResult: Equatable {
        let statusCode: Int
        let isProxyPilot: Bool
    }
    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        _ = homeDirectory
    }

    func readLogTail(from logFile: URL, maxBytes: Int = 32_000) -> String {
        guard maxBytes > 0,
              let handle = try? FileHandle(forReadingFrom: logFile) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.read(upToCount: maxBytes)) ?? nil
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func normalizedUpstreamAPIBase(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return Self.normalizedUpstreamAPIBase(url)
    }

    static func normalizedUpstreamAPIBase(_ apiBase: URL) -> URL {
        guard var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false) else {
            return apiBase
        }

        var segments = components.path.split(separator: "/").map(String.init)
        let suffixes: [[String]] = [
            ["chat", "completions"],
            ["completions"],
            ["models"],
            ["responses"],
            ["embeddings"],
            ["messages"]
        ]

        func hasSuffix(_ candidate: [String], suffix: [String]) -> Bool {
            guard candidate.count >= suffix.count else { return false }
            return Array(candidate.suffix(suffix.count)).map { $0.lowercased() } == suffix
        }

        var stripped = true
        while stripped {
            stripped = false
            for suffix in suffixes {
                if hasSuffix(segments, suffix: suffix) {
                    segments.removeLast(suffix.count)
                    stripped = true
                    break
                }
            }
        }

        components.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url ?? apiBase
    }

    func fetchModels(baseURL: URL, masterKey: String?) async throws -> String {
        let url = baseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let masterKey,
           !masterKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(masterKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProxyServiceError.httpStatus(http.statusCode, body)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func probe(baseURL: URL) async throws -> ProbeResult {
        // We only care that something is listening and responding. Auth errors are still "up".
        let url = baseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            return ProbeResult(
                statusCode: http.statusCode,
                isProxyPilot: http.value(forHTTPHeaderField: "X-ProxyPilot-Server") == "1"
            )
        }
        return ProbeResult(statusCode: 0, isProxyPilot: false)
    }

    func fetchUpstreamModels(
        apiBase: URL,
        apiKey: String,
        provider: UpstreamProvider = .openAI
    ) async throws -> [UpstreamModel] {
        let modelsURL = Self.buildUpstreamURL(
            base: Self.normalizedUpstreamAPIBase(apiBase),
            path: provider.modelsPath
        )
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        applyUpstreamAuth(apiKey: apiKey, provider: provider, request: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if let fallback = fallbackModels(for: provider, statusCode: http.statusCode) {
                return fallback
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProxyServiceError.httpStatus(http.statusCode, body)
        }

        let normalized = AnthropicTranslator.normalizeOpenAICompatibleResponse(
            statusCode: 200,
            responseData: data,
            provider: provider
        )
        if normalized.statusCode != 200 {
            let body = String(data: normalized.data, encoding: .utf8) ?? ""
            throw ProxyServiceError.httpStatus(normalized.statusCode, body)
        }

        do {
            let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: normalized.data)
            return Self.upstreamModels(from: decoded, provider: provider)
        } catch {
            if let fallback = provider.fallbackModelIDs {
                return fallback.map(UpstreamModel.idOnly)
            }
            throw error
        }
    }

    /// Maps a decoded `/v1/models` payload onto `UpstreamModel`, converting per-token
    /// prices to per-million. Extracted from `fetchUpstreamModels` so the mapping —
    /// especially the cache-pricing rules below — is testable without a network round
    /// trip, following the same pure-helper split as `LocalProxyServerHelpers`.
    static func upstreamModels(
        from response: OpenAIModelsResponse,
        provider: UpstreamProvider
    ) -> [UpstreamModel] {
        response.data.map { model in
            let pricing = model.pricing
            let perMillion: (String?) -> Double? = { raw in
                raw.flatMap(Double.init).map { $0 * 1_000_000 }
            }

            let promptPer1M = perMillion(pricing?.prompt)
            let completionPer1M = perMillion(pricing?.completion)
            let cacheReadPer1M = perMillion(pricing?.inputCacheRead)
            let cacheWritePer1M = perMillion(pricing?.inputCacheWrite)

            // The hit/miss pair is only meaningful together: `prompt` *is* the uncached
            // input price, so it doubles as the miss price — but only once we know a
            // cache-read price exists. Populating the miss price unconditionally would
            // flip `pricingPerMillionLabel` into its "cached · uncached" form for every
            // model, including ones the provider does no caching for at all.
            let hitPer1M = cacheReadPer1M
            let missPer1M = cacheReadPer1M == nil ? nil : promptPer1M

            let discovered = UpstreamModel(
                id: model.id,
                contextLength: model.contextLength,
                promptPricePer1M: promptPer1M,
                completionPricePer1M: completionPer1M,
                promptCacheHitPricePer1M: hitPer1M,
                promptCacheMissPricePer1M: missPer1M,
                promptCacheWritePricePer1M: cacheWritePer1M,
                supportedParameters: Set(model.supportedParameters ?? [])
            )
            guard discovered.promptPricePer1M == nil,
                  discovered.completionPricePer1M == nil,
                  let known = provider.knownModelMetadata(for: model.id) else {
                return discovered
            }
            return known
        }.sorted { $0.id < $1.id }
    }

    func testUpstreamChat(
        apiBase: URL,
        apiKey: String,
        model: String,
        provider: UpstreamProvider = .openAI
    ) async throws -> String {
        let url = Self.buildUpstreamURL(
            base: Self.normalizedUpstreamAPIBase(apiBase),
            path: provider.chatCompletionsPath
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyUpstreamAuth(apiKey: apiKey, provider: provider, request: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a brief assistant."],
                ["role": "user", "content": "Reply with exactly: ok"]
            ],
            "temperature": 0.0,
            "max_tokens": 256
        ]
        AnthropicTranslator.stripUnsupportedParameters(&body, for: provider)
        AnthropicTranslator.applyParameterRewrites(&body, for: provider)
        AnthropicTranslator.clampTemperature(&body, for: provider)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw ProxyServiceError.httpStatus(http.statusCode, bodyText)
        }

        let normalized = AnthropicTranslator.normalizeOpenAICompatibleResponse(
            statusCode: 200,
            responseData: data,
            provider: provider
        )
        if normalized.statusCode != 200 {
            let bodyText = String(data: normalized.data, encoding: .utf8) ?? ""
            throw ProxyServiceError.httpStatus(normalized.statusCode, bodyText)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: normalized.data)
        return decoded.text ?? ""
    }

    private func fallbackModels(for provider: UpstreamProvider, statusCode: Int) -> [UpstreamModel]? {
        guard [404, 405, 410, 501].contains(statusCode),
              let fallback = provider.fallbackModelIDs else {
            return nil
        }
        return fallback.map(UpstreamModel.idOnly)
    }

    private static func buildUpstreamURL(
        base: URL,
        path: String
    ) -> URL {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return base.appendingPathComponent(normalizedPath)
    }

    private func applyUpstreamAuth(
        apiKey: String,
        provider: UpstreamProvider,
        request: inout URLRequest
    ) {
        guard !apiKey.isEmpty else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

}

struct OpenAIModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
        let contextLength: Int?
        let pricing: Pricing?
        let supportedParameters: [String]?

        /// Prices arrive as decimal strings in USD **per single token**
        /// (e.g. `"0.000002"`); `UpstreamModel` stores them per million.
        struct Pricing: Decodable {
            let prompt: String?
            let completion: String?
            let inputCacheRead: String?
            let inputCacheWrite: String?

            enum CodingKeys: String, CodingKey {
                case prompt
                case completion
                case inputCacheRead = "input_cache_read"
                case inputCacheWrite = "input_cache_write"
            }
        }

        enum CodingKeys: String, CodingKey {
            case id
            case contextLength = "context_length"
            case pricing
            case supportedParameters = "supported_parameters"
        }
    }
    let data: [Model]
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct ResponseMessage: Decodable {
            let content: String?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // Some providers (e.g., Mistral) may return content as an array
                // of typed parts instead of a plain string.
                if let str = try? container.decode(String.self, forKey: .content) {
                    content = str
                } else if let parts = try? container.decode([ContentPart].self, forKey: .content) {
                    content = parts.compactMap(\.text).joined()
                } else {
                    content = nil
                }
            }

            private struct ContentPart: Decodable {
                let text: String?
            }
            private enum CodingKeys: String, CodingKey { case content }
        }
        let message: ResponseMessage
    }

    let choices: [Choice]

    var text: String? {
        choices.first?.message.content
    }
}

enum ProxyServiceError: LocalizedError {
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status, let body):
            if body.isEmpty {
                return "HTTP \(status)"
            }
            return "HTTP \(status): \(body)"
        }
    }
}
