import Foundation
import Network
import ProxyPilotCore

enum AnthropicTranslatorMode: String, Sendable {
    case hardened
    case legacyFallback
}

@MainActor
final class LocalProxyState: ObservableObject {
    nonisolated init() {}
    @Published var isRunning: Bool = false
    @Published var lastStatus: String = ""
    @Published var sessionRequestCount: Int = 0
    @Published var lastModelSeen: String = ""
    @Published var lastUpstreamModelUsed: String = ""
}

final class LocalProxyServer: @unchecked Sendable {
    enum ServerError: LocalizedError {
        case alreadyRunning
        case notRunning
        case bindFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "Proxy server is already running."
            case .notRunning:
                return "Proxy server is not running."
            case .bindFailed(let message):
                return "Failed to start proxy server: \(message)"
            }
        }
    }

    struct Config: Sendable {
        let host: String
        let port: UInt16
        let masterKey: String
        let upstreamProvider: UpstreamProvider
        let upstreamAPIBase: URL
        let upstreamAPIKey: String?
        let allowedModels: Set<String>
        let requiresAuth: Bool
        let anthropicTranslatorMode: AnthropicTranslatorMode
        let preferredAnthropicUpstreamModel: String
        let googleThoughtSignatureStore: GoogleThoughtSignatureStore?

        var isLocalhostUpstream: Bool {
            let host = upstreamAPIBase.host ?? ""
            let lowered = host.lowercased()
            return lowered == "localhost" || lowered == "127.0.0.1" || lowered == "::1"
        }
    }

    let state = LocalProxyState()
    let reportCard = SessionReportCard()

    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 10 * 1024 * 1024
    static let maxConcurrentConnections = 50

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ProxyPilot.LocalProxyServer")
    private let logURL = URL(fileURLWithPath: "/tmp/proxypilot_builtin_proxy.log")
    private let toolchainLogURL = URL(fileURLWithPath: "/tmp/proxypilot_toolchain.log")
    private let logMaxValueLength = 180
    private let logMaxArgsLength = 120
    private let connectionCountLock = NSLock()
    private var activeConnectionCount: Int = 0
    private var releasedConnectionIDs: Set<String> = []

    private typealias AnthropicStreamingState = AnthropicTranslator.StreamingState

    func start(config: Config) throws {
        if listener != nil { throw ServerError.alreadyRunning }
        Task { @MainActor in
            state.sessionRequestCount = 0
            state.lastModelSeen = ""
            state.lastUpstreamModelUsed = ""
            reportCard.reset()
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let port = NWEndpoint.Port(rawValue: config.port) ?? .init(integerLiteral: 4000)

        do {
            let newListener = try NWListener(using: params, on: port)
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }

                connection.start(queue: self.queue)

                guard self.reserveConnectionSlot() else {
                    self.appendLog("reject connection: too_many_connections limit=\(Self.maxConcurrentConnections)")
                    self.respond(
                        connection: connection,
                        status: 429,
                        body: #"{"error":{"message":"Too many concurrent connections","type":"rate_limit_error"}}"#,
                        contentType: "application/json"
                    )
                    return
                }

                let connectionID = UUID().uuidString
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .cancelled, .failed:
                        self?.releaseConnectionSlotIfNeeded(connectionID: connectionID)
                    default:
                        break
                    }
                }

                self.handle(connection: connection, config: config)
            }
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.appendLog("ready on :\(config.port)")
                    Task { @MainActor [weak self] in
                        self?.state.isRunning = true
                        self?.state.lastStatus = "Ready on 127.0.0.1:\(config.port)"
                    }
                case .failed(let err):
                    self?.appendLog("failed: \(err)")
                    Task { @MainActor [weak self] in
                        self?.state.isRunning = false
                        self?.state.lastStatus = "Failed: \(err)"
                    }
                case .cancelled:
                    self?.appendLog("cancelled")
                    Task { @MainActor [weak self] in
                        self?.state.isRunning = false
                        self?.state.lastStatus = "Stopped"
                    }
                default:
                    break
                }
            }
            self.listener = newListener
            appendLog("starting on :\(config.port)")
            newListener.start(queue: queue)
        } catch {
            throw ServerError.bindFailed(error.localizedDescription)
        }
    }

    func stop() throws {
        guard let listener else { throw ServerError.notRunning }
        listener.cancel()
        self.listener = nil
        Task { @MainActor in
            state.isRunning = false
            state.lastStatus = "Stopped"
        }
        appendLog("stopped")
    }

    // MARK: - Connection Handling

    private func handle(connection: NWConnection, config: Config) {
        receiveUntilHeaderEnd(connection: connection, accumulated: Data(), config: config)
    }

    private func receiveUntilHeaderEnd(connection: NWConnection, accumulated: Data, config: Config) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, isComplete, error in
            if let _ = error { connection.cancel(); return }
            var buffer = accumulated
            if let data, !data.isEmpty { buffer.append(data) }

            if buffer.count > Self.maxHeaderBytes {
                self?.respond(
                    connection: connection,
                    status: 413,
                    body: #"{"error":{"message":"Header too large","type":"invalid_request_error"}}"#,
                    contentType: "application/json"
                )
                return
            }

            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: 0..<range.lowerBound)
                let bodyRemainder = buffer.subdata(in: range.upperBound..<buffer.count)
                self?.handleParsedHeaders(connection: connection, headerData: headerData, bodyRemainder: bodyRemainder, config: config)
                return
            }

            if isComplete { connection.cancel(); return }
            self?.receiveUntilHeaderEnd(connection: connection, accumulated: buffer, config: config)
        }
    }

    private func handleParsedHeaders(connection: NWConnection, headerData: Data, bodyRemainder: Data, config: Config) {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            respond(connection: connection, status: 400, body: "Bad Request", contentType: "text/plain")
            return
        }

        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            respond(connection: connection, status: 400, body: "Bad Request", contentType: "text/plain")
            return
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            respond(connection: connection, status: 400, body: "Bad Request", contentType: "text/plain")
            return
        }

        let method = String(parts[0])
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard let idx = line.firstIndex(of: ":") else { continue }
            let name = line[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            parsedHeaders[name] = value
        }
        let headers = parsedHeaders

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        if contentLength > Self.maxBodyBytes || bodyRemainder.count > Self.maxBodyBytes {
            respond(
                connection: connection,
                status: 413,
                body: #"{"error":{"message":"Request body too large","type":"invalid_request_error"}}"#,
                contentType: "application/json"
            )
            return
        }

        if contentLength <= bodyRemainder.count {
            let body = bodyRemainder.prefix(contentLength)
            appendLogRequest(method: method, path: path, headers: headers)
            route(method: method, path: path, headers: headers, body: Data(body), connection: connection, config: config)
        } else {
            receiveBody(connection: connection, alreadyHave: bodyRemainder, remaining: contentLength - bodyRemainder.count) { [weak self] fullBody in
                guard let self else { return }
                guard let fullBody else {
                    self.respond(
                        connection: connection,
                        status: 413,
                        body: #"{"error":{"message":"Request body too large","type":"invalid_request_error"}}"#,
                        contentType: "application/json"
                    )
                    return
                }
                self.appendLogRequest(method: method, path: path, headers: headers)
                self.route(method: method, path: path, headers: headers, body: fullBody, connection: connection, config: config)
            }
        }
    }

    private func receiveBody(connection: NWConnection, alreadyHave: Data, remaining: Int, completion: @escaping @Sendable (Data?) -> Void) {
        if alreadyHave.count > Self.maxBodyBytes {
            completion(nil)
            return
        }
        if remaining <= 0 {
            completion(alreadyHave)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 32_768)) { data, _, isComplete, error in
            if let _ = error {
                completion(nil)
                connection.cancel()
                return
            }
            var buffer = alreadyHave
            if let data, !data.isEmpty { buffer.append(data) }
            if buffer.count > Self.maxBodyBytes {
                completion(nil)
                return
            }
            let newRemaining = remaining - (data?.count ?? 0)
            if newRemaining <= 0 {
                completion(buffer)
            } else if isComplete {
                completion(buffer)
            } else {
                self.receiveBody(connection: connection, alreadyHave: buffer, remaining: newRemaining, completion: completion)
            }
        }
    }

    // MARK: - Routing

    private func route(method: String, path: String, headers: [String: String], body: Data, connection: NWConnection, config: Config) {
        // GET /v1/models — always allowed (Xcode validation)
        if method == "GET" && (path == "/v1/models" || path == "/models") {
            handleGetModels(path: path, connection: connection, config: config)
            return
        }

        // Auth check for non-models routes
        if config.requiresAuth, !isAuthorized(headers: headers, config: config) {
            respond(
                connection: connection,
                status: 401,
                body: #"{"error":{"message":"Unauthorized","type":"invalid_request_error"}}"#,
                contentType: "application/json"
            )
            return
        }

        // Track AI request metrics
        if method == "POST" && (path == "/v1/chat/completions" || path == "/chat/completions" || path == "/v1/messages") {
            let modelName = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["model"] as? String
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.sessionRequestCount += 1
                if let modelName, !modelName.isEmpty { self.state.lastModelSeen = modelName }
            }
        }

        // POST /v1/chat/completions — OpenAI format
        if method == "POST" && (path == "/v1/chat/completions" || path == "/chat/completions") {
            let isStreaming = isStreamingRequest(body: body)
            Task.detached { [weak self] in
                if isStreaming {
                    await self?.handleStreamingChatCompletions(body: body, connection: connection, config: config)
                } else {
                    await self?.handleChatCompletions(body: body, connection: connection, config: config)
                }
            }
            return
        }

        // POST /v1/messages — Anthropic format (agentic mode)
        if method == "POST" && path == "/v1/messages" {
            Task.detached { [weak self] in
                await self?.handleAnthropicMessages(body: body, headers: headers, connection: connection, config: config)
            }
            return
        }

        respond(connection: connection, status: 404, body: "Not Found", contentType: "text/plain")
    }

    // MARK: - GET /v1/models

    private func handleGetModels(path: String, connection: NWConnection, config: Config) {
        let now = Int(Date().timeIntervalSince1970)
        let models = config.allowedModels.sorted()
        let data: [[String: Any]] = models.map { id in
            [
                "id": id,
                "object": "model",
                "created": now,
                "owned_by": "proxypilot",
                "permission": [],
                "root": id,
                "parent": NSNull()
            ]
        }

        let payload: [String: Any] = [
            "object": "list",
            "data": data
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let jsonText = String(data: jsonData, encoding: .utf8) {
            appendLog("resp GET \(path) 200 models=\(models.count)")
            respond(connection: connection, status: 200, body: jsonText, contentType: "application/json")
        } else {
            appendLog("resp GET \(path) 500 json_encode_failed")
            respond(connection: connection, status: 500, body: "Internal Server Error", contentType: "text/plain")
        }
    }

    // MARK: - Streaming Detection

    private func isStreamingRequest(body: Data) -> Bool {
        LocalProxyServerHelpers.isStreamingRequest(body: body)
    }

    // MARK: - POST /v1/chat/completions (buffered)

    private func handleChatCompletions(body: Data, connection: NWConnection, config: Config) async {
        let requestStartTime = Date()
        let requestModel = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["model"] as? String ?? ""
        if !config.isLocalhostUpstream {
            guard let upstreamKey = config.upstreamAPIKey, !upstreamKey.isEmpty else {
                respond(
                    connection: connection,
                    status: 400,
                    body: #"{"error":{"message":"Missing upstream API key","type":"invalid_request_error"}}"#,
                    contentType: "application/json"
                )
                return
            }
        }

        if !config.allowedModels.isEmpty {
            if let requestedModel = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
               let model = requestedModel["model"] as? String,
               !config.allowedModels.contains(model) {
                respond(
                    connection: connection,
                    status: 400,
                    body: #"{"error":{"message":"Model not allowed","type":"invalid_request_error"}}"#,
                    contentType: "application/json"
                )
                return
            }
        }

        let outboundBody = sanitizedChatRequestBody(body, provider: config.upstreamProvider)
        let upstreamURL = buildUpstreamURL(config: config, path: config.upstreamProvider.chatCompletionsPath)
        var request = URLRequest(url: upstreamURL)
        request.httpMethod = "POST"
        request.httpBody = outboundBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyUpstreamAuth(config: config, request: &request)
        request.timeoutInterval = 60

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 502
            let text = String(decoding: data, as: UTF8.self)
            respond(connection: connection, status: status, body: text, contentType: "application/json")

            if status == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let usage = json["usage"] as? [String: Any] {
                let resolvedModel = (json["model"] as? String).flatMap { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                } ?? requestModel
                let record = SessionReportCard.RequestRecord(
                    timestamp: requestStartTime,
                    model: resolvedModel,
                    promptTokens: usage["prompt_tokens"] as? Int ?? 0,
                    completionTokens: usage["completion_tokens"] as? Int ?? 0,
                    durationSeconds: Date().timeIntervalSince(requestStartTime),
                    path: "/v1/chat/completions",
                    wasStreaming: false
                )
                Task { @MainActor [weak self] in self?.reportCard.record(record) }
            }
        } catch {
            respond(
                connection: connection,
                status: 502,
                body: #"{"error":{"message":"Upstream request failed","type":"server_error"}}"#,
                contentType: "application/json"
            )
        }
    }

    // MARK: - POST /v1/chat/completions (streaming)

    private func handleStreamingChatCompletions(body: Data, connection: NWConnection, config: Config) async {
        let requestStartTime = Date()
        let requestModel = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["model"] as? String ?? ""
        if !config.isLocalhostUpstream {
            guard let upstreamKey = config.upstreamAPIKey, !upstreamKey.isEmpty else {
                respond(
                    connection: connection,
                    status: 400,
                    body: #"{"error":{"message":"Missing upstream API key","type":"invalid_request_error"}}"#,
                    contentType: "application/json"
                )
                return
            }
        }

        if !config.allowedModels.isEmpty {
            if let requestedModel = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
               let model = requestedModel["model"] as? String,
               !config.allowedModels.contains(model) {
                respond(
                    connection: connection,
                    status: 400,
                    body: #"{"error":{"message":"Model not allowed","type":"invalid_request_error"}}"#,
                    contentType: "application/json"
                )
                return
            }
        }

        let outboundBody = sanitizedChatRequestBody(body, provider: config.upstreamProvider)
        let upstreamURL = buildUpstreamURL(config: config, path: config.upstreamProvider.chatCompletionsPath)
        var request = URLRequest(url: upstreamURL)
        request.httpMethod = "POST"
        request.httpBody = outboundBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyUpstreamAuth(config: config, request: &request)
        request.timeoutInterval = 120

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 502

            if httpStatus != 200 {
                var errorBody = ""
                for try await line in bytes.lines { errorBody += line }
                respond(connection: connection, status: httpStatus, body: errorBody, contentType: "application/json")
                return
            }

            // Send SSE response headers
            let headers =
                "HTTP/1.1 200 OK\r\n" +
                "Date: \(HTTPDateFormatter.shared.string(from: Date()))\r\n" +
                "Server: ProxyPilot\r\n" +
                "Content-Type: text/event-stream\r\n" +
                "Cache-Control: no-cache\r\n" +
                "Connection: keep-alive\r\n" +
                "\r\n"
            await sendData(Data(headers.utf8), on: connection)

            // Stream lines from upstream to client
            var lastSeenPromptTokens = 0
            var lastSeenCompletionTokens = 0
            var lastSeenModel = requestModel

            for try await line in bytes.lines {
                let sseData = Data((line + "\n").utf8)
                await sendData(sseData, on: connection)

                // Extract usage from SSE chunks (best-effort, provider-dependent)
                if line.hasPrefix("data: ") && line != "data: [DONE]" {
                    let payload = String(line.dropFirst(6))
                    if let chunkData = payload.data(using: .utf8),
                       let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] {
                        if let chunkModel = chunk["model"] as? String {
                            let trimmed = chunkModel.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                lastSeenModel = trimmed
                            }
                        }
                        if let usage = chunk["usage"] as? [String: Any] {
                            lastSeenPromptTokens = usage["prompt_tokens"] as? Int ?? lastSeenPromptTokens
                            lastSeenCompletionTokens = usage["completion_tokens"] as? Int ?? lastSeenCompletionTokens
                        }
                    }
                }

                if line == "data: [DONE]" {
                    // Send final newline and close
                    await sendData(Data("\n".utf8), on: connection)
                    let record = SessionReportCard.RequestRecord(
                        timestamp: requestStartTime,
                        model: lastSeenModel,
                        promptTokens: lastSeenPromptTokens,
                        completionTokens: lastSeenCompletionTokens,
                        durationSeconds: Date().timeIntervalSince(requestStartTime),
                        path: "/v1/chat/completions",
                        wasStreaming: true
                    )
                    Task { @MainActor [weak self] in self?.reportCard.record(record) }
                    connection.cancel()
                    return
                }
            }

            // If upstream closes without [DONE], record what we have
            let record = SessionReportCard.RequestRecord(
                timestamp: requestStartTime,
                model: lastSeenModel,
                promptTokens: lastSeenPromptTokens,
                completionTokens: lastSeenCompletionTokens,
                durationSeconds: Date().timeIntervalSince(requestStartTime),
                path: "/v1/chat/completions",
                wasStreaming: true
            )
            Task { @MainActor [weak self] in self?.reportCard.record(record) }
            connection.cancel()
        } catch {
            respond(
                connection: connection,
                status: 502,
                body: #"{"error":{"message":"Upstream streaming failed","type":"server_error"}}"#,
                contentType: "application/json"
            )
        }
    }

    // MARK: - POST /v1/messages (Anthropic API Translation)

    private func handleAnthropicMessages(body: Data, headers: [String: String], connection: NWConnection, config: Config) async {
        let requestID = "req_\(UUID().uuidString.prefix(12).lowercased())"

        if !config.isLocalhostUpstream {
            guard let upstreamKey = config.upstreamAPIKey, !upstreamKey.isEmpty else {
                respond(
                    connection: connection,
                    status: 400,
                    body: AnthropicTranslator.errorJSON(message: "Missing upstream API key"),
                    contentType: "application/json"
                )
                return
            }
        }

        guard let anthropicRequest = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            respond(
                connection: connection,
                status: 400,
                body: AnthropicTranslator.errorJSON(message: "Invalid JSON body"),
                contentType: "application/json"
            )
            return
        }
        logIncomingAnthropicRequest(anthropicRequest, requestID: requestID, mode: config.anthropicTranslatorMode)

        let isStreaming = anthropicRequest["stream"] as? Bool == true

        // Remap model: Xcode sends Claude model names (e.g. "claude-sonnet-4-5-20250514")
        // which the upstream provider won't recognize. Use explicit preferred model if allowed.
        let requestedModel = anthropicRequest["model"] as? String ?? "unknown"
        let upstreamModel = LocalProxyServerHelpers.resolveAnthropicUpstreamModel(
            preferredModel: config.preferredAnthropicUpstreamModel,
            allowedModels: config.allowedModels
        )
        let translationContext = AnthropicTranslator.TranslationContext(
            upstreamProvider: config.upstreamProvider,
            resolvedUpstreamModel: upstreamModel,
            googleThoughtSignatureStore: config.googleThoughtSignatureStore
        )
        var openAIBody = AnthropicTranslator.requestToOpenAI(
            anthropicRequest,
            context: translationContext
        ).payload
        openAIBody["model"] = upstreamModel
        appendLog("anthropic model remap: \(requestedModel) → \(upstreamModel) (preferred=\(config.preferredAnthropicUpstreamModel))")
        Task { @MainActor [weak self] in
            self?.state.lastUpstreamModelUsed = upstreamModel
        }

        guard let openAIData = try? JSONSerialization.data(withJSONObject: openAIBody) else {
            respond(
                connection: connection,
                status: 500,
                body: AnthropicTranslator.errorJSON(message: "Failed to encode translated request"),
                contentType: "application/json"
            )
            return
        }

        let upstreamURL = buildUpstreamURL(config: config, path: config.upstreamProvider.chatCompletionsPath)
        var request = URLRequest(url: upstreamURL)
        request.httpMethod = "POST"
        request.httpBody = openAIData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyUpstreamAuth(config: config, request: &request)
        request.timeoutInterval = 120

        if isStreaming {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            switch config.anthropicTranslatorMode {
            case .hardened:
                await handleAnthropicStreamingHardened(
                    request: request,
                    model: requestedModel,
                    reportModel: upstreamModel,
                    requestID: requestID,
                    translationContext: translationContext,
                    mode: config.anthropicTranslatorMode,
                    connection: connection
                )
            case .legacyFallback:
                await handleAnthropicStreamingLegacy(
                    request: request,
                    model: requestedModel,
                    reportModel: upstreamModel,
                    requestID: requestID,
                    mode: config.anthropicTranslatorMode,
                    connection: connection
                )
            }
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            await handleAnthropicBuffered(
                request: request,
                model: requestedModel,
                reportModel: upstreamModel,
                requestID: requestID,
                translationContext: translationContext,
                mode: config.anthropicTranslatorMode,
                connection: connection
            )
        }
    }

    private func handleAnthropicBuffered(
        request: URLRequest,
        model: String,
        reportModel: String,
        requestID: String,
        translationContext: AnthropicTranslator.TranslationContext,
        mode: AnthropicTranslatorMode,
        connection: NWConnection
    ) async {
        let requestStartTime = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 502

            if httpStatus != 200 {
                let errorText = String(decoding: data, as: UTF8.self)
                respond(
                    connection: connection,
                    status: httpStatus,
                    body: AnthropicTranslator.errorJSON(
                        message: upstreamErrorMessage(
                            statusCode: httpStatus,
                            body: errorText,
                            provider: translationContext.upstreamProvider
                        )
                    ),
                    contentType: "application/json"
                )
                return
            }

            guard let openAIResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                respond(
                    connection: connection,
                    status: 502,
                    body: AnthropicTranslator.errorJSON(message: "Failed to parse upstream response"),
                    contentType: "application/json"
                )
                return
            }
            logUpstreamResponse(openAIResponse, requestID: requestID, mode: mode, streaming: false)

            if let usage = openAIResponse["usage"] as? [String: Any] {
                let record = SessionReportCard.RequestRecord(
                    timestamp: requestStartTime,
                    model: reportModel,
                    promptTokens: usage["prompt_tokens"] as? Int ?? 0,
                    completionTokens: usage["completion_tokens"] as? Int ?? 0,
                    durationSeconds: Date().timeIntervalSince(requestStartTime),
                    path: "/v1/messages",
                    wasStreaming: false
                )
                Task { @MainActor [weak self] in self?.reportCard.record(record) }
            }

            let anthropicResponse = AnthropicTranslator.responseFromOpenAI(
                openAIResponse,
                model: model,
                context: translationContext
            ).payload
            logTranslatedAnthropicResponse(anthropicResponse, requestID: requestID, mode: mode)
            if let jsonData = try? JSONSerialization.data(withJSONObject: anthropicResponse),
               let jsonText = String(data: jsonData, encoding: .utf8) {
                respond(connection: connection, status: 200, body: jsonText, contentType: "application/json")
            } else {
                respond(
                    connection: connection,
                    status: 500,
                    body: AnthropicTranslator.errorJSON(message: "Failed to encode Anthropic response"),
                    contentType: "application/json"
                )
            }
        } catch {
            respond(
                connection: connection,
                status: 502,
                body: AnthropicTranslator.errorJSON(message: "Upstream request failed"),
                contentType: "application/json"
            )
        }
    }

    private func handleAnthropicStreamingLegacy(
        request: URLRequest,
        model: String,
        reportModel: String,
        requestID: String,
        mode: AnthropicTranslatorMode,
        connection: NWConnection
    ) async {
        let requestStartTime = Date()
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 502

            if httpStatus != 200 {
                var errorBody = ""
                for try await line in bytes.lines { errorBody += line }
                respond(
                    connection: connection,
                    status: httpStatus,
                    body: AnthropicTranslator.errorJSON(message: "Upstream error: \(errorBody)"),
                    contentType: "application/json"
                )
                return
            }

            await sendAnthropicSSEHeaders(on: connection)

            var isFirstChunk = true
            let msgID = "msg_\(UUID().uuidString.prefix(24).lowercased())"
            var chunkIndex = 0
            var lastSeenPromptTokens = 0
            var lastSeenCompletionTokens = 0

            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))

                if payload == "[DONE]" {
                    let events = AnthropicTranslator.streamingDoneEvents(messageId: msgID, model: model)
                    for event in events {
                        await sendData(Data(event.utf8), on: connection)
                    }
                    logAnthropicStreamingEvent("AN_SSE request_id=\(requestID) mode=\(mode.rawValue) finish=done stop_reason=end_turn")
                    let record = SessionReportCard.RequestRecord(
                        timestamp: requestStartTime, model: reportModel,
                        promptTokens: lastSeenPromptTokens, completionTokens: lastSeenCompletionTokens,
                        durationSeconds: Date().timeIntervalSince(requestStartTime),
                        path: "/v1/messages", wasStreaming: true
                    )
                    Task { @MainActor [weak self] in self?.reportCard.record(record) }
                    connection.cancel()
                    return
                }

                guard let chunkData = payload.data(using: .utf8),
                      let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else {
                    continue
                }
                logUpstreamStreamingChunk(chunk, requestID: requestID, mode: mode, index: chunkIndex)
                chunkIndex += 1

                if let usage = chunk["usage"] as? [String: Any] {
                    lastSeenPromptTokens = usage["prompt_tokens"] as? Int ?? lastSeenPromptTokens
                    lastSeenCompletionTokens = usage["completion_tokens"] as? Int ?? lastSeenCompletionTokens
                }

                if isFirstChunk {
                    let events = AnthropicTranslator.streamingStartEvents(messageId: msgID, model: model)
                    for event in events {
                        await sendData(Data(event.utf8), on: connection)
                    }
                    let textStart = AnthropicTranslator.streamingTextStartEvent(index: 0)
                    await sendData(Data(textStart.utf8), on: connection)
                    isFirstChunk = false
                }

                if let choices = chunk["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let delta = firstChoice["delta"] as? [String: Any],
                   let content = delta["content"] as? String,
                   !content.isEmpty {
                    let event = AnthropicTranslator.streamingDeltaEvent(index: 0, text: content)
                    await sendData(Data(event.utf8), on: connection)
                }
            }

            if !isFirstChunk {
                let events = AnthropicTranslator.streamingDoneEvents(messageId: msgID, model: model)
                for event in events {
                    await sendData(Data(event.utf8), on: connection)
                }
                logAnthropicStreamingEvent("AN_SSE request_id=\(requestID) mode=\(mode.rawValue) finish=eof stop_reason=end_turn")
            }
            let record = SessionReportCard.RequestRecord(
                timestamp: requestStartTime, model: reportModel,
                promptTokens: lastSeenPromptTokens, completionTokens: lastSeenCompletionTokens,
                durationSeconds: Date().timeIntervalSince(requestStartTime),
                path: "/v1/messages", wasStreaming: true
            )
            Task { @MainActor [weak self] in self?.reportCard.record(record) }
            connection.cancel()
        } catch {
            respond(
                connection: connection,
                status: 502,
                body: AnthropicTranslator.errorJSON(message: "Upstream streaming failed"),
                contentType: "application/json"
            )
        }
    }

    private func handleAnthropicStreamingHardened(
        request: URLRequest,
        model: String,
        reportModel: String,
        requestID: String,
        translationContext: AnthropicTranslator.TranslationContext,
        mode: AnthropicTranslatorMode,
        connection: NWConnection
    ) async {
        let requestStartTime = Date()
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 502

            if httpStatus != 200 {
                var errorBody = ""
                for try await line in bytes.lines { errorBody += line }
                respond(
                    connection: connection,
                    status: httpStatus,
                    body: AnthropicTranslator.errorJSON(
                        message: upstreamErrorMessage(
                            statusCode: httpStatus,
                            body: errorBody,
                            provider: translationContext.upstreamProvider
                        )
                    ),
                    contentType: "application/json"
                )
                return
            }

            await sendAnthropicSSEHeaders(on: connection)

            var state = AnthropicStreamingState(
                requestID: requestID,
                messageID: "msg_\(UUID().uuidString.prefix(24).lowercased())"
            )

            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))

                if payload == "[DONE]" {
                    break
                }

                guard let chunkData = payload.data(using: .utf8),
                      let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else {
                    continue
                }

                logUpstreamStreamingChunk(chunk, requestID: requestID, mode: mode, index: state.upstreamChunkIndex)

                let events = AnthropicTranslator.processStreamingChunk(
                    chunk,
                    state: &state,
                    model: model,
                    context: translationContext
                )
                for event in events {
                    await sendData(Data(event.utf8), on: connection)
                }
            }

            let finishEvents = AnthropicTranslator.streamingFinishEvents(state: state)
            for event in finishEvents {
                await sendData(Data(event.utf8), on: connection)
            }
            if state.sentMessageStart {
                logAnthropicStreamingEvent("AN_SSE request_id=\(requestID) mode=\(mode.rawValue) finish=done stop_reason=\(state.finalStopReason) chunks=\(state.upstreamChunkIndex) emitted_events=\(state.streamedEventCount + finishEvents.count)")
            }
            let record = SessionReportCard.RequestRecord(
                timestamp: requestStartTime, model: reportModel,
                promptTokens: state.lastSeenPromptTokens, completionTokens: state.lastSeenCompletionTokens,
                durationSeconds: Date().timeIntervalSince(requestStartTime),
                path: "/v1/messages", wasStreaming: true
            )
            Task { @MainActor [weak self] in self?.reportCard.record(record) }
            connection.cancel()
        } catch {
            respond(
                connection: connection,
                status: 502,
                body: AnthropicTranslator.errorJSON(message: "Upstream streaming failed"),
                contentType: "application/json"
            )
        }
    }

    // MARK: - Helpers

    private func sendData(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    private func sendAnthropicSSEHeaders(on connection: NWConnection) async {
        let headers =
            "HTTP/1.1 200 OK\r\n" +
            "Date: \(HTTPDateFormatter.shared.string(from: Date()))\r\n" +
            "Server: ProxyPilot\r\n" +
            "Content-Type: text/event-stream\r\n" +
            "Cache-Control: no-cache\r\n" +
            "Connection: keep-alive\r\n" +
            "\r\n"
        await sendData(Data(headers.utf8), on: connection)
    }

    private func isAuthorized(headers: [String: String], config: Config) -> Bool {
        LocalProxyServerHelpers.isAuthorized(headers: headers, masterKey: config.masterKey)
    }

    private func respond(connection: NWConnection, status: Int, body: String, contentType: String) {
        let bodyData = Data(body.utf8)
        let date = HTTPDateFormatter.shared.string(from: Date())
        let response =
            "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n" +
            "Date: \(date)\r\n" +
            "Server: ProxyPilot\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        var out = Data(response.utf8)
        out.append(bodyData)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func reasonPhrase(_ status: Int) -> String {
        LocalProxyServerHelpers.reasonPhrase(status)
    }

    private func appendLog(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fh = try? FileHandle(forWritingTo: logURL) {
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
                try? fh.close()
            }
        } else {
            try? data.write(to: logURL)
        }
    }

    private func appendLogRequest(method: String, path: String, headers: [String: String]) {
        let auth = headers["authorization"] ?? ""
        let xApiKey = headers["x-api-key"] != nil
        let authPreview = auth.isEmpty ? "no" : redact(auth, max: 36)
        let line = "req \(method) \(path) auth=\(authPreview) x-api-key=\(xApiKey)"
        appendLog(line)
    }

    // MARK: - Tool Chain Diagnostics

    private func logIncomingAnthropicRequest(_ body: [String: Any], requestID: String, mode: AnthropicTranslatorMode) {
        var lines: [String] = []
        let model = body["model"] as? String ?? "?"
        lines.append("IN_REQ request_id=\(requestID) mode=\(mode.rawValue) ts=\(ISO8601DateFormatter().string(from: Date())) model=\(redact(model))")

        if let tools = body["tools"] as? [[String: Any]] {
            let names = tools.compactMap { tool -> String? in
                if let fn = tool["function"] as? [String: Any] { return fn["name"] as? String }
                return tool["name"] as? String
            }
            lines.append("IN_REQ request_id=\(requestID) tools_count=\(tools.count) tool_names=\(redact(names.joined(separator: ","), max: logMaxValueLength))")
        } else {
            lines.append("IN_REQ request_id=\(requestID) tools_count=0")
        }

        if let messages = body["messages"] as? [[String: Any]] {
            lines.append("IN_REQ request_id=\(requestID) message_count=\(messages.count)")
            for (index, msg) in messages.enumerated() {
                let role = msg["role"] as? String ?? "unknown"
                if let blocks = msg["content"] as? [[String: Any]] {
                    for block in blocks {
                        let type = block["type"] as? String ?? "?"
                        if type == "tool_result" {
                            let id = (block["tool_use_id"] as? String) ?? (block["tool_call_id"] as? String) ?? "?"
                            lines.append("IN_REQ request_id=\(requestID) msg=\(index) role=\(role) block=tool_result id=\(redact(id, max: 48))")
                        } else if type == "tool_use" {
                            let id = block["id"] as? String ?? "?"
                            let name = block["name"] as? String ?? "?"
                            lines.append("IN_REQ request_id=\(requestID) msg=\(index) role=\(role) block=tool_use name=\(redact(name, max: 64)) id=\(redact(id, max: 48))")
                        }
                    }
                }
            }
        }
        appendToolchainLog(lines)
    }

    private func logUpstreamResponse(_ responseBody: [String: Any], requestID: String, mode: AnthropicTranslatorMode, streaming: Bool) {
        var lines: [String] = []
        lines.append("UP_RESP request_id=\(requestID) mode=\(mode.rawValue) streaming=\(streaming) ts=\(ISO8601DateFormatter().string(from: Date()))")

        if let choices = responseBody["choices"] as? [[String: Any]],
           let first = choices.first {
            let finishReason = first["finish_reason"] as? String ?? "null"
            lines.append("UP_RESP request_id=\(requestID) finish_reason=\(finishReason)")

            if let message = first["message"] as? [String: Any] {
                if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                    lines.append("UP_RESP request_id=\(requestID) tool_calls_count=\(toolCalls.count)")
                    for (i, tc) in toolCalls.enumerated() {
                        let id = tc["id"] as? String ?? "?"
                        let fn = tc["function"] as? [String: Any]
                        let name = fn?["name"] as? String ?? "?"
                        let args = fn?["arguments"] as? String ?? ""
                        lines.append("UP_RESP request_id=\(requestID) tool_call=\(i) id=\(redact(id, max: 48)) name=\(redact(name, max: 64)) args_prefix=\(redact(args, max: logMaxArgsLength))")
                    }
                } else {
                    lines.append("UP_RESP request_id=\(requestID) tool_calls_count=0")
                }

                if let content = message["content"] as? String, !content.isEmpty {
                    lines.append("UP_RESP request_id=\(requestID) text=\(redact(content, max: logMaxValueLength))")
                }
            }
        }

        appendToolchainLog(lines)
    }

    private func logUpstreamStreamingChunk(_ chunk: [String: Any], requestID: String, mode: AnthropicTranslatorMode, index: Int) {
        guard let choices = chunk["choices"] as? [[String: Any]],
              let first = choices.first else { return }

        var lines: [String] = []
        if let delta = first["delta"] as? [String: Any],
           let toolCalls = delta["tool_calls"] as? [[String: Any]],
           !toolCalls.isEmpty {
            lines.append("UP_STREAM request_id=\(requestID) mode=\(mode.rawValue) chunk=\(index) tool_calls=\(toolCalls.count)")
            for tc in toolCalls {
                if let fn = tc["function"] as? [String: Any] {
                    let name = fn["name"] as? String ?? "?"
                    let args = fn["arguments"] as? String ?? ""
                    lines.append("UP_STREAM request_id=\(requestID) chunk=\(index) tool_name=\(redact(name, max: 64)) args_prefix=\(redact(args, max: logMaxArgsLength))")
                }
            }
        }

        if let finishReason = first["finish_reason"] as? String {
            lines.append("UP_STREAM request_id=\(requestID) chunk=\(index) finish_reason=\(finishReason)")
        }

        if !lines.isEmpty {
            appendToolchainLog(lines)
        }
    }

    private func logTranslatedAnthropicResponse(_ response: [String: Any], requestID: String, mode: AnthropicTranslatorMode) {
        var lines: [String] = []
        let stopReason = response["stop_reason"] as? String ?? "null"
        lines.append("AN_RESP request_id=\(requestID) mode=\(mode.rawValue) ts=\(ISO8601DateFormatter().string(from: Date())) stop_reason=\(stopReason)")
        lines.append("AN_RESP request_id=\(requestID) model=\(redact(response["model"] as? String ?? "?"))")

        var hasToolUseBlock = false
        if let content = response["content"] as? [[String: Any]] {
            lines.append("AN_RESP request_id=\(requestID) content_blocks=\(content.count)")
            for (i, block) in content.enumerated() {
                let type = block["type"] as? String ?? "?"
                if type == "tool_use" {
                    hasToolUseBlock = true
                    let id = block["id"] as? String ?? "?"
                    let name = block["name"] as? String ?? "?"
                    lines.append("AN_RESP request_id=\(requestID) block=\(i) type=tool_use name=\(redact(name, max: 64)) id=\(redact(id, max: 48))")
                } else if type == "text" {
                    let text = block["text"] as? String ?? ""
                    lines.append("AN_RESP request_id=\(requestID) block=\(i) type=text text=\(redact(text, max: logMaxValueLength))")
                } else {
                    lines.append("AN_RESP request_id=\(requestID) block=\(i) type=\(type)")
                }
            }
        }

        if hasToolUseBlock && stopReason != "tool_use" {
            lines.append("AN_RESP request_id=\(requestID) mismatch=tool_use_block_without_tool_use_stop")
        }
        if stopReason == "tool_use" && !hasToolUseBlock {
            lines.append("AN_RESP request_id=\(requestID) mismatch=tool_use_stop_without_tool_use_block")
        }
        appendToolchainLog(lines)
    }

    private func logAnthropicStreamingEvent(_ message: String) {
        appendToolchainLog([message])
    }

    private func redact(_ text: String, max: Int? = nil) -> String {
        LocalProxyServerHelpers.redact(text, max: max ?? logMaxValueLength)
    }

    private func sanitizedChatRequestBody(_ body: Data, provider: UpstreamProvider) -> Data {
        LocalProxyServerHelpers.sanitizedChatRequestBody(body, provider: provider)
    }

    private func buildUpstreamURL(config: Config, path: String) -> URL {
        LocalProxyServerHelpers.buildUpstreamURL(base: config.upstreamAPIBase, path: path)
    }

    private func applyUpstreamAuth(config: Config, request: inout URLRequest) {
        guard let apiKey = config.upstreamAPIKey, !apiKey.isEmpty else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private func upstreamErrorMessage(
        statusCode: Int,
        body: String,
        provider: UpstreamProvider
    ) -> String {
        LocalProxyServerHelpers.upstreamErrorMessage(statusCode: statusCode, body: body, provider: provider)
    }

    static func limitStatusCode(headerBytes: Int, bodyBytes: Int, activeConnections: Int) -> Int? {
        if activeConnections >= maxConcurrentConnections {
            return 429
        }
        if headerBytes > maxHeaderBytes || bodyBytes > maxBodyBytes {
            return 413
        }
        return nil
    }

    private func reserveConnectionSlot() -> Bool {
        connectionCountLock.lock()
        defer { connectionCountLock.unlock() }
        guard activeConnectionCount < Self.maxConcurrentConnections else {
            return false
        }
        activeConnectionCount += 1
        return true
    }

    private func releaseConnectionSlotIfNeeded(connectionID: String) {
        connectionCountLock.lock()
        defer { connectionCountLock.unlock() }

        if releasedConnectionIDs.contains(connectionID) {
            return
        }
        releasedConnectionIDs.insert(connectionID)
        activeConnectionCount = max(0, activeConnectionCount - 1)

        // Set grows monotonically; reset happens on server stop/restart.
        // Memory: ~36 bytes per UUID. 100K connections ≈ 4 MB — acceptable.
    }

    private func appendToolchainLog(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: toolchainLogURL.path) {
            if let fh = try? FileHandle(forWritingTo: toolchainLogURL) {
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
                try? fh.close()
            }
        } else {
            try? data.write(to: toolchainLogURL)
        }
    }
}

private final class HTTPDateFormatter: @unchecked Sendable {
    static let shared = HTTPDateFormatter()
    private let formatter: DateFormatter

    private init() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        self.formatter = f
    }

    func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
