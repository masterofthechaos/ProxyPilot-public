import XCTest
import ProxyPilotCore
@testable import ProxyPilot

final class SessionHistorySessionTests: XCTestCase {
    func testBuildsNewestFirstSessionSummariesFromReportEvents() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let events = [
            SessionReportEvent(
                source: "cli",
                sessionID: "cli-old",
                record: RequestRecord(
                    timestamp: older,
                    model: "glm-4.5-air",
                    promptTokens: 10,
                    completionTokens: 5,
                    durationSeconds: 1.2,
                    path: "/v1/chat/completions",
                    wasStreaming: false
                )
            ),
            SessionReportEvent(
                source: "cli",
                sessionID: "cli-new",
                record: RequestRecord(
                    timestamp: newer,
                    model: "glm-5.1",
                    promptTokens: 30,
                    completionTokens: 20,
                    durationSeconds: 2.4,
                    path: "/v1/messages",
                    wasStreaming: true
                )
            ),
            SessionReportEvent(
                source: "cli",
                sessionID: "cli-new",
                record: RequestRecord(
                    timestamp: newer.addingTimeInterval(10),
                    model: "glm-5.1",
                    promptTokens: 40,
                    completionTokens: 10,
                    durationSeconds: 1.8,
                    path: "/v1/messages",
                    wasStreaming: false
                )
            )
        ]

        let sessions = SessionHistorySession.build(from: events)

        XCTAssertEqual(sessions.map(\.id), ["cli-new", "cli-old"])
        XCTAssertEqual(sessions[0].source, "cli")
        XCTAssertEqual(sessions[0].requestCount, 2)
        XCTAssertEqual(sessions[0].totalPromptTokens, 70)
        XCTAssertEqual(sessions[0].totalCompletionTokens, 30)
        XCTAssertEqual(sessions[0].totalTokens, 100)
        XCTAssertEqual(sessions[0].modelDistribution.first?.model, "glm-5.1")
        XCTAssertEqual(sessions[0].modelDistribution.first?.count, 2)
        XCTAssertEqual(sessions[0].requests.map(\.timestamp), [newer, newer.addingTimeInterval(10)])
    }

    func testInputOutputAvailabilityReflectsCLICaptureToggle() {
        let session = SessionHistorySession(id: "cli-session", source: "cli", requests: [])

        XCTAssertEqual(
            session.inputOutputLogAvailability(
                masterLoggingEnabled: true,
                cliLoggingEnabled: false,
                matchingRecordCount: 0
            ),
            .cliCaptureDisabled
        )

        XCTAssertEqual(
            session.inputOutputLogAvailability(
                masterLoggingEnabled: true,
                cliLoggingEnabled: true,
                matchingRecordCount: 0
            ),
            .enabledWaitingForRecords
        )

        XCTAssertEqual(
            session.inputOutputLogAvailability(
                masterLoggingEnabled: true,
                cliLoggingEnabled: false,
                matchingRecordCount: 2
            ),
            .hasRecords(count: 2)
        )
    }

    func testInputOutputAvailabilityAllowsGUISessionsWhenMasterLoggingIsEnabled() {
        let session = SessionHistorySession(id: "gui-session", source: "gui", requests: [])

        XCTAssertEqual(
            session.inputOutputLogAvailability(
                masterLoggingEnabled: true,
                cliLoggingEnabled: false,
                matchingRecordCount: 0
            ),
            .enabledWaitingForRecords
        )
    }

    func testInputOutputLogViewModelsFilterAndSortBySessionID() {
        let older = InputOutputLogRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            source: "cli",
            sessionID: "target",
            path: "/v1/messages",
            model: "glm-5.1",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("older prompt"),
            output: .utf8("older output")
        )
        let newer = InputOutputLogRecord(
            timestamp: Date(timeIntervalSince1970: 120),
            source: "cli",
            sessionID: "target",
            path: "/v1/messages",
            model: "glm-5.1",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("newer prompt"),
            output: .utf8("newer output")
        )
        let otherSession = InputOutputLogRecord(
            timestamp: Date(timeIntervalSince1970: 110),
            source: "cli",
            sessionID: "other",
            path: "/v1/messages",
            model: "glm-5.1",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("other prompt"),
            output: .utf8("other output")
        )

        let viewModels = SessionHistoryLogRecordViewModel.matching(
            [newer, otherSession, older],
            sessionID: "target"
        )

        XCTAssertEqual(viewModels.map(\.record.input?.sessionHistoryText), ["older prompt", "newer prompt"])
        XCTAssertEqual(viewModels.map(\.index), [1, 2])
    }

    func testInputOutputLogViewModelsJoinSessionTokenCountsBySortedOrder() {
        let firstTimestamp = Date(timeIntervalSince1970: 100)
        let secondTimestamp = Date(timeIntervalSince1970: 120)
        let firstLog = InputOutputLogRecord(
            timestamp: firstTimestamp,
            source: "cli",
            sessionID: "target",
            path: "/v1/messages",
            model: "glm-4.5-air",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("first prompt"),
            output: .utf8("first output")
        )
        let secondLog = InputOutputLogRecord(
            timestamp: secondTimestamp,
            source: "cli",
            sessionID: "target",
            path: "/v1/messages",
            model: "glm-5.1",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("second prompt"),
            output: .utf8("second output")
        )
        let session = SessionHistorySession(
            id: "target",
            source: "cli",
            requests: [
                RequestRecord(
                    timestamp: firstTimestamp,
                    model: "glm-4.5-air",
                    promptTokens: 1_500,
                    completionTokens: 250,
                    durationSeconds: 1.0,
                    path: "/v1/messages",
                    wasStreaming: true
                ),
                RequestRecord(
                    timestamp: secondTimestamp,
                    model: "glm-5.1",
                    promptTokens: 30,
                    completionTokens: 40,
                    durationSeconds: 2.0,
                    path: "/v1/messages",
                    wasStreaming: true
                )
            ]
        )

        let viewModels = SessionHistoryLogRecordViewModel.matching([secondLog, firstLog], session: session)

        XCTAssertEqual(viewModels.map { $0.tokenCounts?.promptTokens }, [1_500, 30])
        XCTAssertEqual(viewModels.map { $0.tokenCounts?.completionTokens }, [250, 40])
        XCTAssertEqual(viewModels.map { $0.tokenCounts?.totalTokens }, [1_750, 70])
    }

    func testInputOutputLogViewModelsOmitTokenCountsWhenLogAndRequestCountsDiverge() {
        let firstTimestamp = Date(timeIntervalSince1970: 100)
        let secondTimestamp = Date(timeIntervalSince1970: 120)
        let firstLog = InputOutputLogRecord(
            timestamp: firstTimestamp,
            source: "cli",
            sessionID: "target",
            path: "/v1/messages",
            model: "glm-4.5-air",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("first prompt"),
            output: .utf8("first output")
        )
        let secondLog = InputOutputLogRecord(
            timestamp: secondTimestamp,
            source: "cli",
            sessionID: "target",
            path: "/v1/messages",
            model: "glm-5.1",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("second prompt"),
            output: .utf8("second output")
        )
        let session = SessionHistorySession(
            id: "target",
            source: "cli",
            requests: [
                RequestRecord(
                    timestamp: secondTimestamp,
                    model: "glm-5.1",
                    promptTokens: 30,
                    completionTokens: 40,
                    durationSeconds: 2.0,
                    path: "/v1/chat/completions",
                    wasStreaming: false
                )
            ]
        )

        let viewModels = SessionHistoryLogRecordViewModel.matching([secondLog, firstLog], session: session)

        XCTAssertEqual(viewModels.count, 2)
        XCTAssertEqual(viewModels.map { $0.record.input?.sessionHistoryText }, ["first prompt", "second prompt"])
        XCTAssertEqual(viewModels.map(\.tokenCounts), [nil, nil])
    }

    func testSessionHistoryDisplayPolicyCapsRequestsByDefault() {
        let requests = (0..<37).map { index in
            RequestRecord(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                model: "glm-5.1",
                promptTokens: 90_000 + index,
                completionTokens: 100,
                durationSeconds: 1.0,
                path: "/v1/messages",
                wasStreaming: true
            )
        }
        let session = SessionHistorySession(id: "large", source: "cli", requests: requests)

        let collapsed = SessionHistoryDisplayPolicy.visibleRequests(for: session, showAll: false)
        let expanded = SessionHistoryDisplayPolicy.visibleRequests(for: session, showAll: true)

        XCTAssertEqual(
            collapsed.map(\.timestamp),
            requests.prefix(SessionHistoryDisplayPolicy.defaultVisibleRequestLimit).map(\.timestamp)
        )
        XCTAssertEqual(expanded.map(\.timestamp), requests.map(\.timestamp))
        XCTAssertEqual(
            SessionHistoryDisplayPolicy.hiddenRequestCount(for: session, showAll: false),
            requests.count - SessionHistoryDisplayPolicy.defaultVisibleRequestLimit
        )
        XCTAssertEqual(SessionHistoryDisplayPolicy.hiddenRequestCount(for: session, showAll: true), 0)
    }

    func testSessionHistoryDisplayPolicyCapsLogsByDefault() {
        let records = (0..<37).map { index in
            InputOutputLogRecord(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                source: "cli",
                sessionID: "large",
                path: "/v1/messages",
                model: "glm-5.1",
                provider: "zai",
                wasStreaming: true,
                statusCode: 200,
                retentionExpiresAt: nil,
                input: .utf8("prompt \(index)"),
                output: .utf8("output \(index)")
            )
        }
        let viewModels = records.enumerated().map { offset, record in
            SessionHistoryLogRecordViewModel(index: offset + 1, record: record, tokenCounts: nil)
        }

        let collapsed = SessionHistoryDisplayPolicy.visibleLogs(viewModels, showAll: false)
        let expanded = SessionHistoryDisplayPolicy.visibleLogs(viewModels, showAll: true)

        XCTAssertEqual(
            collapsed.map(\.index),
            Array(1...SessionHistoryDisplayPolicy.defaultVisibleLogLimit)
        )
        XCTAssertEqual(expanded.map(\.index), Array(1...37))
        XCTAssertEqual(
            SessionHistoryDisplayPolicy.hiddenLogCount(viewModels, showAll: false),
            37 - SessionHistoryDisplayPolicy.defaultVisibleLogLimit
        )
        XCTAssertEqual(SessionHistoryDisplayPolicy.hiddenLogCount(viewModels, showAll: true), 0)
    }

    func testInputOutputLogMarkdownIncludesPromptAndOutputBodies() {
        let record = InputOutputLogRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            source: "cli",
            sessionID: "target",
            path: "/v1/messages",
            model: "glm-5.1",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("{\"prompt\":\"hello\"}"),
            output: .utf8("{\"answer\":\"world\"}")
        )

        let markdown = SessionHistoryLogExport.markdown(for: record)

        XCTAssertTrue(markdown.contains("## Prompt"))
        XCTAssertTrue(markdown.contains("```json"))
        XCTAssertTrue(markdown.contains("{\"prompt\":\"hello\"}"))
        XCTAssertTrue(markdown.contains("## Output"))
        XCTAssertTrue(markdown.contains("{\"answer\":\"world\"}"))
    }

    func testInputOutputLogMarkdownUsesTextFenceForPlainTextBodies() {
        let record = InputOutputLogRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            source: "cli",
            sessionID: "target",
            path: "/v1/messages",
            model: "glm-5.1",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("plain prompt"),
            output: .utf8("plain output")
        )

        let markdown = SessionHistoryLogExport.markdown(for: record)

        XCTAssertTrue(markdown.contains("```text\nplain prompt"))
        XCTAssertTrue(markdown.contains("```text\nplain output"))
    }

    func testMarkdownFenceLengthExceedsLongestInnerBacktickRun() {
        XCTAssertEqual(SessionHistoryLogExport.markdownFence(for: "no backticks here"), "```")
        XCTAssertEqual(SessionHistoryLogExport.markdownFence(for: "one `inline`"), "```")
        XCTAssertEqual(SessionHistoryLogExport.markdownFence(for: "two ``inline``"), "```")
        // Inner three-backtick run is exactly the default fence length, so
        // the outer fence must be at least four.
        XCTAssertEqual(SessionHistoryLogExport.markdownFence(for: "```swift\nlet x = 1\n```"), "````")
        // Five-backtick run requires a six-backtick outer fence.
        XCTAssertEqual(SessionHistoryLogExport.markdownFence(for: "before\n`````\ninner\n`````\nafter"), "``````")
    }

    func testInputOutputLogMarkdownEscapesInnerCodeBlocks() {
        // The exact failure shape from the Codex review: assistant output
        // contains a nested fenced code block. With the fixed-length 3-fence
        // the outer fence would close early and the `## Output` heading
        // would render as a paragraph below a stray code block.
        let nested = """
        Here is an example:
        ```swift
        let x = 1
        ```
        Thanks!
        """
        let record = InputOutputLogRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            source: "cli",
            sessionID: "target",
            path: "/v1/messages",
            model: "glm-5.1",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8(nested),
            output: .utf8(nested)
        )

        let markdown = SessionHistoryLogExport.markdown(for: record)

        // Outer fence is four backticks, opening with the text language tag.
        XCTAssertTrue(markdown.contains("````text\nHere is an example:"))
        // Inner three-backtick fence is preserved verbatim.
        XCTAssertTrue(markdown.contains("```swift"))
        // Both sections present and unbroken — the parsed structure of the
        // body precedes a complete closing fence followed by the next
        // heading on its own line, not concatenated text.
        XCTAssertTrue(markdown.contains("## Output"))
        // The literal inner content survives without being treated as
        // markdown above it.
        XCTAssertTrue(markdown.contains("let x = 1"))
        XCTAssertTrue(markdown.contains("Thanks!"))

        // Sanity: the rendered output has exactly two outer-fence opens
        // (prompt and output sections), each four backticks long, sitting
        // on a line by themselves with the language tag.
        let openings = markdown.components(separatedBy: "````text\n").count - 1
        XCTAssertEqual(openings, 2)
    }

    func testInputOutputLogMarkdownSurfacesTruncationNotice() {
        let record = InputOutputLogRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            source: "cli",
            sessionID: "target",
            path: "/v1/messages",
            model: "glm-5.1",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("hi"),
            output: .utf8("response (cut off)"),
            outputTruncated: true
        )

        let markdown = SessionHistoryLogExport.markdown(for: record)

        XCTAssertTrue(markdown.contains("truncated"))
    }

    func testSensitiveCopyLabelsWarnAboutDecryptedPromptOutputContent() {
        XCTAssertEqual(SessionHistorySensitiveCopy.menuSectionTitle, "Decrypted prompt/output logs")
        XCTAssertTrue(SessionHistorySensitiveCopy.jsonlMenuTitle.contains("(decrypted)"))
        XCTAssertTrue(SessionHistorySensitiveCopy.markdownMenuTitle.contains("(decrypted)"))
        XCTAssertTrue(SessionHistorySensitiveCopy.inlineNotice.contains("source snippets"))
        XCTAssertTrue(SessionHistorySensitiveCopy.inlineNotice.contains("local file paths"))
        XCTAssertTrue(SessionHistorySensitiveCopy.inlineNotice.contains("decrypted content"))
    }

    func testOutputParserExtractsAssistantTextFromAnthropicSSE() {
        let output = InputOutputLogContent.utf8("""
        event: message_start
        data: {"type":"message_start","message":{"content":[],"type":"message"}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

        event: message_stop
        data: {"type":"message_stop"}
        """)

        let parsed = SessionHistoryOutputParser.parse(output)

        XCTAssertEqual(parsed.kind, .assistantResponse)
        XCTAssertEqual(parsed.assistantText, "Hello world")
        XCTAssertEqual(parsed.summary, "Assistant response")
        XCTAssertEqual(parsed.toolCalls, [])
        XCTAssertFalse(parsed.hasMalformedData)
    }

    func testOutputParserIdentifiesToolCallOnlySSE() {
        let output = InputOutputLogContent.utf8("""
        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call_123","name":"Bash","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"command\\":\\"pwd\\"}"}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}
        """)

        let parsed = SessionHistoryOutputParser.parse(output)

        XCTAssertEqual(parsed.kind, .toolCallOnly)
        XCTAssertEqual(parsed.summary, "Tool call only")
        XCTAssertEqual(parsed.assistantText, "")
        XCTAssertEqual(parsed.toolCalls.map(\.name), ["Bash"])
        XCTAssertEqual(parsed.toolCalls.first?.inputPreview, "{\"command\":\"pwd\"}")
    }

    func testOutputParserExtractsAssistantTextFromOpenAISSE() {
        let output = InputOutputLogContent.utf8("""
        data: {"choices":[{"delta":{"content":"OpenAI "}}]}

        data: {"choices":[{"delta":{"content":"stream"}}]}

        data: [DONE]
        """)

        let parsed = SessionHistoryOutputParser.parse(output)

        XCTAssertEqual(parsed.kind, .assistantResponse)
        XCTAssertEqual(parsed.assistantText, "OpenAI stream")
        XCTAssertEqual(parsed.summary, "Assistant response")
        XCTAssertFalse(parsed.hasMalformedData)
    }

    func testOutputParserCoalescesOpenAIStreamingToolCallChunksByIndex() {
        // A single Bash tool call delivered across three SSE chunks, each
        // keyed by `choices[0].delta.tool_calls[0].index == 0`. Continuation
        // chunks omit `id` and `function.name`. Before the fix this rendered
        // as three rows: one real and two phantom "Tool" rows.
        let output = InputOutputLogContent.utf8(#"""
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"Bash","arguments":"{\"comm"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"and\":\"pw"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"d\"}"}}]}}]}

        data: [DONE]
        """#)

        let parsed = SessionHistoryOutputParser.parse(output)

        XCTAssertEqual(parsed.kind, .toolCallOnly)
        XCTAssertEqual(parsed.toolCalls.count, 1, "Continuation chunks should not produce ghost rows")
        XCTAssertEqual(parsed.toolCalls.first?.id, "call_abc")
        XCTAssertEqual(parsed.toolCalls.first?.name, "Bash")
        XCTAssertEqual(parsed.toolCalls.first?.inputPreview, "{\"command\":\"pwd\"}")
    }

    func testOutputParserKeepsParallelOpenAIToolCallsSeparateByIndex() {
        // Two tool calls in flight simultaneously, interleaved chunks.
        let output = InputOutputLogContent.utf8(#"""
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_one","function":{"name":"Bash","arguments":"{\"a"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_two","function":{"name":"Read","arguments":"{\"f"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\":1}"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"ile\":2}"}}]}}]}

        data: [DONE]
        """#)

        let parsed = SessionHistoryOutputParser.parse(output)

        XCTAssertEqual(parsed.toolCalls.count, 2)
        XCTAssertEqual(parsed.toolCalls[0].id, "call_one")
        XCTAssertEqual(parsed.toolCalls[0].name, "Bash")
        XCTAssertEqual(parsed.toolCalls[0].inputPreview, "{\"a\":1}")
        XCTAssertEqual(parsed.toolCalls[1].id, "call_two")
        XCTAssertEqual(parsed.toolCalls[1].name, "Read")
        XCTAssertEqual(parsed.toolCalls[1].inputPreview, "{\"file\":2}")
    }

    func testOutputParserPreservesNonStreamingMessageToolCalls() {
        // The non-streaming `message.tool_calls` path must continue to
        // produce one row per entry, regardless of any `index` fields.
        let output = InputOutputLogContent.utf8(#"""
        {"choices":[{"message":{"content":"","tool_calls":[
            {"id":"call_a","function":{"name":"Bash","arguments":"{\"x\":1}"}},
            {"id":"call_b","function":{"name":"Read","arguments":"{\"y\":2}"}}
        ]}}]}
        """#)

        let parsed = SessionHistoryOutputParser.parse(output)

        XCTAssertEqual(parsed.toolCalls.count, 2)
        XCTAssertEqual(parsed.toolCalls.map(\.name), ["Bash", "Read"])
        XCTAssertEqual(parsed.toolCalls.map(\.inputPreview), ["{\"x\":1}", "{\"y\":2}"])
    }

    func testOutputParserFallsThroughWhenStreamingChunkOmitsIndex() {
        // Some older OpenAI-compatible providers omit `index` entirely.
        // Without an index we cannot safely coalesce, so each chunk
        // becomes its own row — same behavior as before the fix.
        let output = InputOutputLogContent.utf8(#"""
        data: {"choices":[{"delta":{"tool_calls":[{"id":"call_legacy","function":{"name":"Bash","arguments":"{\"cmd\":\"pwd\"}"}}]}}]}

        data: [DONE]
        """#)

        let parsed = SessionHistoryOutputParser.parse(output)

        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(parsed.toolCalls.first?.id, "call_legacy")
        XCTAssertEqual(parsed.toolCalls.first?.name, "Bash")
    }

    func testOutputParserFallsBackToRawStructureForUnknownOutput() {
        let output = InputOutputLogContent.utf8("{\"unexpected\":true}")

        let parsed = SessionHistoryOutputParser.parse(output)

        XCTAssertEqual(parsed.kind, .rawStructure)
        XCTAssertEqual(parsed.summary, "Raw structure")
        XCTAssertEqual(parsed.assistantText, "")
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }
}
