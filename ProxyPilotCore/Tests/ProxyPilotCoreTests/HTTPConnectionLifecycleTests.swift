import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import ProxyPilotCore

@Suite struct HTTPConnectionLifecycleTests {
    private func channel() throws -> EmbeddedChannel {
        let channel = EmbeddedChannel(handler: HTTPConnectionLifecycleHandler())
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 4000)).wait()
        return channel
    }

    @Test func sequentialKeepAliveRemainsAvailable() throws {
        let channel = try channel()
        defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
        for _ in 0..<2 {
            try channel.writeInbound(HTTPServerRequestPart.head(.init(version: .http1_1, method: .GET, uri: "/v1/models")))
            try channel.writeInbound(HTTPServerRequestPart.end(nil))
            #expect(channel.isActive)
            let receivedHead = try channel.readInbound(as: HTTPServerRequestPart.self)
            let head = try #require(receivedHead)
            if case .head(let request) = head { #expect(request.uri == "/v1/models") }
            else { Issue.record("request head was not forwarded") }
            _ = try channel.readInbound(as: HTTPServerRequestPart.self)
            try channel.writeOutbound(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok)))
            try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        }
        #expect(channel.isActive)
    }

    @Test func overlappingRequestsCloseWithoutInterleavingResponses() throws {
        let channel = try channel()
        defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
        try channel.writeInbound(HTTPServerRequestPart.head(.init(version: .http1_1, method: .POST, uri: "/v1/messages")))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        try channel.writeInbound(HTTPServerRequestPart.head(.init(version: .http1_1, method: .GET, uri: "/v1/models")))
        #expect(!channel.isActive)
        #expect(try channel.readOutbound(as: HTTPServerResponsePart.self) == nil)
    }

    @Test func connectionCloseFlushesResponseBeforeClosing() throws {
        let channel = try channel()
        defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
        let headers = HTTPHeaders([("Connection", "close")])
        try channel.writeInbound(HTTPServerRequestPart.head(.init(version: .http1_1, method: .GET, uri: "/v1/models", headers: headers)))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        try channel.writeOutbound(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok)))
        try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        let receivedHead = try channel.readOutbound(as: HTTPServerResponsePart.self)
        let part = try #require(receivedHead)
        if case .head(let response) = part { #expect(response.headers.first(name: "Connection") == "close") }
        else { Issue.record("response head was not flushed") }
        let receivedEnd = try channel.readOutbound(as: HTTPServerResponsePart.self)
        let end = try #require(receivedEnd)
        if case .end = end {} else { Issue.record("response end was not flushed") }
        #expect(!channel.isActive)
    }
}
