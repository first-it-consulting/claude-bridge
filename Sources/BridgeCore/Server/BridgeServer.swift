import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// The local HTTP server Claude Desktop points at.
///
/// Bound to loopback only: this speaks for whatever credentials the user has
/// configured, so it must not be reachable from the network.
public actor BridgeServer {

    public enum ServerError: LocalizedError {
        case portInUse(UInt16)
        case bindFailed(String)

        public var errorDescription: String? {
            switch self {
            case .portInUse(let port):
                return "Port \(port) is already in use. Pick another port in Settings."
            case .bindFailed(let detail):
                return "Could not start the bridge: \(detail)"
            }
        }
    }

    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    private let router: BridgeRouter

    public private(set) var port: UInt16?

    public init(router: BridgeRouter) {
        self.router = router
        // Two threads is plenty: the work is one long-lived streamed request at
        // a time, and all of it is I/O.
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    public var isRunning: Bool { channel != nil }

    public func start(port requestedPort: UInt16) async throws {
        try await stop()

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(BridgeChannelHandler(router: self.router))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)

        do {
            let ch = try await bootstrap.bind(host: "127.0.0.1", port: Int(requestedPort)).get()
            channel = ch
            port = requestedPort
        } catch let error as IOError where error.errnoCode == EADDRINUSE {
            throw ServerError.portInUse(requestedPort)
        } catch {
            throw ServerError.bindFailed(error.localizedDescription)
        }
    }

    public func stop() async throws {
        guard let channel else { return }
        self.channel = nil
        self.port = nil
        try? await channel.close().get()
    }

    /// Frees the event-loop threads. The server cannot be restarted afterwards.
    public func shutdown() async {
        try? await stop()
        try? await group.shutdownGracefully()
    }

    /// Whether something is already listening, so the UI can say so before the
    /// bind fails.
    public static func isPortAvailable(_ port: UInt16) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }
}

/// Collects one HTTP request, hands it to the router, and streams the response
/// back out.
final class BridgeChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: BridgeRouter
    private var head: HTTPRequestHead?
    private var body: ByteBuffer?
    private var keepAlive = true

    init(router: BridgeRouter) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            self.keepAlive = head.isKeepAlive
            self.body = context.channel.allocator.buffer(capacity: 0)

        case .body(var chunk):
            body?.writeBuffer(&chunk)

        case .end:
            guard let head else { return }
            let bodyData = body.map { Data($0.readableBytesView) } ?? Data()
            self.head = nil
            self.body = nil

            let request = BridgeRequest(
                method: head.method.rawValue,
                path: head.uri,
                headers: Dictionary(head.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last }),
                body: bodyData
            )
            let sink = ChannelResponseSink(
                channel: context.channel,
                keepAlive: keepAlive,
                version: head.version
            )
            Task { await router.handle(request, sink: sink) }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Writes a response onto a NIO channel from Swift Concurrency.
///
/// Every write hops to the channel's event loop, because NIO channels are not
/// safe to touch from an arbitrary task.
struct ChannelResponseSink: ResponseSink, @unchecked Sendable {
    let channel: Channel
    let keepAlive: Bool
    let version: HTTPVersion

    func begin(status: Int, headers: [(String, String)]) async {
        var httpHeaders = HTTPHeaders()
        for (name, value) in headers { httpHeaders.add(name: name, value: value) }
        if httpHeaders["content-length"].isEmpty {
            // Streamed responses have no known length; chunked framing lets the
            // connection stay open for the next request.
            httpHeaders.add(name: "Transfer-Encoding", value: "chunked")
        }
        httpHeaders.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")

        let head = HTTPResponseHead(
            version: version,
            status: HTTPResponseStatus(statusCode: status),
            headers: httpHeaders
        )
        // Must flush: NIO only fulfils a write's promise once the bytes leave
        // the pipeline, so awaiting an unflushed write deadlocks.
        await write(.head(head), flush: true)
    }

    func write(_ text: String) async {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        await write(.body(.byteBuffer(buffer)), flush: true)
    }

    func finish() async {
        await write(.end(nil), flush: true)
        if !keepAlive {
            try? await channel.close().get()
        }
    }

    private func write(_ part: HTTPServerResponsePart, flush: Bool = true) async {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.eventLoop.execute {
            channel.write(NIOAny(part), promise: promise)
            if flush { channel.flush() }
        }
        // A failed write means the client hung up; the upstream task notices
        // when it next tries to write and stops there.
        try? await promise.futureResult.get()
    }
}
