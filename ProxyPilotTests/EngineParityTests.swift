import XCTest
import Darwin
import Network
import ProxyPilotCore
@testable import ProxyPilot

// ProxyPilot has two proxy engines: the app's built-in `LocalProxyServer` and
// the Core `NIOProxyServer` the CLI runs. This suite sends the same request to
// each, against the same scripted provider, and requires that both
//   1. match a stated expectation, and
//   2. match each other,
// in what the client receives and what is journaled. A behavior fixed in one
// engine only fails here. Deliberate differences are listed in
// `knownDifferences` with a reason; an entry that no longer differs fails too.

// MARK: - Scripted provider

private final class ParityOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// What the stand-in provider does with a request.
enum ProviderScript: Sendable {
    /// HTTP 200 `text/event-stream` carrying these events, then a clean end
    /// or a broken chunk.
    case sse(events: [String], broken: Bool)
    /// A complete response with this status and JSON body.
    case json(status: Int, body: String)
    /// Nothing listens at the provider's address.
    case unreachable
}

private final class ScriptedProvider: @unchecked Sendable {
    private let script: ProviderScript
    private let queue = DispatchQueue(label: "proxypilot.parity.provider")
    private var listener: NWListener?

    init(script: ProviderScript) { self.script = script }

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            let once = ParityOnce()
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
        switch script {
        case .unreachable:
            connection.cancel()
        case .json(let status, let body):
            let response = "HTTP/1.1 \(status) Scripted\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        case .sse(let events, let broken):
            let body = events.map { $0 + "\n\n" }.joined()
            var response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                + String(body.utf8.count, radix: 16) + "\r\n" + body + "\r\n"
            if broken {
                response += "100\r\nbroken"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { [queue] _ in
                    queue.asyncAfter(deadline: .now() + 0.1) { connection.forceCancel() }
                })
            } else {
                response += "0\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

// MARK: - Raw client

/// Sends one request and collects every byte the proxy writes, so a second
/// status line or a doubled error event is visible.
private final class ParityClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "proxypilot.parity.client")
    private var received = Data()
    private var continuation: CheckedContinuation<String, Never>?
    private let once = ParityOnce()

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func run(path: String, body: Data, port: UInt16, timeout: TimeInterval = 10) async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.connection.stateUpdateHandler = { [self] state in
                    if case .ready = state {
                        let head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nAuthorization: Bearer \(ParityEngines.capability)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
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
            if let data { received.append(data) }
            if isComplete || error != nil || Self.responseIsComplete(received) { finish() } else { read() }
        }
    }

    /// The Core engine keeps the connection open after a response, so the end
    /// is read from the framing: the last chunk, or the declared length.
    private static func responseIsComplete(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        guard let split = text.range(of: "\r\n\r\n") else { return false }
        let head = text[..<split.lowerBound].lowercased()
        if head.contains("transfer-encoding: chunked") { return text.hasSuffix("0\r\n\r\n") }
        if let length = head.split(separator: "\r\n").first(where: { $0.hasPrefix("content-length:") })
            .flatMap({ Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }) {
            return text[split.upperBound...].utf8.count >= length
        }
        return false
    }

    private func finish() {
        guard once.claim() else { return }
        connection.cancel()
        continuation?.resume(returning: String(decoding: received, as: UTF8.self))
        continuation = nil
    }
}

// MARK: - Observation

/// One journaled request, reduced to what both engines must agree on.
struct JournalRow: Equatable, CustomStringConvertible {
    var path: String
    var wasStreaming: Bool
    var outcome: String?
    var failure: UpstreamFailure?

    var description: String {
        let failureText = failure.map {
            "\($0.kind.rawValue) http=\($0.httpStatus.map(String.init) ?? "-") prompt=\($0.promptTokens.map(String.init) ?? "-") ctx=\($0.contextTokens.map(String.init) ?? "-")"
        } ?? "none"
        return "[\(path) streaming=\(wasStreaming) outcome=\(outcome ?? "-") failure=\(failureText)]"
    }
}

/// What a client and the journal saw for one request, normalized so the two
/// engines' different framing does not count as a difference.
struct Observation: Equatable, CustomStringConvertible {
    var status: Int
    var statusLines: Int
    var isEventStream: Bool
    /// Error events inside a stream.
    var inBandErrors: Int
    /// `error.type` of a JSON error body or the first in-band error.
    var errorType: String?
    /// `error.message` of a JSON error body or the first in-band error, with
    /// the scripted provider's port removed.
    var errorMessage: String?
    var journal: [JournalRow]

    var description: String {
        """
        status=\(status) statusLines=\(statusLines) eventStream=\(isEventStream) inBandErrors=\(inBandErrors)
            errorType=\(errorType ?? "-")
            errorMessage=\(errorMessage ?? "-")
            journal=\(journal.map(\.description).joined(separator: " "))
        """
    }
}

private enum ObservationParser {
    static func parse(raw: String, journal: [SessionReportEvent], providerPort: UInt16) -> Observation {
        let statusLines = raw.components(separatedBy: "HTTP/1.1 ").count - 1
        let status = raw.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        let split = raw.range(of: "\r\n\r\n")
        let head = split.map { raw[..<$0.lowerBound].lowercased() } ?? ""
        var body = split.map { String(raw[$0.upperBound...]) } ?? ""
        if head.contains("transfer-encoding: chunked") { body = dechunk(body) }
        let isEventStream = head.contains("content-type: text/event-stream")

        var inBandErrors = 0
        var errorType: String?
        var errorMessage: String?
        func take(_ object: [String: Any]) {
            guard errorMessage == nil, errorType == nil else { return }
            if let error = object["error"] as? [String: Any] {
                errorType = error["type"] as? String
                errorMessage = error["message"] as? String
            } else if let error = object["error"] as? String {
                errorMessage = error
            }
        }
        if isEventStream {
            for line in body.split(whereSeparator: \.isNewline) where line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let data = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let error = object["error"], !(error is NSNull) else { continue }
                inBandErrors += 1
                take(object)
            }
        } else if let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            take(object)
        }
        let rows = journal.map {
            JournalRow(path: $0.record.path, wasStreaming: $0.record.wasStreaming,
                       outcome: $0.record.streamOutcome, failure: $0.record.upstreamFailure)
        }
        return Observation(
            status: status, statusLines: statusLines, isEventStream: isEventStream,
            inBandErrors: inBandErrors, errorType: errorType,
            errorMessage: errorMessage?.replacingOccurrences(of: ":\(providerPort)", with: ":PORT"),
            journal: rows
        )
    }

    /// Removes chunked transfer framing, working on bytes: a chunk boundary
    /// can fall anywhere, including between a "\r" and a "\n".
    private static func dechunk(_ body: String) -> String {
        let bytes = Array(body.utf8)
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            guard let lineEnd = (index..<bytes.count - 1).first(where: { bytes[$0] == 13 && bytes[$0 + 1] == 10 }),
                  let size = Int(String(decoding: bytes[index..<lineEnd], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces), radix: 16),
                  size > 0 else { break }
            let start = lineEnd + 2
            let end = min(start + size, bytes.count)
            output.append(contentsOf: bytes[start..<end])
            index = end + 2
        }
        return String(decoding: output, as: UTF8.self)
    }
}

// MARK: - Scenarios

enum ParityRoute: String, CaseIterable {
    case chatStreamed, chatBuffered, messagesStreamed, messagesBuffered

    var path: String {
        switch self {
        case .chatStreamed, .chatBuffered: return "/v1/chat/completions"
        case .messagesStreamed, .messagesBuffered: return "/v1/messages"
        }
    }

    var isStreaming: Bool { self == .chatStreamed || self == .messagesStreamed }
    var isMessages: Bool { self == .messagesStreamed || self == .messagesBuffered }

    var body: Data {
        try! JSONSerialization.data(withJSONObject: [
            "model": "fixture", "stream": isStreaming, "max_tokens": 64,
            "messages": [["role": "user", "content": "fixture only"]],
        ])
    }
}

enum ParityScenario: String, CaseIterable {
    case success, contextExceeded, providerError, unreachable, brokenStream

    /// Planted in the scripted provider's error text. It must never reach the
    /// journal or the app's log.
    static let canary = "CANARY-7f3e91-user-text"

    private static let content =
        #"data: {"id":"x","object":"chat.completion.chunk","model":"fixture","choices":[{"index":0,"delta":{"content":"partial fixture text"},"finish_reason":null}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}"#
    private static let finish =
        #"data: {"id":"x","model":"fixture","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
    private static let buffered =
        #"{"id":"x","object":"chat.completion","model":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":"fixture text"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}"#
    /// LM Studio 0.4.28, captured 2026-11-24: a streamed request larger than
    /// the loaded context returns HTTP 200 and one `event: error`.
    private static let lmStudioStreamError = "event: error\n" + #"data: {"error":{"message":"Engine protocol predict request returned 400: {\"error\":{\"code\":400,\"message\":\"request (40031 tokens) exceeds the available context size (32768 tokens), try increasing it\",\"type\":\"exceed_context_size_error\",\"n_prompt_tokens\":40031,\"n_ctx\":32768}}"},"message":"Engine protocol predict request returned 400"}"#
    /// The same condition on a buffered request: HTTP 400, `error` a bare string.
    private static let lmStudioBufferedError = #"{"error":"Engine protocol predict request returned 400: {\"error\":{\"code\":400,\"message\":\"request (40031 tokens) exceeds the available context size (32768 tokens), try increasing it\",\"type\":\"exceed_context_size_error\",\"n_prompt_tokens\":40031,\"n_ctx\":32768}}"}"#
    private static let providerErrorBody =
        #"{"error":{"message":"The engine stopped while reading \#(canary)","type":"server_error"}}"#

    /// What the provider does, given whether the proxy asks it to stream.
    func script(streaming: Bool) -> ProviderScript {
        switch self {
        case .success:
            return streaming
                ? .sse(events: [Self.content, Self.finish, "data: [DONE]"], broken: false)
                : .json(status: 200, body: Self.buffered)
        case .contextExceeded:
            return streaming
                ? .sse(events: [Self.lmStudioStreamError], broken: false)
                : .json(status: 400, body: Self.lmStudioBufferedError)
        case .providerError:
            return .json(status: 500, body: Self.providerErrorBody)
        case .unreachable:
            return .unreachable
        case .brokenStream:
            return .sse(events: [Self.content], broken: true)
        }
    }

    func applies(to route: ParityRoute) -> Bool {
        self != .brokenStream || route.isStreaming
    }
}

/// What every engine must do in one cell. Fields left nil are compared
/// between the engines but not against a fixed value.
struct ParityExpectation {
    var status: Int
    var isEventStream: Bool
    var inBandErrors: Int
    var messageContains: [String] = []
    var failureKind: UpstreamFailure.Kind?
    /// When set, the journaled failure must equal this exactly.
    var failure: UpstreamFailure?
    var outcome: String?
}

enum ParityContract {
    static let contextFailure = UpstreamFailure(kind: .contextExceeded, promptTokens: 40031, contextTokens: 32768)
    static let contextWording = ["40,031 tokens", "32,768-token context", "Reload the model in LM Studio"]

    static func expectation(_ scenario: ParityScenario, _ route: ParityRoute) -> ParityExpectation {
        switch scenario {
        case .success:
            // Only chat streams are journaled with how the stream ended.
            return ParityExpectation(status: 200, isEventStream: route.isStreaming, inBandErrors: 0,
                                     outcome: route == .chatStreamed ? "completed" : nil)
        case .contextExceeded:
            if route.isStreaming {
                // The provider answered 200 and failed inside the stream, so the
                // client's stream carries exactly one error.
                return ParityExpectation(
                    status: 200, isEventStream: true, inBandErrors: 1,
                    messageContains: route.isMessages ? contextWording : ["exceeds the available context size"],
                    failureKind: .contextExceeded, failure: contextFailure, outcome: "upstream_error")
            }
            var failure = contextFailure
            failure = UpstreamFailure(kind: failure.kind, httpStatus: 400,
                                      promptTokens: failure.promptTokens, contextTokens: failure.contextTokens)
            return ParityExpectation(
                status: 400, isEventStream: false, inBandErrors: 0,
                messageContains: route.isMessages ? contextWording : ["exceeds the available context size"],
                failureKind: .contextExceeded, failure: failure)
        case .providerError:
            return ParityExpectation(
                status: 500, isEventStream: false, inBandErrors: 0,
                messageContains: ["The engine stopped while reading"],
                failureKind: .providerError,
                failure: UpstreamFailure(kind: .providerError, httpStatus: 500))
        case .unreachable:
            return ParityExpectation(
                status: 502, isEventStream: false, inBandErrors: 0,
                messageContains: ["could not connect to LM Studio at http://127.0.0.1:PORT", "Start its local server"],
                failureKind: .serverUnreachable,
                failure: UpstreamFailure(kind: .serverUnreachable))
        case .brokenStream:
            return ParityExpectation(status: 200, isEventStream: true, inBandErrors: 1,
                                     messageContains: ["the upstream model stream failed before the response finished"],
                                     failureKind: .connectionLost, failure: UpstreamFailure(kind: .connectionLost),
                                     outcome: "upstream_error")
        }
    }
}

// MARK: - Engines

private enum ParityPorts {
    static func unused() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw URLError(.cannotConnectToHost) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
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
}

/// Everything one engine produced for one request.
struct EngineRun {
    var observation: Observation
    /// The journal file's text, for the canary check.
    var journalText: String
    /// The engine's own log text, when it writes one to a file.
    var logText: String
    /// Every byte the client received.
    var raw: String = ""
}

@MainActor
private enum ParityEngines {
    /// Local credential both engines accept. A provider with an API key
    /// makes each engine require it.
    nonisolated static let capability = "local-test-capability"
    static func withProvider<T>(
        _ script: ProviderScript,
        _ work: (_ providerPort: UInt16, _ directory: URL) async throws -> T
    ) async throws -> T {
        let provider = ScriptedProvider(script: script)
        var providerPort = try await provider.start()
        defer { provider.stop() }
        if case .unreachable = script { providerPort = try ParityPorts.unused() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await work(providerPort, directory)
    }

    static func runApp(_ scenario: ParityScenario, _ route: ParityRoute, provider: UpstreamProvider = .lmStudio) async throws -> EngineRun {
        try await withProvider(scenario.script(streaming: route.isStreaming)) { providerPort, directory in
            let reportURL = directory.appendingPathComponent("session-report.jsonl")
            let logURL = directory.appendingPathComponent("proxy.log")
            // A port that was only reserved and released is occasionally still
            // refused to the listener. Try another instead of failing the cell.
            var started: (server: LocalProxyServer, port: UInt16)?
            for _ in 0..<5 where started == nil {
                let server = LocalProxyServer(sessionReportURL: reportURL, logURL: logURL)
                let port = try ParityPorts.unused()
                let config = LocalProxyServer.Config(
                    host: "127.0.0.1", port: port, masterKey: capability,
                    upstreamProvider: provider,
                    upstreamAPIBase: URL(string: "http://127.0.0.1:\(providerPort)/v1")!,
                    upstreamAPIKey: provider.requiresAPIKey ? "sk-test" : nil,
                    allowedModels: ["fixture"], requiresAuth: false, anthropicTranslatorMode: .hardened,
                    miniMaxRoutingMode: .standard, preferredAnthropicUpstreamModel: "fixture",
                    googleThoughtSignatureStore: nil)
                try? server.start(config: config)
                for _ in 0..<20 where !server.state.isRunning {
                    try await Task.sleep(for: .milliseconds(50))
                }
                if server.state.isRunning { started = (server, port) } else { try? server.stop() }
            }
            let (server, port) = try XCTUnwrap(started, "the app engine did not start listening")
            defer { try? server.stop() }
            let raw = await ParityClient(port: port).run(path: route.path, body: route.body, port: port)
            for _ in 0..<40 where server.state.pendingRequestCount > 0 {
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(200))
            let journal = (try? SessionReportStore.readEvents(from: reportURL)) ?? []
            return EngineRun(
                observation: ObservationParser.parse(raw: raw, journal: journal, providerPort: providerPort),
                journalText: (try? String(contentsOf: reportURL, encoding: .utf8)) ?? "",
                logText: (try? String(contentsOf: logURL, encoding: .utf8)) ?? "", raw: raw)
        }
    }

    static func runCore(_ scenario: ParityScenario, _ route: ParityRoute, provider: UpstreamProvider = .lmStudio) async throws -> EngineRun {
        try await withProvider(scenario.script(streaming: route.isStreaming)) { providerPort, directory in
            let reportURL = directory.appendingPathComponent("session-report.jsonl")
            let stats = SessionStats(sessionReportURL: reportURL, sessionSource: "cli", sessionID: "engine-parity")
            let config = ProxyConfiguration(
                port: 0,
                upstreamProvider: provider,
                upstreamAPIBaseURL: "http://127.0.0.1:\(providerPort)/v1",
                upstreamAPIKey: provider.requiresAPIKey ? "sk-test" : nil,
                masterKey: capability,
                allowedModels: ["fixture"],
                requiresAuth: false,
                preferredAnthropicUpstreamModel: "fixture",
                sessionStats: stats)
            let server = NIOProxyServer()
            let port = try await server.start(config: config)
            let raw = await ParityClient(port: port).run(path: route.path, body: route.body, port: port)
            try await Task.sleep(for: .milliseconds(300))
            try await server.stop()
            let journal = (try? SessionReportStore.readEvents(from: reportURL)) ?? []
            return EngineRun(
                observation: ObservationParser.parse(raw: raw, journal: journal, providerPort: providerPort),
                journalText: (try? String(contentsOf: reportURL, encoding: .utf8)) ?? "",
                logText: "", raw: raw)
        }
    }
}

// MARK: - The suite

final class EngineParityTests: XCTestCase {
    /// Cells where the engines are allowed to differ, keyed
    /// "scenario/route", each with the reason. Keep this list short: every
    /// entry is behavior that has to be maintained twice.
    static let knownDifferences: [String: String] = [:]

    @MainActor
    private func check(
        _ scenario: ParityScenario,
        provider: UpstreamProvider = .lmStudio,
        routes: [ParityRoute] = ParityRoute.allCases,
        expecting: ((ParityRoute) -> ParityExpectation)? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for route in routes where scenario.applies(to: route) {
            let cell = "\(scenario.rawValue)/\(route.rawValue)" + (provider == .lmStudio ? "" : "/\(provider.rawValue)")
            let app = try await ParityEngines.runApp(scenario, route, provider: provider)
            let core = try await ParityEngines.runCore(scenario, route, provider: provider)
            let expected = expecting?(route) ?? ParityContract.expectation(scenario, route)

            for (engine, run) in [("app", app), ("core", core)] {
                let seen = run.observation
                let context = "\(cell) on the \(engine) engine\n\(seen)\n    raw=\(run.raw.prefix(700).debugDescription)"
                XCTAssertEqual(seen.status, expected.status, "status: \(context)", file: file, line: line)
                XCTAssertEqual(seen.statusLines, 1, "one status line: \(context)", file: file, line: line)
                XCTAssertEqual(seen.isEventStream, expected.isEventStream, "stream: \(context)", file: file, line: line)
                XCTAssertEqual(seen.inBandErrors, expected.inBandErrors, "in-band errors: \(context)", file: file, line: line)
                for fragment in expected.messageContains {
                    XCTAssertTrue(seen.errorMessage?.contains(fragment) == true,
                                  "message should contain \"\(fragment)\": \(context)", file: file, line: line)
                }
                XCTAssertEqual(seen.journal.count, 1, "one journal record: \(context)", file: file, line: line)
                XCTAssertEqual(seen.journal.first?.path, route.path, "journal path: \(context)", file: file, line: line)
                XCTAssertEqual(seen.journal.first?.wasStreaming, route.isStreaming, "journal streaming: \(context)", file: file, line: line)
                XCTAssertEqual(seen.journal.first?.failure?.kind, expected.failureKind, "failure kind: \(context)", file: file, line: line)
                if let failure = expected.failure {
                    XCTAssertEqual(seen.journal.first?.failure, failure, "failure: \(context)", file: file, line: line)
                }
                if scenario == .success || expected.outcome != nil {
                    XCTAssertEqual(seen.journal.first?.outcome, expected.outcome, "outcome: \(context)", file: file, line: line)
                }
                // Provider wording may quote the user's request. It goes to the
                // client that sent the request, and nowhere else.
                XCTAssertFalse(run.journalText.contains(ParityScenario.canary), "provider text in the journal: \(context)", file: file, line: line)
                XCTAssertFalse(run.logText.contains(ParityScenario.canary), "provider text in the log: \(context)", file: file, line: line)
            }

            if let reason = Self.knownDifferences[cell] {
                XCTAssertNotEqual(app.observation, core.observation,
                                  "\(cell) is listed as a known difference (\(reason)) but the engines now agree; remove the entry",
                                  file: file, line: line)
            } else {
                XCTAssertEqual(app.observation, core.observation,
                               "\(cell): the engines disagree\napp:  \(app.observation)\ncore: \(core.observation)",
                               file: file, line: line)
            }
        }
    }

    @MainActor func testSuccessfulRequest() async throws { try await check(.success) }
    @MainActor func testPromptLargerThanTheModelContext() async throws { try await check(.contextExceeded) }
    @MainActor func testProviderErrorBeforeAnyResponse() async throws { try await check(.providerError) }
    @MainActor func testProviderNotRunning() async throws { try await check(.unreachable) }
    @MainActor func testConnectionBreaksMidStream() async throws { try await check(.brokenStream) }

    // A provider with a native Messages endpoint is forwarded to directly
    // (Anthropic passthrough), through separate handlers in each engine.
    private static let messagesRoutes: [ParityRoute] = [.messagesStreamed, .messagesBuffered]

    @MainActor func testPassthroughProviderErrorBeforeAnyResponse() async throws {
        try await check(.providerError, provider: .deepSeek, routes: Self.messagesRoutes) { _ in
            // The provider speaks the client's format, so its own error
            // response reaches the client unchanged.
            ParityExpectation(
                status: 500, isEventStream: false, inBandErrors: 0,
                messageContains: ["The engine stopped while reading"],
                failureKind: .providerError, failure: UpstreamFailure(kind: .providerError, httpStatus: 500))
        }
    }

    @MainActor func testPassthroughProviderNotRunning() async throws {
        try await check(.unreachable, provider: .deepSeek, routes: Self.messagesRoutes) { _ in
            ParityExpectation(
                status: 502, isEventStream: false, inBandErrors: 0,
                messageContains: ["could not connect to DeepSeek at http://127.0.0.1:PORT/anthropic"],
                failureKind: .serverUnreachable, failure: UpstreamFailure(kind: .serverUnreachable))
        }
    }

    /// Both engines must give up on a local provider after the same time, and
    /// must agree on which providers are local. Cloud limits differ between
    /// the engines today; the values are pinned so a change to either is seen.
    func testWaitLimitsForLocalProvidersMatchAndCloudLimitsArePinned() {
        let cases: [(provider: UpstreamProvider, base: String, local: Bool)] = [
            (.lmStudio, "http://127.0.0.1:1234/v1", true),
            (.ollama, "http://localhost:11434/v1", true),
            (.openAI, "http://127.0.0.2:8080/v1", true),
            (.openAI, "http://[::1]:8080/v1", true),
            (.openRouter, "https://openrouter.ai/api/v1", false),
            (.openAI, "https://api.openai.com/v1", false),
        ]
        for (provider, base, local) in cases {
            let app = LocalProxyServer.Config(
                host: "127.0.0.1", port: 4000, masterKey: "", upstreamProvider: provider,
                upstreamAPIBase: URL(string: base)!, upstreamAPIKey: nil, allowedModels: [],
                requiresAuth: false, anthropicTranslatorMode: .hardened, miniMaxRoutingMode: .standard,
                preferredAnthropicUpstreamModel: "", googleThoughtSignatureStore: nil)
            let core = ProxyConfiguration(upstreamProvider: provider, upstreamAPIBaseURL: base)
            let label = "\(provider.rawValue) at \(base)"
            XCTAssertEqual(app.isLocalUpstream, local, "app local detection for \(label)")
            XCTAssertEqual(core.isLocalUpstream, local, "core local detection for \(label)")
            if local {
                XCTAssertEqual(app.waitPolicy, core.waitPolicy, "wait limits for \(label)")
                XCTAssertEqual(app.waitPolicy, UpstreamWaitPolicy(idle: 1800, total: nil))
            } else {
                // Known difference: the app waits 120 seconds without data and
                // sets no total; the Core engine waits 30 seconds and caps the
                // whole response at 300.
                XCTAssertEqual(app.waitPolicy, UpstreamWaitPolicy(idle: 120, total: nil), label)
                XCTAssertEqual(core.waitPolicy, UpstreamWaitPolicy(idle: 30, total: 300), label)
            }
        }
    }
}
