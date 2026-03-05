import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOConcurrencyHelpers
@testable import ProxyPilotCore

/// A tiny HTTP server that returns a fixed status code for any request.
/// Used as a fake upstream in tests so we don't depend on real network timeouts.
private final class StubUpstream: Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let channel: NIOLockedValueBox<Channel?> = NIOLockedValueBox(nil)

    /// Starts the stub and returns the bound port.
    func start(statusCode: Int = 500, body: String = "{\"error\":\"stub\"}") async throws -> UInt16 {
        let sc = statusCode
        let b = body
        let ch = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(StubHandler(statusCode: sc, body: b))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        channel.withLockedValue { $0 = ch }
        return UInt16(ch.localAddress!.port!)
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

    init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        guard case .end = part else { return }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
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
            body: "{\"id\":\"chatcmpl-test\",\"choices\":[{\"message\":{\"content\":\"hello\"}}]}"
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
        let stubPort = try await stub.start(statusCode: 200, body: stubBody)

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

        try await server.stop()
        try await stub.stop()
    }

    @Test func streamingRequestReturns502WhenUpstreamErrors() async throws {
        // Start a stub upstream that returns 500 (even for streaming requests,
        // the upstream failing should result in the proxy returning an error)
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
            "stream": true,
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        // Streaming path: upstream 500 → UpstreamClient throws httpError → proxy returns 502
        #expect(httpResponse.statusCode == 502)

        try await server.stop()
        try await stub.stop()
    }
}
