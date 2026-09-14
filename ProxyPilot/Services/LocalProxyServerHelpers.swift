import Darwin
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

    // MARK: - Byte Formatting

    /// Compact, deterministic byte-count display for log lines and the
    /// context-compaction stats UI ("118.4 KB", "312 B").
    // MARK: - Body Length

    /// How a request's declared `Content-Length` should be handled.
    enum ContentLengthOutcome: Equatable {
        case accept(Int)
        case invalid
        case tooLarge
    }

    /// Validate the declared body length before any of it is sliced off.
    ///
    /// A negative value must be rejected here: the caller passes this length to
    /// `prefix(_:)`, whose `maxLength >= 0` precondition traps the process, and
    /// that slice runs *before* the authorization gate — so `Content-Length: -1`
    /// from any local client would otherwise be an unauthenticated crash.
    ///
    /// An absent or unparseable header keeps its historical meaning of "no
    /// body" rather than becoming an error, so only an explicitly negative
    /// length is rejected.
    static func contentLengthOutcome(
        header: String?,
        alreadyReceived: Int,
        maxBodyBytes: Int
    ) -> ContentLengthOutcome {
        let declared = header.flatMap(Int.init) ?? 0
        if declared < 0 { return .invalid }
        if declared > maxBodyBytes || alreadyReceived > maxBodyBytes { return .tooLarge }
        return .accept(declared)
    }

    static func formatByteCount(_ bytes: Int) -> String {
        guard bytes >= 1024 else { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        guard kb >= 1024 else { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
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
                || provider.temperatureRange != nil
                || provider == .openAI,
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
        return "Upstream error: \(SensitiveTextSanitizer.sanitize(body, maxCharacters: 600))"
    }

    // MARK: - Log Redaction

    /// Redact a string for log output: scrub bearer tokens and API key values,
    /// then truncate to the given limit.
    static func redact(_ text: String, max limit: Int = 180) -> String {
        SensitiveTextSanitizer.sanitize(text, maxCharacters: limit)
    }

    static func sessionStartLogLine(
        provider: UpstreamProvider,
        modelIDs: Set<String>,
        preferredModel: String,
        upstreamBaseURL: String
    ) -> String {
        let models = redact(modelIDs.sorted().joined(separator: ","), max: 512)
        let preferred = redact(preferredModel, max: 180)
        return "=== session start === provider=\(provider.rawValue) models=\(models.isEmpty ? "(none)" : models) preferred=\(preferred.isEmpty ? "(none)" : preferred) upstream=\(redact(upstreamBaseURL))"
    }

    static func modelsResponseLogLine(
        path: String,
        provider: UpstreamProvider,
        modelIDs: Set<String>
    ) -> String {
        let models = modelIDs.sorted()
        let ids = models.isEmpty ? "(none)" : models.joined(separator: ",")
        return "resp GET \(path) 200 provider=\(provider.rawValue) models=\(models.count) ids=\(redact(ids))"
    }

    /// Replace "Bearer <token>" with "Bearer ***".
    static func scrubBearer(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"Bearer\s+[^\s,;]+"#) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "Bearer ***")
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
        let models = allowedModels.union(allowedModels.isEmpty ? [] : [ActiveModelAlias.id]).sorted()
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
    static func isModelAllowed(
        body: Data,
        allowedModels: Set<String>,
        activeModel: String = ""
    ) -> Bool {
        if allowedModels.isEmpty { return true }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = json["model"] as? String else {
            return true // can't parse → let the upstream decide
        }
        return ActiveModelAlias.accepts(
            model,
            allowedModels: allowedModels,
            activeModel: activeModel
        )
    }

    // MARK: - Error Response JSON Builders

    /// Build an OpenAI-style error JSON string.
    static func openAIErrorJSON(message: String, type: String = "invalid_request_error") -> String {
        ProxyErrorResponse.openAI(message: message, type: type)
    }

    /// Errors specific to `appendPrivateLogData`'s hardened open/validate path.
    enum PrivateLogWriteError: Error {
        /// `open(2)` failed — including the symlink case, where `O_NOFOLLOW`
        /// makes a symlink at the final path component fail with `ELOOP`.
        case openFailed
        /// `fstat(2)` on the opened descriptor failed.
        case statFailed
        /// The opened descriptor is not a regular file we own (e.g. a
        /// pre-seeded FIFO, device node, or a file owned by another user).
        case unsafeTarget
    }

    /// Serializes every append across all callers (and detached tasks) so
    /// concurrent log lines cannot interleave or clobber one another, and so
    /// the open→validate→fchmod→write sequence below is atomic with respect
    /// to itself. `/tmp` is world-writable, so this also protects the
    /// open/validate step from being raced by another process.
    private static let privateLogAppendLock = NSLock()

    /// Append `data` to the private log at `url`, hardened against a
    /// pre-seeded `/tmp` target (symlink, FIFO, or foreign-owned file) and
    /// against concurrent writers losing or interleaving lines.
    ///
    /// The whole open→validate→write sequence runs under a single process-wide
    /// lock and uses `O_APPEND` so each call writes its full line as one
    /// atomic unit relative to every other caller.
    static func appendPrivateLogData(_ data: Data, to url: URL) throws {
        privateLogAppendLock.lock()
        defer { privateLogAppendLock.unlock() }

        // O_NOFOLLOW refuses to open a symlink at the final path component
        // (fails with ELOOP) instead of silently following it to whatever
        // an attacker pre-seeded /tmp with. O_NONBLOCK is required for the
        // FIFO case: without it, opening a reader-less FIFO for writing
        // blocks in open(2) indefinitely — which, under the lock above,
        // would deadlock every other appender for the process's lifetime.
        // With O_NONBLOCK, a reader-less FIFO fails fast with ENXIO; a FIFO
        // that does have a reader open still gets rejected below by the
        // S_ISREG check. O_NONBLOCK is a no-op for regular files, so the
        // normal path is unaffected; it's cleared after validation anyway
        // so nothing downstream has to reason about it.
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw PrivateLogWriteError.openFailed
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            close(descriptor)
            throw PrivateLogWriteError.statFailed
        }

        // Refuse anything that isn't a plain regular file we own — a FIFO,
        // device node, or a file some other user pre-seeded must be rejected
        // rather than written to.
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid() else {
            close(descriptor)
            throw PrivateLogWriteError.unsafeTarget
        }

        if (info.st_mode & 0o777) != 0o600 {
            // Always chmod the descriptor, never the path — a path-based
            // chmod between our fstat check and here would be racy.
            _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
        }

        // Clear O_NONBLOCK now that we've validated this is a regular file;
        // it was only needed to make the FIFO-open fail fast above.
        let currentFlags = fcntl(descriptor, F_GETFL)
        if currentFlags >= 0 {
            _ = fcntl(descriptor, F_SETFL, currentFlags & ~O_NONBLOCK)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }
}
