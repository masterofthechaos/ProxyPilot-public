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

// MARK: - Error Helper Test

@Test func errorJSONProducesValidJSON() throws {
    let json = AnthropicTranslator.errorJSON(message: "test error")
    let data = try #require(json.data(using: .utf8))
    let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(parsed["type"] as? String == "error")
    let error = try #require(parsed["error"] as? [String: Any])
    #expect(error["message"] as? String == "test error")
}
