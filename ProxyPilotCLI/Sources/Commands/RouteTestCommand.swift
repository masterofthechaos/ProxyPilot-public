import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ProxyPilotCore

struct RouteTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "test", abstract: "Verify the selected RepoGPS route without restarting it.")
    @Option(name: .long) var expectedProvider: String
    @Option(name: .long) var expectedModel: String
    @Option(name: .long) var expectedUpstreamUrl: String
    @Option(name: .long) var timeoutSeconds: Double = 45
    @Option(name: .long) var maxOutputTokens: Int = 2048
    @Flag(name: .long) var json = false

    func run() async throws {
        do {
            guard timeoutSeconds.isFinite, timeoutSeconds > 0, (128...16384).contains(maxOutputTokens) else {
                throw ValidationError("Use a positive timeout and 128–16384 output tokens.")
            }
            let receipt = try await RouteStateStore.withExclusiveLock {
                guard let selected = RouteStateStore.load(), let provider = UpstreamProvider(rawValue: selected.provider) else {
                    throw ValidationError("Choose a RepoGPS provider and model before testing.")
                }
                guard selected.provider == expectedProvider, selected.model == expectedModel else {
                    throw ValidationError("RepoGPS selection changed. Refresh and test again.")
                }
                let endpoint = CLIProxyRuntime.upstreamBaseURL(provider: provider, override: nil)
                try RouteProbeSupport.requireEndpoint(endpoint, matches: expectedUpstreamUrl)
                let secrets = SecretsProviderFactory.make()
                guard case .resolved(let resolved) = ProviderCredentialResolver.resolve(rawProvider: provider.rawValue,
                    explicitKey: nil, upstreamURL: nil, secrets: secrets) else {
                    throw ValidationError("Save the selected provider key first.")
                }
                let key = resolved.apiKey
                let credential = LocalProxyCredential.requiresAuthentication(explicitlyRequired: false, upstreamAPIKey: key)
                    ? try LocalProxyCredential.resolveOrCreate(using: secrets) : nil
                let probe = await CLIProxyRuntime.probeProxy(on: selected.port)
                let server: NIOProxyServer?
                let port: UInt16
                let mode: String
                if probe.reachable {
                    server = nil; port = selected.port; mode = "running_shared_route"
                } else {
                    guard PidFile.read() == nil else { throw ValidationError("The shared proxy is unhealthy. Apply or restart it before testing.") }
                    let temporary = NIOProxyServer()
                    port = try await temporary.start(config: ProxyConfiguration(port: 0, upstreamProvider: provider,
                        upstreamAPIBaseURL: endpoint, upstreamAPIKey: key, masterKey: credential,
                        allowedModels: [selected.model], requiresAuth: credential != nil,
                        preferredAnthropicUpstreamModel: selected.model,
                        googleThoughtSignatureStore: provider == .google ? GoogleThoughtSignatureStore() : nil,
                        promptCaching: CLIPromptCachingMode.auto.configuration,
                        contextCompaction: CLIContextCompactionMode.auto.configuration()))
                    server = temporary; mode = "temporary_startup_probe"
                }
                do {
                    let result = try await verify(port: port, provider: provider, model: selected.model, endpoint: endpoint, credential: credential, mode: mode)
                    try await server?.stop()
                    return result
                } catch {
                    try? await server?.stop()
                    throw error
                }
            }
            OutputFormatter.success(command: "route test", data: receipt,
                humanMessage: "RepoGPS route verified: \(receipt.provider) / \(receipt.model), \(receipt.endpoint) (\(receipt.transport))", json: json)
        } catch {
            OutputFormatter.error(command: "route test", code: "E050", message: (error as? ValidationError)?.message ?? error.localizedDescription, json: json)
            throw ExitCode.failure
        }
    }

    private func verify(port: UInt16, provider: UpstreamProvider, model: String, endpoint: String, credential: String?, mode: String) async throws -> RouteProbeReceipt {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func request(_ path: String, body: [String: Any]? = nil) throws -> URLRequest {
            var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: timeoutSeconds)
            if let credential { r.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
            if let body {
                r.httpMethod = "POST"; r.httpBody = try JSONSerialization.data(withJSONObject: body)
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            return r
        }
        func identity() async throws -> String {
            let (data, response) = try await session.data(for: request("/v1/proxypilot/route"))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ValidationError("The running proxy cannot report its applied endpoint. Update/apply the route before testing.")
            }
            return try RouteProbeSupport.validateIdentity(object, provider: provider.rawValue, model: model, endpoint: endpoint)
        }
        let runtimeID = try await identity() // Never send inference before endpoint identity matches.
        func stream(_ messages: [[String: Any]]) async throws -> RouteProbeReply {
            let payload: [String: Any] = ["model": ActiveModelAlias.id, "messages": messages, "stream": true,
                "max_tokens": maxOutputTokens, "tools": [["type": "function", "function": [
                    "name": "proxypilot_route_probe", "description": "Return the supplied value for a connection test.",
                    "parameters": ["type": "object", "properties": ["value": ["type": "string"]], "required": ["value"]]
                ]]]]
            let (data, response) = try await session.data(for: request("/v1/chat/completions", body: payload))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ValidationError("RepoGPS streaming request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            return try RouteProbeReply(data: data)
        }
        var messages: [[String: Any]] = [["role": "user", "content": "Call proxypilot_route_probe with value ok. Wait for the tool result, then reply with exactly ok."]]
        let first = try await stream(messages)
        guard first.finishReason == "tool_calls", first.tools.count == 1,
              let tool = first.tools.first, let id = tool["id"] as? String,
              let function = tool["function"] as? [String: Any], function["name"] as? String == "proxypilot_route_probe",
              let arguments = function["arguments"] as? String,
              let args = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              args["value"] as? String == "ok" else { throw ValidationError("Streaming responded, but the test tool call was not completed correctly.") }
        messages.append(first.message)
        messages.append(["role": "tool", "tool_call_id": id, "content": "ok"])
        let final = try await stream(messages)
        guard final.finishReason == "stop", !final.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              final.tools.isEmpty else { throw ValidationError("Tool continuation did not return a completed answer.") }
        guard try await identity() == runtimeID else { throw ValidationError("The running proxy changed during the check. Test again.") }
        return RouteProbeReceipt(provider: provider.rawValue, model: model, endpoint: endpoint, transport: mode,
            verifiedChecks: ["endpoint", "active_model_alias", "streaming", "tool_call", "tool_continuation"])
    }
}

struct RouteProbeReceipt: Codable {
    let provider: String
    let model: String
    let endpoint: String
    let transport: String
    let verifiedChecks: [String]
}

enum RouteProbeSupport {
    static func canonicalEndpoint(_ raw: String) -> String? {
        guard var parts = URLComponents(string: raw), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host != nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        return parts.string
    }
    static func requireEndpoint(_ actual: String, matches expected: String) throws {
        guard let a = canonicalEndpoint(actual), let b = canonicalEndpoint(expected), a == b else {
            throw ValidationError("Endpoint mismatch: RepoGPS uses \(actual), while the app expects \(expected). Update the CLI or apply the correct route; no inference was sent.")
        }
    }
    static func validateIdentity(_ object: [String: Any], provider: String, model: String, endpoint: String) throws -> String {
        guard object["provider"] as? String == provider, object["model"] as? String == model,
              let actual = object["endpoint"] as? String, let id = object["session_id"] as? String, !id.isEmpty else {
            throw ValidationError("The running route serves a different provider/model or cannot prove its identity. Apply the selected route.")
        }
        try requireEndpoint(actual, matches: endpoint)
        return id
    }
}

/// Reassembles fragmented SSE tool arguments and preserves reasoning for the next turn.
struct RouteProbeReply {
    let content: String
    let tools: [[String: Any]]
    let finishReason: String
    let message: [String: Any]
    init(data: Data) throws {
        var content = "", reasoning = "", finish: String?, done = false
        var tools: [Int: [String: Any]] = [:]
        for raw in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if value == "[DONE]" { done = true; continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any], object["error"] == nil,
                  let choices = object["choices"] as? [[String: Any]] else { throw ValidationError("Invalid streaming response.") }
            for choice in choices {
                if let reason = choice["finish_reason"] as? String { finish = reason }
                let delta = choice["delta"] as? [String: Any] ?? [:]
                content += delta["content"] as? String ?? ""
                reasoning += delta["reasoning_content"] as? String ?? ""
                for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = fragment["index"] as? Int ?? 0
                    var tool = tools[index] ?? ["type": "function"]
                    for (key, value) in fragment where key != "index" && key != "function" { tool[key] = value }
                    if let f = fragment["function"] as? [String: Any] {
                        var function = tool["function"] as? [String: Any] ?? [:]
                        for (key, value) in f {
                            if key == "arguments", let text = value as? String { function[key] = (function[key] as? String ?? "") + text }
                            else { function[key] = value }
                        }
                        tool["function"] = function
                    }
                    tools[index] = tool
                }
            }
        }
        guard done, let finish else { throw ValidationError("Streaming ended without a completed response.") }
        self.content = content; self.tools = tools.keys.sorted().compactMap { tools[$0] }; finishReason = finish
        var message: [String: Any] = ["role": "assistant", "content": content]
        if !reasoning.isEmpty { message["reasoning_content"] = reasoning }
        if !self.tools.isEmpty { message["tool_calls"] = self.tools }
        self.message = message
    }
}
