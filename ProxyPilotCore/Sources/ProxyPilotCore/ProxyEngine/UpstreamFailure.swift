import Foundation

/// Why an upstream request failed, in a form ProxyPilot can explain.
///
/// Holds a category and numbers only, so it is safe to journal and to place in
/// metadata-only diagnostics. Provider free text is never stored here: it can
/// echo request content, so it stays in memory for display (see
/// `UpstreamFailureReport`).
public struct UpstreamFailure: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, Equatable {
        /// The prompt is larger than the context the model has available.
        case contextExceeded = "context_exceeded"
        /// Nothing accepted the connection at the provider's endpoint.
        case serverUnreachable = "server_unreachable"
        /// The connection dropped before the response finished.
        case connectionLost = "connection_lost"
        /// The provider did not answer in time.
        case timedOut = "timed_out"
        /// The provider reported an error ProxyPilot does not recognize.
        case providerError = "provider_error"

        /// A journal written by a newer ProxyPilot may carry a kind this
        /// build does not know. Read it as an unrecognized provider error;
        /// failing here would drop the whole request record.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .providerError
        }
    }

    public let kind: Kind
    /// HTTP status of the upstream response, when there was one.
    public let httpStatus: Int?
    /// Tokens the provider counted in the rejected prompt.
    public let promptTokens: Int?
    /// Context size the provider had available.
    public let contextTokens: Int?

    /// A few words naming the cause, for a row in a request list.
    public var shortDescription: String {
        switch kind {
        case .contextExceeded: return "prompt larger than the model's context"
        case .serverUnreachable: return "could not reach the provider"
        case .connectionLost: return "connection lost"
        case .timedOut: return "timed out"
        case .providerError: return httpStatus.map { "provider error (HTTP \($0))" } ?? "provider error"
        }
    }

    public init(kind: Kind, httpStatus: Int? = nil, promptTokens: Int? = nil, contextTokens: Int? = nil) {
        self.kind = kind
        self.httpStatus = httpStatus
        self.promptTokens = promptTokens
        self.contextTokens = contextTokens
    }
}

/// A classified failure plus the provider's own wording, for display only.
public struct UpstreamFailureReport: Sendable, Equatable {
    public let failure: UpstreamFailure
    /// Sanitized, truncated provider text. Never journaled.
    public let providerMessage: String?

    public init(failure: UpstreamFailure, providerMessage: String? = nil) {
        self.failure = failure
        self.providerMessage = providerMessage
    }

    /// One sentence naming the cause, then what to do about it.
    ///
    /// `waitedSeconds` is the no-data limit ProxyPilot applied, so a timeout
    /// is reported as ProxyPilot's decision to stop waiting.
    public func userMessage(providerTitle: String, endpoint: String, isLocal: Bool, waitedSeconds: TimeInterval? = nil) -> String {
        switch failure.kind {
        case .contextExceeded:
            let size: String
            if let prompt = failure.promptTokens, let context = failure.contextTokens {
                size = "The request needs \(Self.grouped(prompt)) tokens, but the model has a \(Self.grouped(context))-token context available."
            } else {
                size = "The request is larger than the model's available context."
            }
            return isLocal
                ? "\(size) Reload the model in \(providerTitle) with a larger context length, or choose a model with a larger context."
                : "\(size) Choose a model with a larger context, or start a new conversation."
        case .serverUnreachable:
            return isLocal
                ? "ProxyPilot could not connect to \(providerTitle) at \(endpoint). Start its local server, then try again."
                : "ProxyPilot could not connect to \(providerTitle) at \(endpoint). Check your network connection and the endpoint."
        case .connectionLost:
            return isLocal
                ? "\(providerTitle) closed the connection before the response finished. The model may have been unloaded or stopped; check \(providerTitle), then try again."
                : "\(providerTitle) closed the connection before the response finished. Try again."
        case .timedOut:
            let waited = waitedSeconds.map { " after \(Self.duration($0))" } ?? ""
            let stopped = "ProxyPilot stopped waiting for \(providerTitle)\(waited) without receiving any data."
            return isLocal
                ? "\(stopped) The model may still be loading or reading a long prompt; a smaller prompt, a shorter conversation or a faster model will answer sooner."
                : "\(stopped) Try again."
        case .providerError:
            let status = failure.httpStatus.map { " (HTTP \($0))" } ?? ""
            if let providerMessage, !providerMessage.isEmpty {
                return "\(providerTitle) reported an error\(status): \(providerMessage)"
            }
            return "\(providerTitle) reported an error\(status) without details."
        }
    }

    /// The status a proxy answers with when it reports this failure itself:
    /// the provider's own status when there was one, else 502.
    public var clientStatus: Int { failure.httpStatus ?? 502 }

    /// What a proxy tells the client that sent the request. Both engines
    /// build their error bodies from this.
    public func clientMessage(
        provider: UpstreamProvider,
        providerTitle: String? = nil,
        endpoint: String,
        isLocal: Bool,
        waitedSeconds: TimeInterval? = nil,
        rawBody: String? = nil
    ) -> String {
        if provider == .google, failure.httpStatus == 400,
           rawBody?.localizedCaseInsensitiveContains("thought_signature") == true {
            return "Google direct rejected the tool-call continuation due to thought_signature validation. If this persists, use OpenRouter as the current workaround."
        }
        return userMessage(
            providerTitle: providerTitle ?? provider.title,
            endpoint: endpoint,
            isLocal: isLocal,
            waitedSeconds: waitedSeconds
        )
    }

    /// Category and numbers only, for logs: provider wording can quote the
    /// user's request, so it is never written to a log.
    public var logSummary: String {
        var parts = ["kind=\(failure.kind.rawValue)"]
        if let status = failure.httpStatus { parts.append("http=\(status)") }
        if let prompt = failure.promptTokens { parts.append("prompt_tokens=\(prompt)") }
        if let context = failure.contextTokens { parts.append("context_tokens=\(context)") }
        return parts.joined(separator: " ")
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole >= 120, whole % 60 == 0 { return "\(whole / 60) minutes" }
        return whole == 1 ? "1 second" : "\(whole) seconds"
    }

    /// A whole number with thousands separators, independent of locale.
    static func grouped(_ value: Int) -> String {
        var digits = String(abs(value))
        var index = digits.count - 3
        while index > 0 {
            digits.insert(",", at: digits.index(digits.startIndex, offsetBy: index))
            index -= 3
        }
        return value < 0 ? "-" + digits : digits
    }
}

/// Turns what an upstream sent, or how the transport failed, into an
/// `UpstreamFailureReport`.
///
/// Structured fields decide the category. Providers nest errors differently:
/// LM Studio wraps its engine's JSON error inside a message string, as an
/// object on a stream and as a bare string on a buffered response, so the
/// classifier walks into JSON embedded in strings. Unrecognized errors keep
/// the provider's sanitized wording instead of a guess.
public enum UpstreamFailureClassifier {
    static let providerMessageLimit = 300

    /// A buffered or pre-stream error response.
    public static func classify(httpStatus: Int, body: String) -> UpstreamFailureReport {
        var fields = Fields()
        if let object = jsonObject(in: body) {
            collect(object, into: &fields, depth: 0)
        }
        if fields.message == nil {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { fields.message = trimmed }
        }
        return report(from: fields, httpStatus: httpStatus)
    }

    /// An error event inside a stream. Returns nil for a line that carries no error.
    public static func classify(streamLine line: String) -> UpstreamFailureReport? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"], !(error is NSNull) else {
            return nil
        }
        var fields = Fields()
        collect(object, into: &fields, depth: 0)
        return report(from: fields, httpStatus: nil)
    }

    /// A transport failure, by `NSURLErrorDomain` code. Takes the integer so
    /// callers on every platform can pass `(error as NSError).code`.
    public static func classify(transportErrorCode code: Int) -> UpstreamFailureReport {
        let kind: UpstreamFailure.Kind
        switch code {
        case -1004, -1003: kind = .serverUnreachable   // cannotConnectToHost, cannotFindHost
        case -1005: kind = .connectionLost             // networkConnectionLost
        case -1001: kind = .timedOut                   // timedOut
        default: kind = .providerError
        }
        return UpstreamFailureReport(failure: UpstreamFailure(kind: kind))
    }

    /// A thrown error from the upstream request.
    public static func classify(error: Error) -> UpstreamFailureReport {
        // The Core client throws a provider's error response; classify its
        // status and body, not the wrapper's description.
        if case let UpstreamClient.UpstreamError.httpError(statusCode, body) = error {
            return classify(httpStatus: statusCode, body: String(decoding: body, as: UTF8.self))
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return UpstreamFailureReport(
                failure: UpstreamFailure(kind: .providerError),
                providerMessage: sanitized(nsError.localizedDescription)
            )
        }
        let report = classify(transportErrorCode: nsError.code)
        guard report.failure.kind == .providerError else { return report }
        return UpstreamFailureReport(failure: report.failure, providerMessage: sanitized(nsError.localizedDescription))
    }

    // MARK: - Parsing

    private struct Fields {
        var type: String?
        var code: String?
        var message: String?
        var promptTokens: Int?
        var contextTokens: Int?
    }

    private static func report(from fields: Fields, httpStatus: Int?) -> UpstreamFailureReport {
        let contextTypes: Set<String> = ["exceed_context_size_error", "context_length_exceeded"]
        let isContext = fields.contextTokens != nil
            || fields.type.map(contextTypes.contains) == true
            || fields.code.map(contextTypes.contains) == true
        if isContext {
            return UpstreamFailureReport(
                failure: UpstreamFailure(
                    kind: .contextExceeded,
                    httpStatus: httpStatus,
                    promptTokens: fields.promptTokens,
                    contextTokens: fields.contextTokens
                ),
                providerMessage: fields.message.map(sanitized)
            )
        }
        return UpstreamFailureReport(
            failure: UpstreamFailure(kind: .providerError, httpStatus: httpStatus),
            providerMessage: fields.message.map(sanitized)
        )
    }

    /// Gathers error fields, preferring the innermost values: the outer layers
    /// are wrappers around the engine's own error.
    private static func collect(_ value: Any, into fields: inout Fields, depth: Int) {
        guard depth < 8 else { return }
        if let text = value as? String {
            if let embedded = jsonObject(in: text) {
                collect(embedded, into: &fields, depth: depth + 1)
            } else if !text.isEmpty {
                fields.message = text
            }
            return
        }
        guard let object = value as? [String: Any] else { return }
        if let type = object["type"] as? String, !type.isEmpty { fields.type = type }
        if let code = object["code"] as? String, !code.isEmpty { fields.code = code }
        if let tokens = integer(object["n_prompt_tokens"]) { fields.promptTokens = tokens }
        if let tokens = integer(object["n_ctx"]) { fields.contextTokens = tokens }
        if let message = object["message"] { collect(message, into: &fields, depth: depth + 1) }
        if let error = object["error"], !(error is NSNull) { collect(error, into: &fields, depth: depth + 1) }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    /// The JSON object in `text`: the whole string, or the outermost `{...}`
    /// span when the object is embedded in prose.
    private static func jsonObject(in text: String) -> [String: Any]? {
        func parse(_ candidate: Substring) -> [String: Any]? {
            guard let data = String(candidate).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return parse(text[start...end])
    }

    private static func sanitized(_ text: String) -> String {
        SensitiveTextSanitizer.sanitize(text, maxCharacters: providerMessageLimit)
    }
}
