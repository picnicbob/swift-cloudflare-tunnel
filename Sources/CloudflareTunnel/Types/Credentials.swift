import Foundation

/// Tunnel credentials from Quick Tunnel API or Named Tunnel setup.
///
/// These are `Codable` so you can persist them and reuse tunnels across app launches.
public struct TunnelCredentials: Codable, Sendable {
    public let accountTag: String
    public let tunnelSecret: Data
    public let tunnelID: UUID
    public var hostname: String?

    public init(accountTag: String, tunnelSecret: Data, tunnelID: UUID, hostname: String? = nil) {
        self.accountTag = accountTag
        self.tunnelSecret = tunnelSecret
        self.tunnelID = tunnelID
        self.hostname = hostname
    }
}
