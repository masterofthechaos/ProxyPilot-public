import XCTest
import Darwin
import Network
import ProxyPilotCore
@testable import ProxyPilot

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Scripted upstream: answers every request with exact SSE bytes, then closes
/// cleanly or drops the connection inside a chunk.
private final class ScriptedSSEUpstream: @unchecked Sendable {
    enum Ending { case clean, brokenChunk }

    private let body: String
    private let ending: Ending
    private let queue = DispatchQueue(label: "proxypilot.scripted-sse-upstream")
    private var listener: NWListener?

    init(events: [String], ending: Ending) {
        self.body = events.map { $0 + "\n\n" }.joined()
        self.ending = ending
    }

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port!.rawValue) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return connection.cancel() }
                connection.start(queue: self.queue)
                self.receive(on: connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var next = accumulated
            if let data { next.append(data) }
            if isComplete || error != nil || Self.isComplete(next) {
                self.answer(on: connection)
            } else {
                self.receive(on: connection, accumulated: next)
            }
        }
    }

    private static func isComplete(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        guard let split = text.range(of: "\r\n\r\n") else { return false }
        let length = text[..<split.lowerBound].lowercased().split(separator: "\r\n")
            .first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        return text[split.upperBound...].utf8.count >= length
    }

    private func answer(on connection: NWConnection) {
        var response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            + String(body.utf8.count, radix: 16) + "\r\n" + body + "\r\n"
        switch ending {
        case .clean:
            response += "0\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        case .brokenChunk:
            response += "100\r\nbroken"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [queue] _ in
                queue.asyncAfter(deadline: .now() + 0.1) { connection.forceCancel() }
            })
        }
    }
}

/// Reads everything the proxy writes, without an HTTP client that would hide
/// a second response header block.
private final class RawExchange: @unchecked Sendable {
    private let queue = DispatchQueue(label: "proxypilot.raw-exchange")
    private let connection: NWConnection
    private let once = Once()
    private var collected = Data()
    private var continuation: CheckedContinuation<String, Never>?

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func run(path: String, body: Data, port: UInt16, timeout: TimeInterval = 8) async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.connection.stateUpdateHandler = { [self] state in
                    if case .ready = state {
                        let head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
                        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [self] _ in read() })
                    } else if case .failed = state {
                        finish()
                    }
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) { self.finish() }
            }
        }
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data { collected.append(data) }
            if isComplete || error != nil { finish() } else { read() }
        }
    }

    private func finish() {
        guard once.claim() else { return }
        connection.cancel()
        continuation?.resume(returning: String(decoding: collected, as: UTF8.self))
        continuation = nil
    }
}

final class LocalProxyServerStreamOutcomeTests: XCTestCase {
    private static let content =
        #"data: {"id":"x","object":"chat.completion.chunk","model":"fixture","choices":[{"index":0,"delta":{"content":"partial fixture text"},"finish_reason":null}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}"#
    private static let finish =
        #"data: {"id":"x","model":"fixture","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
    private static let nativeStart =
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_fixture\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"fixture\",\"content\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}"

    private struct Result {
        let raw: String
        let journal: [SessionReportEvent]
        let failures: [[String: String]]
        let failedCount: Int
        let pendingCount: Int
        var notice: UpstreamFailureNotice? = nil
        var statusLines: Int { raw.components(separatedBy: "HTTP/1.1 ").count - 1 }
        var openAIErrorEvents: Int { raw.components(separatedBy: #"data: {"error":"#).count - 1 }
    }

    @MainActor
    private func run(
        events: [String],
        ending: ScriptedSSEUpstream.Ending,
        provider: UpstreamProvider = .ollama,
        path: String = "/v1/chat/completions",
        mode: ProxyPilot.AnthropicTranslatorMode = .hardened,
        providerIdentifier: String = "custom",
        unreachableUpstream: Bool = false
    ) async throws -> Result {
        let upstream = ScriptedSSEUpstream(events: events, ending: ending)
        var upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        // Nothing listens on a port that was only reserved and released.
        if unreachableUpstream { upstreamPort = try Self.unusedLoopbackPort() }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reportURL = directory.appendingPathComponent("session-report.jsonl")
        let server = LocalProxyServer(sessionReportURL: reportURL)
        var failures: [[String: String]] = []
        server.telemetryTracker = { name, payload in
            if name == "proxy_request_failed" { failures.append(payload) }
        }
        let port = try Self.unusedLoopbackPort()

        let config = LocalProxyServer.Config(host: "127.0.0.1", port: port, masterKey: "",
            upstreamProvider: provider, analyticsProviderIdentifier: providerIdentifier,
            upstreamAPIBase: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!, upstreamAPIKey: nil,
            allowedModels: ["fixture"], requiresAuth: false, anthropicTranslatorMode: mode,
            miniMaxRoutingMode: .standard, preferredAnthropicUpstreamModel: "fixture", googleThoughtSignatureStore: nil)
        try server.start(config: config)
        defer { try? server.stop() }
        for _ in 0..<30 {
            if server.state.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "fixture", "stream": true, "max_tokens": 64,
            "messages": [["role": "user", "content": "fixture only"]],
        ])
        let raw = await RawExchange(port: port).run(path: path, body: body, port: port)
        for _ in 0..<30 where server.state.pendingRequestCount > 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(150))
        let journal = (try? SessionReportStore.readEvents(from: reportURL)) ?? []
        return Result(raw: raw, journal: journal, failures: failures,
                      failedCount: server.state.failedRequestCount, pendingCount: server.state.pendingRequestCount,
                      notice: server.state.lastUpstreamFailure)
    }

    private static func unusedLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw URLError(.cannotConnectToHost) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw URLError(.cannotConnectToHost) }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        let port = UInt16(bigEndian: boundAddress.sin_port)
        guard port != 0, port != 4000 else { throw URLError(.cannotConnectToHost) }
        return port
    }

    // MARK: - Explained upstream failures

    /// LM Studio 0.4.28's reply to a prompt larger than the loaded context,
    /// captured 2026-11-24: HTTP 200, then one `event: error`.
    private static let lmStudioContextError = "event: error\n" + #"data: {"error":{"message":"Engine protocol predict request returned 400: {\"error\":{\"code\":400,\"message\":\"request (29656 tokens) exceeds the available context size (8192 tokens), try increasing it\",\"type\":\"exceed_context_size_error\",\"n_prompt_tokens\":29656,\"n_ctx\":8192}}"},"message":"Engine protocol predict request returned 400"}"#

    @MainActor
    func testLMStudioContextErrorIsExplainedJournaledAndForwardedOnce() async throws {
        let r = try await run(events: [Self.lmStudioContextError], ending: .clean,
                              provider: .lmStudio, providerIdentifier: "lmstudio")
        XCTAssertEqual(r.statusLines, 1)
        XCTAssertEqual(r.openAIErrorEvents, 1, "the provider's own event is forwarded, not doubled")
        XCTAssertEqual(r.journal.first?.record.streamOutcome, "upstream_error")
        XCTAssertEqual(r.journal.first?.record.upstreamFailure,
                       UpstreamFailure(kind: .contextExceeded, promptTokens: 29656, contextTokens: 8192))
        let message = try XCTUnwrap(r.notice?.message)
        XCTAssertTrue(message.contains("29,656 tokens"), message)
        XCTAssertTrue(message.contains("8,192-token context"), message)
        XCTAssertTrue(message.contains("Reload the model in LM Studio"), message)
    }

    @MainActor
    func testUnreachableLocalServerIsExplainedToClientAndApp() async throws {
        let r = try await run(events: [], ending: .clean, provider: .lmStudio,
                              providerIdentifier: "lmstudio", unreachableUpstream: true)
        XCTAssertTrue(r.raw.hasPrefix("HTTP/1.1 502"), r.raw)
        // JSONSerialization escapes the endpoint's slashes on the wire.
        XCTAssertTrue(r.raw.replacingOccurrences(of: "\\/", with: "/")
            .contains("could not connect to LM Studio at http://127.0.0.1:"), r.raw)
        XCTAssertTrue(r.raw.contains("Start its local server"), r.raw)
        XCTAssertEqual(r.notice?.failure.kind, .serverUnreachable)
        XCTAssertEqual(r.failedCount, 1)
    }

    /// Home's failure notice stays until a request completes: a later
    /// failure without a reason keeps it, a success clears it.
    @MainActor
    func testFailureNoticeIsClearedByACompletedRequestOnly() {
        let state = LocalProxyState()
        let notice = UpstreamFailureNotice(
            failure: UpstreamFailure(kind: .serverUnreachable), message: "fixture", at: Date())
        state.noteUpstreamFailure(notice)
        XCTAssertEqual(state.lastUpstreamFailure?.failure.kind, .serverUnreachable)

        let failed = UUID()
        state.beginRequest(id: failed, modelName: "fixture", analyticsMetadata: nil)
        XCTAssertTrue(state.failRequest(id: failed))
        XCTAssertNotNil(state.lastUpstreamFailure, "a failed request leaves the explanation in place")

        let completed = UUID()
        state.beginRequest(id: completed, modelName: "fixture", analyticsMetadata: nil)
        XCTAssertTrue(state.completeRequest(id: completed))
        XCTAssertNil(state.lastUpstreamFailure)
    }

    // MARK: - Chat completions

    @MainActor
    func testChatFinishWithDoneIsCompleted() async throws {
        let r = try await run(events: [Self.content, Self.finish, "data: [DONE]"], ending: .clean)
        XCTAssertEqual(r.statusLines, 1)
        XCTAssertEqual(r.openAIErrorEvents, 0)
        XCTAssertTrue(r.raw.contains("data: [DONE]"))
        XCTAssertEqual(r.journal.map(\.record.streamOutcome), ["completed"])
        XCTAssertEqual(r.failedCount, 0)
        XCTAssertTrue(r.failures.isEmpty)
    }

    /// Some valid upstreams finish with finish_reason and never send [DONE].
    @MainActor
    func testChatFinishReasonWithoutDoneIsCompleted() async throws {
        let r = try await run(events: [Self.content, Self.finish], ending: .clean)
        XCTAssertEqual(r.statusLines, 1)
        XCTAssertEqual(r.openAIErrorEvents, 0)
        XCTAssertEqual(r.journal.map(\.record.streamOutcome), ["completed"])
        XCTAssertEqual(r.failedCount, 0)
    }

    @MainActor
    func testChatCleanEndWithoutTerminalSignalIsInterrupted() async throws {
        let r = try await run(events: [Self.content], ending: .clean)
        XCTAssertEqual(r.statusLines, 1)
        XCTAssertTrue(r.raw.contains("partial fixture text"))
        XCTAssertEqual(r.openAIErrorEvents, 1)
        XCTAssertTrue(r.raw.contains(StreamErrorEvent.interruptedCode))
        XCTAssertFalse(r.raw.contains("data: [DONE]"))
        XCTAssertEqual(r.journal.count, 1)
        XCTAssertEqual(r.journal.first?.record.streamOutcome, "interrupted")
        XCTAssertEqual(r.journal.first?.record.promptTokens, 4, "usage is still accounted")
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertEqual(r.pendingCount, 0)
        XCTAssertEqual(r.failures.first?["error_class"], "stream_interrupted")
    }

    /// The GUI used to write a second `HTTP/1.1 502` after the SSE headers.
    @MainActor
    func testChatTransportBreakAfterHeadersIsInBandWithOneStatusLine() async throws {
        let r = try await run(events: [Self.content], ending: .brokenChunk)
        XCTAssertEqual(r.statusLines, 1, r.raw)
        XCTAssertFalse(r.raw.contains("HTTP/1.1 502"))
        XCTAssertTrue(r.raw.contains("partial fixture text"))
        XCTAssertEqual(r.openAIErrorEvents, 1)
        XCTAssertEqual(r.journal.count, 1)
        XCTAssertNotEqual(r.journal.first?.record.streamOutcome, "completed")
        XCTAssertNotNil(r.journal.first?.record.streamOutcome)
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertEqual(r.pendingCount, 0)
    }

    /// A terminal finish_reason followed by an abnormal close is a finished
    /// response: no error event, journaled as completed. (The GUI stops reading
    /// at [DONE], so only the finish_reason variant can reach this path.)
    @MainActor
    func testChatFinishReasonThenTransportBreakIsCompleted() async throws {
        let r = try await run(events: [Self.content, Self.finish], ending: .brokenChunk)
        XCTAssertEqual(r.statusLines, 1)
        XCTAssertEqual(r.openAIErrorEvents, 0, r.raw)
        XCTAssertEqual(r.journal.map(\.record.streamOutcome), ["completed"])
        XCTAssertEqual(r.failedCount, 0)
    }

    @MainActor
    func testChatDoneThenTransportBreakIsCompleted() async throws {
        let r = try await run(events: [Self.content, Self.finish, "data: [DONE]"], ending: .brokenChunk)
        XCTAssertEqual(r.statusLines, 1)
        XCTAssertEqual(r.openAIErrorEvents, 0, r.raw)
        XCTAssertEqual(r.journal.map(\.record.streamOutcome), ["completed"])
    }

    // MARK: - Anthropic Messages streaming paths

    @MainActor
    func testAnthropicStreamingPathsReportBreakInBandWithOneStatusLine() async throws {
        let routes: [(UpstreamProvider, ProxyPilot.AnthropicTranslatorMode, String, String)] = [
            (.ollama, .hardened, Self.content, "hardened"),
            (.ollama, .legacyFallback, Self.content, "legacy"),
            (.deepSeek, .hardened, Self.nativeStart, "passthrough"),
        ]
        for (provider, mode, event, label) in routes {
            let r = try await run(events: [event], ending: .brokenChunk, provider: provider, path: "/v1/messages", mode: mode)
            XCTAssertEqual(r.statusLines, 1, "\(label): \(r.raw)")
            XCTAssertFalse(r.raw.contains("HTTP/1.1 502"), label)
            XCTAssertTrue(r.raw.contains("event: error"), "\(label): \(r.raw)")
            XCTAssertEqual(r.pendingCount, 0, label)
        }
    }
}
