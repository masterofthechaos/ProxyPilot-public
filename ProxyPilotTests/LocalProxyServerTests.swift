import XCTest
import ProxyPilotCore
@testable import ProxyPilot

final class LocalProxyServerTests: XCTestCase {

    // MARK: - Helpers

    private typealias H = LocalProxyServerHelpers

    private func jsonBody(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
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

    func testSanitizeBodyPreservesAllForNonGoogleProvider() throws {
        let input: [String: Any] = [
            "model": "gpt-4o",
            "logprobs": true,
            "seed": 42
        ]
        let body = try JSONSerialization.data(withJSONObject: input)
        let result = H.sanitizedChatRequestBody(body, provider: .openAI)

        // Should be byte-identical (no stripping)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertNotNil(parsed["logprobs"])
        XCTAssertNotNil(parsed["seed"])
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

    // MARK: - Config.isLocalhostUpstream (via the struct)

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
