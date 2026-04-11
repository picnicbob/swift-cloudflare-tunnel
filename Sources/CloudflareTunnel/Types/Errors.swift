import Foundation

// MARK: - Tunnel Errors

/// High-level tunnel operation errors.
public enum TunnelError: Error, LocalizedError {
    case notConfigured
    case connectionFailed(String)
    case tokenInvalid
    case quickTunnelFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Tunnel not configured"
        case .connectionFailed(let msg): return "Tunnel connection failed: \(msg)"
        case .tokenInvalid: return "Invalid tunnel token"
        case .quickTunnelFailed(let msg): return "Quick Tunnel failed: \(msg)"
        }
    }
}

// MARK: - Connection Errors

/// QUIC connection and registration errors.
public enum TunnelConnectionError: Error, LocalizedError {
    case noEdgeServers
    case connectionFailed(String)
    case registrationFailed(String)
    case registrationRejected(String)
    case notConfigured
    case noData
    case maxReconnectAttemptsReached

    public var errorDescription: String? {
        switch self {
        case .noEdgeServers: return "No Cloudflare edge servers found"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .registrationFailed(let msg): return "Registration failed: \(msg)"
        case .registrationRejected(let msg): return "Registration rejected: \(msg)"
        case .notConfigured: return "Tunnel not configured"
        case .noData: return "No data received"
        case .maxReconnectAttemptsReached: return "Max reconnection attempts reached"
        }
    }
}

// MARK: - API Errors

/// Cloudflare REST API errors.
public enum CloudflareAPIError: Error, LocalizedError {
    case requestFailed(statusCode: Int, body: String)
    case apiError(String)
    case invalidResponse(String)
    case invalidToken

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let code, let body):
            return "Cloudflare API request failed (\(code)): \(body.prefix(200))"
        case .apiError(let msg):
            return "Cloudflare API error: \(msg)"
        case .invalidResponse(let msg):
            return "Invalid response: \(msg)"
        case .invalidToken:
            return "Invalid or expired API token"
        }
    }
}
