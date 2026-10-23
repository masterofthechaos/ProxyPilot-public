import NIOCore
import NIOHTTP1

/// Keep transport reads active while upstream work is outstanding so EOF can
/// cancel that work. Serial keep-alive is supported; overlapping HTTP/1 requests
/// close the channel rather than starting work with ambiguous response ordering.
/// This replaces NIO's pipelining assistance, which suppresses socket reads
/// until the response ends and therefore cannot promptly observe disconnects.
// Mutable state is confined to the installed channel's EventLoop.
final class HTTPConnectionLifecycleHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    private var awaitingResponse = false
    private var closeAfterResponse = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let head) = unwrapInboundIn(data) {
            guard !awaitingResponse else {
                context.close(promise: nil)
                return
            }
            awaitingResponse = true
            closeAfterResponse = !head.isKeepAlive
        }
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch unwrapOutboundIn(data) {
        case .head(var head) where closeAfterResponse:
            head.headers.replaceOrAdd(name: "Connection", value: "close")
            context.write(wrapOutboundOut(.head(head)), promise: promise)
        case .end:
            awaitingResponse = false
            if closeAfterResponse {
                let completion = context.eventLoop.makePromise(of: Void.self)
                let channel = context.channel
                completion.futureResult.whenComplete { _ in channel.close(promise: nil) }
                if let promise { completion.futureResult.cascade(to: promise) }
                context.write(data, promise: completion)
            } else {
                context.write(data, promise: promise)
            }
        default:
            context.write(data, promise: promise)
        }
    }
}
