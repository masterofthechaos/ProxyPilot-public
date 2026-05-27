import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOConcurrencyHelpers
@testable import ProxyPilotCore

/// A tiny HTTP server that returns a fixed status code for any request.
/// Used as a fake upstream in tests so we don't depend on real network timeouts.
private struct StubRequestRecord: Sendable {
    let method: String
    let uri: String
    let headers: [(String, String)]
    let body: String

    func headerValue(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }
}

private final class StubUpstream: Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let channel: NIOLockedValueBox<Channel?> = NIOLockedValueBox(nil)
    private let records = NIOLockedValueBox<[StubRequestRecord]>([])

    /// Starts the stub and returns the bound port.
    func start(
        statusCode: Int = 500,
        body: String = "{\"error\":\"stub\"}",
        requireJSONRequest: Bool = false,
        contentType: String = "application/json"
    ) async throws -> UInt16 {
        let sc = statusCode
        let b = body
        let strictJSON = requireJSONRequest
        let ct = contentType
        let ch = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(StubHandler(
                        statusCode: sc,
                        body: b,
                        requireJSONRequest: strictJSON,
                        contentType: ct,
                        records: self.records
                    ))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        channel.withLockedValue { $0 = ch }
        return UInt16(ch.localAddress!.port!)
    }

    func requests() -> [StubRequestRecord] {
        records.withLockedValue { $0 }
    }

    func stop() async throws {
        if let ch = channel.withLockedValue({ c -> Channel? in let r = c; c = nil; return r }) {
            try await ch.close()
        }
        try await group.shutdownGracefully()
    }
}

private final class StubHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let statusCode: Int
    let body: String
    let requireJSONRequest: Bool
    let contentType: String
    let records: NIOLockedValueBox<[StubRequestRecord]>
    var requestHead: HTTPRequestHead?
    var requestBody: ByteBuffer?

    init(
        statusCode: Int,
        body: String,
        requireJSONRequest: Bool,
        contentType: String,
        records: NIOLockedValueBox<[StubRequestRecord]>
    ) {
        self.statusCode = statusCode
        self.body = body
        self.requireJSONRequest = requireJSONRequest
        self.contentType = contentType
        self.records = records
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head
            requestBody = context.channel.allocator.buffer(capacity: 0)
            return
        case .body(var body):
            requestBody?.writeBuffer(&body)
            return
        case .end:
            var responseStatusCode = statusCode
            var responseBody = body
            if let requestHead {
                var capturedBody = ""
                if var buffer = requestBody,
                   let bytes = buffer.readBytes(length: buffer.readableBytes) {
                    capturedBody = String(decoding: bytes, as: UTF8.self)
                }
                let capturedHeaders = requestHead.headers.map { ($0.name, $0.value) }
                records.withLockedValue {
                    $0.append(StubRequestRecord(
                        method: requestHead.method.rawValue,
                        uri: requestHead.uri,
                        headers: capturedHeaders,
                        body: capturedBody
                    ))
                }
                if requireJSONRequest {
                    let contentType = requestHead.headers.first(name: "Content-Type")?.lowercased()
                    let hasJSONContentType = contentType?.split(separator: ";")
                        .first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) == "application/json"
                    let hasJSONBody = (try? JSONSerialization.jsonObject(with: Data(capturedBody.utf8))) != nil
                    if !hasJSONContentType || !hasJSONBody {
                        responseStatusCode = 415
                        responseBody = #"{"error":"strict stub expected application/json"}"#
                    }
                }
            }
            requestHead = nil
            requestBody = nil

            respond(context: context, statusCode: responseStatusCode, body: responseBody)
            return
        }
    }

    private func respond(context: ChannelHandlerContext, statusCode: Int, body: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(body.utf8.count)")

        let head = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: statusCode),
            headers: headers
        )
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

@Suite("NIOProxyServer Tests")
struct NIOProxyServerTests {

    @Test func serverStartsAndReturnsModels() async throws {
        let config = ProxyConfiguration(port: 0, allowedModels: ["gpt-4o", "claude-3"])
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 200)

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["object"] as? String == "list")
        let models = json["data"] as! [[String: Any]]
        #expect(models.count == 2)

        try await server.stop()
    }

    @Test func serverReturnsEmptyModelsWhenNoneConfigured() async throws {
        let config = ProxyConfiguration(port: 0)
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let models = json["data"] as! [[String: Any]]
        #expect(models.count == 0)

        try await server.stop()
    }

    @Test func serverReturns404ForUnknownPath() async throws {
        let config = ProxyConfiguration(port: 0)
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        let url = URL(string: "http://127.0.0.1:\(port)/unknown")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 404)

        try await server.stop()
    }

    @Test func serverReturns401WhenAuthRequiredAndMissing() async throws {
        let config = ProxyConfiguration(port: 0, masterKey: "test-key", requiresAuth: true)
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        // POST to chat completions without auth
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 401)

        // But /v1/models should still work without auth (Xcode compat)
        let (_, modelsResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        #expect((modelsResponse as! HTTPURLResponse).statusCode == 200)

        try await server.stop()
    }

    @Test func modelsEndpointAlsoWorksAtSlashModels() async throws {
        let config = ProxyConfiguration(port: 0, allowedModels: ["test-model"])
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        let url = URL(string: "http://127.0.0.1:\(port)/models")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 200)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let models = json["data"] as! [[String: Any]]
        #expect(models.count == 1)

        try await server.stop()
    }

    // MARK: - Chat Completions Forwarding

    @Test func chatCompletionsForwardsUpstreamResponse() async throws {
        // Start a stub upstream that returns 200 with a fake completion
        let stub = StubUpstream()
        let upstreamPort = try await stub.start(
            statusCode: 200,
            body: "{\"id\":\"chatcmpl-test\",\"choices\":[{\"message\":{\"content\":\"hello\"}}]}",
            requireJSONRequest: true
        )

        let config = ProxyConfiguration(
            port: 0,
            upstreamAPIBaseURL: "http://127.0.0.1:\(upstreamPort)",
            requiresAuth: false
        )
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 200)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["id"] as? String == "chatcmpl-test")

        let capturedRequest = try #require(stub.requests().first)
        #expect(capturedRequest.headerValue("Content-Type") == "application/json")
        #expect(capturedRequest.headerValue("Accept") == "application/json")

        try await server.stop()
        try await stub.stop()
    }

    @Test func zaiChatCompletionsSendsJSONHeadersToStrictUpstream() async throws {
        let stub = StubUpstream()
        let upstreamPort = try await stub.start(
            statusCode: 200,
            body: "{\"id\":\"chatcmpl-zai\",\"model\":\"glm-5.1\",\"choices\":[{\"message\":{\"content\":\"ok\"}}]}",
            requireJSONRequest: true
        )

        let config = ProxyConfiguration(
            port: 0,
            upstreamProvider: .zAI,
            upstreamAPIBaseURL: "http://127.0.0.1:\(upstreamPort)/api/coding/paas/v4",
            requiresAuth: false
        )
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "glm-5.1",
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 200)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        #expect(message?["content"] as? String == "ok")

        let capturedRequest = try #require(stub.requests().first)
        #expect(capturedRequest.headerValue("Content-Type") == "application/json")
        #expect(capturedRequest.headerValue("Accept") == "application/json")

        try await server.stop()
        try await stub.stop()
    }

    @Test func zaiAnthropicMessagesSendsJSONHeadersToStrictUpstream() async throws {
        let openAIResponse: [String: Any] = [
            "id": "chatcmpl-zai-messages",
            "object": "chat.completion",
            "model": "glm-5.1",
            "choices": [
                [
                    "index": 0,
                    "message": ["role": "assistant", "content": "zai ok"],
                    "finish_reason": "stop"
                ]
            ],
            "usage": ["prompt_tokens": 9, "completion_tokens": 2, "total_tokens": 11]
        ]
        let stubBodyData = try JSONSerialization.data(withJSONObject: openAIResponse)
        let stubBody = String(data: stubBodyData, encoding: .utf8)!

        let stub = StubUpstream()
        let upstreamPort = try await stub.start(
            statusCode: 200,
            body: stubBody,
            requireJSONRequest: true
        )

        let config = ProxyConfiguration(
            port: 0,
            upstreamProvider: .zAI,
            upstreamAPIBaseURL: "http://127.0.0.1:\(upstreamPort)/api/coding/paas/v4",
            requiresAuth: false,
            preferredAnthropicUpstreamModel: "glm-5.1"
        )
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-4-5-20250514",
            "max_tokens": 64,
            "stream": false,
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 200)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["type"] as? String == "message")
        #expect(json?["model"] as? String == "claude-sonnet-4-5-20250514")
        let content = json?["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == "zai ok")

        let capturedRequest = try #require(stub.requests().first)
        #expect(capturedRequest.uri.hasSuffix("/chat/completions"))
        #expect(capturedRequest.headerValue("Content-Type") == "application/json")
        #expect(capturedRequest.headerValue("Accept") == "application/json")

        try await server.stop()
        try await stub.stop()
    }

    @Test func zaiAnthropicMessagesStreamingSendsSSEHeadersToStrictUpstream() async throws {
        let streamBody = """
        data: {"id":"chatcmpl-zai-stream","object":"chat.completion.chunk","model":"glm-5.1","choices":[{"index":0,"delta":{"content":"zai stream"},"finish_reason":null}]}

        data: {"id":"chatcmpl-zai-stream","object":"chat.completion.chunk","model":"glm-5.1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":2,"total_tokens":11}}

        data: [DONE]

        """

        let stub = StubUpstream()
        let upstreamPort = try await stub.start(
            statusCode: 200,
            body: streamBody,
            requireJSONRequest: true,
            contentType: "text/event-stream"
        )

        let config = ProxyConfiguration(
            port: 0,
            upstreamProvider: .zAI,
            upstreamAPIBaseURL: "http://127.0.0.1:\(upstreamPort)/api/coding/paas/v4",
            requiresAuth: false,
            preferredAnthropicUpstreamModel: "glm-5.1"
        )
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-4-5-20250514",
            "max_tokens": 64,
            "stream": true,
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 200)
        #expect(httpResponse.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true)

        let body = String(decoding: data, as: UTF8.self)
        #expect(body.contains("event: content_block_delta"))
        #expect(body.contains(#""text":"zai stream""#))
        #expect(body.contains("event: message_stop"))

        let capturedRequest = try #require(stub.requests().first)
        #expect(capturedRequest.uri.hasSuffix("/chat/completions"))
        #expect(capturedRequest.headerValue("Content-Type") == "application/json")
        #expect(capturedRequest.headerValue("Accept") == "text/event-stream")

        try await server.stop()
        try await stub.stop()
    }

    @Test func openAIComputeCacheHintsReachUpstreamBody() async throws {
        let stub = StubUpstream()
        let upstreamPort = try await stub.start(
            statusCode: 200,
            body: "{\"id\":\"chatcmpl-cache\",\"choices\":[{\"message\":{\"content\":\"ok\"}}]}",
            requireJSONRequest: true
        )

        let config = ProxyConfiguration(
            port: 0,
            upstreamProvider: .openAI,
            upstreamAPIBaseURL: "http://127.0.0.1:\(upstreamPort)",
            requiresAuth: false,
            promptCaching: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints),
            sessionID: "nio-session"
        )
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let capturedRequest = try #require(stub.requests().first)
        let capturedBody = try #require(capturedRequest.body.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: capturedBody) as? [String: Any])
        #expect(json["prompt_cache_key"] as? String == "e4c2d4ca225f01cde611bf15_1")
        #expect(json["model"] as? String == "test-model")
        #expect(capturedRequest.headerValue("Content-Type") == "application/json")
        #expect(capturedRequest.headerValue("Accept") == "application/json")

        try await server.stop()
        try await stub.stop()
    }

    @Test func xAIComputeCacheHintsReachUpstreamHeader() async throws {
        let stub = StubUpstream()
        let upstreamPort = try await stub.start(
            statusCode: 200,
            body: "{\"id\":\"chatcmpl-xai\",\"model\":\"grok-4\",\"choices\":[{\"message\":{\"content\":\"ok\"}}]}",
            requireJSONRequest: true
        )

        let config = ProxyConfiguration(
            port: 0,
            upstreamProvider: .xAI,
            upstreamAPIBaseURL: "http://127.0.0.1:\(upstreamPort)/v1",
            upstreamAPIKey: "xai-test",
            requiresAuth: false,
            promptCaching: PromptCachingConfiguration(isEnabled: true, mode: .computeCacheHints),
            sessionID: "nio-session"
        )
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "grok-4",
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let capturedRequest = try #require(stub.requests().first)
        let capturedBody = try #require(capturedRequest.body.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: capturedBody) as? [String: Any])
        #expect(json["prompt_cache_key"] == nil)
        #expect(capturedRequest.headerValue("x-grok-conv-id") == "05254c2af9aac67d2d50ff81_1")

        try await server.stop()
        try await stub.stop()
    }

    @Test func chatCompletionsWritesSharedSessionReportEvent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reportURL = directory.appendingPathComponent("session-report.jsonl")
        let stats = SessionStats(
            sessionReportURL: reportURL,
            sessionSource: "cli",
            sessionID: "nio-test"
        )

        let stub = StubUpstream()
        let upstreamPort = try await stub.start(
            statusCode: 200,
            body: """
            {"id":"chatcmpl-test","model":"glm-5","choices":[{"message":{"content":"hello"}}],"usage":{"prompt_tokens":12,"completion_tokens":7,"total_tokens":19,"prompt_tokens_details":{"cached_tokens":5},"cache_creation_input_tokens":3}}
            """
        )

        let config = ProxyConfiguration(
            port: 0,
            upstreamAPIBaseURL: "http://127.0.0.1:\(upstreamPort)",
            requiresAuth: false,
            sessionStats: stats
        )
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "requested-model",
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let events = try SessionReportStore.readEvents(from: reportURL)
        #expect(events.count == 1)
        #expect(events[0].source == "cli")
        #expect(events[0].sessionID == "nio-test")
        #expect(events[0].record.model == "glm-5")
        #expect(events[0].record.promptTokens == 12)
        #expect(events[0].record.completionTokens == 7)
        #expect(events[0].record.promptCacheHitTokens == 5)
        #expect(events[0].record.promptCacheMissTokens == 7)
        #expect(events[0].record.promptCacheWriteTokens == 3)
        #expect(events[0].record.path == "/v1/chat/completions")
        #expect(events[0].record.wasStreaming == false)

        try await server.stop()
        try await stub.stop()
    }

    @Test func offPromptCachingDoesNotAggregateProviderCacheTelemetry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let reportURL = directory.appendingPathComponent("session-report.jsonl")
        let stats = SessionStats(
            sessionReportURL: reportURL,
            sessionSource: "cli",
            sessionID: "cache-off-test"
        )

        let stub = StubUpstream()
        let upstreamPort = try await stub.start(
            statusCode: 200,
            body: """
            {"id":"chatcmpl-cache-off","model":"glm-5","choices":[{"message":{"content":"hello"}}],"usage":{"prompt_tokens":12,"completion_tokens":7,"total_tokens":19,"prompt_tokens_details":{"cached_tokens":5},"cache_creation_input_tokens":3}}
            """
        )

        let config = ProxyConfiguration(
            port: 0,
            upstreamAPIBaseURL: "http://127.0.0.1:\(upstreamPort)",
            requiresAuth: false,
            sessionStats: stats,
            promptCaching: PromptCachingConfiguration(isEnabled: true, mode: .off)
        )
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "requested-model",
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let events = try SessionReportStore.readEvents(from: reportURL)
        #expect(events.count == 1)
        #expect(events[0].record.promptCacheHitTokens == nil)
        #expect(events[0].record.promptCacheMissTokens == nil)
        #expect(events[0].record.promptCacheWriteTokens == nil)

        let snapshot = await stats.snapshot()
        #expect(snapshot.totalPromptCacheHitTokens == 0)
        #expect(snapshot.totalPromptCacheMissTokens == 0)
        #expect(snapshot.totalPromptCacheWriteTokens == 0)
        #expect(snapshot.cacheAccountingAvailable == false)

        try await server.stop()
        try await stub.stop()
    }

    @Test func chatCompletionsWritesEncryptedInputOutputLogWhenEnabled() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let preferencesURL = directory.appendingPathComponent("settings.json")
        let logURL = directory.appendingPathComponent("records.jsonl.enc")
        let preferencesStore = InputOutputLoggingPreferencesStore(url: preferencesURL)
        try preferencesStore.save(InputOutputLoggingPreferences(
            enabled: true,
            recordInputs: true,
            recordOutputs: true,
            cliEnabled: true,
            retention: .twentyFourHoursDefault
        ))

        let logStore = InputOutputLogStore(
            url: logURL,
            encryptionKey: Data(repeating: 7, count: 32)
        )
        let recorder = InputOutputLoggingRecorder(
            source: "cli",
            preferencesStore: preferencesStore,
            logStore: logStore
        )

        let stub = StubUpstream()
        let upstreamPort = try await stub.start(
            statusCode: 200,
            body: "{\"id\":\"chatcmpl-test\",\"model\":\"test-model\",\"choices\":[{\"message\":{\"content\":\"logged output\"}}]}"
        )

        let config = ProxyConfiguration(
            port: 0,
            upstreamAPIBaseURL: "http://127.0.0.1:\(upstreamPort)",
            requiresAuth: false,
            inputOutputLogger: recorder
        )
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "messages": [["role": "user", "content": "secret prompt"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let rawLog = try String(contentsOf: logURL, encoding: .utf8)
        #expect(!rawLog.contains("secret prompt"))
        #expect(!rawLog.contains("logged output"))

        let records = try await logStore.readRecords()
        #expect(records.count == 1)
        #expect(records[0].source == "cli")
        #expect(records[0].path == "/v1/chat/completions")
        #expect(records[0].model == "test-model")
        #expect(records[0].input?.text?.contains("secret prompt") == true)
        #expect(records[0].output?.text?.contains("logged output") == true)

        try await server.stop()
        try await stub.stop()
    }

    @Test func chatCompletionsReturns502WhenUpstreamErrors() async throws {
        // Start a stub upstream that returns 500
        let stub = StubUpstream()
        let upstreamPort = try await stub.start(statusCode: 500, body: "{\"error\":\"internal\"}")

        let config = ProxyConfiguration(
            port: 0,
            upstreamAPIBaseURL: "http://127.0.0.1:\(upstreamPort)",
            requiresAuth: false
        )
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        // The proxy should forward the upstream 500 status code
        #expect(httpResponse.statusCode == 500)

        try await server.stop()
        try await stub.stop()
    }

    // MARK: - Anthropic Messages (/v1/messages)

    @Test func anthropicMessagesReturns502WhenUpstreamUnreachable() async throws {
        let config = ProxyConfiguration(
            port: 0,
            upstreamAPIBaseURL: "http://127.0.0.1:1",
            requiresAuth: false,
            preferredAnthropicUpstreamModel: "test-model"
        )
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-4-5-20250514",
            "max_tokens": 100,
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 502)

        try await server.stop()
    }

    @Test func anthropicMessagesTranslatesResponseFormat() async throws {
        let openAIResponse: [String: Any] = [
            "id": "chatcmpl-123",
            "object": "chat.completion",
            "choices": [
                [
                    "index": 0,
                    "message": ["role": "assistant", "content": "Hello!"],
                    "finish_reason": "stop"
                ]
            ],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15]
        ]
        let stubBodyData = try JSONSerialization.data(withJSONObject: openAIResponse)
        let stubBody = String(data: stubBodyData, encoding: .utf8)!

        let stub = StubUpstream()
        let stubPort = try await stub.start(statusCode: 200, body: stubBody, requireJSONRequest: true)

        let config = ProxyConfiguration(
            port: 0,
            upstreamAPIBaseURL: "http://127.0.0.1:\(stubPort)",
            requiresAuth: false,
            preferredAnthropicUpstreamModel: "test-model"
        )
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-4-5-20250514",
            "max_tokens": 100,
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 200)

        // Verify the response is in Anthropic format
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "message")
        #expect(json["role"] as? String == "assistant")
        // The model should be the ORIGINAL Claude model name, not the upstream model
        #expect(json["model"] as? String == "claude-sonnet-4-5-20250514")
        // Check content exists
        let content = json["content"] as? [[String: Any]]
        let firstBlock = content?.first
        #expect(firstBlock?["type"] as? String == "text")
        #expect(firstBlock?["text"] as? String == "Hello!")

        let capturedRequest = try #require(stub.requests().first)
        #expect(capturedRequest.headerValue("Content-Type") == "application/json")
        #expect(capturedRequest.headerValue("Accept") == "application/json")

        try await server.stop()
        try await stub.stop()
    }

    @Test func streamingRequestReturns502WhenUpstreamErrors() async throws {
        // Start a stub upstream that returns 500 (even for streaming requests,
        // the upstream failing should result in the proxy returning an error)
        let stub = StubUpstream()
        let upstreamPort = try await stub.start(
            statusCode: 500,
            body: "{\"error\":\"internal\"}",
            requireJSONRequest: true
        )

        let config = ProxyConfiguration(
            port: 0,
            upstreamAPIBaseURL: "http://127.0.0.1:\(upstreamPort)",
            requiresAuth: false
        )
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "stream": true,
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        // Streaming path: upstream 500 → UpstreamClient throws httpError → proxy returns 502
        #expect(httpResponse.statusCode == 502)

        let capturedRequest = try #require(stub.requests().first)
        #expect(capturedRequest.headerValue("Content-Type") == "application/json")
        #expect(capturedRequest.headerValue("Accept") == "text/event-stream")

        try await server.stop()
        try await stub.stop()
    }

    @Test func anthropicMessagesPassthroughsDeepSeekToAnthropicEndpoint() async throws {
        let anthropicResponse: [String: Any] = [
            "id": "msg_deepseek_test",
            "type": "message",
            "role": "assistant",
            "model": "deepseek-v4-pro",
            "content": [["type": "text", "text": "ok"]],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 10, "output_tokens": 2]
        ]
        let stubBodyData = try JSONSerialization.data(withJSONObject: anthropicResponse)
        let stubBody = String(data: stubBodyData, encoding: .utf8)!

        let stub = StubUpstream()
        let stubPort = try await stub.start(statusCode: 200, body: stubBody, requireJSONRequest: true)

        let config = ProxyConfiguration(
            port: 0,
            upstreamProvider: .deepSeek,
            upstreamAPIBaseURL: "http://127.0.0.1:\(stubPort)/v1",
            upstreamAPIKey: "sk-test",
            requiresAuth: false,
            preferredAnthropicUpstreamModel: "deepseek-v4-pro"
        )
        let server = NIOProxyServer()
        let port = try await server.start(config: config)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-4-5-20250514",
            "max_tokens": 100,
            "stream": false,
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 200)

        let capturedRequest = try #require(stub.requests().first)
        #expect(capturedRequest.method == "POST")
        #expect(capturedRequest.uri == "/anthropic/v1/messages")
        #expect(capturedRequest.headerValue("Content-Type") == "application/json")

        let capturedBodyData = Data(capturedRequest.body.utf8)
        let capturedBody = try #require(JSONSerialization.jsonObject(with: capturedBodyData) as? [String: Any])
        #expect(capturedBody["model"] as? String == "deepseek-v4-pro")
        #expect(capturedBody["max_tokens"] as? Int == 100)
        #expect(capturedBody["messages"] != nil)

        try await server.stop()
        try await stub.stop()
    }
}
