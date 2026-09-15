import XCTest
import Darwin
import Network
import ProxyPilotCore
@testable import ProxyPilot

private final class LocalHTTPStubServer: @unchecked Sendable {
    struct RequestRecord {
        let headers: [String: String]
        let body: String

        func headerValue(_ name: String) -> String? {
            headers[name.lowercased()]
        }
    }

    private final class OneShotGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    private let body: String
    private let contentType: String
    private let statusCode: Int
    private let queue = DispatchQueue(label: "proxypilot.local-http-stub")
    private var listener: NWListener?
    private let requestLock = NSLock()
    private var capturedRequests: [RequestRecord] = []

    init(statusCode: Int = 200, body: String, contentType: String = "application/json") {
        self.statusCode = statusCode
        self.body = body
        self.contentType = contentType
    }

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let gate = OneShotGate()

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    if gate.claim() {
                        continuation.resume(returning: port.rawValue)
                    }
                case .failed(let error):
                    if gate.claim() {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                connection.start(queue: self.queue)
                self.receiveRequest(on: connection)
            }

            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func requests() -> [RequestRecord] {
        requestLock.lock()
        defer { requestLock.unlock() }
        return capturedRequests
    }

    private func respond(on connection: NWConnection) {
        let reason = statusCode == 200 ? "OK" : "Error"
        let response = """
        HTTP/1.1 \(statusCode) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """

        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var next = accumulated
            if let data {
                next.append(data)
            }
            if isComplete || error != nil || self.hasCompleteHTTPRequest(next) {
                self.captureRequest(next)
                self.respond(on: connection)
            } else {
                self.receiveRequest(on: connection, accumulated: next)
            }
        }
    }

    private func hasCompleteHTTPRequest(_ data: Data) -> Bool {
        guard let raw = String(data: data, encoding: .utf8),
              let headerRange = raw.range(of: "\r\n\r\n") else {
            return false
        }
        let headers = raw[..<headerRange.lowerBound]
        let contentLength = headers
            .components(separatedBy: "\r\n")
            .compactMap { line -> Int? in
                let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2,
                      pieces[0].lowercased() == "content-length" else {
                    return nil
                }
                return Int(pieces[1].trimmingCharacters(in: .whitespaces))
            }
            .first ?? 0
        let bodyStart = raw.distance(from: raw.startIndex, to: headerRange.upperBound)
        let bodyBytes = data.count - bodyStart
        return bodyBytes >= contentLength
    }

    private func captureRequest(_ data: Data?) {
        guard let data, let raw = String(data: data, encoding: .utf8) else { return }
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let headerLines = parts.first?.components(separatedBy: "\r\n").dropFirst() ?? []
        var headers: [String: String] = [:]
        for line in headerLines {
            let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            headers[String(pieces[0]).lowercased()] = pieces[1].trimmingCharacters(in: .whitespaces)
        }
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")
        requestLock.lock()
        capturedRequests.append(RequestRecord(headers: headers, body: body))
        requestLock.unlock()
    }
}

final class LocalProxyServerTests: XCTestCase {

    @MainActor
    func testLocalProxyStateTracksPendingAndFailedRequestsSeparately() {
        let state = LocalProxyState()
        let first = UUID()
        let second = UUID()

        state.beginRequest(id: first, modelName: "qwen/qwen3.5-9b")
        state.beginRequest(id: second, modelName: nil)

        XCTAssertEqual(state.sessionRequestCount, 2)
        XCTAssertEqual(state.pendingRequestCount, 2)
        XCTAssertEqual(state.failedRequestCount, 0)
        XCTAssertEqual(state.lastModelSeen, "qwen/qwen3.5-9b")
        XCTAssertEqual(state.activeModels, ["qwen/qwen3.5-9b"])

        XCTAssertTrue(state.completeRequest(id: first))
        XCTAssertEqual(state.pendingRequestCount, 1)
        XCTAssertEqual(state.failedRequestCount, 0)
        XCTAssertTrue(state.activeModels.isEmpty)

        XCTAssertTrue(state.failRequest(id: second))
        XCTAssertEqual(state.pendingRequestCount, 0)
        XCTAssertEqual(state.failedRequestCount, 1)
        XCTAssertNotNil(state.lastFailureAt)
    }

    @MainActor
    func testLocalProxyStateMarksPendingRequestsFailedWhenSessionEnds() {
        let state = LocalProxyState()

        state.beginRequest(id: UUID(), modelName: "model-a")
        state.beginRequest(id: UUID(), modelName: "model-b")
        state.failAllPendingRequests()

        XCTAssertEqual(state.sessionRequestCount, 2)
        XCTAssertEqual(state.pendingRequestCount, 0)
        XCTAssertEqual(state.failedRequestCount, 2)
        XCTAssertTrue(state.activeModels.isEmpty)
        XCTAssertNotNil(state.lastFailureAt)
    }

    @MainActor
    func testLocalProxyStateTracksDistinctActiveModelsAcrossConcurrentRequests() {
        let state = LocalProxyState()
        let first = UUID()
        let second = UUID()

        state.beginRequest(id: first, modelName: "openai/gpt-5.6")
        state.beginRequest(id: second, modelName: "anthropic/claude-opus-4.8")
        XCTAssertEqual(state.activeModels, ["openai/gpt-5.6", "anthropic/claude-opus-4.8"])

        XCTAssertTrue(state.completeRequest(id: first))
        XCTAssertEqual(state.activeModels, ["anthropic/claude-opus-4.8"])

        XCTAssertTrue(state.completeRequest(id: second))
        XCTAssertTrue(state.activeModels.isEmpty)
    }

    @MainActor
    func testLocalProxyStateReplacesTransportModelWithResolvedUpstreamModel() {
        let state = LocalProxyState()
        let requestID = UUID()

        state.beginRequest(id: requestID, modelName: "claude-placeholder")
        state.resolveRequest(id: requestID, modelName: "anthropic/claude-opus-4.8:exacto")

        XCTAssertEqual(state.activeModels, ["anthropic/claude-opus-4.8:exacto"])
        XCTAssertEqual(state.lastUpstreamModelUsed, "anthropic/claude-opus-4.8:exacto")
    }

    @MainActor
    func testBeginTrackedRequestCompletesBeforeImmediateResolution() async {
        let server = LocalProxyServer()
        let requestID = UUID()

        await server.beginTrackedRequest(
            id: requestID,
            modelName: "claude-transport",
            clearsUpstreamModelAttribution: true
        )
        server.state.resolveRequest(id: requestID, modelName: "openai/gpt-5.6")

        XCTAssertEqual(server.state.pendingRequestCount, 1)
        XCTAssertEqual(server.state.activeModels, ["openai/gpt-5.6"])
        XCTAssertEqual(server.state.lastUpstreamModelUsed, "openai/gpt-5.6")
    }

    // MARK: - Helpers

    private typealias H = LocalProxyServerHelpers

    private func jsonBody(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    private func unusedLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(descriptor, sockaddrPointer, &length)
            }
        }
        XCTAssertEqual(nameResult, 0)

        return UInt16(bigEndian: boundAddress.sin_port)
    }

    private func waitForLocalProxyToRun(_ server: LocalProxyServer) async {
        for _ in 0..<30 {
            let isRunning = await MainActor.run { server.state.isRunning }
            if isRunning { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func waitForReportCard(_ server: LocalProxyServer, requestCount: Int) async -> Bool {
        for _ in 0..<30 {
            let totalRequests = await MainActor.run { server.reportCard.totalRequests }
            if totalRequests >= requestCount { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func nonLoopbackIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }

        var cursor = interfaces
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, !isLoopback,
                  let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                return String(cString: host)
            }
        }

        return nil
    }

    // MARK: - Request-Line Parsing

    func testParseRequestLineGET() {
        let result = H.parseRequestLine("GET /v1/models HTTP/1.1")
        XCTAssertEqual(result?.method, "GET")
        XCTAssertEqual(result?.path, "/v1/models")
    }

    func testParseRequestLinePOST() {
        let result = H.parseRequestLine("POST /v1/chat/completions HTTP/1.1")
        XCTAssertEqual(result?.method, "POST")
        XCTAssertEqual(result?.path, "/v1/chat/completions")
    }

    func testParseRequestLineStripsQueryString() {
        let result = H.parseRequestLine("GET /v1/models?foo=bar HTTP/1.1")
        XCTAssertEqual(result?.path, "/v1/models")
    }

    func testParseRequestLineMalformedReturnsNil() {
        XCTAssertNil(H.parseRequestLine("INVALID"))
        XCTAssertNil(H.parseRequestLine(""))
    }

    // MARK: - Header Parsing

    func testParseHeadersBasic() {
        let lines = [
            "Content-Type: application/json",
            "Authorization: Bearer sk-test123"
        ]
        let headers = H.parseHeaders(lines)
        XCTAssertEqual(headers["content-type"], "application/json")
        XCTAssertEqual(headers["authorization"], "Bearer sk-test123")
    }

    func testParseHeadersLowercasesKeys() {
        let headers = H.parseHeaders(["X-API-Key: my-key"])
        XCTAssertEqual(headers["x-api-key"], "my-key")
    }

    func testParseHeadersSkipsEmptyAndMalformed() {
        let lines = ["", "no-colon-here", "Valid-Header: value"]
        let headers = H.parseHeaders(lines)
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(headers["valid-header"], "value")
    }

    // MARK: - Content-Length validation

    func testContentLengthOutcomeRejectsNegativeLength() {
        // `Content-Length: -1` used to reach `prefix(-1)`, which traps — and it
        // did so before the auth gate, so any local client could crash the proxy
        // without credentials.
        XCTAssertEqual(
            H.contentLengthOutcome(header: "-1", alreadyReceived: 0, maxBodyBytes: 1_000),
            .invalid
        )
        XCTAssertEqual(
            H.contentLengthOutcome(header: "-9999999", alreadyReceived: 0, maxBodyBytes: 1_000),
            .invalid
        )
    }

    func testContentLengthOutcomeAcceptsValidAndAbsentLengths() {
        XCTAssertEqual(
            H.contentLengthOutcome(header: "42", alreadyReceived: 0, maxBodyBytes: 1_000),
            .accept(42)
        )
        // Absent or unparseable keeps its historical "no body" meaning rather
        // than becoming an error.
        XCTAssertEqual(
            H.contentLengthOutcome(header: nil, alreadyReceived: 0, maxBodyBytes: 1_000),
            .accept(0)
        )
        XCTAssertEqual(
            H.contentLengthOutcome(header: "not-a-number", alreadyReceived: 0, maxBodyBytes: 1_000),
            .accept(0)
        )
    }

    func testContentLengthOutcomeRejectsOversizedBodies() {
        XCTAssertEqual(
            H.contentLengthOutcome(header: "1001", alreadyReceived: 0, maxBodyBytes: 1_000),
            .tooLarge
        )
        XCTAssertEqual(
            H.contentLengthOutcome(header: "10", alreadyReceived: 1_001, maxBodyBytes: 1_000),
            .tooLarge
        )
    }

    func testParseHeadersLastWinsForDuplicates() {
        let lines = [
            "Content-Type: text/plain",
            "Content-Type: application/json"
        ]
        let headers = H.parseHeaders(lines)
        XCTAssertEqual(headers["content-type"], "application/json")
    }

    // MARK: - Route Classification

    func testClassifyGetModelsV1Path() {
        XCTAssertEqual(H.classify(method: "GET", path: "/v1/models"), .getModels)
    }

    func testClassifyGetModelsShortPath() {
        XCTAssertEqual(H.classify(method: "GET", path: "/models"), .getModels)
    }

    func testClassifyPostModelsIsNotFound() {
        XCTAssertEqual(H.classify(method: "POST", path: "/v1/models"), .notFound)
    }

    func testClassifyChatCompletionsV1() {
        XCTAssertEqual(H.classify(method: "POST", path: "/v1/chat/completions"), .chatCompletions)
    }

    func testClassifyChatCompletionsShort() {
        XCTAssertEqual(H.classify(method: "POST", path: "/chat/completions"), .chatCompletions)
    }

    func testClassifyGetChatCompletionsIsNotFound() {
        XCTAssertEqual(H.classify(method: "GET", path: "/v1/chat/completions"), .notFound)
    }

    func testClassifyAnthropicMessages() {
        XCTAssertEqual(H.classify(method: "POST", path: "/v1/messages"), .anthropicMessages)
    }

    func testClassifyUnknownPathIsNotFound() {
        XCTAssertEqual(H.classify(method: "GET", path: "/v1/unknown"), .notFound)
    }

    // MARK: - Authorization

    func testAuthBearerTokenInAuthorizationHeader() {
        let headers = ["authorization": "Bearer my-secret-key"]
        XCTAssertTrue(H.isAuthorized(headers: headers, masterKey: "my-secret-key"))
    }

    func testAuthBearerTokenMismatchFails() {
        let headers = ["authorization": "Bearer wrong-key"]
        XCTAssertFalse(H.isAuthorized(headers: headers, masterKey: "my-secret-key"))
    }

    func testAuthRawKeyInXAPIKeyHeader() {
        let headers = ["x-api-key": "my-secret-key"]
        XCTAssertTrue(H.isAuthorized(headers: headers, masterKey: "my-secret-key"))
    }

    func testAuthRawKeyInApiKeyHeader() {
        let headers = ["api-key": "my-secret-key"]
        XCTAssertTrue(H.isAuthorized(headers: headers, masterKey: "my-secret-key"))
    }

    func testAuthNoHeadersFails() {
        XCTAssertFalse(H.isAuthorized(headers: [:], masterKey: "my-secret-key"))
    }

    func testAuthBearerWithExtraWhitespace() {
        let headers = ["authorization": "  Bearer   my-secret-key  "]
        XCTAssertTrue(H.isAuthorized(headers: headers, masterKey: "my-secret-key"))
    }

    func testAuthEmptyMasterKeyRejectsEmptyBearer() {
        // "Bearer " trims to "Bearer" which doesn't start with "Bearer " anymore,
        // so the token extraction path is skipped; "Bearer" != "" so this is rejected.
        let headers = ["authorization": "Bearer "]
        XCTAssertFalse(H.isAuthorized(headers: headers, masterKey: ""))
    }

    // MARK: - Streaming Detection

    func testIsStreamingTrueDetected() {
        let body = jsonBody(["stream": true, "model": "test"])
        XCTAssertTrue(H.isStreamingRequest(body: body))
    }

    func testIsStreamingFalseDetected() {
        let body = jsonBody(["stream": false, "model": "test"])
        XCTAssertFalse(H.isStreamingRequest(body: body))
    }

    func testIsStreamingMissingDefaultsFalse() {
        let body = jsonBody(["model": "test"])
        XCTAssertFalse(H.isStreamingRequest(body: body))
    }

    func testIsStreamingInvalidJSONReturnsFalse() {
        let body = Data("not json".utf8)
        XCTAssertFalse(H.isStreamingRequest(body: body))
    }

    // MARK: - Upstream URL Construction

    func testBuildUpstreamURLWithLeadingSlash() {
        let base = URL(string: "https://api.example.com/v1")!
        let url = H.buildUpstreamURL(base: base, path: "/chat/completions")
        XCTAssertTrue(url.absoluteString.contains("chat/completions"))
    }

    func testBuildUpstreamURLWithoutLeadingSlash() {
        let base = URL(string: "https://api.example.com/v1")!
        let url = H.buildUpstreamURL(base: base, path: "chat/completions")
        XCTAssertTrue(url.absoluteString.contains("chat/completions"))
    }

    // MARK: - Body Sanitization (Google Provider)

    func testSanitizeBodyStripsGoogleUnsupportedParams() throws {
        let input: [String: Any] = [
            "model": "gemini-3.1-pro",
            "messages": [["role": "user", "content": "hi"]],
            "logprobs": true,
            "top_logprobs": 5,
            "seed": 42,
            "frequency_penalty": 0.5,
            "presence_penalty": 0.3,
            "logit_bias": ["123": 1]
        ]
        let body = try JSONSerialization.data(withJSONObject: input)
        let result = H.sanitizedChatRequestBody(body, provider: .google)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])

        // Stripped keys
        XCTAssertNil(parsed["logprobs"])
        XCTAssertNil(parsed["top_logprobs"])
        XCTAssertNil(parsed["seed"])
        XCTAssertNil(parsed["frequency_penalty"])
        XCTAssertNil(parsed["presence_penalty"])
        XCTAssertNil(parsed["logit_bias"])

        // Preserved keys
        XCTAssertNotNil(parsed["model"])
        XCTAssertNotNil(parsed["messages"])
    }

    func testSanitizeBodyPreservesLegacyOpenAIParameters() throws {
        let input: [String: Any] = [
            "model": "gpt-4o",
            "logprobs": true,
            "seed": 42,
            "max_tokens": 1024
        ]
        let body = try JSONSerialization.data(withJSONObject: input)
        let result = H.sanitizedChatRequestBody(body, provider: .openAI)

        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertNotNil(parsed["logprobs"])
        XCTAssertNotNil(parsed["seed"])
        XCTAssertEqual(parsed["max_tokens"] as? Int, 1024)
        XCTAssertNil(parsed["max_completion_tokens"])
    }

    func testSanitizeBodyRenamesMaxTokensForDirectOpenAIGPT5() throws {
        let input: [String: Any] = [
            "model": "gpt-5.4",
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 4096
        ]
        let body = try JSONSerialization.data(withJSONObject: input)
        let result = H.sanitizedChatRequestBody(body, provider: .openAI)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])

        XCTAssertNil(parsed["max_tokens"])
        XCTAssertEqual(parsed["max_completion_tokens"] as? Int, 4096)
    }

    func testSanitizeBodyLeavesOpenRouterGPT5MaxTokensUnchanged() throws {
        let input: [String: Any] = [
            "model": "openai/gpt-5.4",
            "max_tokens": 4096
        ]
        let body = try JSONSerialization.data(withJSONObject: input)
        let result = H.sanitizedChatRequestBody(body, provider: .openRouter)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])

        XCTAssertEqual(parsed["max_tokens"] as? Int, 4096)
        XCTAssertNil(parsed["max_completion_tokens"])
    }

    func testSanitizeBodyReturnsOriginalForInvalidJSON() {
        let garbage = Data("not json".utf8)
        let result = H.sanitizedChatRequestBody(garbage, provider: .google)
        XCTAssertEqual(result, garbage)
    }

    // MARK: - Anthropic Model Resolution

    func testResolvePreferredModelWhenInAllowedSet() {
        let model = H.resolveAnthropicUpstreamModel(
            preferredModel: "glm-5",
            allowedModels: ["glm-5", "glm-4.7"]
        )
        XCTAssertEqual(model, "glm-5")
    }

    func testResolveFallsBackToFirstSortedWhenPreferredMissing() {
        let model = H.resolveAnthropicUpstreamModel(
            preferredModel: "glm-5",
            allowedModels: ["zeta-model", "alpha-model"]
        )
        XCTAssertEqual(model, "alpha-model")
    }

    func testResolveReturnsPreferredWhenAllowedSetEmpty() {
        let model = H.resolveAnthropicUpstreamModel(
            preferredModel: "glm-5",
            allowedModels: []
        )
        XCTAssertEqual(model, "glm-5")
    }

    // MARK: - Reason Phrases

    func testReasonPhraseKnownCodes() {
        XCTAssertEqual(H.reasonPhrase(200), "OK")
        XCTAssertEqual(H.reasonPhrase(400), "Bad Request")
        XCTAssertEqual(H.reasonPhrase(401), "Unauthorized")
        XCTAssertEqual(H.reasonPhrase(404), "Not Found")
        XCTAssertEqual(H.reasonPhrase(413), "Payload Too Large")
        XCTAssertEqual(H.reasonPhrase(429), "Too Many Requests")
        XCTAssertEqual(H.reasonPhrase(500), "Internal Server Error")
        XCTAssertEqual(H.reasonPhrase(502), "Bad Gateway")
    }

    func testReasonPhraseUnknownCode() {
        XCTAssertEqual(H.reasonPhrase(418), "Unknown")
        XCTAssertEqual(H.reasonPhrase(999), "Unknown")
    }

    // MARK: - Upstream Error Messages

    func testUpstreamErrorGoogleThoughtSignature() {
        let msg = H.upstreamErrorMessage(
            statusCode: 400,
            body: "Invalid thought_signature in tool call",
            provider: .google
        )
        XCTAssertTrue(msg.contains("Google direct rejected"))
        XCTAssertTrue(msg.contains("OpenRouter"))
    }

    func testUpstreamErrorGoogleNonThoughtSignatureIsGeneric() {
        let msg = H.upstreamErrorMessage(
            statusCode: 400,
            body: "Some other error",
            provider: .google
        )
        XCTAssertEqual(msg, "Upstream error: Some other error")
    }

    func testUpstreamErrorNonGoogleProviderIsGeneric() {
        let msg = H.upstreamErrorMessage(
            statusCode: 400,
            body: "thought_signature issue",
            provider: .openRouter
        )
        // Non-Google providers never get the special message
        XCTAssertEqual(msg, "Upstream error: thought_signature issue")
    }

    func testUpstreamErrorGoogleNon400IsGeneric() {
        let msg = H.upstreamErrorMessage(
            statusCode: 500,
            body: "thought_signature error",
            provider: .google
        )
        XCTAssertEqual(msg, "Upstream error: thought_signature error")
    }

    // MARK: - Log Redaction

    func testScrubBearerReplacesToken() {
        let input = "Authorization: Bearer sk-test-secret-key"
        let result = H.scrubBearer(in: input)
        XCTAssertEqual(result, "Authorization: Bearer ***")
        XCTAssertFalse(result.contains("sk-test-secret-key"))
    }

    func testScrubBearerReplacesMultipleDistinctTokens() {
        let input = "Authorization: Bearer sk-first-secret, retry Authorization: Bearer sk-second-secret"
        let result = H.scrubBearer(in: input)
        XCTAssertEqual(result, "Authorization: Bearer ***, retry Authorization: Bearer ***")
        XCTAssertFalse(result.contains("sk-first-secret"))
        XCTAssertFalse(result.contains("sk-second-secret"))
    }

    func testScrubBearerNoTokenUnchanged() {
        let input = "No bearer here"
        XCTAssertEqual(H.scrubBearer(in: input), input)
    }

    func testScrubBearerEmptyTokenUnchanged() {
        let input = "Bearer "
        XCTAssertEqual(H.scrubBearer(in: input), input)
    }

    func testScrubKeyValueSecretsXAPIKey() {
        let input = "x-api-key: sk-abc123"
        let result = H.scrubKeyValueSecrets(in: input)
        XCTAssertTrue(result.contains("***"))
        XCTAssertFalse(result.contains("sk-abc123"))
    }

    func testScrubKeyValueSecretsQuotedAPIKey() {
        let input = #"{"api_key": "sk-secret-value"}"#
        let result = H.scrubKeyValueSecrets(in: input)
        XCTAssertTrue(result.contains("***"))
        XCTAssertFalse(result.contains("sk-secret-value"))
    }

    func testRedactTruncatesLongStrings() {
        let longString = String(repeating: "a", count: 300)
        let result = H.redact(longString, max: 50)
        XCTAssertEqual(result.count, 53) // 50 chars + "..."
        XCTAssertTrue(result.hasSuffix("..."))
    }

    func testRedactStripsNewlines() {
        let input = "line1\nline2\rline3"
        let result = H.redact(input, max: 200)
        XCTAssertFalse(result.contains("\n"))
        XCTAssertFalse(result.contains("\r"))
        XCTAssertTrue(result.contains("line1 line2 line3"))
    }

    func testRedactCombinesBearerAndTruncation() {
        let input = "Bearer sk-long-secret " + String(repeating: "x", count: 300)
        let result = H.redact(input, max: 50)
        XCTAssertFalse(result.contains("sk-long-secret"))
        XCTAssertTrue(result.hasSuffix("..."))
    }

    func testSessionStartLogLineIncludesSeparatorProviderAndModels() {
        let line = H.sessionStartLogLine(
            provider: .ollama,
            modelIDs: ["zeta", "alpha"],
            preferredModel: "alpha",
            upstreamBaseURL: "http://localhost:11434/v1"
        )

        XCTAssertTrue(line.contains("=== session start ==="))
        XCTAssertTrue(line.contains("provider=ollama"))
        XCTAssertTrue(line.contains("models=alpha,zeta"))
        XCTAssertTrue(line.contains("preferred=alpha"))
        XCTAssertTrue(line.contains("upstream=http://localhost:11434/v1"))
    }

    func testModelsResponseLogLineIncludesProviderAndModelIDs() {
        let line = H.modelsResponseLogLine(
            path: "/v1/models",
            provider: .zAI,
            modelIDs: ["glm-5.1", "glm-4.5"]
        )

        XCTAssertEqual(line, "resp GET /v1/models 200 provider=zai models=2 ids=glm-4.5,glm-5.1")
    }

    // MARK: - Models Payload Builder

    func testBuildModelsPayloadStructure() throws {
        let payload = H.buildModelsPayload(allowedModels: ["model-b", "model-a"], timestamp: 1000)
        XCTAssertEqual(payload["object"] as? String, "list")
        let data = try XCTUnwrap(payload["data"] as? [[String: Any]])
        XCTAssertEqual(data.count, 3)

        // Sorted: model-a first
        XCTAssertEqual(data[0]["id"] as? String, "model-a")
        XCTAssertEqual(data[1]["id"] as? String, "model-b")
        XCTAssertEqual(data[2]["id"] as? String, ActiveModelAlias.id)

        // Each model has expected fields
        let first = data[0]
        XCTAssertEqual(first["object"] as? String, "model")
        XCTAssertEqual(first["created"] as? Int, 1000)
        XCTAssertEqual(first["owned_by"] as? String, "proxypilot")
        XCTAssertEqual(first["root"] as? String, "model-a")
    }

    func testBuildModelsPayloadEmptySet() throws {
        let payload = H.buildModelsPayload(allowedModels: [], timestamp: 0)
        let data = try XCTUnwrap(payload["data"] as? [[String: Any]])
        XCTAssertTrue(data.isEmpty)
    }

    // MARK: - Localhost Detection

    func testIsLocalhostForLocalhost() {
        let url = URL(string: "http://localhost:11434/v1")!
        XCTAssertTrue(H.isLocalhostUpstream(url))
    }

    func testIsLocalhostFor127001() {
        let url = URL(string: "http://127.0.0.1:4000/v1")!
        XCTAssertTrue(H.isLocalhostUpstream(url))
    }

    func testIsLocalhostForIPv6Loopback() {
        let url = URL(string: "http://[::1]:4000/v1")!
        XCTAssertTrue(H.isLocalhostUpstream(url))
    }

    func testIsLocalhostFalseForRemote() {
        let url = URL(string: "https://api.openai.com/v1")!
        XCTAssertFalse(H.isLocalhostUpstream(url))
    }

    // MARK: - Model Allow-List

    func testModelAllowedWhenInSet() {
        let body = jsonBody(["model": "glm-5"])
        XCTAssertTrue(H.isModelAllowed(body: body, allowedModels: ["glm-5", "glm-4.7"]))
    }

    func testModelNotAllowedWhenMissing() {
        let body = jsonBody(["model": "unknown-model"])
        XCTAssertFalse(H.isModelAllowed(body: body, allowedModels: ["glm-5"]))
    }

    func testModelAllowedWhenSetIsEmpty() {
        let body = jsonBody(["model": "anything"])
        XCTAssertTrue(H.isModelAllowed(body: body, allowedModels: []))
    }

    func testModelAllowedWhenBodyUnparseable() {
        let garbage = Data("not json".utf8)
        XCTAssertTrue(H.isModelAllowed(body: garbage, allowedModels: ["glm-5"]))
    }

    // MARK: - OpenAI Error JSON Builder

    func testOpenAIErrorJSONIsValidJSON() throws {
        let json = H.openAIErrorJSON(message: "test error")
        let data = try XCTUnwrap(json.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(parsed["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, "test error")
        XCTAssertEqual(error["type"] as? String, "invalid_request_error")
    }

    func testOpenAIErrorJSONCustomType() throws {
        let json = H.openAIErrorJSON(message: "rate limit", type: "rate_limit_error")
        let data = try XCTUnwrap(json.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(parsed["error"] as? [String: Any])
        XCTAssertEqual(error["type"] as? String, "rate_limit_error")
    }

    func testOpenAIErrorJSONEscapesMessageContent() throws {
        let message = "quoted \"message\" with newline\nand backslash \\"
        let json = H.openAIErrorJSON(message: message, type: "server_error")
        let data = try XCTUnwrap(json.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(parsed["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, message)
        XCTAssertEqual(error["type"] as? String, "server_error")
    }

    func testPrivateLogAppendCreates0600File() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxypilot-local-proxy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("proxy.log")
        try H.appendPrivateLogData(Data("test\n".utf8), to: logURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    // MARK: - appendPrivateLogData hardening (TA-05 / TA-06)

    /// A pre-seeded symlink at the log path must be refused, not followed —
    /// O_NOFOLLOW makes `open(2)` fail with ELOOP on a symlink final
    /// component, and the victim file the symlink points at must be left
    /// completely untouched.
    func testPrivateLogAppendRefusesSymlinkAndLeavesVictimUntouched() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxypilot-local-proxy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let victimURL = directory.appendingPathComponent("victim.txt")
        let victimContent = "do-not-touch"
        try victimContent.write(to: victimURL, atomically: true, encoding: .utf8)

        let symlinkURL = directory.appendingPathComponent("proxy.log")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: victimURL)

        XCTAssertThrowsError(try H.appendPrivateLogData(Data("attacker-controlled\n".utf8), to: symlinkURL))

        let victimAfter = try String(contentsOf: victimURL, encoding: .utf8)
        XCTAssertEqual(victimAfter, victimContent, "symlink target must be untouched after a refused append")
    }

    /// A pre-seeded non-regular file (FIFO) at the log path must be refused —
    /// writing to it could hang the caller or leak data to an unexpected
    /// reader. A reader end is held open so `open(2)` on the write side
    /// actually succeeds (matching a real pre-seeding attack) and the
    /// rejection is proven to come from the S_ISREG file-type check, not
    /// merely from a reader-less FIFO failing fast at open time.
    func testPrivateLogAppendRefusesForeignFileType() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxypilot-local-proxy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fifoURL = directory.appendingPathComponent("proxy.log")
        let mkfifoResult = fifoURL.path.withCString { mkfifo($0, S_IRUSR | S_IWUSR) }
        try XCTSkipUnless(mkfifoResult == 0, "mkfifo failed in this test environment")

        // Hold a non-blocking read end open for the duration of the test so
        // the write-side open(2) below doesn't hang or fail with ENXIO —
        // it must reach the fstat/S_ISREG check and be rejected there.
        let readerDescriptor = fifoURL.path.withCString { open($0, O_RDONLY | O_NONBLOCK) }
        try XCTSkipUnless(readerDescriptor >= 0, "could not open FIFO read end in this test environment")
        defer { close(readerDescriptor) }

        XCTAssertThrowsError(try H.appendPrivateLogData(Data("test\n".utf8), to: fifoURL))
    }

    /// A fresh file gets created at 0600 with the expected content, and a
    /// second append lands after the first rather than overwriting it.
    func testPrivateLogAppendCreatesThenAppendsWithCorrectPermissionsAndContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxypilot-local-proxy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("proxy.log")
        try H.appendPrivateLogData(Data("first\n".utf8), to: logURL)

        let attributesAfterFirst = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let permissionsAfterFirst = try XCTUnwrap(attributesAfterFirst[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissionsAfterFirst.intValue & 0o777, 0o600)
        XCTAssertEqual(try String(contentsOf: logURL, encoding: .utf8), "first\n")

        try H.appendPrivateLogData(Data("second\n".utf8), to: logURL)

        let attributesAfterSecond = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let permissionsAfterSecond = try XCTUnwrap(attributesAfterSecond[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissionsAfterSecond.intValue & 0o777, 0o600)
        XCTAssertEqual(try String(contentsOf: logURL, encoding: .utf8), "first\nsecond\n")
    }

    /// Many concurrent appends of distinct, individually-identifiable lines
    /// must all land — whole, unbroken, and exactly once — with no lost
    /// writes or interleaved fragments from the lack of a lock/O_APPEND.
    func testPrivateLogAppendSerializesConcurrentWritersWithoutLossOrInterleaving() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxypilot-local-proxy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("proxy.log")
        let writerCount = 200
        let expectedLines = Set((0..<writerCount).map { "concurrent-line-\($0)" })

        DispatchQueue.concurrentPerform(iterations: writerCount) { index in
            let line = "concurrent-line-\(index)\n"
            try? H.appendPrivateLogData(Data(line.utf8), to: logURL)
        }

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        let lines = contents.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, writerCount, "every writer's line must be present exactly once, none lost or merged")
        XCTAssertEqual(Set(lines), expectedLines, "every line must be whole and unbroken — no interleaved fragments")
    }

    // MARK: - Listener loopback bind regression guard
    //
    // Regression context: commit 52aa0c7 (v1.10.0 triadic audit) tried to enforce
    // loopback binding by setting `params.requiredLocalEndpoint = .hostPort(...)`.
    // That approach raised EINVAL at `NWListener(using:on:)` construction whenever
    // the endpoint port matched the configured port — the listener never started.
    // Commit d66ec03 removed the broken line as collateral while restoring the
    // local-password feature; the proxy started again but no OS-level loopback
    // constraint remained — only the in-process `isLoopbackClientEndpoint` guard
    // still rejected non-loopback client endpoints at the app layer.
    //
    // v1.10.2 enforces loopback at the OS layer via `requiredInterfaceType = .loopback`,
    // the canonical Apple mechanism that restricts the listener to lo0 without
    // conflicting with the `on: port` argument. Parameter construction is extracted
    // into `makeListenerParameters` so the wiring is unit-testable. The end-to-end
    // `testBuiltInProxyRejectsNonLoopbackClients` below is a known blind spot for
    // this regression class — the app-level guard masks listener-binding misconfig.
    // The test below pins the OS-layer constraint directly.

    func testMakeListenerParametersConstrainsListenerToLoopbackInterface() {
        let params = LocalProxyServer.makeListenerParameters()
        XCTAssertEqual(
            params.requiredInterfaceType,
            .loopback,
            "requiredInterfaceType must be .loopback so NWListener only accepts connections arriving via lo0. Regression guard against silent removal."
        )
    }

    func testLoopbackBindHostNormalizesAliasesToIPv4Loopback() {
        XCTAssertEqual(LocalProxyServer.loopbackBindHost(from: "localhost"), "127.0.0.1")
        XCTAssertEqual(LocalProxyServer.loopbackBindHost(from: "::1"), "127.0.0.1")
        XCTAssertEqual(LocalProxyServer.loopbackBindHost(from: ""), "127.0.0.1")
        XCTAssertEqual(LocalProxyServer.loopbackBindHost(from: "127.0.0.1"), "127.0.0.1")
    }

    // MARK: - Config.isLocalhostUpstream (via the struct)

    func testBuiltInProxyRejectsNonLoopbackClients() async throws {
        guard let nonLoopbackHost = nonLoopbackIPv4Address() else {
            throw XCTSkip("No non-loopback IPv4 address available for LAN exposure regression test.")
        }
        let port = try unusedLoopbackPort()
        let server = LocalProxyServer()
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: port,
            masterKey: "test",
            upstreamProvider: .ollama,
            upstreamAPIBase: URL(string: "http://localhost:11434/v1")!,
            upstreamAPIKey: nil,
            allowedModels: [],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "",
            googleThoughtSignatureStore: nil
        )

        try server.start(config: config)
        defer { try? server.stop() }
        await waitForLocalProxyToRun(server)

        let url = URL(string: "http://\(nonLoopbackHost):\(port)/v1/models")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (_, response) = try await session.data(from: url)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            XCTAssertNotEqual(
                statusCode,
                200,
                "Built-in proxy must not serve /v1/models on non-loopback address \(nonLoopbackHost)."
            )
        } catch {
            XCTAssertTrue(true)
        }
    }

    func testConfigIsLocalhostUpstreamTrue() {
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: 4000,
            masterKey: "test",
            upstreamProvider: .ollama,
            upstreamAPIBase: URL(string: "http://localhost:11434/v1")!,
            upstreamAPIKey: nil,
            allowedModels: [],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "llama3",
            googleThoughtSignatureStore: nil
        )
        XCTAssertTrue(config.isLocalhostUpstream)
    }

    func testConfigIsLocalhostUpstreamFalse() {
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: 4000,
            masterKey: "test",
            upstreamProvider: .zAI,
            upstreamAPIBase: URL(string: "https://api.z.ai/api/coding/paas/v4")!,
            upstreamAPIKey: "sk-test",
            allowedModels: ["glm-5"],
            requiresAuth: true,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "glm-5",
            googleThoughtSignatureStore: nil
        )
        XCTAssertFalse(config.isLocalhostUpstream)
    }

    func testOllamaLANUpstreamDoesNotRequireAPIKey() {
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: 4000,
            masterKey: "test",
            upstreamProvider: .ollama,
            upstreamAPIBase: URL(string: "http://192.168.1.50:11434/v1")!,
            upstreamAPIKey: nil,
            allowedModels: ["llama3"],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "llama3",
            googleThoughtSignatureStore: nil
        )
        XCTAssertFalse(config.isLocalhostUpstream)
        XCTAssertFalse(config.requiresUpstreamAPIKey)
    }

    func testCloudLANUpstreamStillRequiresAPIKey() {
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: 4000,
            masterKey: "test",
            upstreamProvider: .zAI,
            upstreamAPIBase: URL(string: "http://192.168.1.50:8080/v1")!,
            upstreamAPIKey: nil,
            allowedModels: ["glm-5"],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "glm-5",
            googleThoughtSignatureStore: nil
        )
        XCTAssertTrue(config.requiresUpstreamAPIKey)
    }

    func testProtectedRoutesRequireAuthWhenUpstreamCredentialIsPresent() {
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: 4000,
            masterKey: "test",
            upstreamProvider: .zAI,
            upstreamAPIBase: URL(string: "https://api.z.ai/api/coding/paas/v4")!,
            upstreamAPIKey: "sk-test",
            allowedModels: ["glm-5"],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "glm-5",
            googleThoughtSignatureStore: nil
        )

        XCTAssertTrue(config.requiresAuthForProtectedRoutes)
    }

    func testProtectedRoutesRequireAuthWhenLocalAuthEnabled() {
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: 4000,
            masterKey: "test",
            upstreamProvider: .zAI,
            upstreamAPIBase: URL(string: "https://api.z.ai/api/coding/paas/v4")!,
            upstreamAPIKey: "sk-test",
            allowedModels: ["glm-5"],
            requiresAuth: true,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "glm-5",
            googleThoughtSignatureStore: nil
        )

        XCTAssertTrue(config.requiresAuthForProtectedRoutes)
    }

    func testLocalNoAuthCompatibilityRemainsWhenNoUpstreamCredentialIsPresent() {
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: 4000,
            masterKey: "test",
            upstreamProvider: .ollama,
            upstreamAPIBase: URL(string: "http://localhost:11434/v1")!,
            upstreamAPIKey: nil,
            allowedModels: ["llama3"],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "llama3",
            googleThoughtSignatureStore: nil
        )

        XCTAssertFalse(config.requiresAuthForProtectedRoutes)
    }

    func testCredentialBackedBuiltInProxyFailsClosedAndKeepsUpstreamKeySeparated() async throws {
        let upstream = LocalHTTPStubServer(body: """
        {"id":"chatcmpl-auth","model":"test-model","choices":[{"message":{"role":"assistant","content":"ok"}}]}
        """)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let port = try unusedLoopbackPort()
        let server = LocalProxyServer()
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: port,
            masterKey: "local-capability",
            upstreamProvider: .openAI,
            upstreamAPIBase: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!,
            upstreamAPIKey: "upstream-secret",
            allowedModels: [],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "",
            googleThoughtSignatureStore: nil
        )

        try server.start(config: config)
        defer { try? server.stop() }
        await waitForLocalProxyToRun(server)

        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var unauthenticated = URLRequest(url: url)
        unauthenticated.httpMethod = "POST"
        unauthenticated.setValue("application/json", forHTTPHeaderField: "Content-Type")
        unauthenticated.httpBody = jsonBody(["model": "test-model", "messages": []])

        let (_, rejectedResponse) = try await URLSession.shared.data(for: unauthenticated)
        XCTAssertEqual((rejectedResponse as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertTrue(upstream.requests().isEmpty)

        var authenticated = unauthenticated
        authenticated.setValue("Bearer local-capability", forHTTPHeaderField: "Authorization")
        let (_, acceptedResponse) = try await URLSession.shared.data(for: authenticated)
        XCTAssertEqual((acceptedResponse as? HTTPURLResponse)?.statusCode, 200)

        let captured = try XCTUnwrap(upstream.requests().first)
        XCTAssertEqual(captured.headerValue("authorization"), "Bearer upstream-secret")
        XCTAssertNotEqual(captured.headerValue("authorization"), "Bearer local-capability")
    }

    func testBuiltInProxyRejectsBrowserOriginBeforeForwarding() async throws {
        let upstream = LocalHTTPStubServer(body: #"{"ok":true}"#)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let port = try unusedLoopbackPort()
        let server = LocalProxyServer()
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: port,
            masterKey: "",
            upstreamProvider: .ollama,
            upstreamAPIBase: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!,
            upstreamAPIKey: nil,
            allowedModels: [],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "",
            googleThoughtSignatureStore: nil
        )

        try server.start(config: config)
        defer { try? server.stop() }
        await waitForLocalProxyToRun(server)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://attacker.invalid", forHTTPHeaderField: "Origin")
        request.httpBody = jsonBody(["model": "test-model", "messages": []])

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertTrue(upstream.requests().isEmpty)
    }

    func testBuiltInProxyRejectsSimpleBrowserMediaTypeBeforeForwarding() async throws {
        let upstream = LocalHTTPStubServer(body: #"{"ok":true}"#)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let port = try unusedLoopbackPort()
        let server = LocalProxyServer()
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: port,
            masterKey: "",
            upstreamProvider: .ollama,
            upstreamAPIBase: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!,
            upstreamAPIKey: nil,
            allowedModels: [],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "",
            googleThoughtSignatureStore: nil
        )

        try server.start(config: config)
        defer { try? server.stop() }
        await waitForLocalProxyToRun(server)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"model":"test-model","messages":[]}"#.utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 415)
        XCTAssertTrue(upstream.requests().isEmpty)
    }

    func testDeepSeekUsesAnthropicPassthroughByDefault() {
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: 4000,
            masterKey: "test",
            upstreamProvider: .deepSeek,
            upstreamAPIBase: URL(string: "https://api.deepseek.com/v1")!,
            upstreamAPIKey: "sk-test",
            allowedModels: ["deepseek-v4-pro"],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "deepseek-v4-pro",
            googleThoughtSignatureStore: nil
        )
        XCTAssertTrue(config.isAnthropicPassthroughActive)
    }

    func testBuiltInProxyAppliesOpenAIComputeCacheHint() async throws {
        let upstream = LocalHTTPStubServer(body: """
        {"id":"chatcmpl-cache","model":"test-model","choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}
        """)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let port = try unusedLoopbackPort()
        let server = LocalProxyServer()
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: port,
            sessionID: "gui-session",
            masterKey: "test",
            upstreamProvider: .openAI,
            upstreamAPIBase: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!,
            upstreamAPIKey: nil,
            allowedModels: [],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "",
            googleThoughtSignatureStore: nil,
            promptCaching: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        try server.start(config: config)
        defer { try? server.stop() }
        await waitForLocalProxyToRun(server)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody([
            "model": "test-model",
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let capturedRequest = try XCTUnwrap(upstream.requests().first)
        let bodyData = try XCTUnwrap(capturedRequest.body.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(json["prompt_cache_key"] as? String, "06647b462d27d54152e29781_1")
        XCTAssertEqual(json["model"] as? String, "test-model")
        XCTAssertEqual(capturedRequest.headerValue("content-type"), "application/json")
        XCTAssertEqual(capturedRequest.headerValue("accept"), "application/json")
    }

    func testBuiltInProxyOllamaAnthropicTranslationRemovesLeadingBillingHeader() async throws {
        let upstream = LocalHTTPStubServer(body: """
        {"id":"chatcmpl-local-cache","model":"qwen3-coder","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}
        """)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let port = try unusedLoopbackPort()
        let server = LocalProxyServer()
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: port,
            sessionID: "gui-local-cache-session",
            masterKey: "test",
            upstreamProvider: .ollama,
            upstreamAPIBase: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!,
            upstreamAPIKey: nil,
            allowedModels: [],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "qwen3-coder",
            googleThoughtSignatureStore: nil,
            promptCaching: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        try server.start(config: config)
        defer { try? server.stop() }
        await waitForLocalProxyToRun(server)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody([
            "model": "claude-sonnet-4-5-20250514",
            "max_tokens": 64,
            "system": "x-anthropic-billing-header: cc_version=2.1.118.147; cc_entrypoint=sdk-cli; cch=203d1;\nYou are a coding agent.",
            "messages": [["role": "user", "content": "Keep cch=12345 here."]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let capturedRequest = try XCTUnwrap(upstream.requests().first)
        let bodyData = try XCTUnwrap(capturedRequest.body.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "You are a coding agent.")
        XCTAssertEqual(messages[1]["content"] as? String, "Keep cch=12345 here.")
    }

    func testBuiltInProxyBufferedChatRecordsCacheWriteTokens() async throws {
        let upstream = LocalHTTPStubServer(body: """
        {"id":"chatcmpl-cache","model":"test-model","choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":12,"completion_tokens":7,"total_tokens":19,"prompt_tokens_details":{"cached_tokens":5},"cache_creation_input_tokens":3}}
        """)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let port = try unusedLoopbackPort()
        let server = LocalProxyServer()
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: port,
            sessionID: "gui-cache-write-session",
            masterKey: "test",
            upstreamProvider: .openAI,
            upstreamAPIBase: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!,
            upstreamAPIKey: nil,
            allowedModels: [],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "",
            googleThoughtSignatureStore: nil,
            promptCaching: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints)
        )

        try server.start(config: config)
        defer { try? server.stop() }
        await waitForLocalProxyToRun(server)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody([
            "model": "test-model",
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let didRecord = await waitForReportCard(server, requestCount: 1)
        XCTAssertTrue(didRecord)

        let (record, totalWriteTokens) = try await MainActor.run {
            (
                try XCTUnwrap(server.reportCard.requests.last),
                server.reportCard.totalPromptCacheWriteTokens
            )
        }
        XCTAssertEqual(record.promptTokens, 12)
        XCTAssertEqual(record.completionTokens, 7)
        XCTAssertEqual(record.promptCacheHitTokens, 5)
        XCTAssertEqual(record.promptCacheMissTokens, 7)
        XCTAssertEqual(record.promptCacheWriteTokens, 3)
        XCTAssertEqual(totalWriteTokens, 3)
    }

    func testBuiltInProxyOffModeSuppressesBufferedChatCacheTelemetry() async throws {
        let upstream = LocalHTTPStubServer(body: """
        {"id":"chatcmpl-cache","model":"test-model","choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":12,"completion_tokens":7,"total_tokens":19,"prompt_tokens_details":{"cached_tokens":5},"cache_creation_input_tokens":3}}
        """)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let port = try unusedLoopbackPort()
        let server = LocalProxyServer()
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: port,
            sessionID: "gui-cache-off-session",
            masterKey: "test",
            upstreamProvider: .openAI,
            upstreamAPIBase: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!,
            upstreamAPIKey: nil,
            allowedModels: [],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "",
            googleThoughtSignatureStore: nil,
            promptCaching: PromptCachingConfiguration(isEnabled: false, mode: .off)
        )

        try server.start(config: config)
        defer { try? server.stop() }
        await waitForLocalProxyToRun(server)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody([
            "model": "test-model",
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let didRecord = await waitForReportCard(server, requestCount: 1)
        XCTAssertTrue(didRecord)

        let (record, totalWriteTokens) = try await MainActor.run {
            (
                try XCTUnwrap(server.reportCard.requests.last),
                server.reportCard.totalPromptCacheWriteTokens
            )
        }
        XCTAssertEqual(record.promptTokens, 12)
        XCTAssertEqual(record.completionTokens, 7)
        XCTAssertNil(record.promptCacheHitTokens)
        XCTAssertNil(record.promptCacheMissTokens)
        XCTAssertNil(record.promptCacheWriteTokens)
        XCTAssertEqual(totalWriteTokens, 0)
    }

    func testDeepSeekBufferedPassthroughRecordsNativeAnthropicUsage() async throws {
        let upstream = LocalHTTPStubServer(body: """
        {"id":"msg_deepseek_test","type":"message","role":"assistant","model":"deepseek-v4-flash","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":32,"service_tier":"standard"}}
        """)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let port = try unusedLoopbackPort()
        let server = LocalProxyServer()
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: port,
            masterKey: "test",
            upstreamProvider: .deepSeek,
            upstreamAPIBase: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!,
            upstreamAPIKey: "sk-test",
            allowedModels: ["deepseek-v4-flash"],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "deepseek-v4-flash",
            googleThoughtSignatureStore: nil
        )

        try server.start(config: config)
        defer { try? server.stop() }
        await waitForLocalProxyToRun(server)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer test", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonBody([
            "model": "claude-opus-4-7",
            "max_tokens": 64,
            "stream": false,
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let didRecord = await waitForReportCard(server, requestCount: 1)
        XCTAssertTrue(didRecord)

        let record = try await MainActor.run {
            try XCTUnwrap(server.reportCard.requests.last)
        }
        XCTAssertEqual(record.model, "deepseek-v4-flash")
        XCTAssertEqual(record.promptTokens, 10)
        XCTAssertEqual(record.completionTokens, 32)
        XCTAssertEqual(record.promptCacheHitTokens, 0)
        XCTAssertEqual(record.promptCacheMissTokens, 10)
        XCTAssertEqual(record.path, "/v1/messages")
        XCTAssertFalse(record.wasStreaming)
    }

    func testDeepSeekStreamingPassthroughRecordsNativeAnthropicUsage() async throws {
        let upstream = LocalHTTPStubServer(
            body: """
            event: message_start
            data: {"type":"message_start","message":{"id":"msg_deepseek_stream","type":"message","role":"assistant","model":"deepseek-v4-flash","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":8,"cache_creation_input_tokens":0,"cache_read_input_tokens":2,"output_tokens":1}}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":0}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":4}}

            event: message_stop
            data: {"type":"message_stop"}

            """,
            contentType: "text/event-stream"
        )
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let port = try unusedLoopbackPort()
        let server = LocalProxyServer()
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: port,
            masterKey: "test",
            upstreamProvider: .deepSeek,
            upstreamAPIBase: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!,
            upstreamAPIKey: "sk-test",
            allowedModels: ["deepseek-v4-flash"],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "deepseek-v4-flash",
            googleThoughtSignatureStore: nil
        )

        try server.start(config: config)
        defer { try? server.stop() }
        await waitForLocalProxyToRun(server)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer test", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonBody([
            "model": "claude-opus-4-7",
            "max_tokens": 64,
            "stream": true,
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let didRecord = await waitForReportCard(server, requestCount: 1)
        XCTAssertTrue(didRecord)

        let record = try await MainActor.run {
            try XCTUnwrap(server.reportCard.requests.last)
        }
        XCTAssertEqual(record.model, "deepseek-v4-flash")
        XCTAssertEqual(record.promptTokens, 10)
        XCTAssertEqual(record.completionTokens, 4)
        XCTAssertEqual(record.promptCacheHitTokens, 2)
        XCTAssertEqual(record.promptCacheMissTokens, 8)
        XCTAssertEqual(record.path, "/v1/messages")
        XCTAssertTrue(record.wasStreaming)
    }

    func testMoonshotBufferedPassthroughRecordsNativeAnthropicUsage() async throws {
        let upstream = LocalHTTPStubServer(body: """
        {"id":"msg_deepseek_test","type":"message","role":"assistant","model":"kimi-k3","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":32,"service_tier":"standard"}}
        """)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let port = try unusedLoopbackPort()
        let server = LocalProxyServer()
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: port,
            masterKey: "test",
            upstreamProvider: .moonshot,
            upstreamAPIBase: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!,
            upstreamAPIKey: "sk-test",
            allowedModels: ["kimi-k3"],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "kimi-k3",
            googleThoughtSignatureStore: nil
        )

        try server.start(config: config)
        defer { try? server.stop() }
        await waitForLocalProxyToRun(server)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer test", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonBody([
            "model": "claude-opus-4-7",
            "max_tokens": 64,
            "stream": false,
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (responseBody, response) = try await URLSession.shared.data(for: request)
        XCTAssertTrue(String(decoding: responseBody, as: UTF8.self).contains("kimi-k3"))
        let captured = try XCTUnwrap(upstream.requests().first)
        XCTAssertEqual(captured.headerValue("authorization"), "Bearer sk-test")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(captured.body.utf8)) as? [String: Any])
        XCTAssertEqual(sent["model"] as? String, "kimi-k3")
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let didRecord = await waitForReportCard(server, requestCount: 1)
        XCTAssertTrue(didRecord)

        let record = try await MainActor.run {
            try XCTUnwrap(server.reportCard.requests.last)
        }
        XCTAssertEqual(record.model, "kimi-k3")
        XCTAssertEqual(record.promptTokens, 10)
        XCTAssertEqual(record.completionTokens, 32)
        XCTAssertEqual(record.promptCacheHitTokens, 0)
        XCTAssertEqual(record.promptCacheMissTokens, 10)
        XCTAssertEqual(record.path, "/v1/messages")
        XCTAssertFalse(record.wasStreaming)
    }

    func testMoonshotStreamingPassthroughRecordsNativeAnthropicUsage() async throws {
        let upstream = LocalHTTPStubServer(
            body: """
            event: message_start
            data: {"type":"message_start","message":{"id":"msg_deepseek_stream","type":"message","role":"assistant","model":"kimi-k3","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":8,"cache_creation_input_tokens":0,"cache_read_input_tokens":2,"output_tokens":1}}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":0}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":4}}

            event: message_stop
            data: {"type":"message_stop"}

            """,
            contentType: "text/event-stream"
        )
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let port = try unusedLoopbackPort()
        let server = LocalProxyServer()
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: port,
            masterKey: "test",
            upstreamProvider: .moonshot,
            upstreamAPIBase: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!,
            upstreamAPIKey: "sk-test",
            allowedModels: ["kimi-k3"],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "kimi-k3",
            googleThoughtSignatureStore: nil
        )

        try server.start(config: config)
        defer { try? server.stop() }
        await waitForLocalProxyToRun(server)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer test", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonBody([
            "model": "claude-opus-4-7",
            "max_tokens": 64,
            "stream": true,
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (responseBody, response) = try await URLSession.shared.data(for: request)
        XCTAssertTrue(String(decoding: responseBody, as: UTF8.self).contains("kimi-k3"))
        let captured = try XCTUnwrap(upstream.requests().first)
        XCTAssertEqual(captured.headerValue("authorization"), "Bearer sk-test")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(captured.body.utf8)) as? [String: Any])
        XCTAssertEqual(sent["model"] as? String, "kimi-k3")
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let didRecord = await waitForReportCard(server, requestCount: 1)
        XCTAssertTrue(didRecord)

        let record = try await MainActor.run {
            try XCTUnwrap(server.reportCard.requests.last)
        }
        XCTAssertEqual(record.model, "kimi-k3")
        XCTAssertEqual(record.promptTokens, 10)
        XCTAssertEqual(record.completionTokens, 4)
        XCTAssertEqual(record.promptCacheHitTokens, 2)
        XCTAssertEqual(record.promptCacheMissTokens, 8)
        XCTAssertEqual(record.path, "/v1/messages")
        XCTAssertTrue(record.wasStreaming)
    }

    func testSuccessfulEmptyAnthropicPassthroughStreamCompletesTrackingAndRecordsRequest() async throws {
        let upstream = LocalHTTPStubServer(body: "", contentType: "text/event-stream")
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let port = try unusedLoopbackPort()
        let server = LocalProxyServer()
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: port,
            masterKey: "test",
            upstreamProvider: .deepSeek,
            upstreamAPIBase: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!,
            upstreamAPIKey: "sk-test",
            allowedModels: ["deepseek-v4-flash"],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "deepseek-v4-flash",
            googleThoughtSignatureStore: nil
        )

        try server.start(config: config)
        defer { try? server.stop() }
        await waitForLocalProxyToRun(server)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer test", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonBody([
            "model": "claude-opus-4-7",
            "max_tokens": 64,
            "stream": true,
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let didRecord = await waitForReportCard(server, requestCount: 1)
        XCTAssertTrue(didRecord)

        let (record, pendingCount, failedCount) = try await MainActor.run {
            (
                try XCTUnwrap(server.reportCard.requests.last),
                server.state.pendingRequestCount,
                server.state.failedRequestCount
            )
        }
        XCTAssertEqual(record.model, "deepseek-v4-flash")
        XCTAssertEqual(record.promptTokens, 0)
        XCTAssertEqual(record.completionTokens, 0)
        XCTAssertTrue(record.wasStreaming)
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(failedCount, 0)
    }

    func testDirectOpenAIChatClearsPriorRemappedModelAttribution() async throws {
        let upstream = LocalHTTPStubServer(body: """
        {"id":"chatcmpl-direct","model":"gpt-5.6","choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}
        """)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let port = try unusedLoopbackPort()
        let server = LocalProxyServer()
        let config = LocalProxyServer.Config(
            host: "127.0.0.1",
            port: port,
            masterKey: "test",
            upstreamProvider: .openAI,
            upstreamAPIBase: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!,
            upstreamAPIKey: nil,
            allowedModels: [],
            requiresAuth: false,
            anthropicTranslatorMode: .hardened,
            miniMaxRoutingMode: .standard,
            preferredAnthropicUpstreamModel: "routed-model",
            googleThoughtSignatureStore: nil
        )

        try server.start(config: config)
        defer { try? server.stop() }
        await waitForLocalProxyToRun(server)
        await MainActor.run {
            server.state.lastUpstreamModelUsed = "routed-model"
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody([
            "model": "gpt-5.6",
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let didRecord = await waitForReportCard(server, requestCount: 1)
        XCTAssertTrue(didRecord)

        let (lastUpstreamModelUsed, lastModelSeen) = await MainActor.run {
            (server.state.lastUpstreamModelUsed, server.state.lastModelSeen)
        }
        XCTAssertEqual(lastUpstreamModelUsed, "")
        XCTAssertEqual(lastModelSeen, "gpt-5.6")
    }

    // MARK: - Static limitStatusCode (existing on LocalProxyServer)

    func testLimitStatusCode429AtExactLimit() {
        let status = LocalProxyServer.limitStatusCode(
            headerBytes: 100,
            bodyBytes: 100,
            activeConnections: LocalProxyServer.maxConcurrentConnections
        )
        XCTAssertEqual(status, 429)
    }

    func testLimitStatusCode413TakesPriorityOverNil() {
        let status = LocalProxyServer.limitStatusCode(
            headerBytes: LocalProxyServer.maxHeaderBytes + 1,
            bodyBytes: 0,
            activeConnections: 0
        )
        XCTAssertEqual(status, 413)
    }

    func testLimitStatusCodeNilWhenAllWithinLimits() {
        let status = LocalProxyServer.limitStatusCode(
            headerBytes: 1024,
            bodyBytes: 1024,
            activeConnections: 1
        )
        XCTAssertNil(status)
    }

    func testFormatByteCountUsesCompactUnits() {
        XCTAssertEqual(LocalProxyServerHelpers.formatByteCount(0), "0 B")
        XCTAssertEqual(LocalProxyServerHelpers.formatByteCount(312), "312 B")
        XCTAssertEqual(LocalProxyServerHelpers.formatByteCount(121_242), "118.4 KB")
        XCTAssertEqual(LocalProxyServerHelpers.formatByteCount(3 * 1024 * 1024), "3.0 MB")
    }
}
