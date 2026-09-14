import Foundation
import Network
import ProxyPilotCore

enum AnthropicTranslatorMode: String, Sendable {
    case hardened
    case legacyFallback
}

/// Snapshot of the most recent Active Context Compaction application,
/// published for the settings UI stats line.
struct ContextCompactionStat: Equatable, Sendable {
    let originalBytes: Int
    let compactedBytes: Int
    let date: Date
}

struct RequestAnalyticsMetadata: Equatable, Sendable {
    let providerIdentifier: String
    let pathCategory: String
}

@MainActor
final class LocalProxyState: ObservableObject {
    nonisolated init() {}
    @Published var isRunning: Bool = false
    @Published var lastStatus: String = ""
    @Published var sessionRequestCount: Int = 0
    @Published private(set) var pendingRequestCount: Int = 0
    @Published private(set) var failedRequestCount: Int = 0
    @Published private(set) var activeModels: Set<String> = []
    @Published private(set) var lastFailureAt: Date?
    @Published var lastModelSeen: String = ""
    @Published var lastUpstreamModelUsed: String = ""
    @Published var activeXcodeAgentModel: String = ""
    @Published var lastXcodeAgentRequestModel: String = ""
    @Published var lastXcodeAgentRequestStatus: Int?
    @Published var lastXcodeAgentRequestAt: Date?
    @Published var lastContextCompaction: ContextCompactionStat?

    private var activeRequestIDs: Set<UUID> = []
    private var activeRequestModels: [UUID: String] = [:]
    private var activeRequestAnalytics: [UUID: RequestAnalyticsMetadata] = [:]

    func resetSessionTracking() {
        sessionRequestCount = 0
        pendingRequestCount = 0
        failedRequestCount = 0
        activeRequestIDs.removeAll()
        activeRequestModels.removeAll()
        activeRequestAnalytics.removeAll()
        activeModels.removeAll()
        lastFailureAt = nil
        lastContextCompaction = nil
    }

    func beginRequest(
        id: UUID,
        modelName: String?,
        analyticsMetadata: RequestAnalyticsMetadata? = nil,
        clearsUpstreamModelAttribution: Bool = false
    ) {
        if clearsUpstreamModelAttribution {
            lastUpstreamModelUsed = ""
        }
        sessionRequestCount += 1
        activeRequestIDs.insert(id)
        pendingRequestCount = activeRequestIDs.count
        if let modelName, !modelName.isEmpty {
            lastModelSeen = modelName
            activeRequestModels[id] = modelName
        }
        activeRequestAnalytics[id] = analyticsMetadata
        refreshActiveModels()
    }

    func resolveRequest(id: UUID, modelName: String) {
        guard activeRequestIDs.contains(id), !modelName.isEmpty else { return }
        activeRequestModels[id] = modelName
        lastUpstreamModelUsed = modelName
        refreshActiveModels()
    }

    @discardableResult
    func completeRequest(id: UUID) -> Bool {
        guard activeRequestIDs.remove(id) != nil else { return false }
        activeRequestModels.removeValue(forKey: id)
        activeRequestAnalytics.removeValue(forKey: id)
        pendingRequestCount = activeRequestIDs.count
        refreshActiveModels()
        return true
    }

    @discardableResult
    func failRequest(id: UUID) -> Bool {
        guard activeRequestIDs.remove(id) != nil else { return false }
        activeRequestModels.removeValue(forKey: id)
        activeRequestAnalytics.removeValue(forKey: id)
        failedRequestCount += 1
        pendingRequestCount = activeRequestIDs.count
        lastFailureAt = Date()
        refreshActiveModels()
        return true
    }

    func failAllPendingRequests() {
        let failedCount = activeRequestIDs.count
        failedRequestCount += failedCount
        activeRequestIDs.removeAll()
        activeRequestModels.removeAll()
        activeRequestAnalytics.removeAll()
        pendingRequestCount = 0
        activeModels.removeAll()
        if failedCount > 0 {
            lastFailureAt = Date()
        }
    }

    func analyticsMetadata(for id: UUID) -> RequestAnalyticsMetadata? {
        activeRequestAnalytics[id]
    }

    func importCompletedRequests(count: Int, lastModel: String?) {
        sessionRequestCount = max(0, count)
        pendingRequestCount = 0
        failedRequestCount = 0
        activeRequestIDs.removeAll()
        activeRequestModels.removeAll()
        activeModels.removeAll()
        lastFailureAt = nil
        if let lastModel, !lastModel.isEmpty {
            lastModelSeen = lastModel
        }
    }

    private func refreshActiveModels() {
        activeModels = Set(activeRequestModels.values)
    }
}

// `InputOutputLoggerSessionCache` now lives in ProxyPilotCore so the GUI, CLI,
// and MCP proxy entry points share one implementation. See
// `ProxyPilotCore/Sources/ProxyPilotCore/Models/InputOutputLoggingStore.swift`.

final class LocalProxyServer: @unchecked Sendable {
    var telemetryTracker: ((_ name: String, _ payload: [String: String]) -> Void)?
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
        let sessionID: String
        let masterKey: String
        let upstreamProvider: UpstreamProvider
        let analyticsProviderIdentifier: String
        let upstreamAPIBase: URL
        let upstreamAPIKey: String?
        let allowedModels: Set<String>
        let denyRequestsWhenAllowlistEmpty: Bool
        let requiresAuth: Bool
        let anthropicTranslatorMode: AnthropicTranslatorMode
        let miniMaxRoutingMode: MiniMaxRoutingMode
        let preferredAnthropicUpstreamModel: String
        let googleThoughtSignatureStore: GoogleThoughtSignatureStore?
        /// Resolved on every request so logging preferences changed while the
        /// proxy is running (enable/disable, retention, CLI scope) take effect
        /// live instead of being frozen at proxy start.
        let inputOutputLoggerProvider: (@Sendable () -> InputOutputLoggingRecorder?)?
        var inputOutputLogger: InputOutputLoggingRecorder? { inputOutputLoggerProvider?() }
        var promptCaching: PromptCachingConfiguration = .default
        var contextCompaction: ContextCompactionConfiguration = .disabled

        init(
            host: String,
            port: UInt16,
            sessionID: String = UUID().uuidString,
            masterKey: String,
            upstreamProvider: UpstreamProvider,
            analyticsProviderIdentifier: String? = nil,
            upstreamAPIBase: URL,
            upstreamAPIKey: String?,
            allowedModels: Set<String>,
            denyRequestsWhenAllowlistEmpty: Bool = false,
            requiresAuth: Bool,
            anthropicTranslatorMode: AnthropicTranslatorMode,
            miniMaxRoutingMode: MiniMaxRoutingMode,
            preferredAnthropicUpstreamModel: String,
            googleThoughtSignatureStore: GoogleThoughtSignatureStore?,
            inputOutputLoggerProvider: (@Sendable () -> InputOutputLoggingRecorder?)? = nil,
            promptCaching: PromptCachingConfiguration = .default,
            contextCompaction: ContextCompactionConfiguration = .disabled
        ) {
            self.host = host
            self.port = port
            self.sessionID = sessionID
            self.masterKey = masterKey
            self.upstreamProvider = upstreamProvider
            self.analyticsProviderIdentifier = analyticsProviderIdentifier ?? upstreamProvider.rawValue
            self.upstreamAPIBase = upstreamAPIBase
            self.upstreamAPIKey = upstreamAPIKey
            self.allowedModels = allowedModels
            self.denyRequestsWhenAllowlistEmpty = denyRequestsWhenAllowlistEmpty
            self.requiresAuth = requiresAuth
            self.anthropicTranslatorMode = anthropicTranslatorMode
            self.miniMaxRoutingMode = miniMaxRoutingMode
            self.preferredAnthropicUpstreamModel = preferredAnthropicUpstreamModel
            self.googleThoughtSignatureStore = googleThoughtSignatureStore
            self.inputOutputLoggerProvider = inputOutputLoggerProvider
            self.promptCaching = promptCaching
            self.contextCompaction = contextCompaction
        }

        var isLocalhostUpstream: Bool {
            let host = upstreamAPIBase.host ?? ""
            let lowered = host.lowercased()
            return lowered == "localhost" || lowered == "127.0.0.1" || lowered == "::1"
        }

        var requiresUpstreamAPIKey: Bool {
            upstreamProvider.requiresAPIKey && !isLocalhostUpstream
        }

        var requiresAuthForProtectedRoutes: Bool {
            LocalProxyCredential.requiresAuthentication(
                explicitlyRequired: requiresAuth,
                upstreamAPIKey: upstreamAPIKey
            )
        }

        var upstreamAPIBaseURL: String {
            upstreamAPIBase.absoluteString
        }

        var isAnthropicPassthroughActive: Bool {
            upstreamProvider.usesAnthropicPassthroughByDefault
                || (miniMaxRoutingMode == .anthropicPassthrough && upstreamProvider.supportsAnthropicPassthrough)
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
        connectionCountLock.lock()
        activeConnectionCount = 0
        releasedConnectionIDs.removeAll()
        connectionCountLock.unlock()
        Task { @MainActor in
            state.resetSessionTracking()
            state.lastModelSeen = ""
            state.lastUpstreamModelUsed = ""
            state.activeXcodeAgentModel = config.preferredAnthropicUpstreamModel
            state.lastXcodeAgentRequestModel = ""
            state.lastXcodeAgentRequestStatus = nil
            state.lastXcodeAgentRequestAt = nil
            reportCard.reset()
        }

        let bindHost = Self.loopbackBindHost(from: config.host)
        let port = NWEndpoint.Port(rawValue: config.port) ?? .init(integerLiteral: 4000)
        let params = Self.makeListenerParameters()

        do {
            let newListener = try NWListener(using: params, on: port)
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }

                guard Self.isLoopbackClientEndpoint(connection.endpoint) else {
                    self.appendLog("reject connection: non_loopback endpoint=\(connection.endpoint)")
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
                    self?.appendLog("ready on \(config.host):\(config.port) loopback_only=true")
                    Task { @MainActor [weak self] in
                        self?.state.isRunning = true
                        self?.state.lastStatus = "Ready on \(config.host):\(config.port)"
                    }
                case .failed(let err):
                    self?.appendLog("failed: \(err)")
                    Task { @MainActor [weak self] in
                        self?.state.isRunning = false
                        self?.state.lastStatus = "Failed: \(err)"
                        self?.state.activeXcodeAgentModel = ""
                    }
                case .cancelled:
                    self?.appendLog("cancelled")
                    Task { @MainActor [weak self] in
                        self?.state.isRunning = false
                        self?.state.lastStatus = "Stopped"
                        self?.state.activeXcodeAgentModel = ""
                    }
                default:
                    break
                }
            }
            self.listener = newListener
            appendLog(LocalProxyServerHelpers.sessionStartLogLine(
                provider: config.upstreamProvider,
                modelIDs: config.allowedModels,
                preferredModel: config.preferredAnthropicUpstreamModel,
                upstreamBaseURL: config.upstreamAPIBaseURL
            ))
            appendLog("starting on \(bindHost):\(config.port) loopback_only=true")
            newListener.start(queue: queue)
        } catch {
            throw ServerError.bindFailed(error.localizedDescription)
        }
    }

    func stop() throws {
        guard let listener else { throw ServerError.notRunning }
        listener.cancel()
        self.listener = nil
        // listener.cancel() only stops accepting new connections; any
        // NWConnections already accepted keep running and may still fire
        // their own release later (harmless — releaseConnectionSlotIfNeeded's
        // max(0, ...) clamps it, and start() resets again). Reset the slot
        // accounting at both lifecycle boundaries so releasedConnectionIDs
        // cannot accumulate unboundedly across restarts on this
        // app-lifetime-retained instance.
        connectionCountLock.lock()
        activeConnectionCount = 0
        releasedConnectionIDs.removeAll()
        connectionCountLock.unlock()
        Task { @MainActor in
            state.failAllPendingRequests()
            state.isRunning = false
            state.lastStatus = "Stopped"
            state.activeXcodeAgentModel = ""
            state.lastXcodeAgentRequestModel = ""
            state.lastXcodeAgentRequestStatus = nil
            state.lastXcodeAgentRequestAt = nil
        }
        appendLog("stopped")
    }

    // MARK: - Connection Handling

    private func handle(connection: NWConnection, config: Config) {
        receiveUntilHeaderEnd(connection: connection, accumulated: Data(), config: config)
    }

    private static func isLoopbackClientEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let value = String(describing: host).lowercased()
        return value == "localhost" || value == "::1" || value == "0:0:0:0:0:0:0:1" || value.hasPrefix("127.")
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
        var headerFields: [LocalHTTPHeaderField] = []
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard let idx = line.firstIndex(of: ":") else { continue }
            let name = line[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            parsedHeaders[name] = value
            headerFields.append(LocalHTTPHeaderField(name: name, value: value))
        }
        let headers = parsedHeaders

        if let rejection = LocalRequestAdmissionPolicy.rejection(
            method: method,
            requestTarget: rawPath,
            headers: headerFields,
            listenerPort: config.port
        ) {
            respond(
                connection: connection,
                status: rejection.statusCode,
                body: ProxyErrorResponse.openAI(message: rejection.message),
                contentType: "application/json"
            )
            return
        }

        let contentLength: Int
        switch LocalProxyServerHelpers.contentLengthOutcome(
            header: headers["content-length"],
            alreadyReceived: bodyRemainder.count,
            maxBodyBytes: Self.maxBodyBytes
        ) {
        case .invalid:
            respond(
                connection: connection,
                status: 400,
                body: #"{"error":{"message":"Invalid Content-Length","type":"invalid_request_error"}}"#,
                contentType: "application/json"
            )
            return
        case .tooLarge:
            respond(
                connection: connection,
                status: 413,
                body: #"{"error":{"message":"Request body too large","type":"invalid_request_error"}}"#,
                contentType: "application/json"
            )
            return
        case .accept(let length):
            contentLength = length
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

        // Auth check for non-models routes when local auth is explicitly enabled.
        if config.requiresAuthForProtectedRoutes, !isAuthorized(headers: headers, config: config) {
            respond(
                connection: connection,
                status: 401,
                body: #"{"error":{"message":"Unauthorized","type":"invalid_request_error"}}"#,
                contentType: "application/json"
            )
            return
        }

        if method == "POST" && (path == "/v1/chat/completions" || path == "/chat/completions" || path == "/v1/messages") {
            let trackingID = UUID()
            let attribution = RequestAttribution.validated(headers: headers)
            let modelName = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["model"] as? String

            if path == "/v1/messages" {
                Task.detached { [weak self] in
                    guard let self else { return }
                    await RequestAttributionContext.$current.withValue(attribution) {
                        await self.beginTrackedRequest(
                            id: trackingID,
                            modelName: modelName,
                            providerIdentifier: config.analyticsProviderIdentifier,
                            pathCategory: "anthropic_messages"
                        )
                        await self.handleAnthropicMessages(body: body, headers: headers, connection: connection, config: config, trackingID: trackingID)
                    }
                }
                return
            }

            let isStreaming = isStreamingRequest(body: body)
            Task.detached { [weak self] in
                guard let self else { return }
                await RequestAttributionContext.$current.withValue(attribution) {
                    await self.beginTrackedRequest(
                        id: trackingID,
                        modelName: modelName,
                        providerIdentifier: config.analyticsProviderIdentifier,
                        pathCategory: "chat_completions",
                        clearsUpstreamModelAttribution: true
                    )
                    if isStreaming {
                        await self.handleStreamingChatCompletions(body: body, tutorEnvelope: headers["x-repogps-tutor"], connection: connection, config: config, trackingID: trackingID)
                    } else {
                        await self.handleChatCompletions(body: body, tutorEnvelope: headers["x-repogps-tutor"], connection: connection, config: config, trackingID: trackingID)
                    }
                }
            }
            return
        }

        respond(connection: connection, status: 404, body: "Not Found", contentType: "text/plain")
    }

    // MARK: - GET /v1/models

    private func handleGetModels(path: String, connection: NWConnection, config: Config) {
        let now = Int(Date().timeIntervalSince1970)
        let models = config.allowedModels.union(config.allowedModels.isEmpty ? [] : [ActiveModelAlias.id]).sorted()
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
            appendLog(LocalProxyServerHelpers.modelsResponseLogLine(
                path: path,
                provider: config.upstreamProvider,
                modelIDs: config.allowedModels
            ))
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

    private func handleChatCompletions(body: Data, tutorEnvelope: String?, connection: NWConnection, config: Config, trackingID: UUID) async {
        let requestStartTime = Date()
        let requestModel = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["model"] as? String ?? ""
        if config.requiresUpstreamAPIKey {
            guard let upstreamKey = config.upstreamAPIKey, !upstreamKey.isEmpty else {
                respond(
                    connection: connection,
                    status: 400,
                    body: #"{"error":{"message":"Missing upstream API key","type":"invalid_request_error"}}"#,
                    contentType: "application/json"
                )
                await failTrackedRequest(id: trackingID)
                return
            }
        }

        if config.denyRequestsWhenAllowlistEmpty || !config.allowedModels.isEmpty {
            if let requestedModel = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
               let model = requestedModel["model"] as? String,
               config.allowedModels.isEmpty || !ActiveModelAlias.accepts(
                model,
                allowedModels: config.allowedModels,
                activeModel: config.preferredAnthropicUpstreamModel
               ) {
                respond(
                    connection: connection,
                    status: 400,
                    body: #"{"error":{"message":"Model not allowed","type":"invalid_request_error"}}"#,
                    contentType: "application/json"
                )
                await failTrackedRequest(id: trackingID)
                return
            }
        }

        let rewrittenBody = ActiveModelAlias.rewriteJSONBody(body, activeModel: config.preferredAnthropicUpstreamModel)
        let tutorBody = TutorRequestAdapter.mutateChatCompletionsBody(
            rewrittenBody,
            envelopeHeader: tutorEnvelope,
            attribution: RequestAttributionContext.current,
            provider: config.upstreamProvider
        )
        let outboundBody = sanitizedChatRequestBody(tutorBody, provider: config.upstreamProvider)
        let upstreamURL = buildUpstreamURL(config: config, path: config.upstreamProvider.chatCompletionsPath)
        var request = URLRequest(url: upstreamURL)
        request.httpMethod = "POST"
        request.httpBody = outboundBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPromptCacheMutation(path: config.upstreamProvider.chatCompletionsPath, model: requestModel, config: config, request: &request)
        applyUpstreamAuth(config: config, request: &request)
        request.timeoutInterval = 60

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let upstreamStatus = (response as? HTTPURLResponse)?.statusCode ?? 502
            let normalized = AnthropicTranslator.normalizeOpenAICompatibleResponse(
                statusCode: upstreamStatus,
                responseData: data,
                provider: config.upstreamProvider
            )
            let text = String(decoding: normalized.data, as: UTF8.self)
            let responseBody = text
            let responseData = normalized.data

            respond(connection: connection, status: normalized.statusCode, body: responseBody, contentType: "application/json")
            await recordInputOutputLog(
                inputBody: body,
                outputBody: responseData,
                model: modelFromResponse(responseData) ?? requestModel,
                path: "/v1/chat/completions",
                wasStreaming: false,
                statusCode: normalized.statusCode,
                startedAt: requestStartTime,
                config: config
            )

            if normalized.statusCode == 200 {
                let json = try? JSONSerialization.jsonObject(with: normalized.data) as? [String: Any]
                let usage = passthroughUsage(from: normalized.data)
                let resolvedModel = (json?["model"] as? String).flatMap { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                } ?? requestModel
                let record = SessionReportCard.RequestRecord(
                    timestamp: requestStartTime,
                    model: resolvedModel,
                    promptTokens: usage?.promptTokens ?? 0,
                    completionTokens: usage?.completionTokens ?? 0,
                    promptCacheHitTokens: usage?.promptCacheHitTokens,
                    promptCacheMissTokens: usage?.promptCacheMissTokens,
                    promptCacheWriteTokens: usage?.promptCacheWriteTokens,
                    durationSeconds: Date().timeIntervalSince(requestStartTime),
                    path: "/v1/chat/completions",
                    wasStreaming: false
                )
                await recordSessionReport(record, config: config, trackingID: trackingID)
            } else {
                await failTrackedRequest(id: trackingID)
            }
        } catch {
            respond(
                connection: connection,
                status: 502,
                body: #"{"error":{"message":"Upstream request failed","type":"server_error"}}"#,
                contentType: "application/json"
            )
            await failTrackedRequest(id: trackingID)
        }
    }

    // MARK: - POST /v1/chat/completions (streaming)

    private func handleStreamingChatCompletions(body: Data, tutorEnvelope: String?, connection: NWConnection, config: Config, trackingID: UUID) async {
        let requestStartTime = Date()
        let requestModel = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["model"] as? String ?? ""
        if config.requiresUpstreamAPIKey {
            guard let upstreamKey = config.upstreamAPIKey, !upstreamKey.isEmpty else {
                respond(
                    connection: connection,
                    status: 400,
                    body: #"{"error":{"message":"Missing upstream API key","type":"invalid_request_error"}}"#,
                    contentType: "application/json"
                )
                await failTrackedRequest(id: trackingID)
                return
            }
        }

        if config.denyRequestsWhenAllowlistEmpty || !config.allowedModels.isEmpty {
            if let requestedModel = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
               let model = requestedModel["model"] as? String,
               config.allowedModels.isEmpty || !ActiveModelAlias.accepts(
                model,
                allowedModels: config.allowedModels,
                activeModel: config.preferredAnthropicUpstreamModel
               ) {
                respond(
                    connection: connection,
                    status: 400,
                    body: #"{"error":{"message":"Model not allowed","type":"invalid_request_error"}}"#,
                    contentType: "application/json"
                )
                await failTrackedRequest(id: trackingID)
                return
            }
        }

        let rewrittenBody = ActiveModelAlias.rewriteJSONBody(body, activeModel: config.preferredAnthropicUpstreamModel)
        let tutorBody = TutorRequestAdapter.mutateChatCompletionsBody(
            rewrittenBody,
            envelopeHeader: tutorEnvelope,
            attribution: RequestAttributionContext.current,
            provider: config.upstreamProvider
        )
        let outboundBody = sanitizedChatRequestBody(tutorBody, provider: config.upstreamProvider)
        let upstreamURL = buildUpstreamURL(config: config, path: config.upstreamProvider.chatCompletionsPath)
        var request = URLRequest(url: upstreamURL)
        request.httpMethod = "POST"
        request.httpBody = outboundBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyPromptCacheMutation(path: config.upstreamProvider.chatCompletionsPath, model: requestModel, config: config, request: &request)
        applyUpstreamAuth(config: config, request: &request)
        request.timeoutInterval = 120

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 502

            if httpStatus != 200 {
                var errorBody = ""
                for try await line in bytes.lines { errorBody += line }
                respond(connection: connection, status: httpStatus, body: errorBody, contentType: "application/json")
                await failTrackedRequest(id: trackingID)
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
            var lastSeenPromptCacheHitTokens: Int?
            var lastSeenPromptCacheMissTokens: Int?
            var lastSeenPromptCacheWriteTokens: Int?
            var lastSeenModel = requestModel
            var outputCapture = StreamedOutputCapture(captureEnabled: config.inputOutputLogger != nil)
            var streamingNormalizationContext = AnthropicTranslator.OpenAICompatibleStreamingNormalizationContext()

            for try await line in bytes.lines {
                let normalizedLine = AnthropicTranslator.normalizeOpenAICompatibleStreamingLine(
                    line,
                    provider: config.upstreamProvider,
                    context: &streamingNormalizationContext
                )
                let sseData = SSEFraming.terminatedData(normalizedLine)
                outputCapture.append(sseData)
                await sendData(sseData, on: connection)

                // Extract usage from SSE chunks (best-effort, provider-dependent)
                if let usage = AnthropicTranslator.anthropicPassthroughUsage(fromStreamingLine: normalizedLine) {
                    lastSeenModel = usage.model ?? lastSeenModel
                    lastSeenPromptTokens = usage.promptTokens ?? lastSeenPromptTokens
                    lastSeenCompletionTokens = usage.completionTokens ?? lastSeenCompletionTokens
                    lastSeenPromptCacheHitTokens = usage.promptCacheHitTokens ?? lastSeenPromptCacheHitTokens
                    lastSeenPromptCacheMissTokens = usage.promptCacheMissTokens ?? lastSeenPromptCacheMissTokens
                    lastSeenPromptCacheWriteTokens = usage.promptCacheWriteTokens ?? lastSeenPromptCacheWriteTokens
                }

                if normalizedLine == "data: [DONE]" {
                    // Send final newline and close
                    await sendData(Data("\n".utf8), on: connection)
                    let record = SessionReportCard.RequestRecord(
                        timestamp: requestStartTime,
                        model: lastSeenModel,
                        promptTokens: lastSeenPromptTokens,
                        completionTokens: lastSeenCompletionTokens,
                        promptCacheHitTokens: lastSeenPromptCacheHitTokens,
                        promptCacheMissTokens: lastSeenPromptCacheMissTokens,
                        promptCacheWriteTokens: lastSeenPromptCacheWriteTokens,
                        durationSeconds: Date().timeIntervalSince(requestStartTime),
                        path: "/v1/chat/completions",
                        wasStreaming: true
                    )
                    await recordSessionReport(record, config: config, trackingID: trackingID)
                    await recordInputOutputLog(
                        inputBody: body,
                        outputBody: outputCapture.capturedOutput,
                        outputTruncated: outputCapture.isTruncated,
                        model: lastSeenModel,
                        path: "/v1/chat/completions",
                        wasStreaming: true,
                        statusCode: 200,
                        startedAt: requestStartTime,
                        config: config
                    )
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
                promptCacheHitTokens: lastSeenPromptCacheHitTokens,
                promptCacheMissTokens: lastSeenPromptCacheMissTokens,
                promptCacheWriteTokens: lastSeenPromptCacheWriteTokens,
                durationSeconds: Date().timeIntervalSince(requestStartTime),
                path: "/v1/chat/completions",
                wasStreaming: true
            )
            await recordSessionReport(record, config: config, trackingID: trackingID)
            await recordInputOutputLog(
                inputBody: body,
                outputBody: outputCapture.capturedOutput,
                outputTruncated: outputCapture.isTruncated,
                model: lastSeenModel,
                path: "/v1/chat/completions",
                wasStreaming: true,
                statusCode: 200,
                startedAt: requestStartTime,
                config: config
            )
            connection.cancel()
        } catch {
            respond(
                connection: connection,
                status: 502,
                body: #"{"error":{"message":"Upstream streaming failed","type":"server_error"}}"#,
                contentType: "application/json"
            )
            await failTrackedRequest(id: trackingID)
        }
    }

    // MARK: - POST /v1/messages (Anthropic API Translation)

    private func handleAnthropicMessages(body: Data, headers: [String: String], connection: NWConnection, config: Config, trackingID: UUID) async {
        let requestID = "req_\(UUID().uuidString.prefix(12).lowercased())"

        if config.requiresUpstreamAPIKey {
            guard let upstreamKey = config.upstreamAPIKey, !upstreamKey.isEmpty else {
                respond(
                    connection: connection,
                    status: 400,
                    body: AnthropicTranslator.errorJSON(message: "Missing upstream API key"),
                    contentType: "application/json"
                )
                await failTrackedRequest(id: trackingID)
                return
            }
        }

        guard var anthropicRequest = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            respond(
                connection: connection,
                status: 400,
                body: AnthropicTranslator.errorJSON(message: "Invalid JSON body"),
                contentType: "application/json"
            )
            await failTrackedRequest(id: trackingID)
            return
        }
        logIncomingAnthropicRequest(anthropicRequest, requestID: requestID, mode: config.anthropicTranslatorMode)

        let isStreaming = anthropicRequest["stream"] as? Bool == true
        let requestedModel = anthropicRequest["model"] as? String ?? "unknown"
        let upstreamModel = LocalProxyServerHelpers.resolveAnthropicUpstreamModel(
            preferredModel: config.preferredAnthropicUpstreamModel,
            allowedModels: config.allowedModels
        )

        // --- Anthropic Passthrough: forward directly to the provider /anthropic endpoint ---
        if config.isAnthropicPassthroughActive,
           let passthroughBase = config.upstreamProvider.anthropicPassthroughBaseURL(from: config.upstreamAPIBaseURL) {

            anthropicRequest["model"] = upstreamModel
            AnthropicTranslator.sanitizeAnthropicPassthroughRequest(&anthropicRequest, for: config.upstreamProvider)

            guard let passthroughData = try? JSONSerialization.data(withJSONObject: anthropicRequest) else {
                respond(connection: connection, status: 500,
                        body: AnthropicTranslator.errorJSON(message: "Failed to encode passthrough request"),
                        contentType: "application/json")
                return
            }

            appendLog("anthropic passthrough: \(redact(requestedModel)) → \(redact(upstreamModel)) via \(passthroughBase)/v1/messages")
            Task { @MainActor [weak self] in
                self?.state.resolveRequest(id: trackingID, modelName: upstreamModel)
            }

            guard let passthroughURL = URL(string: passthroughBase + "/v1/messages") else {
                respond(connection: connection, status: 500,
                        body: AnthropicTranslator.errorJSON(message: "Invalid passthrough URL"),
                        contentType: "application/json")
                return
            }
            var request = URLRequest(url: passthroughURL)
            request.httpMethod = "POST"
            request.httpBody = passthroughData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120

            if isStreaming {
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                applyPromptCacheMutation(path: "/v1/messages", model: upstreamModel, config: config, request: &request)
                applyUpstreamAuth(config: config, request: &request)
                await handleAnthropicPassthroughStreaming(
                    request: request,
                    model: requestedModel,
                    reportModel: upstreamModel,
                    requestID: requestID,
                    trackingID: trackingID,
                    connection: connection,
                    provider: config.upstreamProvider,
                    inputBody: body,
                    config: config
                )
            } else {
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                applyPromptCacheMutation(path: "/v1/messages", model: upstreamModel, config: config, request: &request)
                applyUpstreamAuth(config: config, request: &request)
                await handleAnthropicPassthroughBuffered(
                    request: request,
                    model: requestedModel,
                    reportModel: upstreamModel,
                    requestID: requestID,
                    trackingID: trackingID,
                    connection: connection,
                    provider: config.upstreamProvider,
                    inputBody: body,
                    config: config
                )
            }
            return
        }

        // --- Standard path: translate Anthropic → OpenAI ---
        let compaction = ContextCompactionAdapter.compactAnthropicSystem(
            anthropicRequest["system"],
            provider: config.upstreamProvider,
            configuration: config.contextCompaction
        )
        if compaction.applied, let compactedSystem = compaction.system {
            anthropicRequest["system"] = compactedSystem
            let stat = ContextCompactionStat(
                originalBytes: compaction.originalUTF8Bytes,
                compactedBytes: compaction.compactedUTF8Bytes,
                date: Date()
            )
            appendLog("acca: system \(LocalProxyServerHelpers.formatByteCount(compaction.originalUTF8Bytes)) → \(LocalProxyServerHelpers.formatByteCount(compaction.compactedUTF8Bytes)) (\(compaction.strategy))")
            Task { @MainActor [weak self] in
                self?.state.lastContextCompaction = stat
            }
        }

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
        appendLog("anthropic model remap: \(redact(requestedModel)) → \(redact(upstreamModel)) (preferred=\(redact(config.preferredAnthropicUpstreamModel)))")
        Task { @MainActor [weak self] in
            self?.state.resolveRequest(id: trackingID, modelName: upstreamModel)
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
        request.timeoutInterval = 120

        if isStreaming {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            applyPromptCacheMutation(path: config.upstreamProvider.chatCompletionsPath, model: upstreamModel, config: config, request: &request)
            applyUpstreamAuth(config: config, request: &request)
            switch config.anthropicTranslatorMode {
            case .hardened:
                await handleAnthropicStreamingHardened(
                    request: request,
                    model: requestedModel,
                    reportModel: upstreamModel,
                    requestID: requestID,
                    trackingID: trackingID,
                    translationContext: translationContext,
                    mode: config.anthropicTranslatorMode,
                    connection: connection,
                    inputBody: body,
                    config: config
                )
            case .legacyFallback:
                await handleAnthropicStreamingLegacy(
                    request: request,
                    model: requestedModel,
                    reportModel: upstreamModel,
                    requestID: requestID,
                    trackingID: trackingID,
                    mode: config.anthropicTranslatorMode,
                    connection: connection,
                    inputBody: body,
                    config: config
                )
            }
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            applyPromptCacheMutation(path: config.upstreamProvider.chatCompletionsPath, model: upstreamModel, config: config, request: &request)
            applyUpstreamAuth(config: config, request: &request)
            await handleAnthropicBuffered(
                request: request,
                model: requestedModel,
                reportModel: upstreamModel,
                requestID: requestID,
                trackingID: trackingID,
                translationContext: translationContext,
                mode: config.anthropicTranslatorMode,
                connection: connection,
                inputBody: body,
                config: config
            )
        }
    }

    private func handleAnthropicBuffered(
        request: URLRequest,
        model: String,
        reportModel: String,
        requestID: String,
        trackingID: UUID,
        translationContext: AnthropicTranslator.TranslationContext,
        mode: AnthropicTranslatorMode,
        connection: NWConnection,
        inputBody: Data,
        config: Config
    ) async {
        let requestStartTime = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 502

            if httpStatus != 200 {
                let errorText = String(decoding: data, as: UTF8.self)
                recordXcodeAgentRequest(model: reportModel, status: httpStatus)
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
                await failTrackedRequest(id: trackingID)
                return
            }

            guard let openAIResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                respond(
                    connection: connection,
                    status: 502,
                    body: AnthropicTranslator.errorJSON(message: "Failed to parse upstream response"),
                    contentType: "application/json"
                )
                recordXcodeAgentRequest(model: reportModel, status: 502)
                await failTrackedRequest(id: trackingID)
                return
            }
            logUpstreamResponse(openAIResponse, requestID: requestID, mode: mode, streaming: false)

            let usage = openAIResponse["usage"] as? [String: Any]
            let usageSnapshot = AnthropicTranslator.anthropicPassthroughUsage(from: data)
            let record = SessionReportCard.RequestRecord(
                timestamp: requestStartTime,
                model: reportModel,
                promptTokens: usage?["prompt_tokens"] as? Int ?? 0,
                completionTokens: usage?["completion_tokens"] as? Int ?? 0,
                promptCacheHitTokens: usageSnapshot?.promptCacheHitTokens,
                promptCacheMissTokens: usageSnapshot?.promptCacheMissTokens,
                durationSeconds: Date().timeIntervalSince(requestStartTime),
                path: "/v1/messages",
                wasStreaming: false
            )
            await recordSessionReport(record, config: config, trackingID: trackingID)

            let anthropicResponse = AnthropicTranslator.responseFromOpenAI(
                openAIResponse,
                model: model,
                context: translationContext
            ).payload
            logTranslatedAnthropicResponse(anthropicResponse, requestID: requestID, mode: mode)
            if let jsonData = try? JSONSerialization.data(withJSONObject: anthropicResponse),
               let jsonText = String(data: jsonData, encoding: .utf8) {
                respond(connection: connection, status: 200, body: jsonText, contentType: "application/json")
                await recordInputOutputLog(
                    inputBody: inputBody,
                    outputBody: jsonData,
                    model: reportModel,
                    path: "/v1/messages",
                    wasStreaming: false,
                    statusCode: 200,
                    startedAt: requestStartTime,
                    config: config
                )
                recordXcodeAgentRequest(model: reportModel, status: 200)
            } else {
                respond(
                    connection: connection,
                    status: 500,
                    body: AnthropicTranslator.errorJSON(message: "Failed to encode Anthropic response"),
                    contentType: "application/json"
                )
                recordXcodeAgentRequest(model: reportModel, status: 500)
                await failTrackedRequest(id: trackingID)
            }
        } catch {
            respond(
                connection: connection,
                status: 502,
                body: AnthropicTranslator.errorJSON(message: "Upstream request failed"),
                contentType: "application/json"
            )
            recordXcodeAgentRequest(model: reportModel, status: 502)
            await failTrackedRequest(id: trackingID)
        }
    }

    private func handleAnthropicStreamingLegacy(
        request: URLRequest,
        model: String,
        reportModel: String,
        requestID: String,
        trackingID: UUID,
        mode: AnthropicTranslatorMode,
        connection: NWConnection,
        inputBody: Data,
        config: Config
    ) async {
        let requestStartTime = Date()
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 502

            if httpStatus != 200 {
                var errorBody = ""
                for try await line in bytes.lines { errorBody += line }
                recordXcodeAgentRequest(model: reportModel, status: httpStatus)
                respond(
                    connection: connection,
                    status: httpStatus,
                    body: AnthropicTranslator.errorJSON(
                        message: upstreamErrorMessage(
                            statusCode: httpStatus,
                            body: errorBody,
                            provider: config.upstreamProvider
                        )
                    ),
                    contentType: "application/json"
                )
                await failTrackedRequest(id: trackingID)
                return
            }

            await sendAnthropicSSEHeaders(on: connection)

            var isFirstChunk = true
            let msgID = "msg_\(UUID().uuidString.prefix(24).lowercased())"
            var chunkIndex = 0
            var lastSeenPromptTokens = 0
            var lastSeenCompletionTokens = 0
            var lastSeenPromptCacheHitTokens: Int?
            var lastSeenPromptCacheMissTokens: Int?
            var lastSeenPromptCacheWriteTokens: Int?
            var outputCapture = StreamedOutputCapture(captureEnabled: config.inputOutputLogger != nil)

            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))

                if payload == "[DONE]" {
                    let events = AnthropicTranslator.streamingDoneEvents(messageId: msgID, model: model)
                    for event in events {
                        let eventData = Data(event.utf8)
                        outputCapture.append(eventData)
                        await sendData(eventData, on: connection)
                    }
                    logAnthropicStreamingEvent("AN_SSE request_id=\(requestID) mode=\(mode.rawValue) finish=done stop_reason=end_turn")
                    let record = SessionReportCard.RequestRecord(
                        timestamp: requestStartTime, model: reportModel,
                        promptTokens: lastSeenPromptTokens, completionTokens: lastSeenCompletionTokens,
                        promptCacheHitTokens: lastSeenPromptCacheHitTokens,
                        promptCacheMissTokens: lastSeenPromptCacheMissTokens,
                        promptCacheWriteTokens: lastSeenPromptCacheWriteTokens,
                        durationSeconds: Date().timeIntervalSince(requestStartTime),
                        path: "/v1/messages", wasStreaming: true
                    )
                    await recordSessionReport(record, config: config, trackingID: trackingID)
                    await recordInputOutputLog(
                        inputBody: inputBody,
                        outputBody: outputCapture.capturedOutput,
                        outputTruncated: outputCapture.isTruncated,
                        model: reportModel,
                        path: "/v1/messages",
                        wasStreaming: true,
                        statusCode: 200,
                        startedAt: requestStartTime,
                        config: config
                    )
                    recordXcodeAgentRequest(model: reportModel, status: 200)
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
                    let usageSnapshot = AnthropicTranslator.anthropicPassthroughUsage(fromStreamingLine: line)
                    lastSeenPromptCacheHitTokens = usageSnapshot?.promptCacheHitTokens ?? lastSeenPromptCacheHitTokens
                    lastSeenPromptCacheMissTokens = usageSnapshot?.promptCacheMissTokens ?? lastSeenPromptCacheMissTokens
                    lastSeenPromptCacheWriteTokens = usageSnapshot?.promptCacheWriteTokens ?? lastSeenPromptCacheWriteTokens
                }

                if isFirstChunk {
                    let events = AnthropicTranslator.streamingStartEvents(messageId: msgID, model: model)
                    for event in events {
                        let eventData = Data(event.utf8)
                        outputCapture.append(eventData)
                        await sendData(eventData, on: connection)
                    }
                    let textStart = AnthropicTranslator.streamingTextStartEvent(index: 0)
                    let textStartData = Data(textStart.utf8)
                    outputCapture.append(textStartData)
                    await sendData(textStartData, on: connection)
                    isFirstChunk = false
                }

                if let choices = chunk["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let delta = firstChoice["delta"] as? [String: Any],
                   let content = delta["content"] as? String,
                   !content.isEmpty {
                    let event = AnthropicTranslator.streamingDeltaEvent(index: 0, text: content)
                    let eventData = Data(event.utf8)
                    outputCapture.append(eventData)
                    await sendData(eventData, on: connection)
                }
            }

            if !isFirstChunk {
                let events = AnthropicTranslator.streamingDoneEvents(messageId: msgID, model: model)
                for event in events {
                    let eventData = Data(event.utf8)
                    outputCapture.append(eventData)
                    await sendData(eventData, on: connection)
                }
                logAnthropicStreamingEvent("AN_SSE request_id=\(requestID) mode=\(mode.rawValue) finish=eof stop_reason=end_turn")
            }
            let record = SessionReportCard.RequestRecord(
                timestamp: requestStartTime, model: reportModel,
                promptTokens: lastSeenPromptTokens, completionTokens: lastSeenCompletionTokens,
                promptCacheHitTokens: lastSeenPromptCacheHitTokens,
                promptCacheMissTokens: lastSeenPromptCacheMissTokens,
                promptCacheWriteTokens: lastSeenPromptCacheWriteTokens,
                durationSeconds: Date().timeIntervalSince(requestStartTime),
                path: "/v1/messages", wasStreaming: true
            )
            await recordSessionReport(record, config: config, trackingID: trackingID)
            await recordInputOutputLog(
                inputBody: inputBody,
                outputBody: outputCapture.capturedOutput,
                outputTruncated: outputCapture.isTruncated,
                model: reportModel,
                path: "/v1/messages",
                wasStreaming: true,
                statusCode: 200,
                startedAt: requestStartTime,
                config: config
            )
            recordXcodeAgentRequest(model: reportModel, status: 200)
            connection.cancel()
        } catch {
            respond(
                connection: connection,
                status: 502,
                body: AnthropicTranslator.errorJSON(message: "Upstream streaming failed"),
                contentType: "application/json"
            )
            recordXcodeAgentRequest(model: reportModel, status: 502)
            await failTrackedRequest(id: trackingID)
        }
    }

    private func handleAnthropicStreamingHardened(
        request: URLRequest,
        model: String,
        reportModel: String,
        requestID: String,
        trackingID: UUID,
        translationContext: AnthropicTranslator.TranslationContext,
        mode: AnthropicTranslatorMode,
        connection: NWConnection,
        inputBody: Data,
        config: Config
    ) async {
        let requestStartTime = Date()
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 502

            if httpStatus != 200 {
                var errorBody = ""
                for try await line in bytes.lines { errorBody += line }
                recordXcodeAgentRequest(model: reportModel, status: httpStatus)
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
                await failTrackedRequest(id: trackingID)
                return
            }

            await sendAnthropicSSEHeaders(on: connection)

            var state = AnthropicStreamingState(
                requestID: requestID,
                messageID: "msg_\(UUID().uuidString.prefix(24).lowercased())"
            )
            var outputCapture = StreamedOutputCapture(captureEnabled: config.inputOutputLogger != nil)

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
                    let eventData = Data(event.utf8)
                    outputCapture.append(eventData)
                    await sendData(eventData, on: connection)
                }
            }

            let finishEvents = AnthropicTranslator.streamingFinishEvents(state: state)
            for event in finishEvents {
                let eventData = Data(event.utf8)
                outputCapture.append(eventData)
                await sendData(eventData, on: connection)
            }
            if state.sentMessageStart {
                logAnthropicStreamingEvent("AN_SSE request_id=\(requestID) mode=\(mode.rawValue) finish=done stop_reason=\(state.finalStopReason) chunks=\(state.upstreamChunkIndex) emitted_events=\(state.streamedEventCount + finishEvents.count)")
            }
            let record = SessionReportCard.RequestRecord(
                timestamp: requestStartTime, model: reportModel,
                promptTokens: state.lastSeenPromptTokens, completionTokens: state.lastSeenCompletionTokens,
                promptCacheHitTokens: state.lastSeenPromptCacheHitTokens,
                promptCacheMissTokens: state.lastSeenPromptCacheMissTokens,
                promptCacheWriteTokens: state.lastSeenPromptCacheWriteTokens,
                durationSeconds: Date().timeIntervalSince(requestStartTime),
                path: "/v1/messages", wasStreaming: true
            )
            await recordSessionReport(record, config: config, trackingID: trackingID)
            await recordInputOutputLog(
                inputBody: inputBody,
                outputBody: outputCapture.capturedOutput,
                outputTruncated: outputCapture.isTruncated,
                model: reportModel,
                path: "/v1/messages",
                wasStreaming: true,
                statusCode: 200,
                startedAt: requestStartTime,
                config: config
            )
            recordXcodeAgentRequest(model: reportModel, status: 200)
            connection.cancel()
        } catch {
            respond(
                connection: connection,
                status: 502,
                body: AnthropicTranslator.errorJSON(message: "Upstream streaming failed"),
                contentType: "application/json"
            )
            recordXcodeAgentRequest(model: reportModel, status: 502)
            await failTrackedRequest(id: trackingID)
        }
    }

    // MARK: - Anthropic Passthrough Handlers

    private func handleAnthropicPassthroughBuffered(
        request: URLRequest,
        model: String,
        reportModel: String,
        requestID: String,
        trackingID: UUID,
        connection: NWConnection,
        provider: UpstreamProvider = .miniMax,
        inputBody: Data,
        config: Config
    ) async {
        let requestStartTime = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 502

            let validated = AnthropicTranslator.validateAnthropicPassthroughResponse(
                statusCode: statusCode,
                responseData: data,
                provider: provider
            )

            let text = String(decoding: validated.data, as: UTF8.self)
            let usage = passthroughUsage(from: validated.data)
            let responseModel = usage?.model ?? modelFromResponse(validated.data) ?? reportModel
            respond(connection: connection, status: validated.statusCode, body: text, contentType: "application/json")
            if (200..<300).contains(validated.statusCode) {
                let record = SessionReportCard.RequestRecord(
                    timestamp: requestStartTime,
                    model: responseModel,
                    promptTokens: usage?.promptTokens ?? 0,
                    completionTokens: usage?.completionTokens ?? 0,
                    promptCacheHitTokens: usage?.promptCacheHitTokens,
                    promptCacheMissTokens: usage?.promptCacheMissTokens,
                    promptCacheWriteTokens: usage?.promptCacheWriteTokens,
                    durationSeconds: Date().timeIntervalSince(requestStartTime),
                    path: "/v1/messages",
                    wasStreaming: false
                )
                await recordSessionReport(record, config: config, trackingID: trackingID)
            } else {
                await failTrackedRequest(id: trackingID)
            }
            await recordInputOutputLog(
                inputBody: inputBody,
                outputBody: validated.data,
                model: responseModel,
                path: "/v1/messages",
                wasStreaming: false,
                statusCode: validated.statusCode,
                startedAt: requestStartTime,
                config: config
            )
            recordXcodeAgentRequest(model: responseModel, status: validated.statusCode)

            appendLog("passthrough buffered response: status=\(validated.statusCode) model=\(redact(responseModel))")
        } catch {
            appendLog("passthrough error: \(error.localizedDescription)")
            respond(
                connection: connection,
                status: 502,
                body: AnthropicTranslator.errorJSON(message: "Passthrough upstream error: \(error.localizedDescription)"),
                contentType: "application/json"
            )
            recordXcodeAgentRequest(model: reportModel, status: 502)
            await failTrackedRequest(id: trackingID)
        }
    }

    private func handleAnthropicPassthroughStreaming(
        request: URLRequest,
        model: String,
        reportModel: String,
        requestID: String,
        trackingID: UUID,
        connection: NWConnection,
        provider: UpstreamProvider = .miniMax,
        inputBody: Data,
        config: Config
    ) async {
        let requestStartTime = Date()
        var lastSeenModel = reportModel
        var lastSeenPromptTokens = 0
        var lastSeenCompletionTokens = 0
        var lastSeenPromptCacheHitTokens: Int?
        var lastSeenPromptCacheMissTokens: Int?
        var lastSeenPromptCacheWriteTokens: Int?
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 502

            if statusCode >= 400 {
                var errorData = Data()
                for try await byte in bytes { errorData.append(byte) }
                let text = String(decoding: errorData, as: UTF8.self)
                respond(connection: connection, status: statusCode, body: text, contentType: "application/json")
                recordXcodeAgentRequest(model: reportModel, status: statusCode)
                await failTrackedRequest(id: trackingID)
                return
            }

            // Send SSE response headers before streaming data.
            let headers =
                "HTTP/1.1 200 OK\r\n" +
                "Date: \(HTTPDateFormatter.shared.string(from: Date()))\r\n" +
                "Server: ProxyPilot\r\n" +
                "Content-Type: text/event-stream\r\n" +
                "Cache-Control: no-cache\r\n" +
                "Connection: keep-alive\r\n" +
                "\r\n"
            await sendData(Data(headers.utf8), on: connection)
            var outputCapture = StreamedOutputCapture(captureEnabled: config.inputOutputLogger != nil)

            for try await line in bytes.lines {
                let validatedLine = AnthropicTranslator.validateAnthropicPassthroughStreamingLine(
                    line,
                    provider: provider
                )
                updatePassthroughStreamingUsage(
                    from: validatedLine,
                    model: &lastSeenModel,
                    promptTokens: &lastSeenPromptTokens,
                    completionTokens: &lastSeenCompletionTokens,
                    promptCacheHitTokens: &lastSeenPromptCacheHitTokens,
                    promptCacheMissTokens: &lastSeenPromptCacheMissTokens,
                    promptCacheWriteTokens: &lastSeenPromptCacheWriteTokens
                )
                let sseData = SSEFraming.terminatedData(validatedLine)
                outputCapture.append(sseData)
                await sendData(sseData, on: connection)
            }

            // Send final newline and close.
            await sendData(Data("\n".utf8), on: connection)
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            let record = SessionReportCard.RequestRecord(
                timestamp: requestStartTime,
                model: lastSeenModel,
                promptTokens: lastSeenPromptTokens,
                completionTokens: lastSeenCompletionTokens,
                promptCacheHitTokens: lastSeenPromptCacheHitTokens,
                promptCacheMissTokens: lastSeenPromptCacheMissTokens,
                promptCacheWriteTokens: lastSeenPromptCacheWriteTokens,
                durationSeconds: Date().timeIntervalSince(requestStartTime),
                path: "/v1/messages",
                wasStreaming: true
            )
            await recordSessionReport(record, config: config, trackingID: trackingID)
            appendLog("passthrough streaming complete: model=\(redact(lastSeenModel))")
            await recordInputOutputLog(
                inputBody: inputBody,
                outputBody: outputCapture.capturedOutput,
                outputTruncated: outputCapture.isTruncated,
                model: lastSeenModel,
                path: "/v1/messages",
                wasStreaming: true,
                statusCode: 200,
                startedAt: requestStartTime,
                config: config
            )
            recordXcodeAgentRequest(model: lastSeenModel, status: 200)
        } catch {
            appendLog("passthrough streaming error: \(error.localizedDescription)")
            respond(
                connection: connection,
                status: 502,
                body: AnthropicTranslator.errorJSON(message: "Passthrough streaming error: \(error.localizedDescription)"),
                contentType: "application/json"
            )
            recordXcodeAgentRequest(model: reportModel, status: 502)
            await failTrackedRequest(id: trackingID)
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

    func beginTrackedRequest(
        id: UUID,
        modelName: String?,
        providerIdentifier: String? = nil,
        pathCategory: String = "other",
        clearsUpstreamModelAttribution: Bool = false
    ) async {
        await MainActor.run { [weak self] in
            self?.state.beginRequest(
                id: id,
                modelName: modelName,
                analyticsMetadata: providerIdentifier.map {
                    RequestAnalyticsMetadata(providerIdentifier: $0, pathCategory: pathCategory)
                },
                clearsUpstreamModelAttribution: clearsUpstreamModelAttribution
            )
        }
    }

    private func failTrackedRequest(id: UUID) async {
        let clientSurface = RequestAttributionContext.current?.client ?? "gui"
        await MainActor.run { [weak self] in
            guard let self else { return }
            let metadata = self.state.analyticsMetadata(for: id)
            guard self.state.failRequest(id: id) else { return }
            self.telemetryTracker?(
                "proxy_request_failed",
                [
                    "stage": "proxy_request",
                    "error_class": "request_failed",
                    "status_class": "unknown",
                    "path_category": metadata?.pathCategory ?? "other",
                    "provider_identifier": metadata?.providerIdentifier ?? "unknown",
                    "client_surface": clientSurface,
                    "retryable": "unknown"
                ]
            )
        }
    }

    private func recordInputOutputLog(
        inputBody: Data?,
        outputBody: Data?,
        outputTruncated: Bool = false,
        model: String?,
        path: String,
        wasStreaming: Bool,
        statusCode: Int?,
        startedAt: Date,
        config: Config
    ) async {
        guard let logger = config.inputOutputLogger else { return }

        try? await logger.record(
            path: path,
            model: model,
            provider: config.upstreamProvider.rawValue,
            wasStreaming: wasStreaming,
            statusCode: statusCode,
            startedAt: startedAt,
            inputBody: inputBody,
            outputBody: outputBody,
            outputTruncated: outputTruncated
        )
    }

    private func recordSessionReport(
        _ record: SessionReportCard.RequestRecord,
        config: Config,
        trackingID: UUID
    ) async {
        let record = recordWithAllowedCacheTelemetry(record, promptCaching: config.promptCaching)
        let attribution = RequestAttributionContext.current
        let currentSessionID = attribution?.sessionID ?? config.sessionID
        let shouldRecord = await MainActor.run { [weak self] in
            guard let self else { return false }
            guard self.state.completeRequest(id: trackingID) else { return false }
            self.reportCard.record(record)
            return true
        }
        guard shouldRecord else { return }

        let coreRecord = RequestRecord(
            timestamp: record.timestamp,
            model: record.model,
            promptTokens: record.promptTokens,
            completionTokens: record.completionTokens,
            promptCacheHitTokens: record.promptCacheHitTokens,
            promptCacheMissTokens: record.promptCacheMissTokens,
            promptCacheWriteTokens: record.promptCacheWriteTokens,
            durationSeconds: record.durationSeconds,
            path: record.path,
            wasStreaming: record.wasStreaming,
            providerIdentifier: config.analyticsProviderIdentifier,
            promptCachingMode: config.promptCaching.mode.rawValue,
            contextCompactionEnabled: config.contextCompaction.isEnabled,
            translationMode: config.isAnthropicPassthroughActive
                ? "anthropic_passthrough"
                : config.anthropicTranslatorMode.rawValue
        )
        try? SessionReportStore.append(
            SessionReportEvent(
                source: attribution?.client ?? "gui",
                sessionID: currentSessionID,
                record: coreRecord
            )
        )
    }

    private func recordWithAllowedCacheTelemetry(
        _ record: SessionReportCard.RequestRecord,
        promptCaching: PromptCachingConfiguration
    ) -> SessionReportCard.RequestRecord {
        guard promptCaching.recordsProviderCacheTelemetry else {
            return SessionReportCard.RequestRecord(
                id: record.id,
                timestamp: record.timestamp,
                model: record.model,
                promptTokens: record.promptTokens,
                completionTokens: record.completionTokens,
                promptCacheHitTokens: nil,
                promptCacheMissTokens: nil,
                promptCacheWriteTokens: nil,
                durationSeconds: record.durationSeconds,
                path: record.path,
                wasStreaming: record.wasStreaming
            )
        }
        return record
    }

    private func modelFromResponse(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["model"] as? String
    }

    private func passthroughUsage(from data: Data) -> AnthropicTranslator.AnthropicUsageSnapshot? {
        AnthropicTranslator.anthropicPassthroughUsage(from: data)
    }

    private func updatePassthroughStreamingUsage(
        from line: String,
        model: inout String,
        promptTokens: inout Int,
        completionTokens: inout Int,
        promptCacheHitTokens: inout Int?,
        promptCacheMissTokens: inout Int?,
        promptCacheWriteTokens: inout Int?
    ) {
        guard let usage = AnthropicTranslator.anthropicPassthroughUsage(fromStreamingLine: line) else { return }
        model = usage.model ?? model
        promptTokens = usage.promptTokens ?? promptTokens
        completionTokens = usage.completionTokens ?? completionTokens
        promptCacheHitTokens = usage.promptCacheHitTokens ?? promptCacheHitTokens
        promptCacheMissTokens = usage.promptCacheMissTokens ?? promptCacheMissTokens
        promptCacheWriteTokens = usage.promptCacheWriteTokens ?? promptCacheWriteTokens
    }

    private func recordXcodeAgentRequest(model: String, status: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state.lastXcodeAgentRequestModel = model
            self.state.lastXcodeAgentRequestStatus = status
            self.state.lastXcodeAgentRequestAt = Date()
        }
        appendLog("xcode agent proof: model=\(redact(model)) status=\(status)")
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

    static func loopbackBindHost(from configuredHost: String) -> String {
        let host = configuredHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host == "localhost" || host == "::1" { return "127.0.0.1" }
        return host.isEmpty ? "127.0.0.1" : host
    }

    static func makeListenerParameters() -> NWParameters {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        return params
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
            "X-ProxyPilot-Server: 1\r\n" +
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
        try? LocalProxyServerHelpers.appendPrivateLogData(data, to: logURL)
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

    private func applyPromptCacheMutation(
        path: String,
        model: String?,
        config: Config,
        request: inout URLRequest
    ) {
        guard let body = request.httpBody else { return }
        let headers = (request.allHTTPHeaderFields ?? [:]).map { ($0.key, $0.value) }
        let mutation = PromptCacheAdapter.mutate(
            path: path,
            headers: headers,
            body: body,
            provider: config.upstreamProvider,
            model: model,
            sessionID: config.sessionID,
            configuration: config.promptCaching
        )
        request.httpBody = mutation.body
        for (name, value) in mutation.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
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

        // Set grows monotonically within a single run, but is explicitly
        // cleared (along with activeConnectionCount) in both start() and
        // stop() — not just implied by "restart" — so it cannot accumulate
        // across the app-lifetime-retained LocalProxyServer instance.
        // Memory within one run: ~36 bytes per UUID. 100K connections ≈ 4 MB.
    }

    private func appendToolchainLog(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        try? LocalProxyServerHelpers.appendPrivateLogData(data, to: toolchainLogURL)
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
