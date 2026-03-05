import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOConcurrencyHelpers

/// A SwiftNIO-based HTTP proxy server.
public final class NIOProxyServer: Sendable {

    private let serverChannel: NIOLockedValueBox<Channel?>
    private let group: MultiThreadedEventLoopGroup

    public init() {
        self.serverChannel = NIOLockedValueBox(nil)
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    /// Starts the proxy server and returns the actual bound port.
    /// Pass `config.port == 0` to let the OS pick a free port.
    @discardableResult
    public func start(config: ProxyConfiguration) async throws -> UInt16 {
        guard serverChannel.withLockedValue({ $0 }) == nil else {
            throw ProxyEngineError.alreadyRunning
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(config: config))
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 16)
            .childChannelOption(.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let channel: Channel
        do {
            channel = try await bootstrap.bind(host: config.host, port: Int(config.port)).get()
        } catch {
            throw ProxyEngineError.bindFailed
        }

        serverChannel.withLockedValue { $0 = channel }

        guard let localAddress = channel.localAddress, let port = localAddress.port else {
            throw ProxyEngineError.bindFailed
        }

        return UInt16(port)
    }

    /// Gracefully shuts down the server.
    public func stop() async throws {
        guard let channel = serverChannel.withLockedValue({ ch -> Channel? in
            let current = ch
            ch = nil
            return current
        }) else {
            throw ProxyEngineError.notRunning
        }

        try await channel.close()
        try await group.shutdownGracefully()
    }
}
