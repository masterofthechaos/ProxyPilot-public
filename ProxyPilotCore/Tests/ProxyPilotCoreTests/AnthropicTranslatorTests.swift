import Testing
import Foundation
@testable import ProxyPilotCore

// MARK: - SSE Parsing Helper

private func parseSSE(_ sse: String) throws -> (event: String, data: [String: Any]) {
    let lines = sse.components(separatedBy: "\n")
    let eventLine = lines.first { $0.hasPrefix("event: ") }
    let dataLine = lines.first { $0.hasPrefix("data: ") }
    guard let rawEvent = eventLine, let rawData = dataLine else {
        throw ParseError.missingFields
    }
    let eventName = rawEvent.replacingOccurrences(of: "event: ", with: "")
    let jsonStr = rawData.replacingOccurrences(of: "data: ", with: "")
    guard let data = (try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8))) as? [String: Any] else {
        throw ParseError.invalidJSON
    }
    return (eventName, data)
}

private enum ParseError: Error {
    case missingFields
    case invalidJSON
}

// MARK: - Request Conversion Tests

@Test func requestToOpenAIMapsToolUseIDFromToolResult() throws {
    let anthropic: [String: Any] = [
        "model": "claude-sonnet-4-5-20250514",
        "messages": [
            [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": "toolu_123",
                        "content": "ok"
                    ]
                ]
            ]
        ]
    ]

    let openAI = AnthropicTranslator.requestToOpenAI(anthropic)
    let messages = try #require(openAI["messages"] as? [[String: Any]])
    let toolMessage = try #require(messages.first)
    #expect(toolMessage["role"] as? String == "tool")
    #expect(toolMessage["tool_call_id"] as? String == "toolu_123")
}

@Test func requestToOpenAIConvertsSystemContentBlocks() throws {
    let anthropic: [String: Any] = [
        "model": "claude-sonnet-4-5-20250514",
        "system": [
            ["type": "text", "text": "You are helpful."]
        ],
        "messages": [
            ["role": "user", "content": "Hello"]
        ]
    ]

    let openAI = AnthropicTranslator.requestToOpenAI(anthropic)
    let messages = try #require(openAI["messages"] as? [[String: Any]])
    let systemMsg = try #require(messages.first)
    #expect(systemMsg["role"] as? String == "system")
    #expect(systemMsg["content"] as? String == "You are helpful.")
}

@Test func requestToOpenAISetsToolChoiceAuto() throws {
    let anthropic: [String: Any] = [
        "model": "claude-sonnet-4-5-20250514",
        "messages": [["role": "user", "content": "Search for docs"]],
        "tools": [
            [
                "name": "search",
                "description": "Search docs",
                "input_schema": ["type": "object", "properties": [:] as [String: Any]]
            ]
        ]
    ]

    let openAI = AnthropicTranslator.requestToOpenAI(anthropic)
    #expect(openAI["tool_choice"] as? String == "auto")
}

@Test func requestToOpenAIInjectsStoredGoogleThoughtSignature() throws {
    let store = GoogleThoughtSignatureStore()
    store.store(signature: "sig_123", for: "toolu_1")
    let anthropic: [String: Any] = [
        "model": "claude-sonnet-4-5-20250514",
        "messages": [
            [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "id": "toolu_1",
                        "name": "search",
                        "input": ["query": "ProxyPilot"]
                    ]
                ]
            ]
        ]
    ]

    let result = AnthropicTranslator.requestToOpenAI(
        anthropic,
        context: .init(
            upstreamProvider: .google,
            resolvedUpstreamModel: "gemini-3.1-pro",
            googleThoughtSignatureStore: store
        )
    )
    let messages = try #require(result.payload["messages"] as? [[String: Any]])
    let assistant = try #require(messages.first)
    let toolCalls = try #require(assistant["tool_calls"] as? [[String: Any]])
    let toolCall = try #require(toolCalls.first)
    let extraContent = try #require(toolCall["extra_content"] as? [String: Any])
    let google = try #require(extraContent["google"] as? [String: Any])
    #expect(google["thought_signature"] as? String == "sig_123")
    #expect(result.usedGoogleBypassFallback == false)
}

@Test func responseFromOpenAICapturesGoogleThoughtSignature() throws {
    let store = GoogleThoughtSignatureStore()
    let openAI: [String: Any] = [
        "choices": [
            [
                "finish_reason": "tool_calls",
                "message": [
                    "role": "assistant",
                    "tool_calls": [
                        [
                            "id": "call_1",
                            "type": "function",
                            "extra_content": [
                                "google": [
                                    "thought_signature": "sig_abc"
                                ]
                            ],
                            "function": [
                                "name": "search",
                                "arguments": "{\"query\":\"ProxyPilot\"}"
                            ]
                        ]
                    ]
                ]
            ]
        ]
    ]

    let result = AnthropicTranslator.responseFromOpenAI(
        openAI,
        model: "claude-sonnet-4-5-20250514",
        context: .init(
            upstreamProvider: .google,
            resolvedUpstreamModel: "gemini-3.1-pro",
            googleThoughtSignatureStore: store
        )
    )
    #expect(result.capturedGoogleSignatures == 1)
    #expect(store.lookup(toolCallID: "call_1") == "sig_abc")
}

// MARK: - Parameter Rewrite Tests (v1.4.9)

@Test func parameterRewriteRenamesSeedForMistral() {
    var request: [String: Any] = [
        "model": "devstral-2-25-12",
        "seed": 42,
        "messages": [["role": "user", "content": "hi"]]
    ]
    AnthropicTranslator.applyParameterRewrites(&request, for: .mistral)
    #expect(request["seed"] == nil)
    #expect(request["random_seed"] as? Int == 42)
    #expect(request["model"] as? String == "devstral-2-25-12")
}

@Test func parameterRewriteRenamesMaxCompletionTokensForMistral() {
    var request: [String: Any] = [
        "model": "devstral-2-25-12",
        "max_completion_tokens": 1024,
        "messages": [["role": "user", "content": "hi"]]
    ]
    AnthropicTranslator.applyParameterRewrites(&request, for: .mistral)
    #expect(request["max_completion_tokens"] == nil)
    #expect(request["max_tokens"] as? Int == 1024)
}

@Test func parameterRewriteNoOpForOpenAI() {
    var request: [String: Any] = [
        "model": "gpt-4",
        "seed": 42,
        "max_completion_tokens": 1024
    ]
    AnthropicTranslator.applyParameterRewrites(&request, for: .openAI)
    #expect(request["seed"] as? Int == 42)
    #expect(request["max_completion_tokens"] as? Int == 1024)
}

@Test func parameterRewritePreservesUnrelatedKeys() {
    var request: [String: Any] = [
        "model": "devstral-2-25-12",
        "seed": 42,
        "temperature": 0.7,
        "messages": [["role": "user", "content": "hi"]]
    ]
    AnthropicTranslator.applyParameterRewrites(&request, for: .mistral)
    #expect(request["temperature"] as? Double == 0.7)
    #expect((request["messages"] as? [[String: Any]])?.count == 1)
}

@Test func temperatureClampNoOpWhenNilRange() {
    var request: [String: Any] = [
        "model": "gpt-4",
        "temperature": 0.0
    ]
    AnthropicTranslator.clampTemperature(&request, for: .openAI)
    #expect(request["temperature"] as? Double == 0.0)
}

@Test func stripUnsupportedParametersRemovesGoogleOnlyKeys() {
    var request: [String: Any] = [
        "model": "gemini-3.1-pro",
        "seed": 1,
        "frequency_penalty": 0.5,
        "messages": [["role": "user", "content": "hi"]]
    ]

    AnthropicTranslator.stripUnsupportedParameters(&request, for: .google)

    #expect(request["seed"] == nil)
    #expect(request["frequency_penalty"] == nil)
    #expect(request["model"] as? String == "gemini-3.1-pro")
}

@Test func normalizeMiniMaxResponseStripsNonStandardKeys() throws {
    let payload = """
    {
      "id": "chatcmpl_123",
      "object": "chat.completion",
      "model": "MiniMax-M2.7",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "ok",
            "reasoning_details": [{"text": "hidden"}]
          },
          "finish_reason": "stop"
        }
      ],
      "usage": {
        "prompt_tokens": 1,
        "completion_tokens": 2,
        "total_tokens": 3,
        "completion_tokens_details": {"reasoning_tokens": 9}
      },
      "base_resp": {"status_code": 0, "status_msg": "success"},
      "input_sensitive": false,
      "output_sensitive": false
    }
    """.data(using: .utf8)!

    let normalized = AnthropicTranslator.normalizeOpenAICompatibleResponse(
        statusCode: 200,
        responseData: payload,
        provider: .miniMax
    )
    let json = try #require(JSONSerialization.jsonObject(with: normalized.data) as? [String: Any])
    #expect(normalized.statusCode == 200)
    #expect(json["base_resp"] == nil)
    #expect(json["input_sensitive"] == nil)
    let usage = try #require(json["usage"] as? [String: Any])
    #expect(usage["completion_tokens_details"] == nil)
    let choices = try #require(json["choices"] as? [[String: Any]])
    let message = try #require(choices.first?["message"] as? [String: Any])
    #expect(message["reasoning_details"] == nil)
}

@Test func normalizeMiniMaxEmbeddedErrorRewritesHTTPStatus() throws {
    let payload = """
    {
      "base_resp": {
        "status_code": 1001,
        "status_msg": "Invalid API key"
      }
    }
    """.data(using: .utf8)!

    let normalized = AnthropicTranslator.normalizeOpenAICompatibleResponse(
        statusCode: 200,
        responseData: payload,
        provider: .miniMax
    )
    let json = try #require(JSONSerialization.jsonObject(with: normalized.data) as? [String: Any])
    let error = try #require(json["error"] as? [String: Any])
    #expect(normalized.statusCode == 401)
    #expect(error["message"] as? String == "Invalid API key")
}

// MARK: - MiniMax Streaming Quirk Fixes (v1.4.14)

@Test func miniMaxStreamingDeltaWithEmptyRoleIsNormalized() throws {
    let payload = """
    {
      "id": "chatcmpl-123",
      "choices": [{"delta": {"role": "", "content": "hello"}}],
      "model": "MiniMax-M2.5"
    }
    """.data(using: .utf8)!

    let normalized = AnthropicTranslator.normalizeOpenAICompatibleResponse(
        statusCode: 200,
        responseData: payload,
        provider: .miniMax
    )
    let json = try #require(JSONSerialization.jsonObject(with: normalized.data) as? [String: Any])
    let choices = try #require(json["choices"] as? [[String: Any]])
    let delta = try #require(choices.first?["delta"] as? [String: Any])
    #expect(delta["role"] as? String == "assistant")
    #expect(delta["content"] as? String == "hello")
}

@Test func miniMaxStreamingChunkWithMissingIDIsHandled() throws {
    let payload = """
    {
      "choices": [{"delta": {"content": "hi"}}],
      "model": "MiniMax-M2.5"
    }
    """.data(using: .utf8)!

    let normalized = AnthropicTranslator.normalizeOpenAICompatibleResponse(
        statusCode: 200,
        responseData: payload,
        provider: .miniMax
    )
    let json = try #require(JSONSerialization.jsonObject(with: normalized.data) as? [String: Any])
    let id = try #require(json["id"] as? String)
    #expect(id.hasPrefix("chatcmpl-minimax-"))
}

@Test func miniMaxCNSameStreamingFixesApply() throws {
    let payload = """
    {
      "choices": [{"delta": {"role": "", "content": "test"}}],
      "model": "MiniMax-M2.5"
    }
    """.data(using: .utf8)!

    let normalized = AnthropicTranslator.normalizeOpenAICompatibleResponse(
        statusCode: 200,
        responseData: payload,
        provider: .miniMaxCN
    )
    let json = try #require(JSONSerialization.jsonObject(with: normalized.data) as? [String: Any])
    let choices = try #require(json["choices"] as? [[String: Any]])
    let delta = try #require(choices.first?["delta"] as? [String: Any])
    #expect(delta["role"] as? String == "assistant")
    // Also verify id was synthesized
    let id = try #require(json["id"] as? String)
    #expect(id.hasPrefix("chatcmpl-minimax-"))
}

@Test func miniMaxStreamingLineWithEmptyRoleIsNormalized() throws {
    let line = """
    data: {"choices":[{"delta":{"role":"","content":"hi"}}],"model":"MiniMax-M2.5"}
    """
    let normalized = AnthropicTranslator.normalizeOpenAICompatibleStreamingLine(
        line,
        provider: .miniMax
    )
    #expect(normalized.hasPrefix("data: "))
    let jsonStr = String(normalized.dropFirst(6))
    let json = try #require(JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Any])
    let choices = try #require(json["choices"] as? [[String: Any]])
    let delta = try #require(choices.first?["delta"] as? [String: Any])
    #expect(delta["role"] as? String == "assistant")
}

@Test func miniMaxStreamingLineDoesNotSynthesizeID() throws {
    let line = #"data: {"choices":[{"delta":{"content":"hi"}}],"model":"MiniMax-M2.5"}"#
    let normalized = AnthropicTranslator.normalizeOpenAICompatibleStreamingLine(
        line,
        provider: .miniMax
    )
    let jsonStr = String(normalized.dropFirst(6))
    let json = try #require(JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Any])
    // Streaming line normalizer must NOT synthesize an id — callers manage stream-wide ids.
    #expect(json["id"] == nil)
}

@Test func miniMaxBufferedResponseWithEmptyRoleIsNormalized() throws {
    let payload = """
    {
      "id": "chatcmpl-456",
      "choices": [{"message": {"role": "", "content": "done"}, "finish_reason": "stop"}],
      "model": "MiniMax-M2.5"
    }
    """.data(using: .utf8)!

    let normalized = AnthropicTranslator.normalizeOpenAICompatibleResponse(
        statusCode: 200,
        responseData: payload,
        provider: .miniMax
    )
    let json = try #require(JSONSerialization.jsonObject(with: normalized.data) as? [String: Any])
    let choices = try #require(json["choices"] as? [[String: Any]])
    let message = try #require(choices.first?["message"] as? [String: Any])
    #expect(message["role"] as? String == "assistant")
}

@Test func miniMaxExistingIDIsPreserved() throws {
    let payload = """
    {
      "id": "chatcmpl-existing",
      "choices": [{"delta": {"content": "hi"}}],
      "model": "MiniMax-M2.5"
    }
    """.data(using: .utf8)!

    let normalized = AnthropicTranslator.normalizeOpenAICompatibleResponse(
        statusCode: 200,
        responseData: payload,
        provider: .miniMax
    )
    let json = try #require(JSONSerialization.jsonObject(with: normalized.data) as? [String: Any])
    #expect(json["id"] as? String == "chatcmpl-existing")
}

// MARK: - Anthropic Passthrough Validation (v1.4.15)

@Test func passthroughResponseValidation_validResponse() throws {
    let payload = """
    {
      "id": "msg_123",
      "type": "message",
      "role": "assistant",
      "content": [{"type": "text", "text": "hello"}],
      "stop_reason": "end_turn",
      "model": "MiniMax-M2.5"
    }
    """.data(using: .utf8)!

    let validated = AnthropicTranslator.validateAnthropicPassthroughResponse(
        statusCode: 200, responseData: payload, provider: .miniMax
    )
    let json = try #require(JSONSerialization.jsonObject(with: validated.data) as? [String: Any])
    #expect(validated.statusCode == 200)
    #expect(json["id"] as? String == "msg_123")
    #expect(json["role"] as? String == "assistant")
}

@Test func passthroughResponseValidation_stripsBaseResp() throws {
    let payload = """
    {
      "id": "msg_123",
      "role": "assistant",
      "content": [{"type": "text", "text": "hi"}],
      "stop_reason": "end_turn",
      "base_resp": {"status_code": 0, "status_msg": "success"},
      "input_sensitive": false,
      "output_sensitive": false
    }
    """.data(using: .utf8)!

    let validated = AnthropicTranslator.validateAnthropicPassthroughResponse(
        statusCode: 200, responseData: payload, provider: .miniMax
    )
    let json = try #require(JSONSerialization.jsonObject(with: validated.data) as? [String: Any])
    #expect(json["base_resp"] == nil)
    #expect(json["input_sensitive"] == nil)
    #expect(json["output_sensitive"] == nil)
}

@Test func passthroughResponseValidation_fixesEmptyRole() throws {
    let payload = """
    {"id": "msg_123", "role": "", "content": [{"type": "text", "text": "hi"}], "stop_reason": "end_turn"}
    """.data(using: .utf8)!

    let validated = AnthropicTranslator.validateAnthropicPassthroughResponse(
        statusCode: 200, responseData: payload, provider: .miniMax
    )
    let json = try #require(JSONSerialization.jsonObject(with: validated.data) as? [String: Any])
    #expect(json["role"] as? String == "assistant")
}

@Test func passthroughResponseValidation_synthesizesMissingID() throws {
    let payload = """
    {"role": "assistant", "content": [{"type": "text", "text": "hi"}], "stop_reason": "end_turn"}
    """.data(using: .utf8)!

    let validated = AnthropicTranslator.validateAnthropicPassthroughResponse(
        statusCode: 200, responseData: payload, provider: .miniMax
    )
    let json = try #require(JSONSerialization.jsonObject(with: validated.data) as? [String: Any])
    let id = try #require(json["id"] as? String)
    #expect(id.hasPrefix("msg_minimax_"))
}

@Test func passthroughResponseValidation_fixesInvalidStopReason() throws {
    let payload = """
    {"id": "msg_123", "role": "assistant", "content": [{"type": "text", "text": "hi"}], "stop_reason": "length"}
    """.data(using: .utf8)!

    let validated = AnthropicTranslator.validateAnthropicPassthroughResponse(
        statusCode: 200, responseData: payload, provider: .miniMax
    )
    let json = try #require(JSONSerialization.jsonObject(with: validated.data) as? [String: Any])
    #expect(json["stop_reason"] as? String == "end_turn")
}

@Test func passthroughRequestSanitization_stripsUnsupportedParams() {
    var request: [String: Any] = [
        "model": "MiniMax-M2.5",
        "messages": [["role": "user", "content": "hi"]],
        "max_tokens": 1024,
        "temperature": 0.0,
        "top_k": 40,
        "stop_sequences": ["STOP"],
        "service_tier": "auto"
    ]
    AnthropicTranslator.sanitizeAnthropicPassthroughRequest(&request, for: .miniMax)
    #expect(request["top_k"] == nil)
    #expect(request["stop_sequences"] == nil)
    #expect(request["service_tier"] == nil)
    #expect(request["model"] as? String == "MiniMax-M2.5")
    #expect(request["max_tokens"] as? Int == 1024)
    // Temperature should be clamped to 0.01
    #expect(request["temperature"] as? Double == 0.01)
}

@Test func passthroughStreamingLineValidation_fixesEmptyRole() throws {
    let line = #"data: {"type":"message_start","message":{"id":"msg_1","role":"","model":"MiniMax-M2.5"}}"#
    let validated = AnthropicTranslator.validateAnthropicPassthroughStreamingLine(line, provider: .miniMax)
    let jsonStr = String(validated.dropFirst(6))
    let json = try #require(JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Any])
    let message = try #require(json["message"] as? [String: Any])
    #expect(message["role"] as? String == "assistant")
}

@Test func passthroughStreamingLineValidation_passesNonMiniMaxThrough() {
    let line = "data: {\"type\":\"message_start\"}"
    let validated = AnthropicTranslator.validateAnthropicPassthroughStreamingLine(line, provider: .openAI)
    #expect(validated == line)
}

// MARK: - Response Conversion Tests

@Test func responseFromOpenAIToolCallsForcesToolUseStopReason() throws {
    let openAI: [String: Any] = [
        "choices": [
            [
                "finish_reason": "stop",
                "message": [
                    "role": "assistant",
                    "content": "Using tool",
                    "tool_calls": [
                        [
                            "id": "call_1",
                            "type": "function",
                            "function": [
                                "name": "DocumentationSearch",
                                "arguments": "{\"query\":\"ProxyPilot\"}"
                            ]
                        ]
                    ]
                ]
            ]
        ]
    ]

    let translated = AnthropicTranslator.responseFromOpenAI(openAI, model: "claude-sonnet-4-5-20250514")
    #expect(translated["stop_reason"] as? String == "tool_use")
}

@Test func responseFromOpenAINoToolsUsesEndTurn() {
    let openAI: [String: Any] = [
        "choices": [
            [
                "finish_reason": "stop",
                "message": [
                    "role": "assistant",
                    "content": "Done"
                ]
            ]
        ]
    ]

    let translated = AnthropicTranslator.responseFromOpenAI(openAI, model: "claude-sonnet-4-5-20250514")
    #expect(translated["stop_reason"] as? String == "end_turn")
}

@Test func responseFromOpenAILengthMapsToMaxTokens() {
    let openAI: [String: Any] = [
        "choices": [
            [
                "finish_reason": "length",
                "message": [
                    "role": "assistant",
                    "content": "partial"
                ]
            ]
        ]
    ]

    let translated = AnthropicTranslator.responseFromOpenAI(openAI, model: "claude-sonnet-4-5-20250514")
    #expect(translated["stop_reason"] as? String == "max_tokens")
}

@Test func responseToolUseStopReasonWithoutBlocksFallsToEndTurn() {
    let openAI: [String: Any] = [
        "choices": [
            [
                "finish_reason": "tool_calls",
                "message": [
                    "role": "assistant",
                    "content": "I will search for that."
                ]
            ]
        ]
    ]

    let translated = AnthropicTranslator.responseFromOpenAI(openAI, model: "test-model")
    #expect(translated["stop_reason"] as? String == "end_turn")
}

// MARK: - Streaming Chunk State Machine Tests

@Test func processChunkTextEmitsMessageStartAndDelta() throws {
    var state = AnthropicTranslator.StreamingState(requestID: "req_1", messageID: "msg_1")
    let chunk: [String: Any] = [
        "choices": [["delta": ["content": "Hello"], "finish_reason": NSNull()]]
    ]

    let events = AnthropicTranslator.processStreamingChunk(chunk, state: &state, model: "glm-5")
    #expect(state.sentMessageStart == true)
    #expect(state.textAnthropicIndex == 0)
    // Should have: message_start, text_start, text_delta = 3 events
    #expect(events.count == 3)
    let (ev1, _) = try parseSSE(events[0])
    let (ev2, _) = try parseSSE(events[1])
    let (ev3, _) = try parseSSE(events[2])
    #expect(ev1 == "message_start")
    #expect(ev2 == "content_block_start")
    #expect(ev3 == "content_block_delta")
}

@Test func processChunkSecondTextOmitsMessageStart() throws {
    var state = AnthropicTranslator.StreamingState(requestID: "req_1", messageID: "msg_1")
    let chunk1: [String: Any] = ["choices": [["delta": ["content": "Hi"], "finish_reason": NSNull()]]]
    _ = AnthropicTranslator.processStreamingChunk(chunk1, state: &state, model: "glm-5")

    let chunk2: [String: Any] = ["choices": [["delta": ["content": " there"], "finish_reason": NSNull()]]]
    let events = AnthropicTranslator.processStreamingChunk(chunk2, state: &state, model: "glm-5")

    // Second chunk: only text delta (no message_start, no text_start)
    #expect(events.count == 1)
    let (ev, _) = try parseSSE(events[0])
    #expect(ev == "content_block_delta")
}

@Test func processChunkToolCallEmitsToolUseStart() throws {
    var state = AnthropicTranslator.StreamingState(requestID: "req_1", messageID: "msg_1")
    let chunk: [String: Any] = [
        "choices": [[
            "delta": [
                "tool_calls": [
                    [
                        "index": 0,
                        "id": "call_abc",
                        "function": ["name": "search", "arguments": ""]
                    ]
                ]
            ],
            "finish_reason": NSNull()
        ]]
    ]

    let events = AnthropicTranslator.processStreamingChunk(chunk, state: &state, model: "glm-5")
    #expect(state.sawToolUse == true)
    // message_start + tool_use content_block_start = 2 events
    #expect(events.count == 2)
    let (ev2, data2) = try parseSSE(events[1])
    #expect(ev2 == "content_block_start")
    let block = try #require(data2["content_block"] as? [String: Any])
    #expect(block["type"] as? String == "tool_use")
    #expect(block["name"] as? String == "search")
}

@Test func processChunkTextThenToolGetsCorrectIndexes() throws {
    var state = AnthropicTranslator.StreamingState(requestID: "req_1", messageID: "msg_1")

    // Text chunk
    let textChunk: [String: Any] = ["choices": [["delta": ["content": "Let me search"], "finish_reason": NSNull()]]]
    _ = AnthropicTranslator.processStreamingChunk(textChunk, state: &state, model: "glm-5")
    #expect(state.textAnthropicIndex == 0)

    // Tool chunk
    let toolChunk: [String: Any] = [
        "choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "search", "arguments": ""]]]], "finish_reason": NSNull()]]
    ]
    _ = AnthropicTranslator.processStreamingChunk(toolChunk, state: &state, model: "glm-5")

    let toolState = try #require(state.toolStatesByOpenAIIndex[0])
    #expect(toolState.anthropicContentIndex == 1)
    #expect(state.startedAnthropicIndexes == [0, 1])
}

// MARK: - Finish Events Tests

@Test func finishEventsClosesAllStartedBlocks() throws {
    var state = AnthropicTranslator.StreamingState(requestID: "req_1", messageID: "msg_1")
    state.sentMessageStart = true
    state.startedAnthropicIndexes = [0, 1]
    state.finalStopReason = "end_turn"

    let events = AnthropicTranslator.streamingFinishEvents(state: state)
    // 2 content_block_stop + message_delta + message_stop = 4
    #expect(events.count == 4)
    let (ev1, d1) = try parseSSE(events[0])
    let (ev2, d2) = try parseSSE(events[1])
    #expect(ev1 == "content_block_stop")
    #expect(d1["index"] as? Int == 0)
    #expect(ev2 == "content_block_stop")
    #expect(d2["index"] as? Int == 1)
}

@Test func finishEventsToolUseOverridesEndTurn() throws {
    var state = AnthropicTranslator.StreamingState(requestID: "req_1", messageID: "msg_1")
    state.sentMessageStart = true
    state.startedAnthropicIndexes = [0]
    state.sawToolUse = true
    state.finalStopReason = "end_turn"

    let events = AnthropicTranslator.streamingFinishEvents(state: state)
    let messageDeltaSSE = try #require(events.first { sse in
        guard let (ev, _) = try? parseSSE(sse) else { return false }
        return ev == "message_delta"
    })
    let (_, data) = try parseSSE(messageDeltaSSE)
    let delta = try #require(data["delta"] as? [String: Any])
    #expect(delta["stop_reason"] as? String == "tool_use")
}

@Test func finishEventsNoMessageStartReturnsEmpty() {
    let state = AnthropicTranslator.StreamingState(requestID: "req_1", messageID: "msg_1")
    // sentMessageStart is false by default
    let events = AnthropicTranslator.streamingFinishEvents(state: state)
    #expect(events.isEmpty)
}

// MARK: - Streaming SSE Event Generator Tests

@Test func streamingStartEventsContainsMessageStart() throws {
    let events = AnthropicTranslator.streamingStartEvents(messageId: "msg_test123", model: "glm-5")
    #expect(events.count == 1)
    let (event, data) = try parseSSE(events[0])
    #expect(event == "message_start")
    let message = try #require(data["message"] as? [String: Any])
    #expect(message["id"] as? String == "msg_test123")
    #expect(message["model"] as? String == "glm-5")
    #expect(message["role"] as? String == "assistant")
}

@Test func streamingTextStartEventHasCorrectIndex() throws {
    let sse = AnthropicTranslator.streamingTextStartEvent(index: 2)
    let (event, data) = try parseSSE(sse)
    #expect(event == "content_block_start")
    #expect(data["index"] as? Int == 2)
    let block = try #require(data["content_block"] as? [String: Any])
    #expect(block["type"] as? String == "text")
}

@Test func streamingDeltaEventContainsText() throws {
    let sse = AnthropicTranslator.streamingDeltaEvent(index: 0, text: "hello world")
    let (event, data) = try parseSSE(sse)
    #expect(event == "content_block_delta")
    #expect(data["index"] as? Int == 0)
    let delta = try #require(data["delta"] as? [String: Any])
    #expect(delta["type"] as? String == "text_delta")
    #expect(delta["text"] as? String == "hello world")
}

@Test func streamingDeltaEventDefaultIndexIsZero() throws {
    let sse = AnthropicTranslator.streamingDeltaEvent(text: "hi")
    let (_, data) = try parseSSE(sse)
    #expect(data["index"] as? Int == 0)
}

@Test func streamingToolUseStartEventHasIDAndName() throws {
    let sse = AnthropicTranslator.streamingToolUseStartEvent(index: 1, id: "toolu_abc", name: "search")
    let (event, data) = try parseSSE(sse)
    #expect(event == "content_block_start")
    #expect(data["index"] as? Int == 1)
    let block = try #require(data["content_block"] as? [String: Any])
    #expect(block["type"] as? String == "tool_use")
    #expect(block["id"] as? String == "toolu_abc")
    #expect(block["name"] as? String == "search")
}

@Test func streamingToolUseInputDeltaContainsPartialJSON() throws {
    let sse = AnthropicTranslator.streamingToolUseInputDeltaEvent(index: 1, partialJSON: "{\"query\":")
    let (event, data) = try parseSSE(sse)
    #expect(event == "content_block_delta")
    #expect(data["index"] as? Int == 1)
    let delta = try #require(data["delta"] as? [String: Any])
    #expect(delta["type"] as? String == "input_json_delta")
    #expect(delta["partial_json"] as? String == "{\"query\":")
}

@Test func streamingContentBlockStopEventHasIndex() throws {
    let sse = AnthropicTranslator.streamingContentBlockStopEvent(index: 3)
    let (event, data) = try parseSSE(sse)
    #expect(event == "content_block_stop")
    #expect(data["index"] as? Int == 3)
}

@Test func streamingMessageDeltaEventHasStopReason() throws {
    let sse = AnthropicTranslator.streamingMessageDeltaEvent(stopReason: "tool_use", outputTokens: 42)
    let (event, data) = try parseSSE(sse)
    #expect(event == "message_delta")
    let delta = try #require(data["delta"] as? [String: Any])
    #expect(delta["stop_reason"] as? String == "tool_use")
    let usage = try #require(data["usage"] as? [String: Any])
    #expect(usage["output_tokens"] as? Int == 42)
}

@Test func streamingMessageStopEventFormat() throws {
    let sse = AnthropicTranslator.streamingMessageStopEvent()
    let (event, data) = try parseSSE(sse)
    #expect(event == "message_stop")
    #expect(data["type"] as? String == "message_stop")
}

@Test func streamingDoneEventsContainsThreeEvents() throws {
    let events = AnthropicTranslator.streamingDoneEvents(messageId: "msg_test", model: "glm-5")
    #expect(events.count == 3)
    let (ev1, _) = try parseSSE(events[0])
    let (ev2, _) = try parseSSE(events[1])
    let (ev3, _) = try parseSSE(events[2])
    #expect(ev1 == "content_block_stop")
    #expect(ev2 == "message_delta")
    #expect(ev3 == "message_stop")
}

// MARK: - Additional Streaming State Machine Tests

@Test func processChunkToolArgumentsAccumulateBytes() throws {
    var state = AnthropicTranslator.StreamingState(requestID: "req_1", messageID: "msg_1")
    // First chunk: create the tool
    let chunk1: [String: Any] = [
        "choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "search", "arguments": ""]]]], "finish_reason": NSNull()]]
    ]
    _ = AnthropicTranslator.processStreamingChunk(chunk1, state: &state, model: "glm-5")

    // Second chunk: send arguments
    let chunk2: [String: Any] = [
        "choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "{\"q\":"]]]], "finish_reason": NSNull()]]
    ]
    _ = AnthropicTranslator.processStreamingChunk(chunk2, state: &state, model: "glm-5")

    let chunk3: [String: Any] = [
        "choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "\"test\"}"]]]], "finish_reason": NSNull()]]
    ]
    _ = AnthropicTranslator.processStreamingChunk(chunk3, state: &state, model: "glm-5")

    let toolState = try #require(state.toolStatesByOpenAIIndex[0])
    // {"q": is 5 chars + "test"} is 7 chars = 12
    #expect(toolState.argsBytes == 12)
}

// MARK: - Error Helper Test

@Test func errorJSONProducesValidJSON() throws {
    let json = AnthropicTranslator.errorJSON(message: "test error")
    let data = try #require(json.data(using: .utf8))
    let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(parsed["type"] as? String == "error")
    let error = try #require(parsed["error"] as? [String: Any])
    #expect(error["message"] as? String == "test error")
}
