import Foundation
import NIOCore
import NIOHTTP1

/// Wrapper to pass non-Sendable NIO types across Task boundaries.
/// Safety: the wrapped value is only accessed on its EventLoop via `eventLoop.execute`.
private struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
}

final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {

    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let config: ProxyConfiguration

    // Accumulated request state (reset after each .end)
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    init(config: ProxyConfiguration) {
        self.config = config
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head
            requestBody = context.channel.allocator.buffer(capacity: 0)

        case .body(var body):
            requestBody?.writeBuffer(&body)

        case .end:
            guard let head = requestHead else {
                context.close(promise: nil)
                return
            }

            handleRequest(context: context, head: head, body: requestBody)

            // Reset for next request on this connection (keep-alive)
            requestHead = nil
            requestBody = nil
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    // MARK: - Request Routing

    private func handleRequest(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        body: ByteBuffer?
    ) {
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri

        // Auth check: skip for models endpoints (Xcode compatibility)
        let isModelsEndpoint = (path == "/v1/models" || path == "/models")
        if !isModelsEndpoint && config.requiresAuth {
            guard authenticateRequest(head) else {
                sendErrorResponse(context: context, status: .unauthorized, message: "Unauthorized")
                return
            }
        }

        switch (head.method, path) {
        case (.GET, "/v1/models"), (.GET, "/models"):
            handleModels(context: context)

        case (.POST, "/v1/chat/completions"), (.POST, "/chat/completions"):
            handleChatCompletions(context: context, head: head, body: body, path: path)

        case (.POST, "/v1/messages"):
            handleAnthropicMessages(context: context, head: head, body: body)

        default:
            sendErrorResponse(context: context, status: .notFound, message: "Not found")
        }
    }

    // MARK: - Auth

    private func authenticateRequest(_ head: HTTPRequestHead) -> Bool {
        guard let masterKey = config.masterKey, !masterKey.isEmpty else {
            return true
        }

        // Check Authorization: Bearer <token>
        if let auth = head.headers["Authorization"].first {
            let token = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : auth
            if token == masterKey { return true }
        }

        // Check X-Api-Key
        if let key = head.headers["X-Api-Key"].first, key == masterKey {
            return true
        }

        // Check Api-Key
        if let key = head.headers["Api-Key"].first, key == masterKey {
            return true
        }

        return false
    }

    // MARK: - Models Endpoint

    private func handleModels(context: ChannelHandlerContext) {
        let modelEntries = config.allowedModels.sorted().map { model -> [String: Any] in
            [
                "id": model,
                "object": "model",
                "created": 0,
                "owned_by": "proxypilot"
            ]
        }

        let responseDict: [String: Any] = [
            "object": "list",
            "data": modelEntries
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: responseDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            sendErrorResponse(context: context, status: .internalServerError, message: "Failed to encode models")
            return
        }

        sendJSONResponse(context: context, status: .ok, json: jsonString)
    }

    // MARK: - Anthropic Messages (/v1/messages)

    private func handleAnthropicMessages(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        body: ByteBuffer?
    ) {
        let bodyData: Data
        if var buf = body, let bytes = buf.readBytes(length: buf.readableBytes) {
            bodyData = Data(bytes)
        } else {
            bodyData = Data()
        }

        guard var anthropicRequest = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            sendErrorResponse(context: context, status: .badRequest, message: "Invalid JSON body")
            return
        }

        let isStreaming = anthropicRequest["stream"] as? Bool == true
        let headers: [(String, String)] = head.headers.map { ($0.name, $0.value) }
        let ctxBox = UnsafeSendableBox(value: context)
        let eventLoop = context.eventLoop

        // --- Anthropic Passthrough: forward directly to MiniMax /anthropic endpoint ---
        if config.isAnthropicPassthroughActive {
            // Remap model to the preferred upstream model.
            if !config.preferredAnthropicUpstreamModel.isEmpty {
                anthropicRequest["model"] = config.preferredAnthropicUpstreamModel
            }
            AnthropicTranslator.sanitizeAnthropicPassthroughRequest(&anthropicRequest, for: config.upstreamProvider)

            guard let passthroughBody = try? JSONSerialization.data(withJSONObject: anthropicRequest) else {
                sendErrorResponse(context: context, status: .internalServerError, message: "Failed to serialize passthrough request")
                return
            }

            guard let passthroughBase = config.upstreamProvider.anthropicPassthroughBaseURL(from: config.upstreamAPIBaseURL) else {
                sendErrorResponse(context: context, status: .internalServerError, message: "No Anthropic passthrough URL for provider")
                return
            }

            // Build a temporary config with the passthrough base URL so UpstreamClient targets the right host.
            let passthroughConfig = ProxyConfiguration(
                host: config.host,
                port: config.port,
                upstreamProvider: config.upstreamProvider,
                upstreamAPIBaseURL: passthroughBase,
                upstreamAPIKey: config.upstreamAPIKey,
                masterKey: config.masterKey,
                allowedModels: config.allowedModels,
                requiresAuth: config.requiresAuth,
                preferredAnthropicUpstreamModel: config.preferredAnthropicUpstreamModel,
                sessionStats: config.sessionStats
            )

            if isStreaming {
                handleAnthropicPassthroughStreaming(
                    ctxBox: ctxBox,
                    eventLoop: eventLoop,
                    headers: headers,
                    body: passthroughBody,
                    config: passthroughConfig
                )
            } else {
                handleAnthropicPassthroughBuffered(
                    ctxBox: ctxBox,
                    eventLoop: eventLoop,
                    headers: headers,
                    body: passthroughBody,
                    config: passthroughConfig
                )
            }
            return
        }

        // --- Standard path: translate Anthropic → OpenAI ---
        let originalModel = anthropicRequest["model"] as? String ?? "claude"
        let resolvedUpstreamModel = config.preferredAnthropicUpstreamModel.isEmpty
            ? (anthropicRequest["model"] as? String ?? "")
            : config.preferredAnthropicUpstreamModel
        let translationContext = AnthropicTranslator.TranslationContext(
            upstreamProvider: config.upstreamProvider,
            resolvedUpstreamModel: resolvedUpstreamModel,
            googleThoughtSignatureStore: config.googleThoughtSignatureStore
        )
        var openAIRequest = AnthropicTranslator.requestToOpenAI(
            anthropicRequest,
            context: translationContext
        ).payload

        if !config.preferredAnthropicUpstreamModel.isEmpty {
            openAIRequest["model"] = config.preferredAnthropicUpstreamModel
        }

        if isStreaming {
            openAIRequest["stream"] = true
        }

        guard let openAIBody = try? JSONSerialization.data(withJSONObject: openAIRequest) else {
            sendErrorResponse(context: context, status: .internalServerError, message: "Failed to serialize translated request")
            return
        }

        if isStreaming {
            handleAnthropicStreaming(
                ctxBox: ctxBox,
                eventLoop: eventLoop,
                headers: headers,
                body: openAIBody,
                originalModel: originalModel,
                translationContext: translationContext,
                config: config
            )
        } else {
            handleAnthropicBuffered(
                ctxBox: ctxBox,
                eventLoop: eventLoop,
                headers: headers,
                body: openAIBody,
                originalModel: originalModel,
                translationContext: translationContext,
                config: config
            )
        }
    }

    // MARK: - Anthropic Passthrough Handlers

    private func handleAnthropicPassthroughBuffered(
        ctxBox: UnsafeSendableBox<ChannelHandlerContext>,
        eventLoop: EventLoop,
        headers: [(String, String)],
        body: Data,
        config: ProxyConfiguration
    ) {
        Task {
            do {
                let (responseData, statusCode, _) = try await UpstreamClient.forward(
                    path: "/v1/messages",
                    method: "POST",
                    headers: headers,
                    body: body,
                    config: config
                )

                let validated = AnthropicTranslator.validateAnthropicPassthroughResponse(
                    statusCode: statusCode,
                    responseData: responseData,
                    provider: config.upstreamProvider
                )

                guard let responseString = String(data: validated.data, encoding: .utf8) else {
                    eventLoop.execute {
                        self.sendErrorResponse(context: ctxBox.value, status: .badGateway, message: "Failed to decode passthrough response")
                        ctxBox.value.flush()
                    }
                    return
                }

                let httpStatus: HTTPResponseStatus = .init(statusCode: validated.statusCode)
                eventLoop.execute {
                    self.sendJSONResponse(context: ctxBox.value, status: httpStatus, json: responseString)
                    ctxBox.value.flush()
                }
            } catch {
                let message: String
                if case let UpstreamClient.UpstreamError.httpError(statusCode, bodyData) = error {
                    message = self.upstreamErrorMessage(
                        statusCode: statusCode,
                        responseData: bodyData,
                        provider: config.upstreamProvider
                    )
                } else {
                    message = "Upstream passthrough error: \(error.localizedDescription)"
                }
                eventLoop.execute {
                    self.sendErrorResponse(context: ctxBox.value, status: .badGateway, message: message)
                    ctxBox.value.flush()
                }
            }
        }
    }

    private func handleAnthropicPassthroughStreaming(
        ctxBox: UnsafeSendableBox<ChannelHandlerContext>,
        eventLoop: EventLoop,
        headers: [(String, String)],
        body: Data,
        config: ProxyConfiguration
    ) {
        Task {
            var streamStarted = false

            do {
                let stream = UpstreamClient.forwardStreaming(
                    path: "/v1/messages",
                    method: "POST",
                    headers: headers,
                    body: body,
                    config: config
                )

                for try await chunk in stream {
                    guard let line = String(data: chunk, encoding: .utf8)?.trimmingCharacters(in: .newlines) else {
                        continue
                    }

                    // Validate each SSE event.
                    let validatedLine = AnthropicTranslator.validateAnthropicPassthroughStreamingLine(
                        line,
                        provider: config.upstreamProvider
                    )

                    let lineData = Data((validatedLine + "\n").utf8)

                    if !streamStarted {
                        streamStarted = true
                        eventLoop.execute {
                            var headers = HTTPHeaders()
                            headers.add(name: "Content-Type", value: "text/event-stream")
                            headers.add(name: "Cache-Control", value: "no-cache")
                            headers.add(name: "Connection", value: "keep-alive")
                            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
                            ctxBox.value.write(self.wrapOutboundOut(.head(head)), promise: nil)
                        }
                    }

                    let chunkCopy = lineData
                    eventLoop.execute {
                        var buffer = ctxBox.value.channel.allocator.buffer(capacity: chunkCopy.count)
                        buffer.writeBytes(chunkCopy)
                        ctxBox.value.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                        ctxBox.value.flush()
                    }
                }

                // Send end
                eventLoop.execute {
                    if !streamStarted {
                        let head = HTTPResponseHead(version: .http1_1, status: .ok)
                        ctxBox.value.write(self.wrapOutboundOut(.head(head)), promise: nil)
                    }
                    ctxBox.value.write(self.wrapOutboundOut(.end(nil)), promise: nil)
                    ctxBox.value.flush()
                }
            } catch {
                let message: String
                if case let UpstreamClient.UpstreamError.httpError(_, bodyData) = error {
                    message = self.upstreamErrorMessage(
                        statusCode: 502,
                        responseData: bodyData,
                        provider: config.upstreamProvider
                    )
                } else {
                    message = "Upstream passthrough streaming error: \(error.localizedDescription)"
                }
                eventLoop.execute {
                    if !streamStarted {
                        self.sendErrorResponse(context: ctxBox.value, status: .badGateway, message: message)
                    }
                    ctxBox.value.flush()
                }
            }
        }
    }

    // MARK: - Standard Anthropic Translation Handlers

    private func handleAnthropicBuffered(
        ctxBox: UnsafeSendableBox<ChannelHandlerContext>,
        eventLoop: EventLoop,
        headers: [(String, String)],
        body: Data,
        originalModel: String,
        translationContext: AnthropicTranslator.TranslationContext,
        config: ProxyConfiguration
    ) {
        Task {
            do {
                let (responseData, statusCode, _) = try await UpstreamClient.forward(
                    path: config.upstreamProvider.chatCompletionsPath,
                    method: "POST",
                    headers: headers,
                    body: body,
                    config: config
                )

                guard (200..<300).contains(statusCode) else {
                    let message = self.upstreamErrorMessage(
                        statusCode: statusCode,
                        responseData: responseData,
                        provider: config.upstreamProvider
                    )
                    eventLoop.execute {
                        self.sendErrorResponse(context: ctxBox.value, status: .badGateway, message: message)
                        ctxBox.value.flush()
                    }
                    return
                }

                guard let upstreamJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                    eventLoop.execute {
                        self.sendErrorResponse(context: ctxBox.value, status: .badGateway, message: "Failed to parse upstream response")
                        ctxBox.value.flush()
                    }
                    return
                }

                let anthropicResponse = AnthropicTranslator.responseFromOpenAI(
                    upstreamJSON,
                    model: originalModel,
                    context: translationContext
                ).payload

                guard let responseJSON = try? JSONSerialization.data(withJSONObject: anthropicResponse),
                      let responseString = String(data: responseJSON, encoding: .utf8) else {
                    eventLoop.execute {
                        self.sendErrorResponse(context: ctxBox.value, status: .internalServerError, message: "Failed to serialize response")
                        ctxBox.value.flush()
                    }
                    return
                }

                eventLoop.execute {
                    self.sendJSONResponse(context: ctxBox.value, status: .ok, json: responseString)
                    ctxBox.value.flush()
                }
            } catch {
                let message: String
                if case let UpstreamClient.UpstreamError.httpError(statusCode, bodyData) = error {
                    message = self.upstreamErrorMessage(
                        statusCode: statusCode,
                        responseData: bodyData,
                        provider: config.upstreamProvider
                    )
                } else {
                    message = "Upstream error: \(error.localizedDescription)"
                }
                eventLoop.execute {
                    self.sendErrorResponse(context: ctxBox.value, status: .badGateway, message: message)
                    ctxBox.value.flush()
                }
            }
        }
    }

    private func handleAnthropicStreaming(
        ctxBox: UnsafeSendableBox<ChannelHandlerContext>,
        eventLoop: EventLoop,
        headers: [(String, String)],
        body: Data,
        originalModel: String,
        translationContext: AnthropicTranslator.TranslationContext,
        config: ProxyConfiguration
    ) {
        Task {
            var streamStarted = false
            let messageID = "msg_\(UUID().uuidString.prefix(24).lowercased())"
            var state = AnthropicTranslator.StreamingState(
                requestID: UUID().uuidString,
                messageID: messageID
            )

            do {
                let stream = UpstreamClient.forwardStreaming(
                    path: config.upstreamProvider.chatCompletionsPath,
                    method: "POST",
                    headers: headers,
                    body: body,
                    config: config
                )

                for try await chunk in stream {
                    // Each chunk is one line (with trailing \n) from the SSE stream
                    guard let line = String(data: chunk, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                        continue
                    }

                    // Skip empty lines and non-data lines
                    guard line.hasPrefix("data: ") else { continue }
                    let dataPayload = String(line.dropFirst(6))

                    // Check for stream termination
                    if dataPayload == "[DONE]" { break }

                    // Parse the JSON chunk
                    guard let chunkData = dataPayload.data(using: .utf8),
                          let chunkDict = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else {
                        continue
                    }

                    // Translate chunk to Anthropic SSE events
                    let anthropicEvents = AnthropicTranslator.processStreamingChunk(
                        chunkDict,
                        state: &state,
                        model: originalModel,
                        context: translationContext
                    )

                    if !anthropicEvents.isEmpty && !streamStarted {
                        streamStarted = true
                        eventLoop.execute {
                            var responseHeaders = HTTPHeaders()
                            responseHeaders.add(name: "Content-Type", value: "text/event-stream")
                            responseHeaders.add(name: "Cache-Control", value: "no-cache")
                            responseHeaders.add(name: "Connection", value: "keep-alive")

                            let head = HTTPResponseHead(
                                version: .http1_1,
                                status: .ok,
                                headers: responseHeaders
                            )
                            ctxBox.value.write(self.wrapOutboundOut(.head(head)), promise: nil)
                            ctxBox.value.flush()
                        }
                    }

                    for event in anthropicEvents {
                        let eventCopy = event
                        eventLoop.execute {
                            var buffer = ctxBox.value.channel.allocator.buffer(capacity: eventCopy.utf8.count)
                            buffer.writeString(eventCopy)
                            ctxBox.value.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                            ctxBox.value.flush()
                        }
                    }
                }

                // Emit finish events
                let finishEvents = AnthropicTranslator.streamingFinishEvents(state: state)
                let didStart = streamStarted

                if !finishEvents.isEmpty && !didStart {
                    // Edge case: finish events but stream never started (unlikely)
                    eventLoop.execute {
                        self.sendErrorResponse(context: ctxBox.value, status: .badGateway, message: "Upstream returned empty stream")
                        ctxBox.value.flush()
                    }
                } else {
                    for event in finishEvents {
                        let eventCopy = event
                        eventLoop.execute {
                            var buffer = ctxBox.value.channel.allocator.buffer(capacity: eventCopy.utf8.count)
                            buffer.writeString(eventCopy)
                            ctxBox.value.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                            ctxBox.value.flush()
                        }
                    }

                    eventLoop.execute {
                        if didStart {
                            ctxBox.value.write(self.wrapOutboundOut(.end(nil)), promise: nil)
                            ctxBox.value.flush()
                        } else {
                            self.sendErrorResponse(context: ctxBox.value, status: .badGateway, message: "Upstream returned empty stream")
                            ctxBox.value.flush()
                        }
                    }
                }
            } catch {
                let didStart = streamStarted
                let message: String
                if case let UpstreamClient.UpstreamError.httpError(statusCode, bodyData) = error {
                    message = self.upstreamErrorMessage(
                        statusCode: statusCode,
                        responseData: bodyData,
                        provider: config.upstreamProvider
                    )
                } else {
                    message = "Upstream error: \(error.localizedDescription)"
                }
                eventLoop.execute {
                    if didStart {
                        ctxBox.value.write(self.wrapOutboundOut(.end(nil)), promise: nil)
                        ctxBox.value.flush()
                    } else {
                        self.sendErrorResponse(context: ctxBox.value, status: .badGateway, message: message)
                        ctxBox.value.flush()
                    }
                }
            }
        }
    }

    // MARK: - Chat Completions

    private func handleChatCompletions(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        body: ByteBuffer?,
        path: String
    ) {
        let bodyData: Data
        if var buf = body, let bytes = buf.readBytes(length: buf.readableBytes) {
            bodyData = Data(bytes)
        } else {
            bodyData = Data()
        }

        let isStreaming = HTTPRequestParser.isStreamingRequest(body: bodyData)
        let sanitizedBody = sanitizedChatRequestBody(bodyData)

        // Collect headers as tuples
        let headers: [(String, String)] = head.headers.map { ($0.name, $0.value) }

        // Box context so it can cross the Task boundary safely.
        // All access goes through eventLoop.execute, which is the only safe way.
        let ctxBox = UnsafeSendableBox(value: context)
        let eventLoop = context.eventLoop

        if isStreaming {
            handleStreamingCompletions(
                ctxBox: ctxBox,
                eventLoop: eventLoop,
                path: path,
                method: String(describing: head.method),
                headers: headers,
                body: sanitizedBody,
                config: config
            )
        } else {
            handleBufferedCompletions(
                ctxBox: ctxBox,
                eventLoop: eventLoop,
                path: path,
                method: String(describing: head.method),
                headers: headers,
                body: sanitizedBody,
                config: config
            )
        }
    }

    private func handleBufferedCompletions(
        ctxBox: UnsafeSendableBox<ChannelHandlerContext>,
        eventLoop: EventLoop,
        path: String,
        method: String,
        headers: [(String, String)],
        body: Data,
        config: ProxyConfiguration
    ) {
        Task {
            do {
                let (responseData, upstreamStatusCode, responseHeaders) = try await UpstreamClient.forward(
                    path: config.upstreamProvider.chatCompletionsPath,
                    method: method,
                    headers: headers,
                    body: body,
                    config: config
                )
                let normalized = AnthropicTranslator.normalizeOpenAICompatibleResponse(
                    statusCode: upstreamStatusCode,
                    responseData: responseData,
                    provider: config.upstreamProvider
                )

                eventLoop.execute {
                    self.sendUpstreamResponse(
                        context: ctxBox.value,
                        data: normalized.data,
                        statusCode: normalized.statusCode,
                        upstreamHeaders: responseHeaders
                    )
                    ctxBox.value.flush()
                }
            } catch {
                let message = "Upstream error: \(error.localizedDescription)"
                eventLoop.execute {
                    self.sendErrorResponse(
                        context: ctxBox.value,
                        status: .badGateway,
                        message: message
                    )
                    ctxBox.value.flush()
                }
            }
        }
    }

    private func handleStreamingCompletions(
        ctxBox: UnsafeSendableBox<ChannelHandlerContext>,
        eventLoop: EventLoop,
        path: String,
        method: String,
        headers: [(String, String)],
        body: Data,
        config: ProxyConfiguration
    ) {
        Task {
            var streamStarted = false

            do {
                let stream = UpstreamClient.forwardStreaming(
                    path: config.upstreamProvider.chatCompletionsPath,
                    method: method,
                    headers: headers,
                    body: body,
                    config: config
                )

                for try await chunk in stream {
                    let normalizedLine = AnthropicTranslator.normalizeOpenAICompatibleStreamingLine(
                        String(decoding: chunk, as: UTF8.self).trimmingCharacters(in: .newlines),
                        provider: config.upstreamProvider
                    )
                    let chunkData = Data((normalizedLine + "\n").utf8)

                    if !streamStarted {
                        streamStarted = true
                        eventLoop.execute {
                            var responseHeaders = HTTPHeaders()
                            responseHeaders.add(name: "Content-Type", value: "text/event-stream")
                            responseHeaders.add(name: "Cache-Control", value: "no-cache")
                            responseHeaders.add(name: "Connection", value: "keep-alive")

                            let head = HTTPResponseHead(
                                version: .http1_1,
                                status: .ok,
                                headers: responseHeaders
                            )
                            ctxBox.value.write(self.wrapOutboundOut(.head(head)), promise: nil)
                            ctxBox.value.flush()
                        }
                    }

                    let chunkCopy = chunkData
                    eventLoop.execute {
                        var buffer = ctxBox.value.channel.allocator.buffer(capacity: chunkCopy.count)
                        buffer.writeBytes(chunkCopy)
                        ctxBox.value.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                        ctxBox.value.flush()
                    }
                }

                let didStart = streamStarted
                eventLoop.execute {
                    if !didStart {
                        self.sendErrorResponse(
                            context: ctxBox.value,
                            status: .badGateway,
                            message: "Upstream returned empty stream"
                        )
                        ctxBox.value.flush()
                    } else {
                        ctxBox.value.write(self.wrapOutboundOut(.end(nil)), promise: nil)
                        ctxBox.value.flush()
                    }
                }
            } catch {
                let didStart = streamStarted
                let message = "Upstream error: \(error.localizedDescription)"
                eventLoop.execute {
                    if didStart {
                        ctxBox.value.write(self.wrapOutboundOut(.end(nil)), promise: nil)
                        ctxBox.value.flush()
                    } else {
                        self.sendErrorResponse(
                            context: ctxBox.value,
                            status: .badGateway,
                            message: message
                        )
                        ctxBox.value.flush()
                    }
                }
            }
        }
    }

    // MARK: - Response Helpers

    private func sendUpstreamResponse(
        context: ChannelHandlerContext,
        data: Data,
        statusCode: Int,
        upstreamHeaders: [(String, String)]
    ) {
        let status = HTTPResponseStatus(statusCode: statusCode)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(data.count)")

        // Forward relevant upstream headers
        let forwardHeaders: Set<String> = ["content-type", "x-request-id"]
        for (name, value) in upstreamHeaders {
            if forwardHeaders.contains(name.lowercased()) {
                headers.add(name: name, value: value)
            }
        }

        // Ensure Content-Type is set
        if !headers.contains(name: "Content-Type") {
            headers.add(name: "Content-Type", value: "application/json")
        }

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        context.write(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func sendJSONResponse(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        json: String
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(json.utf8.count)")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: json.utf8.count)
        buffer.writeString(json)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        context.write(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func sendErrorResponse(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        message: String
    ) {
        let errorDict: [String: Any] = [
            "error": [
                "message": message,
                "type": "error",
                "code": status.code
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: errorDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            // Last resort: plain text error
            let fallback = "{\"error\":{\"message\":\"\(message)\"}}"
            sendJSONResponse(context: context, status: status, json: fallback)
            return
        }

        sendJSONResponse(context: context, status: status, json: jsonString)
    }

    private func sanitizedChatRequestBody(_ body: Data) -> Data {
        let provider = config.upstreamProvider
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

    private func upstreamErrorMessage(
        statusCode: Int,
        responseData: Data,
        provider: UpstreamProvider
    ) -> String {
        let body = String(decoding: responseData, as: UTF8.self)
        if provider == .google,
           statusCode == 400,
           body.localizedCaseInsensitiveContains("thought_signature") {
            return "Google direct rejected the tool-call continuation due to thought_signature validation. If this persists, use OpenRouter as the current workaround."
        }
        return "Upstream returned status \(statusCode)"
    }
}
