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
