import Testing
import Foundation
@testable import ProxyPilotCore

/// Payloads captured from LM Studio 0.4.28 (llama.cpp engine 2.82.0) on
/// 2026-11-24 by sending a prompt larger than the loaded context.
@Suite("Upstream failure classification")
struct UpstreamFailureTests {
    private let lmStudioStreamError = #"data: {"error":{"message":"Engine protocol predict request returned 400: {\"error\":{\"code\":400,\"message\":\"request (40031 tokens) exceeds the available context size (32768 tokens), try increasing it\",\"type\":\"exceed_context_size_error\",\"n_prompt_tokens\":40031,\"n_ctx\":32768}}"},"message":"Engine protocol predict request returned 400: {\"error\":{\"code\":400,\"message\":\"request (40031 tokens) exceeds the available context size (32768 tokens), try increasing it\",\"type\":\"exceed_context_size_error\",\"n_prompt_tokens\":40031,\"n_ctx\":32768}}"}"#
    private let lmStudioBufferedError = #"{"error":"Engine protocol predict request returned 400: {\"error\":{\"code\":400,\"message\":\"request (40031 tokens) exceeds the available context size (32768 tokens), try increasing it\",\"type\":\"exceed_context_size_error\",\"n_prompt_tokens\":40031,\"n_ctx\":32768}}"}"#

    @Test func lmStudioStreamedContextErrorIsClassifiedWithItsNumbers() throws {
        let report = try #require(UpstreamFailureClassifier.classify(streamLine: lmStudioStreamError))
        #expect(report.failure == UpstreamFailure(kind: .contextExceeded, promptTokens: 40031, contextTokens: 32768))
        let message = report.userMessage(providerTitle: "LM Studio", endpoint: "http://localhost:1234/v1", isLocal: true)
        #expect(message.contains("40,031 tokens"))
        #expect(message.contains("32,768-token context"))
        #expect(message.contains("Reload the model in LM Studio with a larger context length"))
    }

    @Test func lmStudioBufferedContextErrorIsClassifiedWithItsStatus() {
        let report = UpstreamFailureClassifier.classify(httpStatus: 400, body: lmStudioBufferedError)
        #expect(report.failure == UpstreamFailure(kind: .contextExceeded, httpStatus: 400, promptTokens: 40031, contextTokens: 32768))
    }

    @Test func streamCompletionKeepsTheClassifiedFailure() {
        var completion = OpenAIChatStreamCompletion()
        completion.observe(line: "event: error")
        completion.observe(line: lmStudioStreamError)
        #expect(completion.sawUpstreamError)
        #expect(completion.upstreamFailure?.failure.kind == .contextExceeded)
        #expect(completion.outcomeAtEndOfStream == .upstreamError)
    }

    /// The engine's error can sit four levels down, reachable only through
    /// the error object's message string.
    @Test func deeplyNestedEngineErrorIsStillClassified() throws {
        let line = #"data: {"error":{"message":"Engine protocol predict request returned 400: {\"error\":{\"code\":400,\"message\":\"too big\",\"type\":\"exceed_context_size_error\",\"n_prompt_tokens\":29656,\"n_ctx\":8192}}"},"message":"Engine protocol predict request returned 400"}"#
        let report = try #require(UpstreamFailureClassifier.classify(streamLine: line))
        #expect(report.failure == UpstreamFailure(kind: .contextExceeded, promptTokens: 29656, contextTokens: 8192))
    }

    @Test func ordinaryStreamLinesAreNotFailures() {
        #expect(UpstreamFailureClassifier.classify(streamLine: #"data: {"choices":[{"delta":{"content":"hi"}}]}"#) == nil)
        #expect(UpstreamFailureClassifier.classify(streamLine: "data: [DONE]") == nil)
        #expect(UpstreamFailureClassifier.classify(streamLine: #"data: {"error":null,"choices":[]}"#) == nil)
    }

    @Test func unrecognizedErrorKeepsSanitizedProviderWording() {
        let report = UpstreamFailureClassifier.classify(
            httpStatus: 500,
            body: #"{"error":{"message":"model runner stopped, Authorization: Bearer sk-abcdefghijklmnopqrstuvwxyz012345"}}"#
        )
        #expect(report.failure == UpstreamFailure(kind: .providerError, httpStatus: 500))
        let text = report.userMessage(providerTitle: "Ollama", endpoint: "http://localhost:11434/v1", isLocal: true)
        #expect(text.hasPrefix("Ollama reported an error (HTTP 500): model runner stopped"))
        #expect(!text.contains("sk-abcdefghijklmnopqrstuvwxyz012345"))
    }

    @Test func nonJSONBodyIsReportedAsProviderText() {
        let report = UpstreamFailureClassifier.classify(httpStatus: 503, body: "  Service Unavailable\n")
        #expect(report.failure.kind == .providerError)
        #expect(report.providerMessage == "Service Unavailable")
        let empty = UpstreamFailureClassifier.classify(httpStatus: 502, body: "")
        #expect(empty.userMessage(providerTitle: "LM Studio", endpoint: "x", isLocal: true)
            == "LM Studio reported an error (HTTP 502) without details.")
    }

    @Test func providerTextIsTruncated() {
        let report = UpstreamFailureClassifier.classify(httpStatus: 500, body: String(repeating: "x", count: 5000))
        #expect((report.providerMessage?.count ?? 0) <= UpstreamFailureClassifier.providerMessageLimit + 16)
    }

    @Test func transportCodesMapToCauses() {
        #expect(UpstreamFailureClassifier.classify(transportErrorCode: -1004).failure.kind == .serverUnreachable)
        #expect(UpstreamFailureClassifier.classify(transportErrorCode: -1003).failure.kind == .serverUnreachable)
        #expect(UpstreamFailureClassifier.classify(transportErrorCode: -1005).failure.kind == .connectionLost)
        #expect(UpstreamFailureClassifier.classify(transportErrorCode: -1001).failure.kind == .timedOut)
        #expect(UpstreamFailureClassifier.classify(transportErrorCode: -999).failure.kind == .providerError)
        let refused = UpstreamFailureClassifier.classify(error: NSError(domain: NSURLErrorDomain, code: -1004))
        let text = refused.userMessage(providerTitle: "LM Studio", endpoint: "http://localhost:1234/v1", isLocal: true)
        #expect(text == "ProxyPilot could not connect to LM Studio at http://localhost:1234/v1. Start its local server, then try again.")
    }

    @Test func timeoutIsReportedAsProxyPilotsOwnLimit() {
        let report = UpstreamFailureClassifier.classify(transportErrorCode: -1001)
        let local = report.userMessage(providerTitle: "LM Studio", endpoint: "x", isLocal: true, waitedSeconds: 1800)
        #expect(local.hasPrefix("ProxyPilot stopped waiting for LM Studio after 30 minutes without receiving any data."))
        let cloud = report.userMessage(providerTitle: "OpenRouter", endpoint: "x", isLocal: false, waitedSeconds: 120)
        #expect(cloud == "ProxyPilot stopped waiting for OpenRouter after 2 minutes without receiving any data. Try again.")
        let short = report.userMessage(providerTitle: "OpenRouter", endpoint: "x", isLocal: false, waitedSeconds: 30)
        #expect(short.contains("after 30 seconds"))
    }

    @Test func localUpstreamsGetALongNoDataLimitAndNoTotalLimit() {
        let local = ProxyConfiguration(upstreamProvider: .lmStudio)
        #expect(local.isLocalUpstream)
        #expect(local.waitPolicy == UpstreamWaitPolicy(idle: 1800, total: nil))
        #expect(local.effectiveUpstreamRequestTimeout == 1800)
        let cloud = ProxyConfiguration(upstreamProvider: .openRouter)
        #expect(!cloud.isLocalUpstream)
        #expect(cloud.waitPolicy == UpstreamWaitPolicy(idle: 30, total: 300))
        let loopbackCustom = ProxyConfiguration(upstreamProvider: .openAI, upstreamAPIBaseURL: "http://127.0.0.1:8080/v1")
        #expect(loopbackCustom.waitPolicy == .local)
        #expect(local.withUpstreamRequestTimeout(45).effectiveUpstreamRequestTimeout == 45)
    }

    /// The limits must reach the session the engine uses, not only the
    /// configuration. The system default total is seven days.
    @Test func upstreamSessionCarriesItsWaitPolicy() {
        let local = UpstreamClient.session(for: ProxyConfiguration(upstreamProvider: .lmStudio)).configuration
        #expect(local.timeoutIntervalForRequest == 1800)
        #expect(local.timeoutIntervalForResource > 24 * 3600)
        let cloud = UpstreamClient.session(for: ProxyConfiguration(upstreamProvider: .openRouter)).configuration
        #expect(cloud.timeoutIntervalForRequest == 30)
        #expect(cloud.timeoutIntervalForResource == 300)
    }

    @Test func anUnknownFailureKindFromANewerBuildStillDecodes() throws {
        let json = Data(#"{"kind":"model_not_loaded","httpStatus":503}"#.utf8)
        let failure = try JSONDecoder().decode(UpstreamFailure.self, from: json)
        #expect(failure == UpstreamFailure(kind: .providerError, httpStatus: 503))
    }

    // MARK: - What a client is told

    @Test func googleThoughtSignatureRejectionKeepsItsOwnExplanation() {
        func message(provider: UpstreamProvider, status: Int, body: String) -> String {
            UpstreamFailureClassifier.classify(httpStatus: status, body: body)
                .clientMessage(provider: provider, endpoint: "https://example.invalid/v1", isLocal: false, rawBody: body)
        }
        let special = message(provider: .google, status: 400, body: "Invalid thought_signature in tool call")
        #expect(special.contains("Google direct rejected"))
        #expect(special.contains("OpenRouter"))
        // Only Google, and only a 400, gets the special explanation.
        #expect(!message(provider: .openRouter, status: 400, body: "thought_signature issue").contains("Google direct"))
        #expect(!message(provider: .google, status: 500, body: "thought_signature error").contains("Google direct"))
        #expect(message(provider: .google, status: 400, body: "Some other error")
            == "Google Gemini reported an error (HTTP 400): Some other error"
            || message(provider: .google, status: 400, body: "Some other error").hasSuffix("reported an error (HTTP 400): Some other error"))
    }

    @Test func clientMessageNamesACustomProviderGenerically() {
        let report = UpstreamFailureClassifier.classify(transportErrorCode: -1004)
        let message = report.clientMessage(provider: .openAI, providerTitle: "The provider",
                                           endpoint: "http://127.0.0.1:9/v1", isLocal: true)
        #expect(message.hasPrefix("ProxyPilot could not connect to The provider at http://127.0.0.1:9/v1."))
        #expect(report.clientStatus == 502)
    }

    @Test func coreClientErrorsAreClassifiedFromTheProviderResponse() {
        let body = Data(lmStudioBufferedError.utf8)
        let report = UpstreamFailureClassifier.classify(
            error: UpstreamClient.UpstreamError.httpError(statusCode: 400, body: body))
        #expect(report.failure == UpstreamFailure(kind: .contextExceeded, httpStatus: 400, promptTokens: 40031, contextTokens: 32768))
        #expect(report.clientStatus == 400)
    }

    /// Provider wording can quote the user's request, so the log line carries
    /// the category and numbers and nothing else.
    @Test func logSummaryCarriesNoProviderWording() {
        let report = UpstreamFailureClassifier.classify(
            httpStatus: 500, body: #"{"error":{"message":"stopped while reading SECRET-USER-TEXT"}}"#)
        #expect(report.providerMessage?.contains("SECRET-USER-TEXT") == true)
        #expect(report.logSummary == "kind=provider_error http=500")
        let context = UpstreamFailureClassifier.classify(httpStatus: 400, body: lmStudioBufferedError)
        #expect(context.logSummary == "kind=context_exceeded http=400 prompt_tokens=40031 context_tokens=32768")
    }

    @Test func journalRecordsDecodeWithAndWithoutAFailure() throws {
        let legacy = #"{"timestamp":0,"model":"m","promptTokens":1,"completionTokens":2,"durationSeconds":1,"path":"/v1/chat/completions","wasStreaming":true,"streamOutcome":"upstream_error"}"#
        let old = try JSONDecoder().decode(RequestRecord.self, from: Data(legacy.utf8))
        #expect(old.upstreamFailure == nil)
        let record = RequestRecord(
            model: "m", promptTokens: 0, completionTokens: 0, durationSeconds: 1,
            path: "/v1/chat/completions", wasStreaming: true, streamOutcome: "upstream_error",
            upstreamFailure: UpstreamFailure(kind: .contextExceeded, promptTokens: 29656, contextTokens: 8192)
        )
        let data = try JSONEncoder().encode(record)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""kind":"context_exceeded""#))
        #expect(try JSONDecoder().decode(RequestRecord.self, from: data) == record)
    }
}
