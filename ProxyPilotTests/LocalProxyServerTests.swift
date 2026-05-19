import XCTest
import Darwin
import ProxyPilotCore
@testable import ProxyPilot

final class LocalProxyServerTests: XCTestCase {

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

    func testUpstreamErrorGitHubCopilotEntitlementExplainsAccessRequirement() {
        let msg = H.upstreamErrorMessage(
            statusCode: 403,
            body: #"{"error":{"message":"GitHub Copilot subscription required for this account"}}"#,
            provider: .githubCopilot
        )
        XCTAssertTrue(msg.contains("GitHub authentication is present"))
        XCTAssertTrue(msg.contains("does not appear to have GitHub Copilot access"))
        XCTAssertTrue(msg.contains("Copilot Pro, Business, Enterprise"))
    }

    func testUpstreamErrorGitHubCopilotMaskedModelListFailureExplainsAccessRequirement() {
        let msg = H.upstreamErrorMessage(
            statusCode: 500,
            body: #"{"error":{"message":"Failed to list models","type":"api_error"}}"#,
            provider: .githubCopilot
        )
        XCTAssertTrue(msg.contains("GitHub Copilot sidecar could not access Copilot models"))
        XCTAssertTrue(msg.contains("If GitHub authentication completed successfully"))
        XCTAssertTrue(msg.contains("does not appear to have GitHub Copilot access"))
    }

    func testUpstreamErrorGitHubCopilotUnexpectedUserAgentStaysGeneric() {
        let msg = H.upstreamErrorMessage(
            statusCode: 403,
            body: "Forbidden: unexpected user-agent curl/8.7.1",
            provider: .githubCopilot
        )
        XCTAssertEqual(msg, "Upstream error: Forbidden: unexpected user-agent curl/8.7.1")
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
        XCTAssertEqual(data.count, 2)

        // Sorted: model-a first
        XCTAssertEqual(data[0]["id"] as? String, "model-a")
        XCTAssertEqual(data[1]["id"] as? String, "model-b")

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
}
