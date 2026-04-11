import Foundation

/// An incoming HTTP request received through the Cloudflare Tunnel.
public struct IncomingRequest: Sendable {
    /// The connection type for the tunneled request.
    public enum ConnectionType: Sendable {
        case http
        case websocket
        case tcp
    }

    /// The destination path (e.g., "/api/users").
    public let dest: String

    /// The type of connection (HTTP, WebSocket, or TCP).
    public let connectionType: ConnectionType

    /// The HTTP method (GET, POST, etc.).
    public let method: String

    /// The Host header value.
    public let host: String

    /// HTTP headers as name-value pairs.
    public let headers: [(String, String)]

    /// Raw Cloudflare metadata key-value pairs.
    public let rawMetadata: [(String, String)]

    public init(
        dest: String,
        connectionType: ConnectionType,
        method: String,
        host: String,
        headers: [(String, String)],
        rawMetadata: [(String, String)]
    ) {
        self.dest = dest
        self.connectionType = connectionType
        self.method = method
        self.host = host
        self.headers = headers
        self.rawMetadata = rawMetadata
    }
}
