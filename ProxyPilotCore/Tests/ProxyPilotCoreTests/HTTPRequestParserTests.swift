import Testing
import Foundation
@testable import ProxyPilotCore

// MARK: - HTTPRequestParser Tests

@Test func parseValidGETRequest() {
    let raw = "GET /v1/chat/completions HTTP/1.1\r\nHost: localhost:8080\r\nContent-Length: 0\r\n"
    let data = raw.data(using: .utf8)!
    let result = HTTPRequestParser.parse(headerData: data)
    guard case .success(let req) = result else {
        Issue.record("Expected success, got failure")
        return
    }
    #expect(req.method == "GET")
    #expect(req.path == "/v1/chat/completions")
    #expect(req.headers["host"] == "localhost:8080")
    #expect(req.contentLength == 0)
}

@Test func parsePOSTRequestWithContentLength() {
    let raw = "POST /v1/chat/completions HTTP/1.1\r\nHost: localhost:8080\r\nContent-Length: 256\r\nAuthorization: Bearer sk-test\r\n"
    let data = raw.data(using: .utf8)!
    let result = HTTPRequestParser.parse(headerData: data)
    guard case .success(let req) = result else {
        Issue.record("Expected success, got failure")
        return
    }
    #expect(req.method == "POST")
    #expect(req.path == "/v1/chat/completions")
    #expect(req.contentLength == 256)
    #expect(req.headers["authorization"] == "Bearer sk-test")
}

@Test func parseStripsQueryStringFromPath() {
    let raw = "GET /v1/models?filter=chat HTTP/1.1\r\nHost: localhost\r\n"
    let data = raw.data(using: .utf8)!
    let result = HTTPRequestParser.parse(headerData: data)
    guard case .success(let req) = result else {
        Issue.record("Expected success, got failure")
        return
    }
    #expect(req.path == "/v1/models")
}

@Test func parseEmptyDataReturnsEmptyHeaderError() {
    let result = HTTPRequestParser.parse(headerData: Data())
    guard case .failure(let err) = result else {
        Issue.record("Expected failure for empty data")
        return
    }
    #expect(err == .emptyHeader)
}

@Test func parseInvalidRequestLineReturnsError() {
    // A line with only one token (no path)
    let raw = "CONNECT\r\nHost: localhost\r\n"
    let data = raw.data(using: .utf8)!
    let result = HTTPRequestParser.parse(headerData: data)
    guard case .failure(let err) = result else {
        Issue.record("Expected failure for invalid request line")
        return
    }
    #expect(err == .invalidRequestLine)
}

// MARK: - AuthorizationValidator Tests

@Test func authValidWithBearerToken() {
    let headers = ["authorization": "Bearer my-secret-key"]
    #expect(AuthorizationValidator.isAuthorized(headers: headers, masterKey: "my-secret-key"))
}

@Test func authValidWithXApiKey() {
    let headers = ["x-api-key": "my-secret-key"]
    #expect(AuthorizationValidator.isAuthorized(headers: headers, masterKey: "my-secret-key"))
}

@Test func authValidWithRawApiKey() {
    let headers = ["api-key": "my-secret-key"]
    #expect(AuthorizationValidator.isAuthorized(headers: headers, masterKey: "my-secret-key"))
}

@Test func authInvalidWithWrongKey() {
    let headers = ["authorization": "Bearer wrong-key"]
    #expect(!AuthorizationValidator.isAuthorized(headers: headers, masterKey: "my-secret-key"))
}

@Test func authInvalidWithNoAuthHeader() {
    let headers = ["host": "localhost"]
    #expect(!AuthorizationValidator.isAuthorized(headers: headers, masterKey: "my-secret-key"))
}

// MARK: - ModelFilter Tests

@Test func modelFilterAllowsAllWhenSetIsEmpty() {
    #expect(ModelFilter.isAllowed("gpt-4o", in: []))
}

@Test func modelFilterAllowsExactMatch() {
    #expect(ModelFilter.isAllowed("gpt-4o", in: ["gpt-4o", "claude-3-5-sonnet"]))
}

@Test func modelFilterBlocksUnknownModel() {
    #expect(!ModelFilter.isAllowed("some-random-model", in: ["gpt-4o", "claude-3-5-sonnet"]))
}

// MARK: - Streaming Detection Tests

@Test func streamingDetectionReturnsTrueWhenFlagSet() {
    let json = #"{"model":"gpt-4o","stream":true,"messages":[]}"#
    let data = json.data(using: .utf8)!
    #expect(HTTPRequestParser.isStreamingRequest(body: data))
}

@Test func streamingDetectionReturnsFalseWhenFlagFalse() {
    let json = #"{"model":"gpt-4o","stream":false,"messages":[]}"#
    let data = json.data(using: .utf8)!
    #expect(!HTTPRequestParser.isStreamingRequest(body: data))
}

@Test func streamingDetectionReturnsFalseWhenFlagAbsent() {
    let json = #"{"model":"gpt-4o","messages":[]}"#
    let data = json.data(using: .utf8)!
    #expect(!HTTPRequestParser.isStreamingRequest(body: data))
}

@Test func streamingDetectionReturnsFalseForInvalidJSON() {
    let data = "not json".data(using: .utf8)!
    #expect(!HTTPRequestParser.isStreamingRequest(body: data))
}

// MARK: - Model Extraction Tests

@Test func extractModelReturnsModelString() {
    let json = #"{"model":"claude-3-5-sonnet","messages":[]}"#
    let data = json.data(using: .utf8)!
    #expect(HTTPRequestParser.extractModel(from: data) == "claude-3-5-sonnet")
}

@Test func extractModelReturnsNilWhenAbsent() {
    let json = #"{"messages":[]}"#
    let data = json.data(using: .utf8)!
    #expect(HTTPRequestParser.extractModel(from: data) == nil)
}
