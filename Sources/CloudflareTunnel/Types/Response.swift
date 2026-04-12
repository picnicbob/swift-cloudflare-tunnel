import Foundation

/// A response to send back through the Cloudflare Tunnel.
public struct ProxyResponse: Sendable {
    /// HTTP status code.
    public let statusCode: Int

    /// Response headers as name-value pairs.
    public let headers: [(String, String)]

    /// Response body data.
    public let body: Data

    public init(statusCode: Int, headers: [(String, String)], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Convenience: 404 Not Found response.
    public static func notFound() -> ProxyResponse {
        ProxyResponse(statusCode: 404, headers: [("Content-Type", "text/plain")], body: Data("Not Found".utf8))
    }

    /// Convenience: 502 Bad Gateway error response.
    public static func error(_ message: String) -> ProxyResponse {
        ProxyResponse(statusCode: 502, headers: [("Content-Type", "text/plain")], body: Data(message.utf8))
    }
}

// MARK: - Bidirectional Stream Session

/// Manages a bidirectional data relay for WebSocket/TCP connections.
///
/// The handler creates a `StreamSession` to control the relay:
/// - `onData`: called when data arrives from the client
/// - `send(_:)`: sends data back to the client
/// - `close()`: terminates the outbound direction
public final class StreamSession: @unchecked Sendable {
    /// Initial HTTP response to send before the bidirectional relay starts.
    public let initialResponse: ProxyResponse

    private let _onData: @Sendable (Data) async -> Void
    private let _onClose: @Sendable () async -> Void

    /// Outbound data channel consumed by the relay loop.
    internal let outbound: AsyncStream<Data>
    private let outboundContinuation: AsyncStream<Data>.Continuation

    public init(
        initialResponse: ProxyResponse,
        onData: @escaping @Sendable (Data) async -> Void,
        onClose: @escaping @Sendable () async -> Void
    ) {
        self.initialResponse = initialResponse
        self._onData = onData
        self._onClose = onClose
        (self.outbound, self.outboundContinuation) = AsyncStream<Data>.makeStream()
    }

    /// Send data back to the tunnel client (origin -> client direction).
    public func send(_ data: Data) {
        outboundContinuation.yield(data)
    }

    /// Close the outbound direction of the stream.
    public func close() {
        outboundContinuation.finish()
    }

    internal func handleData(_ data: Data) async {
        await _onData(data)
    }

    internal func handleClose() async {
        await _onClose()
        outboundContinuation.finish()
    }
}
