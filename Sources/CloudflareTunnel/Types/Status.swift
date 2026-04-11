import Foundation

// MARK: - Connection Status

/// Simple connection status for domain tracking and persistence.
public enum ConnectionStatus: String, Codable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error
}

// MARK: - Connection State

/// Detailed connection state with associated values.
/// Used for state observation callbacks from ``CloudflareTunnel/setStateCallback(_:)``.
public enum ConnectionState: Sendable {
    case disconnected
    case connecting
    case registering
    case connected(location: String)
    case reconnecting(attempt: Int)
    case failed(Error)
}

// MARK: - Domain Status

/// Status information for a single tunneled domain.
public struct DomainStatus: Sendable {
    public let domain: String
    /// Opaque identifier provided by the caller for request routing.
    public let routeIdentifier: String
    public var connectionStatus: ConnectionStatus
    public var publicURL: String?
    public var connectedSince: Date?
    public var lastError: String?
    public var requestsProxied: Int
    public var bytesIn: UInt64
    public var bytesOut: UInt64

    public init(
        domain: String,
        routeIdentifier: String,
        connectionStatus: ConnectionStatus = .disconnected
    ) {
        self.domain = domain
        self.routeIdentifier = routeIdentifier
        self.connectionStatus = connectionStatus
        self.publicURL = nil
        self.connectedSince = nil
        self.lastError = nil
        self.requestsProxied = 0
        self.bytesIn = 0
        self.bytesOut = 0
    }
}

// MARK: - Quick Tunnel Result

/// Result from starting a Quick Tunnel.
public struct QuickTunnelResult: Sendable {
    /// The temporary trycloudflare.com hostname.
    public let hostname: String

    /// Full public URL including the https:// scheme.
    public var url: String { "https://\(hostname)" }
}

// MARK: - Internal Registration Types

struct ConnectionRegistrationResult: Sendable {
    let uuid: Data
    let locationName: String
    let tunnelIsRemotelyManaged: Bool
}

enum ConnectionResult: Sendable {
    case success(ConnectionRegistrationResult)
    case registrationError(cause: String, retryAfter: Int64, shouldRetry: Bool)
    case error(String)
}
