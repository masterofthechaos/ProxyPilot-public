import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers
@testable import ProxyPilotCore

// MARK: - Terminal-signal detection and event shapes

@Suite("Stream completion detection")
struct StreamCompletionDetectionTests {
    private func completion(_ lines: [String]) -> OpenAIChatStreamCompletion {
        var completion = OpenAIChatStreamCompletion()
        lines.forEach { completion.observe(line: $0) }
        return completion
    }

    private let content = #"data: {"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}"#
    private let finish = #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#

    @Test func doneAloneCompletes() {
        let c = completion([content, "data: [DONE]"])
        #expect(c.outcomeAtEndOfStream == .completed)
        #expect(!c.needsInterruptionEvent)
    }

    @Test func doneWithoutSpaceCompletes() {
        #expect(completion([content, "data:[DONE]"]).outcomeAtEndOfStream == .completed)
    }

    /// Some valid upstreams send a terminal finish_reason and close without [DONE].
    @Test func finishReasonWithoutDoneCompletes() {
        let c = completion([content, finish])
        #expect(c.sawFinishReason && !c.sawDone)
        #expect(c.outcomeAtEndOfStream == .completed)
        #expect(!c.needsInterruptionEvent)
    }

    @Test func toolCallsFinishReasonCompletes() {
        let line = #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#
        #expect(completion([content, line]).outcomeAtEndOfStream == .completed)
    }

    @Test func cleanEndWithNeitherSignalIsInterrupted() {
        let usageOnly = #"data: {"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":1}}"#
        let c = completion([content, usageOnly, ": keep-alive comment", ""])
        #expect(c.outcomeAtEndOfStream == .interrupted)
        #expect(c.needsInterruptionEvent)
    }

    @Test func upstreamErrorEventIsAnErrorWithoutASecondEvent() {
        let c = completion([content, #"data: {"error":{"message":"model crashed"}}"#])
        #expect(c.outcomeAtEndOfStream == .upstreamError)
        #expect(!c.needsInterruptionEvent, "the upstream error was already forwarded")
    }

    @Test func openAIErrorEventMatchesTheAISDKErrorChunkShape() throws {
        let data = StreamErrorEvent.openAIChat(message: StreamErrorEvent.interruptedMessage, code: StreamErrorEvent.interruptedCode)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("data: ") && text.hasSuffix("\n\n"))
        #expect(!text.contains("data: [DONE]"), "no completion marker after an error")
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(text.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines).utf8))
                as? [String: Any]
        )
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["message"] as? String == StreamErrorEvent.interruptedMessage)
        #expect(error["code"] as? String == "stream_interrupted")
        #expect(json["choices"] == nil)
    }

    /// OpenCode retries automatically on rate-limit/overload wording; these
    /// messages must not trigger a silent replay of a long request.
    @Test func errorMessagesAvoidClientRetryTriggers() {
        let messages = [
            StreamErrorEvent.interruptedMessage,
            StreamErrorEvent.upstreamFailureMessage(detail: "The network connection was lost."),
        ]
        for message in messages {
            let lower = message.lowercased()
            for trigger in ["rate limit", "too many requests", "rate increased too quickly", "overloaded", "exhausted", "unavailable"] {
                #expect(!lower.contains(trigger), "\(trigger) in \(message)")
            }
        }
        for code in [StreamErrorEvent.interruptedCode, StreamErrorEvent.upstreamFailureCode] {
            #expect(!code.contains("exhausted") && !code.contains("unavailable") && !code.contains("rate_limit"))
        }
    }

    @Test func anthropicErrorEventShape() throws {
        let text = String(decoding: StreamErrorEvent.anthropic(message: "boom"), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "event: error")
        let json = try #require(JSONSerialization.jsonObject(with: Data(lines[1].dropFirst(6).utf8)) as? [String: Any])
        #expect(json["type"] as? String == "error")
        #expect((json["error"] as? [String: Any])?["message"] as? String == "boom")
    }

    /// Journals written before outcomes existed must still decode.
    @Test func legacyJournalRecordsDecodeWithoutAnOutcome() throws {
        let legacy = #"""
        {"timestamp":800000000,"model":"m","promptTokens":1,"completionTokens":2,"durationSeconds":1,"path":"/v1/chat/completions","wasStreaming":true}
        """#
        let record = try JSONDecoder().decode(RequestRecord.self, from: Data(legacy.utf8))
        #expect(record.streamOutcome == nil)

        let labelled = RequestRecord(model: "m", promptTokens: 1, completionTokens: 1, durationSeconds: 1,
                                     path: "/v1/chat/completions", wasStreaming: true, streamOutcome: "interrupted")
        let roundTrip = try JSONDecoder().decode(RequestRecord.self, from: JSONEncoder().encode(labelled))
        #expect(roundTrip.streamOutcome == "interrupted")
    }
}

// MARK: - Engine behaviour against a scripted upstream

/// Scripted raw-socket upstream: answers each request with exact bytes, then
/// either closes cleanly or drops the connection mid-chunk.
private final class ScriptedUpstream: Sendable {
    enum Ending: Sendable { case clean, brokenChunk }

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let channel = NIOLockedValueBox<Channel?>(nil)

    func start(lines: [String], ending: Ending) async throws -> Int {
        let body = lines.map { $0 + "\n\n" }.joined()
        let ch = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ScriptedHandler(body: body, ending: ending))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        channel.withLockedValue { $0 = ch }
        return ch.localAddress!.port!
    }

    func stop() async throws {
        if let ch = channel.withLockedValue({ c -> Channel? in let r = c; c = nil; return r }) {
            try await ch.close()
        }
        try await group.shutdownGracefully()
    }
}

private final class ScriptedHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let body: String
    let ending: ScriptedUpstream.Ending
    private var received = ""
    private var answered = false

    init(body: String, ending: ScriptedUpstream.Ending) {
        self.body = body
        self.ending = ending
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        received += buffer.readString(length: buffer.readableBytes) ?? ""
        guard !answered, let headerEnd = received.range(of: "\r\n\r\n") else { return }
        let head = received[..<headerEnd.lowerBound].lowercased()
        let length = head.split(separator: "\r\n")
            .first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        guard received[headerEnd.upperBound...].utf8.count >= length else { return }
        answered = true

        let chunk = String(body.utf8.count, radix: 16) + "\r\n" + body + "\r\n"
        var response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" + chunk
        switch ending {
        case .clean:
            response += "0\r\n\r\n"
            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: response))).whenComplete { _ in
                context.close(promise: nil)
            }
        case .brokenChunk:
            // Announce a 256-byte chunk, send 6 bytes, then drop the connection.
            response += "100\r\nbroken"
            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: response))).whenComplete { _ in
                context.eventLoop.scheduleTask(in: .milliseconds(100)) {
                    context.close(promise: nil)
                }
            }
        }
    }
}

/// Collects everything the proxy writes until it closes, without an HTTP
/// client that would hide a second response header block.
private final class RawCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let bytes = NIOLockedValueBox("")
    let isClosed = NIOLockedValueBox(false)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let text = buffer.readString(length: buffer.readableBytes) ?? ""
        bytes.withLockedValue { $0 += text }
    }

    func channelInactive(context: ChannelHandlerContext) {
        isClosed.withLockedValue { $0 = true }
    }
}

@Suite("Streaming outcome through the NIO engine", .serialized)
struct StreamOutcomeEngineTests {
    private static let content =
        #"data: {"id":"x","object":"chat.completion.chunk","model":"fixture","choices":[{"index":0,"delta":{"content":"partial fixture text"},"finish_reason":null}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}"#
    private static let finish =
        #"data: {"id":"x","model":"fixture","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#

    private struct Exchange {
        let raw: String
        let journal: [SessionReportEvent]
        var ioRecords: [InputOutputLogRecord] = []
        var statusLineCount: Int { raw.components(separatedBy: "HTTP/1.1 ").count - 1 }
        var errorEvents: Int { raw.components(separatedBy: #"data: {"error":"#).count - 1 }
    }

    private func exchange(
        lines: [String],
        ending: ScriptedUpstream.Ending,
        path: String = "/v1/chat/completions",
        body: String = #"{"model":"fixture","stream":true,"messages":[{"role":"user","content":"hi"}]}"#,
        provider: UpstreamProvider? = nil,
        withLogger: Bool = false
    ) async throws -> Exchange {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reportURL = directory.appendingPathComponent("session-report.jsonl")
        let stats = SessionStats(sessionReportURL: reportURL, sessionSource: "cli", sessionID: "stream-outcome-test")

        let upstream = ScriptedUpstream()
        let upstreamPort = try await upstream.start(lines: lines, ending: ending)
        var logStore: InputOutputLogStore?
        var recorder: InputOutputLoggingRecorder?
        if withLogger {
            let preferences = InputOutputLoggingPreferencesStore(url: directory.appendingPathComponent("settings.json"))
            try preferences.save(InputOutputLoggingPreferences(
                enabled: true, recordInputs: true, recordOutputs: true, cliEnabled: true, retention: .twentyFourHoursDefault))
            let store = InputOutputLogStore(url: directory.appendingPathComponent("records.jsonl.enc"),
                                            encryptionKey: Data(repeating: 7, count: 32))
            logStore = store
            recorder = InputOutputLoggingRecorder(source: "cli", preferencesStore: preferences, logStore: store)
        }
        let config: ProxyConfiguration
        if let provider {
            // Native Anthropic passthrough, configured as the existing passthrough tests do.
            config = ProxyConfiguration(
                port: 0,
                upstreamProvider: provider,
                upstreamAPIBaseURL: "http://127.0.0.1:\(upstreamPort)/v1",
                upstreamAPIKey: "sk-test",
                masterKey: "local-test-capability",
                requiresAuth: false,
                preferredAnthropicUpstreamModel: "fixture",
                sessionStats: stats
            )
        } else {
            config = ProxyConfiguration(
                port: 0,
                upstreamAPIBaseURL: "http://127.0.0.1:\(upstreamPort)",
                requiresAuth: false,
                sessionStats: stats,
                inputOutputLogger: recorder
            )
        }
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let collector = RawCollector()
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(collector) }
            .connect(host: "127.0.0.1", port: Int(port))
            .get()
        let request = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nAuthorization: Bearer local-test-capability\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        try await client.writeAndFlush(client.allocator.buffer(string: request)).get()

        // The proxy keeps the connection open after a chunked response; wait
        // for the terminating chunk (or close), with a bound.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let raw = collector.bytes.withLockedValue { $0 }
            if raw.hasSuffix("0\r\n\r\n") || collector.isClosed.withLockedValue({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(200)) // let the journal append finish
        let raw = collector.bytes.withLockedValue { $0 }
        try? await client.close()
        try await group.shutdownGracefully()
        try await server.stop()
        try await upstream.stop()
        let journal = (try? SessionReportStore.readEvents(from: reportURL)) ?? []
        let ioRecords = (try? await logStore?.readRecords()) ?? []
        return Exchange(raw: raw, journal: journal, ioRecords: ioRecords ?? [])
    }

    @Test func finishWithDoneIsCompleted() async throws {
        let x = try await exchange(lines: [Self.content, Self.finish, "data: [DONE]"], ending: .clean)
        #expect(x.statusLineCount == 1)
        #expect(x.errorEvents == 0)
        #expect(x.raw.contains("data: [DONE]"))
        #expect(x.journal.map(\.record.streamOutcome) == ["completed"])
    }

    @Test func finishReasonWithoutDoneIsCompleted() async throws {
        let x = try await exchange(lines: [Self.content, Self.finish], ending: .clean)
        #expect(x.statusLineCount == 1)
        #expect(x.errorEvents == 0)
        #expect(x.journal.map(\.record.streamOutcome) == ["completed"])
    }

    @Test func cleanEndWithoutTerminalSignalIsReportedInterrupted() async throws {
        let x = try await exchange(lines: [Self.content], ending: .clean)
        #expect(x.statusLineCount == 1)
        #expect(x.raw.contains("partial fixture text"))
        #expect(x.errorEvents == 1)
        #expect(x.raw.contains("stream_interrupted"))
        #expect(!x.raw.contains("data: [DONE]"))
        #expect(x.journal.count == 1)
        #expect(x.journal.first?.record.streamOutcome == "interrupted")
        #expect(x.journal.first?.record.promptTokens == 4)
    }

    /// A transport break after 200 must reach the client as an error and be
    /// journaled as not completed. Linux's client can end a broken chunked
    /// body without throwing, so the exact label is not asserted.
    @Test func transportBreakAfterHeadersIsReportedInBand() async throws {
        let x = try await exchange(lines: [Self.content], ending: .brokenChunk)
        #expect(x.statusLineCount == 1)
        #expect(x.raw.contains("partial fixture text"))
        #expect(x.errorEvents == 1)
        #expect(x.journal.count == 1)
        #expect(x.journal.first?.record.streamOutcome != "completed")
        #expect(x.journal.first?.record.streamOutcome != nil)
    }

    /// Anthropic Messages (translated from an OpenAI-compatible upstream):
    /// a break after the stream started ends with `event: error`, never a
    /// second response.
    @Test func anthropicTranslatedStreamBreakEndsWithErrorEvent() async throws {
        let x = try await exchange(
            lines: [Self.content],
            ending: .brokenChunk,
            path: "/v1/messages",
            body: #"{"model":"fixture","max_tokens":64,"stream":true,"messages":[{"role":"user","content":"hi"}]}"#
        )
        #expect(x.statusLineCount == 1)
        #expect(x.raw.contains("event: message_start"))
        #if canImport(Darwin)
        #expect(x.raw.contains("event: error"))
        #endif
    }

    /// A terminal signal followed by an abnormal close is still a finished
    /// response: no error event, journaled as completed.
    @Test(arguments: [true, false])
    func terminalSignalThenTransportBreakIsCompleted(withDone: Bool) async throws {
        let lines = withDone ? [Self.content, Self.finish, "data: [DONE]"] : [Self.content, Self.finish]
        let x = try await exchange(lines: lines, ending: .brokenChunk)
        #expect(x.statusLineCount == 1)
        #expect(x.errorEvents == 0, "\(x.raw)")
        #expect(x.journal.map(\.record.streamOutcome) == ["completed"])
    }

    @Test func inputOutputRecordCarriesTheOutcome() async throws {
        let x = try await exchange(lines: [Self.content], ending: .clean, withLogger: true)
        #expect(x.ioRecords.count == 1)
        #expect(x.ioRecords.first?.streamOutcome == "interrupted")
        #expect(x.ioRecords.first?.statusCode == 200, "the HTTP status actually sent")
        #expect(x.ioRecords.first?.output?.text?.contains("stream_interrupted") == true)
    }

    /// Native Anthropic passthrough: a break after the stream started ends
    /// with `event: error` and a terminated response.
    @Test func anthropicPassthroughStreamBreakEndsWithErrorEvent() async throws {
        let start = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_fixture\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"fixture\",\"content\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}"
        let x = try await exchange(
            lines: [start],
            ending: .brokenChunk,
            path: "/v1/messages",
            body: #"{"model":"fixture","max_tokens":64,"stream":true,"messages":[{"role":"user","content":"hi"}]}"#,
            provider: .deepSeek
        )
        #expect(x.statusLineCount == 1, "\(x.raw)")
        #expect(x.raw.contains("message_start"))
        #if canImport(Darwin)
        #expect(x.raw.contains("event: error"), "\(x.raw)")
        #expect(x.raw.hasSuffix("0\r\n\r\n"), "the chunked response is terminated")
        #endif
    }

    @Test func upstreamErrorEventIsForwardedOnceAndJournaledAsError() async throws {
        let x = try await exchange(lines: [Self.content, #"data: {"error":{"message":"model crashed"}}"#], ending: .clean)
        #expect(x.statusLineCount == 1)
        #expect(x.errorEvents == 1)
        #expect(x.raw.contains("model crashed"))
        #expect(x.journal.first?.record.streamOutcome == "upstream_error")
    }
}
