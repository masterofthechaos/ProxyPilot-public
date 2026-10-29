import Foundation
import CoreFoundation

/// Provider adapter for RepoGPS Tutor. The public RepoGPS contract speaks in
/// terms of consult and delegate; this adapter projects those roles onto
/// OpenRouter server tools for the first backend implementation.
///
/// `consultation_policy: "required"` selects the Advisor on the first round
/// per user turn. Selecting its server-tool type is essential when ordinary
/// client tools are also available: generic `required` can choose a file read.
/// This adapter is
/// stateless, but every request carries the full OpenAI chat-completions
/// `messages` history, so per-turn state is derived from that history rather
/// than stored: `tool_choice: {"type":"openrouter:advisor"}` is only set on the FIRST round of
/// the current user turn — the round that begins immediately after the last
/// `role: "user"` message, before any assistant tool call or tool result has
/// appeared later in that same turn. Once the model has issued a tool call
/// in the current turn (resolved or not), forcing is not reapplied until the
/// next `role: "user"` message opens a new turn, even if earlier turns
/// contained tool activity. If `messages` is missing, malformed, or not an
/// array of message objects, the adapter fails safe by NOT forcing —
/// termination beats forcing. This logic assumes OpenAI chat-completions
/// message shape (`role: "tool"` for tool results); it only ever runs on the
/// `/v1/chat/completions` route, which is not reachable from the separate
/// Anthropic `/v1/messages` translation path in either proxy engine.
public enum TutorRequestAdapter {
    public static let headerName = "X-RepoGPS-Tutor"

    public static func accepts(envelopeHeader: String?, attribution: RequestAttribution?, provider: UpstreamProvider) -> Bool {
        provider == .openRouter && attribution?.client == "repogps"
            && envelopeHeader.flatMap(decodeEnvelope)?.backend == "openrouter"
    }

    /// A caller-selected Tutor timeout, if present. No new timeout default is
    /// chosen here; old envelopes continue using the proxy's existing policy.
    public static func upstreamTimeout(envelopeHeader: String?, attribution: RequestAttribution?, provider: UpstreamProvider) -> TimeInterval? {
        guard provider == .openRouter, attribution?.client == "repogps",
              let envelope = envelopeHeader.flatMap(decodeEnvelope), envelope.backend == "openrouter" else { return nil }
        return envelope.upstreamTimeoutSeconds
    }

    public static func mutateChatCompletionsBody(
        _ body: Data,
        envelopeHeader: String?,
        attribution: RequestAttribution?,
        provider: UpstreamProvider
    ) -> Data {
        guard provider == .openRouter,
              attribution?.client == "repogps",
              let envelopeHeader,
              let envelope = decodeEnvelope(envelopeHeader),
              envelope.backend == "openrouter",
              var request = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            return body
        }

        let toolsValue = request["tools"]
        guard toolsValue == nil || toolsValue is [[String: Any]] else {
            return body
        }
        // Canonical envelope-derived projections win: any caller-supplied tool
        // claiming a reserved Tutor server-tool type is dropped and replaced,
        // never merged, so a client can never shadow the envelope's validated
        // advisor/worker parameters by pre-supplying its own tool of that type.
        var tools = (toolsValue as? [[String: Any]] ?? []).filter { tool in
            !Self.reservedToolTypes.contains(tool["type"] as? String ?? "")
        }
        tools.append(advisorTool(envelope.advisor))
        tools.append(subagentTool(envelope.worker, webAccess: envelope.workerWebAccess))
        request["tools"] = tools
        if envelope.consultationPolicy == "required", isFirstRoundOfCurrentUserTurn(request["messages"]) {
            request["tool_choice"] = ["type": "openrouter:advisor"]
        }
        return (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? body
    }

    private static let reservedToolTypes: Set<String> = ["openrouter:advisor", "openrouter:subagent"]

    /// Returns true only for the first round of the current user turn, i.e.
    /// the span of `messages` after the last `role: "user"` message contains
    /// neither an assistant message with a non-empty `tool_calls` array nor
    /// any `role: "tool"` message. See the type-level doc comment for the
    /// consultation-policy rationale. Fails safe to `false` (do not force)
    /// when `messages` is missing, not an array, or contains non-object
    /// entries, and when no `role: "user"` message is present at all.
    private static func isFirstRoundOfCurrentUserTurn(_ messagesValue: Any?) -> Bool {
        guard let messages = messagesValue as? [[String: Any]] else { return false }
        guard let lastUserIndex = messages.lastIndex(where: { ($0["role"] as? String) == "user" }) else {
            return false
        }
        let span = messages[(lastUserIndex + 1)...]
        let hasAssistantToolCall = span.contains { message in
            (message["role"] as? String) == "assistant"
                && !((message["tool_calls"] as? [Any])?.isEmpty ?? true)
        }
        let hasToolResult = span.contains { ($0["role"] as? String) == "tool" }
        return !hasAssistantToolCall && !hasToolResult
    }

    private static func advisorTool(_ role: Role) -> [String: Any] {
        [
            "type": "openrouter:advisor",
            "parameters": [
                "name": "Tutor",
                "model": role.model,
                "instructions": "Act as RepoGPS Tutor: challenge assumptions, identify correctness and safety risks, and return concise, actionable guidance. Do not attempt to re-enter Tutor.",
                "forward_transcript": false,
                "max_completion_tokens": role.maxCompletionTokens,
            ],
        ]
    }

    private static func subagentTool(_ role: Role, webAccess: Bool) -> [String: Any] {
        var parameters: [String: Any] = [
            "model": role.model,
            "instructions": "Act as a focused RepoGPS Tutor worker. Complete only the self-contained task description, preserve its constraints, and return the requested outcome without assuming parent-conversation context.",
            "max_completion_tokens": role.maxCompletionTokens,
            "max_tool_calls": role.maxToolCalls,
        ]
        if webAccess {
            parameters["tools"] = [["type": "openrouter:web_search"]]
        }
        return ["type": "openrouter:subagent", "parameters": parameters]
    }

    private static func decodeEnvelope(_ value: String) -> Envelope? {
        guard value.utf8.count <= 8_192 else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1,
              ["automatic", "required"].contains(envelope.consultationPolicy),
              envelope.advisor.isValid,
              envelope.worker.isValid,
              envelope.upstreamTimeoutSeconds.map({ $0.isFinite && $0 > 0 }) ?? true
        else {
            return nil
        }
        return envelope
    }

    private struct Envelope: Decodable {
        let version: Int
        let backend: String
        let consultationPolicy: String
        let advisor: Role
        let worker: Role
        let workerWebAccess: Bool
        let upstreamTimeoutSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case version
            case backend
            case consultationPolicy = "consultation_policy"
            case advisor
            case worker
            case workerWebAccess = "worker_web_access"
            case upstreamTimeoutSeconds = "upstream_timeout_seconds"
        }
    }

    private struct Role: Decodable {
        let model: String
        let maxCompletionTokens: Int
        let maxToolCalls: Int

        var isValid: Bool {
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && model.utf8.count <= 512
                && (1...65_536).contains(maxCompletionTokens)
                && (1...25).contains(maxToolCalls)
        }

        enum CodingKeys: String, CodingKey {
            case model
            case maxCompletionTokens = "max_completion_tokens"
            case maxToolCalls = "max_tool_calls"
        }
    }
}

/// Content-free nested execution evidence. Only an actual provider result can
/// supply a returned model or per-call usage. The selected role configuration
/// and the outer response's model/usage are deliberately not fallbacks.
public struct TutorServerToolReceipt: Codable, Sendable, Equatable {
    public let callID: String
    public let role: String
    public let status: String
    public let returnedModel: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let providerReportedCostUSD: Double?

    public init(callID: String, role: String, status: String, returnedModel: String?,
                promptTokens: Int? = nil, completionTokens: Int? = nil,
                providerReportedCostUSD: Double? = nil) {
        self.callID = callID
        self.role = role
        self.status = status
        self.returnedModel = returnedModel
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.providerReportedCostUSD = providerReportedCostUSD
    }
}

/// Observes Chat Completions protocol messages without changing the response.
/// In particular, text that merely says "I consulted Tutor" is not evidence.
/// Server tools can emit multiple assistant/tool messages on one choice, so
/// streaming role transitions must be assembled before pairing by call ID.
public struct TutorResponseAccounting {
    private var calls: [String: String] = [:]
    private var results: [String: [String: Any]] = [:]
    private var streamed: [Int: [String: Any]] = [:]
    private var typed: [String: TutorServerToolReceipt] = [:]

    public init() {}

    public static func receipts(from data: Data) -> [TutorServerToolReceipt] {
        var observer = Self()
        observer.observe(data)
        return observer.receipts
    }

    /// Nested figures are a decomposition, not amounts to add to outer usage.
    /// Most OpenRouter server-tool results currently omit per-call billing;
    /// nulls preserve that absence instead of assigning the lead's aggregate.
    public static func nestedBreakdown(records: [RequestRecord]) -> [String: Any] {
        let calls = records.flatMap { $0.serverToolCalls ?? [] }
        return Dictionary(grouping: calls, by: \.role).mapValues { receipts -> [String: Any] in
            let usageAvailable = receipts.allSatisfy { $0.promptTokens != nil && $0.completionTokens != nil }
            let costAvailable = receipts.allSatisfy { $0.providerReportedCostUSD != nil }
            return [
                "calls": receipts.count,
                "successful_calls": receipts.filter { $0.status == "ok" }.count,
                "failed_calls": receipts.filter { $0.status == "error" }.count,
                "unproven_calls": receipts.filter { $0.status == "unproven" }.count,
                "returned_models": Dictionary(grouping: receipts.compactMap(\.returnedModel), by: { $0 }).mapValues(\.count),
                "model_identity_available": receipts.allSatisfy { $0.returnedModel != nil },
                "per_call_usage_available": usageAvailable,
                "prompt_tokens": usageAvailable ? receipts.compactMap(\.promptTokens).reduce(0, +) as Any : NSNull(),
                "completion_tokens": usageAvailable ? receipts.compactMap(\.completionTokens).reduce(0, +) as Any : NSNull(),
                "provider_reported_usd": costAvailable ? receipts.compactMap(\.providerReportedCostUSD).reduce(0, +) as Any : NSNull(),
                "accounting_provenance": usageAvailable ? "provider_reported_nested_results" : "unavailable_in_provider_results",
            ]
        }
    }

    public mutating func observe(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        observe(root)
    }

    public mutating func observe(streamingLine line: String) {
        guard line.hasPrefix("data:"),
              let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8) else { return }
        observe(data)
    }

    public var receipts: [TutorServerToolReceipt] {
        var copy = self
        for key in copy.streamed.keys.sorted() { copy.flush(key) }
        var receipts = copy.typed
        for (id, role) in copy.calls {
            guard let result = copy.results[id] else { continue }
            receipts[id] = Self.receipt(id: id, role: role, result: result)
        }
        return receipts.values.sorted { $0.callID < $1.callID }
    }

    private mutating func observe(_ root: [String: Any]) {
        if let messages = root["messages"] as? [[String: Any]] { messages.forEach { observeMessage($0) } }
        if let choices = root["choices"] as? [[String: Any]] {
            for choice in choices {
                if let message = choice["message"] as? [String: Any] { observeMessage(message) }
                if let messages = choice["messages"] as? [[String: Any]] { messages.forEach { observeMessage($0) } }
                if let delta = choice["delta"] as? [String: Any], !delta.isEmpty {
                    observeDelta(delta, index: choice["index"] as? Int ?? 0)
                }
            }
        }
        if root["role"] as? String == "assistant" || root["role"] as? String == "tool" { observeMessage(root) }
        // Only structured protocol containers are traversed. Model-authored
        // JSON in content strings is never promoted to a server receipt.
        observeTyped(root)
    }

    private mutating func observeMessage(_ message: [String: Any]) {
        if message["role"] as? String == "assistant", let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                guard let id = call["id"] as? String,
                      let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let role = Self.role(name) else { continue }
                calls[id] = role
            }
        }
        if message["role"] as? String == "tool", let id = message["tool_call_id"] as? String,
           let result = Self.resultObject(message["content"]) { results[id] = result }
    }

    private mutating func observeDelta(_ delta: [String: Any], index: Int) {
        if let current = streamed[index] {
            let changedRole = (delta["role"] as? String).map { $0 != current["role"] as? String } ?? false
            let changedID = (delta["tool_call_id"] as? String).map { id in
                (current["tool_call_id"] as? String).map { $0 != id } ?? false
            } ?? false
            if changedRole || changedID { flush(index) }
        }
        var message = streamed[index] ?? ["role": delta["role"] as? String ?? "assistant"]
        if let id = delta["tool_call_id"] as? String { message["tool_call_id"] = id }
        if message["role"] as? String == "tool" {
            if let content = delta["content"] as? String { message["content"] = (message["content"] as? String ?? "") + content }
            else if let content = delta["content"] { message["content"] = content }
        }
        if let incoming = delta["tool_calls"] as? [[String: Any]] {
            var toolCalls = message["_calls"] as? [Int: [String: Any]] ?? [:]
            for fragment in incoming {
                let callIndex = fragment["index"] as? Int ?? 0
                var call = toolCalls[callIndex] ?? [:]
                if let id = fragment["id"] as? String { call["id"] = id }
                var function = call["function"] as? [String: Any] ?? [:]
                if let name = (fragment["function"] as? [String: Any])?["name"] as? String {
                    function["name"] = (function["name"] as? String ?? "") + name
                }
                call["function"] = function
                toolCalls[callIndex] = call
            }
            message["_calls"] = toolCalls
        }
        streamed[index] = message
    }

    private mutating func flush(_ index: Int) {
        guard var message = streamed.removeValue(forKey: index) else { return }
        if let toolCalls = message.removeValue(forKey: "_calls") as? [Int: [String: Any]] {
            message["tool_calls"] = toolCalls.keys.sorted().compactMap { toolCalls[$0] }
        }
        observeMessage(message)
    }

    private mutating func observeTyped(_ value: Any) {
        if let array = value as? [Any] { array.forEach { observeTyped($0) }; return }
        guard let object = value as? [String: Any] else { return }
        if let type = object["type"] as? String, ["openrouter:advisor", "openrouter:subagent"].contains(type),
           let role = Self.role(type), let id = (object["call_id"] ?? object["id"]) as? String,
           ["completed", "ok", "error", "failed"].contains(object["status"] as? String ?? "") {
            typed[id] = Self.receipt(id: id, role: role, result: object)
        }
        for key in ["output", "item", "message", "messages", "choices", "delta"] {
            if let child = object[key] { observeTyped(child) }
        }
        if let content = object["content"] as? [Any] { observeTyped(content) }
    }

    private static func role(_ name: String) -> String? {
        for (base, role) in [("advisor", "advisor"), ("subagent", "worker")] {
            if name == "openrouter:\(base)" || name == "openrouter_\(base)" { return role }
            let prefix = "openrouter_\(base)__"
            if name.hasPrefix(prefix) {
                let suffix = name.dropFirst(prefix.count)
                if !suffix.isEmpty && suffix.allSatisfy({ $0.isASCII && $0.isNumber }) { return role }
            }
        }
        return nil
    }

    private static func resultObject(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        let text: String?
        if let array = value as? [[String: Any]] {
            text = array.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        } else { text = value as? String }
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func receipt(id: String, role: String, result: [String: Any]) -> TutorServerToolReceipt {
        let successfulStatus = ["ok", "completed"].contains(result["status"] as? String ?? "")
        let outcome = result[role == "advisor" ? "advice" : "outcome"] as? String
        let success = successfulStatus && !(outcome?.isEmpty ?? true) && result["error"] == nil
        let status = success ? "ok" : (["error", "failed"].contains(result["status"] as? String ?? "") ? "error" : "unproven")
        let usage = result["usage"] as? [String: Any]
        func integer(_ key: String, alternative: String) -> Int? {
            guard let value = (usage?[key] ?? usage?[alternative]) as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue >= 0,
                  value.doubleValue.rounded(.towardZero) == value.doubleValue else { return nil }
            return value.intValue
        }
        let cost = (usage?["cost"] as? NSNumber).flatMap { value -> Double? in
            CFGetTypeID(value) != CFBooleanGetTypeID() && value.doubleValue.isFinite && value.doubleValue >= 0 ? value.doubleValue : nil
        }
        let model = (result["model"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return .init(callID: id, role: role, status: status, returnedModel: model,
                     promptTokens: integer("prompt_tokens", alternative: "input_tokens"),
                     completionTokens: integer("completion_tokens", alternative: "output_tokens"),
                     providerReportedCostUSD: cost)
    }
}
