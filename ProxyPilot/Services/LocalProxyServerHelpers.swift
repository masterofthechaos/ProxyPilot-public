import Foundation
import ProxyPilotCore

/// Pure, testable helpers extracted from `LocalProxyServer`.
///
/// Every function here is deterministic and free of side effects (no Network
/// framework, no file I/O, no MainActor state). The originals in
/// `LocalProxyServer` delegate to these so behaviour stays in sync.
enum LocalProxyServerHelpers {

    // MARK: - HTTP Request-Line Parsing

    /// Parse an HTTP request line ("GET /v1/models HTTP/1.1") into method and
    /// path components. Returns `nil` when the line is malformed.
    /// Query strings are stripped from the path.
    static func parseRequestLine(_ line: String) -> (method: String, path: String)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? rawPath
        return (method, path)
    }

    // MARK: - Header Parsing

    /// Parse raw HTTP header lines (after the request line) into a
    /// lowercased-key dictionary. Duplicate headers are last-wins.
    static func parseHeaders(_ lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines {
            if line.isEmpty { continue }
            guard let idx = line.firstIndex(of: ":") else { continue }
            let name = line[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            result[name] = value
        }
        return result
    }

    // MARK: - Route Classification

    /// Identifies the logical route for an incoming request.
    enum Route: Equatable {
        case getModels
        case chatCompletions
        case anthropicMessages
        case notFound
    }

    static func classify(method: String, path: String) -> Route {
        if method == "GET" && (path == "/v1/models" || path == "/models") {
            return .getModels
        }
        if method == "POST" && (path == "/v1/chat/completions" || path == "/chat/completions") {
            return .chatCompletions
        }
        if method == "POST" && path == "/v1/messages" {
            return .anthropicMessages
        }
        return .notFound
    }

    // MARK: - Auth

    /// Checks whether an incoming request is authorized given parsed headers
    /// and the expected master key.
    static func isAuthorized(headers: [String: String], masterKey: String) -> Bool {
        let candidates = [
            headers["authorization"],
            headers["x-api-key"],
            headers["api-key"]
        ]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        for value in candidates {
            if value.hasPrefix("Bearer ") {
                let token = value.dropFirst("Bearer ".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if token == masterKey { return true }
            }
            if value == masterKey { return true }
        }
        return false
    }

    // MARK: - Streaming Detection

    /// Returns `true` when the JSON body contains `"stream": true`.
    static func isStreamingRequest(body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return json["stream"] as? Bool == true
    }

    // MARK: - Upstream URL Construction

    /// Build the upstream URL by appending a normalized path to the API base.
    static func buildUpstreamURL(base: URL, path: String) -> URL {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return base.appendingPathComponent(normalizedPath)
    }

    // MARK: - Body Sanitization

    /// Strips provider-unsupported top-level keys from a JSON request body.
    /// Returns the original data unchanged when the provider has no blocklist
    /// or the body is not valid JSON.
    static func sanitizedChatRequestBody(_ body: Data, provider: UpstreamProvider) -> Data {
        guard !provider.unsupportedOpenAIParameters.isEmpty
                || !provider.parameterRewrites.isEmpty
                || provider.temperatureRange != nil,
              var request = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return body
        }

        AnthropicTranslator.stripUnsupportedParameters(&request, for: provider)
        AnthropicTranslator.applyParameterRewrites(&request, for: provider)
        AnthropicTranslator.clampTemperature(&request, for: provider)
        return (try? JSONSerialization.data(withJSONObject: request)) ?? body
    }

    // MARK: - Anthropic Model Resolution

    /// Resolves the upstream model to use for an Anthropic-translated request.
    /// Prefers the configured preferred model if it appears in the allowed set;
    /// otherwise falls back to the first sorted allowed model or the preferred
    /// model itself.
    static func resolveAnthropicUpstreamModel(
        preferredModel: String,
        allowedModels: Set<String>
    ) -> String {
        if allowedModels.contains(preferredModel) {
            return preferredModel
        }
        return allowedModels.sorted().first ?? preferredModel
    }

    // MARK: - HTTP Reason Phrases

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "Unknown"
        }
    }

    // MARK: - Upstream Error Message Formatting

    static func upstreamErrorMessage(
        statusCode: Int,
        body: String,
        provider: UpstreamProvider
    ) -> String {
        if provider == .google,
           statusCode == 400,
           body.localizedCaseInsensitiveContains("thought_signature") {
            return "Google direct rejected the tool-call continuation due to thought_signature validation. If this persists, use OpenRouter as the current workaround."
        }
        return "Upstream error: \(body)"
    }

    // MARK: - Log Redaction

    /// Redact a string for log output: scrub bearer tokens and API key values,
    /// then truncate to the given limit.
    static func redact(_ text: String, max limit: Int = 180) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let tokenScrubbed = scrubKeyValueSecrets(in: scrubBearer(in: cleaned))
        if tokenScrubbed.count <= limit { return tokenScrubbed }
        return String(tokenScrubbed.prefix(limit)) + "..."
    }

    /// Replace "Bearer <token>" with "Bearer ***".
    static func scrubBearer(in text: String) -> String {
        let marker = "Bearer "
        guard let range = text.range(of: marker) else { return text }
        let suffix = text[range.upperBound...]
        let tokenEnd = suffix.firstIndex(where: { $0.isWhitespace || $0 == "," || $0 == ";" }) ?? text.endIndex
        let token = String(text[range.upperBound..<tokenEnd])
        if token.isEmpty { return text }
        return text.replacingOccurrences(of: marker + token, with: marker + "***")
    }

    /// Scrub key-value patterns like `x-api-key: sk-xxx` and `"api_key": "sk-xxx"`.
    static func scrubKeyValueSecrets(in text: String) -> String {
        let rules: [(String, String)] = [
            (#"(?i)(x-api-key\s*[:=]\s*)([^\s\"']+)"#, "$1***"),
            (#"(?i)(api[-_ ]?key\s*[:=]\s*)([^\s\"']+)"#, "$1***"),
            (#"(?i)(\"api_key\"\s*:\s*\")([^\"]+)(\")"#, "$1***$3")
        ]

        var output = text
        for (pattern, replacement) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: replacement)
        }
        return output
    }

    // MARK: - Models Payload Builder

    /// Build the JSON payload for GET /v1/models without depending on NWConnection.
    static func buildModelsPayload(allowedModels: Set<String>, timestamp: Int) -> [String: Any] {
        let models = allowedModels.sorted()
        let data: [[String: Any]] = models.map { id in
            [
                "id": id,
                "object": "model",
                "created": timestamp,
                "owned_by": "proxypilot",
                "permission": [] as [Any],
                "root": id,
                "parent": NSNull()
            ]
        }
        return [
            "object": "list",
            "data": data
        ]
    }

    // MARK: - Config Localhost Detection

    /// Returns `true` when the given URL points to localhost / 127.0.0.1 / ::1.
    static func isLocalhostUpstream(_ url: URL) -> Bool {
        let host = url.host ?? ""
        let lowered = host.lowercased()
        return lowered == "localhost" || lowered == "127.0.0.1" || lowered == "::1"
    }

    // MARK: - Model Allow-List Check

    /// Returns `true` when the request body's model field is allowed (or the
    /// allowlist is empty, which means "allow all").
    static func isModelAllowed(body: Data, allowedModels: Set<String>) -> Bool {
        if allowedModels.isEmpty { return true }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = json["model"] as? String else {
            return true // can't parse → let the upstream decide
        }
        return allowedModels.contains(model)
    }

    // MARK: - Error Response JSON Builders

    /// Build an OpenAI-style error JSON string.
    static func openAIErrorJSON(message: String, type: String = "invalid_request_error") -> String {
        #"{"error":{"message":"\#(message)","type":"\#(type)"}}"#
    }
}
