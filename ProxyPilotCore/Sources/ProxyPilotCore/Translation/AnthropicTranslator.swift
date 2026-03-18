import Foundation

/// Translates between Anthropic /v1/messages format and OpenAI /v1/chat/completions format.
public enum AnthropicTranslator {
    public struct TranslationContext: Sendable {
        public let upstreamProvider: UpstreamProvider
        public let resolvedUpstreamModel: String
        public let googleThoughtSignatureStore: GoogleThoughtSignatureStore?

        public init(
            upstreamProvider: UpstreamProvider = .openAI,
            resolvedUpstreamModel: String = "",
            googleThoughtSignatureStore: GoogleThoughtSignatureStore? = nil
        ) {
            self.upstreamProvider = upstreamProvider
            self.resolvedUpstreamModel = resolvedUpstreamModel
            self.googleThoughtSignatureStore = googleThoughtSignatureStore
        }

        public var isGoogleGemini3: Bool {
            upstreamProvider == .google && resolvedUpstreamModel.lowercased().hasPrefix("gemini-3")
        }

        public var isGoogleGemini25: Bool {
            upstreamProvider == .google && resolvedUpstreamModel.lowercased().hasPrefix("gemini-2.5")
        }
    }

    public struct RequestTranslationResult {
        public let payload: [String: Any]
        public let injectedGoogleSignatures: Int
        public let usedGoogleBypassFallback: Bool

        public init(
            payload: [String: Any],
            injectedGoogleSignatures: Int,
            usedGoogleBypassFallback: Bool
        ) {
            self.payload = payload
            self.injectedGoogleSignatures = injectedGoogleSignatures
            self.usedGoogleBypassFallback = usedGoogleBypassFallback
        }
    }

    public struct ResponseTranslationResult {
        public let payload: [String: Any]
        public let capturedGoogleSignatures: Int

        public init(payload: [String: Any], capturedGoogleSignatures: Int) {
            self.payload = payload
            self.capturedGoogleSignatures = capturedGoogleSignatures
        }
    }

    // MARK: - Request: Anthropic → OpenAI

    public static func requestToOpenAI(_ anthropic: [String: Any]) -> [String: Any] {
        requestToOpenAI(anthropic, context: TranslationContext()).payload
    }

    public static func requestToOpenAI(
        _ anthropic: [String: Any],
        context: TranslationContext
    ) -> RequestTranslationResult {
        var openAI: [String: Any] = [:]

        if let model = anthropic["model"] as? String {
            openAI["model"] = model
        }

        var messages: [[String: Any]] = []

        if let system = anthropic["system"] as? String {
            messages.append(["role": "system", "content": system])
        } else if let systemBlocks = anthropic["system"] as? [[String: Any]] {
            let text = systemBlocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
            if !text.isEmpty {
                messages.append(["role": "system", "content": text])
            }
        }

        var injectedGoogleSignatures = 0
        var usedGoogleBypassFallback = false

        if let anthropicMessages = anthropic["messages"] as? [[String: Any]] {
            for msg in anthropicMessages {
                let converted = convertMessage(
                    msg,
                    context: context,
                    injectedGoogleSignatures: &injectedGoogleSignatures,
                    usedGoogleBypassFallback: &usedGoogleBypassFallback
                )
                messages.append(contentsOf: converted)
            }
        }

        openAI["messages"] = messages

        if let maxTokens = anthropic["max_tokens"] {
            openAI["max_tokens"] = maxTokens
        }
        if let temperature = anthropic["temperature"] {
            openAI["temperature"] = temperature
        }
        if let topP = anthropic["top_p"] {
            openAI["top_p"] = topP
        }
        if let stopSequences = anthropic["stop_sequences"] as? [String] {
            openAI["stop"] = stopSequences
        }
        if let stream = anthropic["stream"] as? Bool {
            openAI["stream"] = stream
        }

        if let tools = anthropic["tools"] as? [[String: Any]] {
            openAI["tools"] = tools.map { convertToolToOpenAI($0) }
            openAI["tool_choice"] = "auto"
        }

        stripUnsupportedParameters(&openAI, for: context.upstreamProvider)
        applyParameterRewrites(&openAI, for: context.upstreamProvider)
        clampTemperature(&openAI, for: context.upstreamProvider)

        return RequestTranslationResult(
            payload: openAI,
            injectedGoogleSignatures: injectedGoogleSignatures,
            usedGoogleBypassFallback: usedGoogleBypassFallback
        )
    }

    public static func stripUnsupportedParameters(
        _ request: inout [String: Any],
        for provider: UpstreamProvider
    ) {
        for key in provider.unsupportedOpenAIParameters {
            request.removeValue(forKey: key)
        }
    }

    /// Renames request parameter keys for providers that use non-standard names.
    public static func applyParameterRewrites(
        _ request: inout [String: Any],
        for provider: UpstreamProvider
    ) {
        for (oldKey, newKey) in provider.parameterRewrites {
            if let value = request.removeValue(forKey: oldKey) {
                request[newKey] = value
            }
        }
    }

    /// Clamps the temperature parameter to the provider's valid range.
    public static func clampTemperature(
        _ request: inout [String: Any],
        for provider: UpstreamProvider
    ) {
        guard let range = provider.temperatureRange,
              let temp = request["temperature"] as? Double else { return }
        request["temperature"] = min(max(temp, range.lowerBound), range.upperBound)
    }

    private static func convertMessage(
        _ msg: [String: Any],
        context: TranslationContext,
        injectedGoogleSignatures: inout Int,
        usedGoogleBypassFallback: inout Bool
    ) -> [[String: Any]] {
        let role = msg["role"] as? String ?? "user"

        if let content = msg["content"] as? String {
            return [["role": role, "content": content]]
        }

        guard let blocks = msg["content"] as? [[String: Any]] else {
            return [["role": role, "content": ""]]
        }

        var result: [[String: Any]] = []
        var textParts: [String] = []
        var toolCalls: [[String: Any]] = []

        for block in blocks {
            let type = block["type"] as? String ?? ""

            switch type {
            case "text":
                if let text = block["text"] as? String {
                    textParts.append(text)
                }

            case "tool_use":
                let toolCallID = block["id"] as? String ?? UUID().uuidString
                var toolCall: [String: Any] = [
                    "id": toolCallID,
                    "type": "function",
                    "function": [
                        "name": block["name"] as? String ?? "",
                        "arguments": jsonString(from: block["input"] ?? [:])
                    ]
                ]

                if context.upstreamProvider == .google {
                    if let signature = context.googleThoughtSignatureStore?.lookup(toolCallID: toolCallID) {
                        injectGoogleThoughtSignature(into: &toolCall, signature: signature)
                        injectedGoogleSignatures += 1
                    } else if context.isGoogleGemini3 {
                        injectGoogleThoughtSignature(
                            into: &toolCall,
                            signature: "skip_thought_signature_validator"
                        )
                        usedGoogleBypassFallback = true
                    }
                }

                toolCalls.append(toolCall)

            case "tool_result":
                let toolCallId = (block["tool_use_id"] as? String) ?? (block["tool_call_id"] as? String) ?? ""
                let content: String
                if let text = block["content"] as? String {
                    content = text
                } else if let contentBlocks = block["content"] as? [[String: Any]] {
                    content = contentBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
                } else {
                    content = ""
                }
                result.append([
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "content": content
                ])

            default:
                break
            }
        }

        if role == "assistant" {
            var assistantMsg: [String: Any] = ["role": "assistant"]
            if !textParts.isEmpty {
                assistantMsg["content"] = textParts.joined()
            }
            if !toolCalls.isEmpty {
                assistantMsg["tool_calls"] = toolCalls
            }
            result.insert(assistantMsg, at: 0)
        } else if !textParts.isEmpty {
            result.insert(["role": role, "content": textParts.joined()], at: 0)
        }

        return result
    }

    private static func convertToolToOpenAI(_ tool: [String: Any]) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": tool["name"] as? String ?? "",
                "description": tool["description"] as? String ?? "",
                "parameters": tool["input_schema"] ?? [:]
            ]
        ]
    }

    // MARK: - Response: OpenAI → Anthropic (non-streaming)

    public static func responseFromOpenAI(_ openAI: [String: Any], model: String) -> [String: Any] {
        responseFromOpenAI(openAI, model: model, context: TranslationContext()).payload
    }

    public static func responseFromOpenAI(
        _ openAI: [String: Any],
        model: String,
        context: TranslationContext
    ) -> ResponseTranslationResult {
        let id = "msg_\(UUID().uuidString.prefix(24).lowercased())"

        var content: [[String: Any]] = []
        var stopReason = "end_turn"
        var hasToolUseBlock = false
        var capturedGoogleSignatures = 0

        if let choices = openAI["choices"] as? [[String: Any]],
           let firstChoice = choices.first {
            if let message = firstChoice["message"] as? [String: Any] {
                if let text = message["content"] as? String, !text.isEmpty {
                    content.append(["type": "text", "text": text])
                }

                if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                    for tc in toolCalls {
                        let toolCallID = tc["id"] as? String ?? UUID().uuidString
                        if let signature = googleThoughtSignature(fromToolCall: tc) {
                            context.googleThoughtSignatureStore?.store(signature: signature, for: toolCallID)
                            capturedGoogleSignatures += 1
                        }

                        if let function = tc["function"] as? [String: Any] {
                            var toolUse: [String: Any] = [
                                "type": "tool_use",
                                "id": toolCallID,
                                "name": function["name"] as? String ?? ""
                            ]
                            if let argsStr = function["arguments"] as? String,
                               let argsData = argsStr.data(using: .utf8),
                               let argsObj = try? JSONSerialization.jsonObject(with: argsData) {
                                toolUse["input"] = argsObj
                            } else {
                                toolUse["input"] = [:]
                            }
                            content.append(toolUse)
                            hasToolUseBlock = true
                        }
                    }
                }
            }

            if let finishReason = firstChoice["finish_reason"] as? String {
                stopReason = mapFinishReason(finishReason)
            }
        }

        if content.isEmpty {
            content.append(["type": "text", "text": ""])
        }

        if hasToolUseBlock {
            stopReason = "tool_use"
        }
        if stopReason == "tool_use" && !hasToolUseBlock {
            stopReason = "end_turn"
        }

        var usage: [String: Any] = ["input_tokens": 0, "output_tokens": 0]
        if let openAIUsage = openAI["usage"] as? [String: Any] {
            usage["input_tokens"] = openAIUsage["prompt_tokens"] ?? 0
            usage["output_tokens"] = openAIUsage["completion_tokens"] ?? 0
        }

        let payload: [String: Any] = [
            "id": id,
            "type": "message",
            "role": "assistant",
            "content": content,
            "model": model,
            "stop_reason": stopReason,
            "stop_sequence": NSNull(),
            "usage": usage
        ]

        return ResponseTranslationResult(
            payload: payload,
            capturedGoogleSignatures: capturedGoogleSignatures
        )
    }

    // MARK: - Streaming: OpenAI chunks → Anthropic SSE events

    public static func streamingStartEvents(messageId: String, model: String) -> [String] {
        let messageStart: [String: Any] = [
            "type": "message_start",
            "message": [
                "id": messageId,
                "type": "message",
                "role": "assistant",
                "content": [],
                "model": model,
                "stop_reason": NSNull(),
                "stop_sequence": NSNull(),
                "usage": ["input_tokens": 0, "output_tokens": 0]
            ]
        ]

        return [formatSSE(event: "message_start", data: messageStart)]
    }

    public static func streamingTextStartEvent(index: Int) -> String {
        let contentBlockStart: [String: Any] = [
            "type": "content_block_start",
            "index": index,
            "content_block": [
                "type": "text",
                "text": ""
            ]
        ]
        return formatSSE(event: "content_block_start", data: contentBlockStart)
    }

    public static func streamingDeltaEvent(index: Int = 0, text: String) -> String {
        let delta: [String: Any] = [
            "type": "content_block_delta",
            "index": index,
            "delta": [
                "type": "text_delta",
                "text": text
            ]
        ]
        return formatSSE(event: "content_block_delta", data: delta)
    }

    public static func streamingToolUseStartEvent(index: Int, id: String, name: String) -> String {
        let contentBlockStart: [String: Any] = [
            "type": "content_block_start",
            "index": index,
            "content_block": [
                "type": "tool_use",
                "id": id,
                "name": name,
                "input": [:]
            ]
        ]
        return formatSSE(event: "content_block_start", data: contentBlockStart)
    }

    public static func streamingToolUseInputDeltaEvent(index: Int, partialJSON: String) -> String {
        let delta: [String: Any] = [
            "type": "content_block_delta",
            "index": index,
            "delta": [
                "type": "input_json_delta",
                "partial_json": partialJSON
            ]
        ]
        return formatSSE(event: "content_block_delta", data: delta)
    }

    public static func streamingContentBlockStopEvent(index: Int) -> String {
        let contentBlockStop: [String: Any] = [
            "type": "content_block_stop",
            "index": index
        ]
        return formatSSE(event: "content_block_stop", data: contentBlockStop)
    }

    public static func streamingMessageDeltaEvent(stopReason: String, outputTokens: Int = 0) -> String {
        let messageDelta: [String: Any] = [
            "type": "message_delta",
            "delta": [
                "stop_reason": stopReason,
                "stop_sequence": NSNull()
            ],
            "usage": [
                "output_tokens": outputTokens
            ]
        ]
        return formatSSE(event: "message_delta", data: messageDelta)
    }

    public static func streamingMessageStopEvent() -> String {
        let messageStop: [String: Any] = [
            "type": "message_stop"
        ]
        return formatSSE(event: "message_stop", data: messageStop)
    }

    public static func streamingDoneEvents(messageId: String, model: String) -> [String] {
        let contentBlockStop: [String: Any] = [
            "type": "content_block_stop",
            "index": 0
        ]

        let messageDelta: [String: Any] = [
            "type": "message_delta",
            "delta": [
                "stop_reason": "end_turn",
                "stop_sequence": NSNull()
            ],
            "usage": [
                "output_tokens": 0
            ]
        ]

        let messageStop: [String: Any] = [
            "type": "message_stop"
        ]

        return [
            formatSSE(event: "content_block_stop", data: contentBlockStop),
            formatSSE(event: "message_delta", data: messageDelta),
            formatSSE(event: "message_stop", data: messageStop)
        ]
    }

    // MARK: - Streaming State Machine

    public struct StreamingState {
        public struct ToolState {
            public var anthropicContentIndex: Int
            public var id: String
            public var name: String
            public var argsBytes: Int

            public init(anthropicContentIndex: Int, id: String, name: String, argsBytes: Int) {
                self.anthropicContentIndex = anthropicContentIndex
                self.id = id
                self.name = name
                self.argsBytes = argsBytes
            }
        }

        public var requestID: String
        public var sentMessageStart: Bool = false
        public var messageID: String
        public var nextAnthropicIndex: Int = 0
        public var textAnthropicIndex: Int?
        public var startedAnthropicIndexes: [Int] = []
        public var toolStatesByOpenAIIndex: [Int: ToolState] = [:]
        public var toolCallIDsByOpenAIIndex: [Int: String] = [:]
        public var capturedGoogleToolCallIDs: Set<String> = []
        public var sawToolUse: Bool = false
        public var finalStopReason: String = "end_turn"
        public var upstreamChunkIndex: Int = 0
        public var streamedEventCount: Int = 0
        public var lastSeenPromptTokens: Int = 0
        public var lastSeenCompletionTokens: Int = 0

        public init(requestID: String, messageID: String) {
            self.requestID = requestID
            self.messageID = messageID
        }
    }

    /// Process a single OpenAI streaming chunk. Returns SSE event strings to send to the client.
    public static func processStreamingChunk(
        _ chunk: [String: Any],
        state: inout StreamingState,
        model: String
    ) -> [String] {
        processStreamingChunk(
            chunk,
            state: &state,
            model: model,
            context: TranslationContext()
        )
    }

    public static func processStreamingChunk(
        _ chunk: [String: Any],
        state: inout StreamingState,
        model: String,
        context: TranslationContext
    ) -> [String] {
        var events: [String] = []

        if let usage = chunk["usage"] as? [String: Any] {
            state.lastSeenPromptTokens = usage["prompt_tokens"] as? Int ?? state.lastSeenPromptTokens
            state.lastSeenCompletionTokens = usage["completion_tokens"] as? Int ?? state.lastSeenCompletionTokens
        }

        guard let choices = chunk["choices"] as? [[String: Any]],
              let firstChoice = choices.first else {
            return events
        }

        if let finishReason = firstChoice["finish_reason"] as? String {
            switch finishReason {
            case "tool_calls": state.finalStopReason = "tool_use"
            case "length": state.finalStopReason = "max_tokens"
            case "stop": state.finalStopReason = "end_turn"
            default: break
            }
        }

        guard let delta = firstChoice["delta"] as? [String: Any] else { return events }

        if !state.sentMessageStart {
            events.append(contentsOf: streamingStartEvents(messageId: state.messageID, model: model))
            state.sentMessageStart = true
        }

        if let content = delta["content"] as? String, !content.isEmpty {
            if state.textAnthropicIndex == nil {
                let idx = state.nextAnthropicIndex
                state.nextAnthropicIndex += 1
                state.textAnthropicIndex = idx
                state.startedAnthropicIndexes.append(idx)
                events.append(streamingTextStartEvent(index: idx))
            }
            if let idx = state.textAnthropicIndex {
                events.append(streamingDeltaEvent(index: idx, text: content))
            }
        }

        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            let deltaLevelSignature = googleThoughtSignature(fromContainer: delta)

            for toolCall in toolCalls {
                let openAIIndex = toolCall["index"] as? Int ?? 0

                if let toolCallID = nonEmptyString(toolCall["id"]) {
                    state.toolCallIDsByOpenAIIndex[openAIIndex] = toolCallID
                }

                let signature = googleThoughtSignature(fromToolCall: toolCall)
                    ?? (toolCalls.count == 1 ? deltaLevelSignature : nil)
                if let signature {
                    let toolCallID = nonEmptyString(toolCall["id"])
                        ?? state.toolCallIDsByOpenAIIndex[openAIIndex]
                    if let toolCallID, !state.capturedGoogleToolCallIDs.contains(toolCallID) {
                        context.googleThoughtSignatureStore?.store(signature: signature, for: toolCallID)
                        state.capturedGoogleToolCallIDs.insert(toolCallID)
                    }
                }

                if state.toolStatesByOpenAIIndex[openAIIndex] == nil {
                    let function = toolCall["function"] as? [String: Any]
                    let id = nonEmptyString(toolCall["id"])
                        ?? state.toolCallIDsByOpenAIIndex[openAIIndex]
                        ?? UUID().uuidString
                    let name = (function?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "tool"
                    let idx = state.nextAnthropicIndex
                    state.nextAnthropicIndex += 1

                    state.toolCallIDsByOpenAIIndex[openAIIndex] = id
                    state.toolStatesByOpenAIIndex[openAIIndex] = StreamingState.ToolState(
                        anthropicContentIndex: idx, id: id, name: name, argsBytes: 0
                    )
                    state.startedAnthropicIndexes.append(idx)
                    state.sawToolUse = true

                    events.append(streamingToolUseStartEvent(index: idx, id: id, name: name))
                }

                if let function = toolCall["function"] as? [String: Any],
                   let argsChunk = function["arguments"] as? String,
                   !argsChunk.isEmpty,
                   var toolState = state.toolStatesByOpenAIIndex[openAIIndex] {
                    events.append(streamingToolUseInputDeltaEvent(
                        index: toolState.anthropicContentIndex,
                        partialJSON: argsChunk
                    ))
                    toolState.argsBytes += argsChunk.count
                    state.toolStatesByOpenAIIndex[openAIIndex] = toolState
                }
            }
        }

        state.streamedEventCount += events.count
        return events
    }

    /// Generate final closing events for a completed stream.
    public static func streamingFinishEvents(state: StreamingState) -> [String] {
        guard state.sentMessageStart else { return [] }

        var events: [String] = []

        for idx in state.startedAnthropicIndexes {
            events.append(streamingContentBlockStopEvent(index: idx))
        }

        var stopReason = state.finalStopReason
        if state.sawToolUse && stopReason == "end_turn" { stopReason = "tool_use" }
        if stopReason == "tool_use" && !state.sawToolUse { stopReason = "end_turn" }

        events.append(streamingMessageDeltaEvent(stopReason: stopReason))
        events.append(streamingMessageStopEvent())

        return events
    }

    // MARK: - Error Helper

    public static func errorJSON(message: String) -> String {
        let error: [String: Any] = [
            "type": "error",
            "error": [
                "type": "api_error",
                "message": message
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: error),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return #"{"type":"error","error":{"type":"api_error","message":"Unknown error"}}"#
    }

    // MARK: - Private Helpers

    private static func formatSSE(event: String, data: [String: Any]) -> String {
        let jsonStr: String
        if let jsonData = try? JSONSerialization.data(withJSONObject: data),
           let str = String(data: jsonData, encoding: .utf8) {
            jsonStr = str
        } else {
            jsonStr = "{}"
        }
        return "event: \(event)\ndata: \(jsonStr)\n\n"
    }

    private static func jsonString(from value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    private static func mapFinishReason(_ finishReason: String) -> String {
        switch finishReason {
        case "tool_calls":
            return "tool_use"
        case "length":
            return "max_tokens"
        case "stop":
            return "end_turn"
        default:
            return "end_turn"
        }
    }

    private static func injectGoogleThoughtSignature(into toolCall: inout [String: Any], signature: String) {
        toolCall["extra_content"] = [
            "google": [
                "thought_signature": signature
            ]
        ]
    }

    private static func googleThoughtSignature(fromToolCall toolCall: [String: Any]) -> String? {
        googleThoughtSignature(fromContainer: toolCall)
    }

    private static func googleThoughtSignature(fromContainer container: [String: Any]) -> String? {
        guard let extraContent = container["extra_content"] as? [String: Any],
              let google = extraContent["google"] as? [String: Any],
              let signature = nonEmptyString(google["thought_signature"]) else {
            return nil
        }
        return signature
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
