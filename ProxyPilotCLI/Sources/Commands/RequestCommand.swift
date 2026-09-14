import ArgumentParser
import Foundation
import ProxyPilotCore

/// Runs one bounded, attributed request without changing the shared lead route.
/// The listener binds to an OS-selected loopback port and is shut down before return.
struct RequestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "request",
        abstract: "Run one independent attributed request from JSON on stdin."
    )

    @Option(name: .long) var provider: String
    @Option(name: .long) var model: String
    @Option(name: .long, help: "Explicit upstream base URL (HTTPS or loopback HTTP).") var url: String?
    @Option(name: .long) var sessionId: String
    @Option(name: .long) var role: String = "navigator"
    @Option(name: .long) var maxOutputTokens: Int = 2_048
    @Flag(name: .long) var json = false

    private static let maximumInputBytes = 256 * 1_024

    func run() async throws {
        guard let upstream = UpstreamProvider(rawValue: provider) else {
            return try fail("E001", "Unknown provider: \(provider)")
        }
        guard let attribution = RequestAttribution.validated(
            client: "repogps", sessionID: sessionId, role: role
        ) else {
            return try fail("E034", "Request requires a valid RepoGPS session UUID and role lead|navigator")
        }
        guard (128...16_384).contains(maxOutputTokens) else {
            return try fail("E034", "--max-output-tokens must be between 128 and 16384")
        }
        if let url {
            guard let components = URLComponents(string: url),
                  let scheme = components.scheme?.lowercased(),
                  components.host != nil,
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil,
                  scheme == "https" || (scheme == "http" && isLocalhostURL(url)) else {
                return try fail("E036", "--url must use HTTPS or loopback HTTP with no userinfo, query, or fragment")
            }
        }

        let input = try FileHandle.standardInput.read(upToCount: Self.maximumInputBytes + 1) ?? Data()
        guard !input.isEmpty, input.count <= Self.maximumInputBytes,
              let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              object["schema_version"] as? Int == 1,
              let messages = object["messages"] as? [[String: Any]], !messages.isEmpty else {
            return try fail("E034", "stdin must be schema-1 JSON with a bounded non-empty messages array")
        }

        let secrets = SecretsProviderFactory.make()
        let apiKey = upstream.secretKey.flatMap {
            ProcessInfo.processInfo.environment[$0] ?? (try? secrets.get(key: $0))
        }
        guard apiKey != nil || upstream.isLocal || url.map(isLocalhostURL) == true else {
            return try fail("E004", "No stored credential for \(provider)")
        }
        let localProxyCredential = LocalProxyCredential.requiresAuthentication(
            explicitlyRequired: false,
            upstreamAPIKey: apiKey
        ) ? try LocalProxyCredential.resolveOrCreate(using: secrets) : nil

        let stats = SessionStats(
            sessionReportURL: SessionReportStore.defaultURL,
            sessionSource: attribution.client,
            sessionID: attribution.sessionID
        )
        let config = ProxyConfiguration(
            port: 0,
            upstreamProvider: upstream,
            upstreamAPIBaseURL: url,
            upstreamAPIKey: apiKey,
            masterKey: localProxyCredential,
            allowedModels: [model],
            requiresAuth: localProxyCredential != nil,
            preferredAnthropicUpstreamModel: model,
            sessionStats: stats,
            googleThoughtSignatureStore: upstream == .google ? GoogleThoughtSignatureStore() : nil
        )
        let server = NIOProxyServer()
        let port: UInt16
        do {
            port = try await server.start(config: config)
        } catch {
            return try fail("E003", "Independent loopback runtime failed to start")
        }

        var payload = object
        payload.removeValue(forKey: "schema_version")
        payload["model"] = model
        payload["max_tokens"] = maxOutputTokens
        payload["stream"] = false
        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
            timeoutInterval: 45
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let localProxyCredential {
            request.setValue("Bearer \(localProxyCredential)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(attribution.client, forHTTPHeaderField: "X-ProxyPilot-Client")
        request.setValue(attribution.sessionID, forHTTPHeaderField: "X-ProxyPilot-Session-ID")
        request.setValue(attribution.role, forHTTPHeaderField: "X-ProxyPilot-Role")

        let responseData: Data
        let response: URLResponse
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 45
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            (responseData, response) = try await session.data(for: request)
        } catch {
            try? await server.stop()
            return try fail("E005", "Independent request timed out or failed")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              responseData.count <= Self.maximumInputBytes,
              let result = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            try? await server.stop()
            return try fail("E005", "Independent request returned an invalid or oversized response")
        }

        let returnedModel = result["model"] as? String
        let choices = result["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let output = message?["content"] as? String
        guard let output else {
            try? await server.stop()
            return try fail("E005", "Independent request returned no text content")
        }
        let usage = result["usage"] as? [String: Any] ?? [:]
        let promptTokens = usage["prompt_tokens"] as? Int
        let completionTokens = usage["completion_tokens"] as? Int
        let providerCost = (usage["cost"] as? NSNumber)?.doubleValue
        let metadata = upstream.knownModelMetadata(for: returnedModel ?? model)
        let estimated = metadata?.estimatedCostUSD(
            promptTokens: promptTokens ?? 0,
            completionTokens: completionTokens ?? 0
        )
        OutputFormatter.success(
            command: "request",
            data: RequestPayload(
                output: output,
                provider: provider,
                requestedModel: model,
                returnedModel: returnedModel,
                role: attribution.role,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                providerReportedCostUSD: providerCost,
                estimatedCostUSD: providerCost == nil ? estimated : nil,
                costProvenance: providerCost != nil ? "provider_reported" : (estimated != nil ? "provider_known_catalog_estimate" : "unavailable"),
                runtime: "ephemeral_loopback"
            ),
            humanMessage: output,
            json: json
        )
        try await server.stop()
    }

    private func fail(_ code: String, _ message: String) throws {
        OutputFormatter.error(command: "request", code: code, message: message, json: json)
        throw ExitCode.failure
    }
}

private struct RequestPayload: Encodable {
    let output: String
    let provider: String
    let requestedModel: String
    let returnedModel: String?
    let role: String
    let promptTokens: Int?
    let completionTokens: Int?
    let providerReportedCostUSD: Double?
    let estimatedCostUSD: Double?
    let costProvenance: String
    let runtime: String

    enum CodingKeys: String, CodingKey {
        case output, provider, role, runtime
        case requestedModel = "requested_model"
        case returnedModel = "returned_model"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case providerReportedCostUSD = "provider_reported_cost_usd"
        case estimatedCostUSD = "estimated_cost_usd"
        case costProvenance = "cost_provenance"
    }
}
