import XCTest
@testable import ProxyPilot

final class AnthropicTranslatorTests: XCTestCase {

    // MARK: - SSE Parsing Helper

    private func parseSSE(_ sse: String) throws -> (event: String, data: [String: Any]) {
        let lines = sse.components(separatedBy: "\n")
        let eventLine = lines.first { $0.hasPrefix("event: ") }
        let dataLine = lines.first { $0.hasPrefix("data: ") }
        let eventName = try XCTUnwrap(eventLine).replacingOccurrences(of: "event: ", with: "")
        let jsonStr = try XCTUnwrap(dataLine).replacingOccurrences(of: "data: ", with: "")
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Any])
        return (eventName, data)
    }

    // MARK: - Existing Request/Response Tests

    func testRequestToOpenAIMapsToolUseIDFromToolResult() throws {
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
        let messages = try XCTUnwrap(openAI["messages"] as? [[String: Any]])
        let toolMessage = try XCTUnwrap(messages.first)
        XCTAssertEqual(toolMessage["role"] as? String, "tool")
        XCTAssertEqual(toolMessage["tool_call_id"] as? String, "toolu_123")
    }

    func testResponseFromOpenAIToolCallsForcesToolUseStopReason() throws {
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
        XCTAssertEqual(translated["stop_reason"] as? String, "tool_use")
    }

    func testResponseFromOpenAINoToolsUsesEndTurn() throws {
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
        XCTAssertEqual(translated["stop_reason"] as? String, "end_turn")
    }

    func testResponseFromOpenAILengthMapsToMaxTokens() throws {
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
        XCTAssertEqual(translated["stop_reason"] as? String, "max_tokens")
    }

    // MARK: - Stop Reason Invariant: tool_use Without Blocks

    func testResponseToolUseStopReasonWithoutBlocksFallsToEndTurn() throws {
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
        XCTAssertEqual(translated["stop_reason"] as? String, "end_turn")
    }

    // MARK: - Request Translation

    func testRequestToOpenAIConvertsSystemContentBlocks() throws {
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
        let messages = try XCTUnwrap(openAI["messages"] as? [[String: Any]])
        let systemMsg = try XCTUnwrap(messages.first)
        XCTAssertEqual(systemMsg["role"] as? String, "system")
        XCTAssertEqual(systemMsg["content"] as? String, "You are helpful.")
    }

    func testRequestToOpenAISetsToolChoiceAuto() throws {
        let anthropic: [String: Any] = [
            "model": "claude-sonnet-4-5-20250514",
            "messages": [["role": "user", "content": "Search for docs"]],
            "tools": [
                [
                    "name": "search",
                    "description": "Search docs",
                    "input_schema": ["type": "object", "properties": [:]]
                ]
            ]
        ]

        let openAI = AnthropicTranslator.requestToOpenAI(anthropic)
        XCTAssertEqual(openAI["tool_choice"] as? String, "auto")
    }

    func testRequestToOpenAIInjectsStoredGoogleThoughtSignature() throws {
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
        let messages = try XCTUnwrap(result.payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first)
        let toolCalls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        let toolCall = try XCTUnwrap(toolCalls.first)
        let extraContent = try XCTUnwrap(toolCall["extra_content"] as? [String: Any])
        let google = try XCTUnwrap(extraContent["google"] as? [String: Any])
        XCTAssertEqual(google["thought_signature"] as? String, "sig_123")
    }

    func testResponseFromOpenAICapturesGoogleThoughtSignature() throws {
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
        XCTAssertEqual(result.capturedGoogleSignatures, 1)
        XCTAssertEqual(store.lookup(toolCallID: "call_1"), "sig_abc")
    }

    // MARK: - SSE Event Generator Tests

    func testStreamingStartEventsContainsMessageStart() throws {
        let events = AnthropicTranslator.streamingStartEvents(messageId: "msg_test123", model: "glm-5")
        XCTAssertEqual(events.count, 1)
        let (event, data) = try parseSSE(events[0])
        XCTAssertEqual(event, "message_start")
        let message = try XCTUnwrap(data["message"] as? [String: Any])
        XCTAssertEqual(message["id"] as? String, "msg_test123")
        XCTAssertEqual(message["model"] as? String, "glm-5")
        XCTAssertEqual(message["role"] as? String, "assistant")
    }

    func testStreamingTextStartEventHasCorrectIndex() throws {
        let sse = AnthropicTranslator.streamingTextStartEvent(index: 2)
        let (event, data) = try parseSSE(sse)
        XCTAssertEqual(event, "content_block_start")
        XCTAssertEqual(data["index"] as? Int, 2)
        let block = try XCTUnwrap(data["content_block"] as? [String: Any])
        XCTAssertEqual(block["type"] as? String, "text")
    }

    func testStreamingDeltaEventContainsText() throws {
        let sse = AnthropicTranslator.streamingDeltaEvent(index: 0, text: "hello world")
        let (event, data) = try parseSSE(sse)
        XCTAssertEqual(event, "content_block_delta")
        XCTAssertEqual(data["index"] as? Int, 0)
        let delta = try XCTUnwrap(data["delta"] as? [String: Any])
        XCTAssertEqual(delta["type"] as? String, "text_delta")
        XCTAssertEqual(delta["text"] as? String, "hello world")
    }

    func testStreamingToolUseStartEventHasIDAndName() throws {
        let sse = AnthropicTranslator.streamingToolUseStartEvent(index: 1, id: "toolu_abc", name: "search")
        let (event, data) = try parseSSE(sse)
        XCTAssertEqual(event, "content_block_start")
        XCTAssertEqual(data["index"] as? Int, 1)
        let block = try XCTUnwrap(data["content_block"] as? [String: Any])
        XCTAssertEqual(block["type"] as? String, "tool_use")
        XCTAssertEqual(block["id"] as? String, "toolu_abc")
        XCTAssertEqual(block["name"] as? String, "search")
    }

    func testStreamingToolUseInputDeltaContainsPartialJSON() throws {
        let sse = AnthropicTranslator.streamingToolUseInputDeltaEvent(index: 1, partialJSON: "{\"query\":")
        let (event, data) = try parseSSE(sse)
        XCTAssertEqual(event, "content_block_delta")
        XCTAssertEqual(data["index"] as? Int, 1)
        let delta = try XCTUnwrap(data["delta"] as? [String: Any])
        XCTAssertEqual(delta["type"] as? String, "input_json_delta")
        XCTAssertEqual(delta["partial_json"] as? String, "{\"query\":")
    }

    func testStreamingContentBlockStopEventHasIndex() throws {
        let sse = AnthropicTranslator.streamingContentBlockStopEvent(index: 3)
        let (event, data) = try parseSSE(sse)
        XCTAssertEqual(event, "content_block_stop")
        XCTAssertEqual(data["index"] as? Int, 3)
    }

    func testStreamingMessageDeltaEventHasStopReason() throws {
        let sse = AnthropicTranslator.streamingMessageDeltaEvent(stopReason: "tool_use", outputTokens: 42)
        let (event, data) = try parseSSE(sse)
        XCTAssertEqual(event, "message_delta")
        let delta = try XCTUnwrap(data["delta"] as? [String: Any])
        XCTAssertEqual(delta["stop_reason"] as? String, "tool_use")
        let usage = try XCTUnwrap(data["usage"] as? [String: Any])
        XCTAssertEqual(usage["output_tokens"] as? Int, 42)
    }

    func testStreamingMessageStopEventFormat() throws {
        let sse = AnthropicTranslator.streamingMessageStopEvent()
        let (event, data) = try parseSSE(sse)
        XCTAssertEqual(event, "message_stop")
        XCTAssertEqual(data["type"] as? String, "message_stop")
    }

    func testStreamingDoneEventsContainsThreeEvents() throws {
        let events = AnthropicTranslator.streamingDoneEvents(messageId: "msg_test", model: "glm-5")
        XCTAssertEqual(events.count, 3)
        let (ev1, _) = try parseSSE(events[0])
        let (ev2, _) = try parseSSE(events[1])
        let (ev3, _) = try parseSSE(events[2])
        XCTAssertEqual(ev1, "content_block_stop")
        XCTAssertEqual(ev2, "message_delta")
        XCTAssertEqual(ev3, "message_stop")
    }

    // MARK: - State Machine Tests

    func testProcessChunkTextEmitsMessageStartAndDelta() throws {
        var state = AnthropicTranslator.StreamingState(requestID: "req_1", messageID: "msg_1")
        let chunk: [String: Any] = [
            "choices": [["delta": ["content": "Hello"], "finish_reason": NSNull()]]
        ]

        let events = AnthropicTranslator.processStreamingChunk(chunk, state: &state, model: "glm-5")
        XCTAssertTrue(state.sentMessageStart)
        XCTAssertEqual(state.textAnthropicIndex, 0)
        // Should have: message_start, text_start, text_delta = 3 events
        XCTAssertEqual(events.count, 3)
        let (ev1, _) = try parseSSE(events[0])
        let (ev2, _) = try parseSSE(events[1])
        let (ev3, _) = try parseSSE(events[2])
        XCTAssertEqual(ev1, "message_start")
        XCTAssertEqual(ev2, "content_block_start")
        XCTAssertEqual(ev3, "content_block_delta")
    }

    func testProcessChunkSecondTextOmitsMessageStart() throws {
        var state = AnthropicTranslator.StreamingState(requestID: "req_1", messageID: "msg_1")
        let chunk1: [String: Any] = ["choices": [["delta": ["content": "Hi"], "finish_reason": NSNull()]]]
        _ = AnthropicTranslator.processStreamingChunk(chunk1, state: &state, model: "glm-5")

        let chunk2: [String: Any] = ["choices": [["delta": ["content": " there"], "finish_reason": NSNull()]]]
        let events = AnthropicTranslator.processStreamingChunk(chunk2, state: &state, model: "glm-5")

        // Second chunk: only text delta (no message_start, no text_start)
        XCTAssertEqual(events.count, 1)
        let (ev, _) = try parseSSE(events[0])
        XCTAssertEqual(ev, "content_block_delta")
    }

    func testProcessChunkToolCallEmitsToolUseStart() throws {
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
        XCTAssertTrue(state.sawToolUse)
        // message_start + tool_use content_block_start = 2 events
        XCTAssertEqual(events.count, 2)
        let (ev2, data2) = try parseSSE(events[1])
        XCTAssertEqual(ev2, "content_block_start")
        let block = try XCTUnwrap(data2["content_block"] as? [String: Any])
        XCTAssertEqual(block["type"] as? String, "tool_use")
        XCTAssertEqual(block["name"] as? String, "search")
    }

    func testProcessChunkToolArgumentsAccumulateBytes() throws {
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

        let toolState = try XCTUnwrap(state.toolStatesByOpenAIIndex[0])
        // {"q": is 5 chars + "test"} is 7 chars = 12
        XCTAssertEqual(toolState.argsBytes, 12)
    }

    func testProcessChunkTextThenToolGetsCorrectIndexes() throws {
        var state = AnthropicTranslator.StreamingState(requestID: "req_1", messageID: "msg_1")

        // Text chunk
        let textChunk: [String: Any] = ["choices": [["delta": ["content": "Let me search"], "finish_reason": NSNull()]]]
        _ = AnthropicTranslator.processStreamingChunk(textChunk, state: &state, model: "glm-5")
        XCTAssertEqual(state.textAnthropicIndex, 0)

        // Tool chunk
        let toolChunk: [String: Any] = [
            "choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "search", "arguments": ""]]]], "finish_reason": NSNull()]]
        ]
        _ = AnthropicTranslator.processStreamingChunk(toolChunk, state: &state, model: "glm-5")

        let toolState = try XCTUnwrap(state.toolStatesByOpenAIIndex[0])
        XCTAssertEqual(toolState.anthropicContentIndex, 1)
        XCTAssertEqual(state.startedAnthropicIndexes, [0, 1])
    }

    func testFinishEventsClosesAllStartedBlocks() throws {
        var state = AnthropicTranslator.StreamingState(requestID: "req_1", messageID: "msg_1")
        state.sentMessageStart = true
        state.startedAnthropicIndexes = [0, 1]
        state.finalStopReason = "end_turn"

        let events = AnthropicTranslator.streamingFinishEvents(state: state)
        // 2 content_block_stop + message_delta + message_stop = 4
        XCTAssertEqual(events.count, 4)
        let (ev1, d1) = try parseSSE(events[0])
        let (ev2, d2) = try parseSSE(events[1])
        XCTAssertEqual(ev1, "content_block_stop")
        XCTAssertEqual(d1["index"] as? Int, 0)
        XCTAssertEqual(ev2, "content_block_stop")
        XCTAssertEqual(d2["index"] as? Int, 1)
    }

    func testFinishEventsToolUseOverridesEndTurn() throws {
        var state = AnthropicTranslator.StreamingState(requestID: "req_1", messageID: "msg_1")
        state.sentMessageStart = true
        state.startedAnthropicIndexes = [0]
        state.sawToolUse = true
        state.finalStopReason = "end_turn"

        let events = AnthropicTranslator.streamingFinishEvents(state: state)
        // Find the message_delta event
        let messageDelta = try events.first { try parseSSE($0).event == "message_delta" }
        let (_, data) = try parseSSE(try XCTUnwrap(messageDelta))
        let delta = try XCTUnwrap(data["delta"] as? [String: Any])
        XCTAssertEqual(delta["stop_reason"] as? String, "tool_use")
    }

    func testFinishEventsNoMessageStartReturnsEmpty() {
        let state = AnthropicTranslator.StreamingState(requestID: "req_1", messageID: "msg_1")
        // sentMessageStart is false by default
        let events = AnthropicTranslator.streamingFinishEvents(state: state)
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Edge Cases

    func testErrorJSONProducesValidJSON() throws {
        let json = AnthropicTranslator.errorJSON(message: "test error")
        let data = try XCTUnwrap(json.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(parsed["type"] as? String, "error")
        let error = try XCTUnwrap(parsed["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, "test error")
    }

    func testStreamingDeltaEventDefaultIndexIsZero() throws {
        let sse = AnthropicTranslator.streamingDeltaEvent(text: "hi")
        let (_, data) = try parseSSE(sse)
        XCTAssertEqual(data["index"] as? Int, 0)
    }
}
