import Foundation

/// Cloudflare tunnel configuration. Persist this (it's Codable) to reuse tunnels across launches.
public struct TunnelConfiguration: Codable, Sendable {
    public var apiToken: String
    public var accountId: String
    public var tunnelId: String?
    public var tunnelName: String?
    public var tunnelSecret: Data?
    public var domainMappings: [String: DomainMapping]
    /// Default service URL for ingress rules when a domain mapping doesn't specify one.
    public var defaultServiceURL: String

    public init(
        apiToken: String = "",
        accountId: String = "",
        tunnelId: String? = nil,
        tunnelName: String? = nil,
        tunnelSecret: Data? = nil,
        domainMappings: [String: DomainMapping] = [:],
        defaultServiceURL: String = "http://localhost:8080"
    ) {
        self.apiToken = apiToken
        self.accountId = accountId
        self.tunnelId = tunnelId
        self.tunnelName = tunnelName
        self.tunnelSecret = tunnelSecret
        self.domainMappings = domainMappings
        self.defaultServiceURL = defaultServiceURL
    }

    /// Whether the token and account ID are set.
    public var hasToken: Bool { !apiToken.isEmpty && !accountId.isEmpty }

    /// Whether a tunnel ID is configured.
    public var hasTunnel: Bool { tunnelId != nil }
}

/// Maps a domain to a route identifier and service URL for ingress rules.
public struct DomainMapping: Codable, Sendable {
    public let domain: String
    /// Opaque identifier the caller uses to route requests. The library stores it but never interprets it.
    public let routeIdentifier: String
    public let zoneId: String
    public var dnsRecordId: String?
    /// The local service URL for ingress rules.
    public var serviceURL: String

    public init(
        domain: String,
        routeIdentifier: String,
        zoneId: String,
        dnsRecordId: String? = nil,
        serviceURL: String = "http://localhost:8080"
    ) {
        self.domain = domain
        self.routeIdentifier = routeIdentifier
        self.zoneId = zoneId
        self.dnsRecordId = dnsRecordId
        self.serviceURL = serviceURL
    }
}

/// A Cloudflare tunnel ingress rule.
public struct IngressRule: Codable, Sendable {
    public let hostname: String?
    public let path: String?
    public let service: String

    public init(hostname: String?, path: String? = nil, service: String) {
        self.hostname = hostname
        self.path = path
        self.service = service
    }
}

/// A Cloudflare DNS zone.
public struct CloudflareZone: Codable, Sendable {
    public let id: String
    public let name: String
    public let status: String
}

/// A Cloudflare DNS record.
public struct DNSRecord: Codable, Sendable {
    public let id: String
    public let type: String
    public let name: String
    public let content: String
}

/// Result of API token verification.
public struct TokenVerification: Sendable {
    public let valid: Bool
    public let accountId: String
}

/// A Cloudflare edge server address.
public struct EdgeAddress: Sendable {
    public let host: String
    public let port: UInt16
}
