import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
    @Option(name: .long, help: "Attributed client: repogps, xcode-agent, or epiphyte.") var client: String = "repogps"
    @Option(name: .long, help: "Request timeout in seconds.") var timeoutSeconds: Double = 45
    @Option(name: .long) var maxOutputTokens: Int = 2_048
    @Flag(name: .long) var json = false

    private static let maximumInputBytes = 256 * 1_024

    func run() async throws {
        guard let upstream = UpstreamProvider(rawValue: provider) else {
            return try fail("E001", "Unknown provider: \(provider)")
        }
        guard let attribution = RequestAttribution.validated(
            client: client, sessionID: sessionId, role: role
        ) else {
            return try fail("E034", "Request requires a known client, valid session UUID, and role lead|navigator")
        }
        guard (128...16_384).contains(maxOutputTokens) else {
            return try fail("E034", "--max-output-tokens must be between 128 and 16384")
        }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            return try fail("E034", "--timeout-seconds must be a finite positive number")
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

        // Independent Epiphyte requests do not own the shared listener. Publish
        // only their actual process-held lifetime for the GUI's client badge.
        let activityLease = attribution.client == "epiphyte"
            ? try EpiphyteRequestLease(.init(sessionID: attribution.sessionID, provider: provider, model: model)) : nil
        defer { withExtendedLifetime(activityLease) {} }
        let stats = SessionStats(
            sessionReportURL: SessionReportStore.defaultURL,
            sessionSource: attribution.client,
            sessionID: attribution.sessionID
        )
        let config = ProxyConfiguration(
            port: 0,
            upstreamProvider: upstream,
            upstreamAPIBaseURL: CLIProxyRuntime.upstreamBaseURL(provider: upstream, override: url),
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
        // The explicit command cap owns the limit. OpenAI's model rewrite must
        // not prefer a competing limit inherited from untrusted stdin.
        payload.removeValue(forKey: "max_completion_tokens")
        payload["model"] = model
        payload["max_tokens"] = maxOutputTokens
        payload["stream"] = false
        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
            timeoutInterval: timeoutSeconds
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
            configuration.timeoutIntervalForRequest = timeoutSeconds
            configuration.timeoutIntervalForResource = timeoutSeconds
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
        guard let reply = try? IndependentRequestAssistantReply(result: result) else {
            try? await server.stop()
            return try fail("E005", "Independent request returned no assistant content or tool calls")
        }
        let output = reply.output
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
                messageJSON: reply.messageJSON,
                finishReason: reply.finishReason,
                client: attribution.client,
                sessionID: attribution.sessionID,
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
            humanMessage: output ?? "Assistant returned tool calls",
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
    let output: String?
    let messageJSON: String
    let finishReason: String?
    let client: String
    let sessionID: String
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
        case output, provider, role, runtime, client
        case sessionID = "session_id"
        case messageJSON = "message_json"
        case finishReason = "finish_reason"
        case requestedModel = "requested_model"
        case returnedModel = "returned_model"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case providerReportedCostUSD = "provider_reported_cost_usd"
        case estimatedCostUSD = "estimated_cost_usd"
        case costProvenance = "cost_provenance"
    }
}


/// Preserve the complete assistant message (including provider-required opaque fields).
/// A tool response must have tool calls and the corresponding stop reason.
struct IndependentRequestAssistantReply {
    let output: String?
    let messageJSON: String
    let finishReason: String
    init(result: [String: Any]) throws {
        guard let choices = result["choices"] as? [[String: Any]],
              let first = choices.first, let message = first["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let finish = first["finish_reason"] as? String else { throw ValidationError("Invalid assistant response") }
        let tools = message["tool_calls"] as? [[String: Any]] ?? []
        guard (finish == "tool_calls") == !tools.isEmpty,
              message["content"] is String || !tools.isEmpty else { throw ValidationError("Inconsistent assistant response") }
        output = message["content"] as? String
        finishReason = finish
        messageJSON = String(decoding: try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]), as: UTF8.self)
    }
}
