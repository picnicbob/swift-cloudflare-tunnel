import Foundation
import os

// MARK: - CloudflareTunnel

/// Native Swift client for Cloudflare Tunnel.
///
/// Exposes any Swift server (Vapor, Hummingbird, raw NIO, iOS app, macOS daemon)
/// to the internet via Cloudflare Tunnel without running `cloudflared`.
///
/// Supports two modes:
/// 1. **Quick Tunnel**: one-call temporary URL via trycloudflare.com (no account needed)
/// 2. **Named Tunnel**: persistent custom domains via Cloudflare API token
///
/// ## Quick Start
/// ```swift
/// let tunnel = CloudflareTunnel()
/// tunnel.setRequestHandler { request, body in
///     ProxyResponse(statusCode: 200, headers: [], body: Data("Hello".utf8))
/// }
/// let result = try await tunnel.startQuickTunnel()
/// print(result.url) // https://random-words.trycloudflare.com
/// ```
public actor CloudflareTunnel {
    private var domains: [String: DomainStatus] = [:]
    private var connection: TunnelConnection?
    private var tunnelConfig: TunnelConfiguration?
    private var quickTunnelCredentials: TunnelCredentials?
    private let api = CloudflareAPI()
    private var healthCheckTask: Task<Void, Never>?
    private var requestHandler: (@Sendable (IncomingRequest, Data?) async -> ProxyResponse)?
    private var stateCallback: (@Sendable (ConnectionState) -> Void)?
    private let logger: TunnelLogger

    /// Prefix for auto-generated tunnel names. Only used with named tunnels.
    public let tunnelNamePrefix: String

    /// Create a new CloudflareTunnel instance.
    ///
    /// - Parameters:
    ///   - logger: Logger implementation. Defaults to `OSLogTunnelLogger`.
    ///   - tunnelNamePrefix: Prefix for auto-generated tunnel names. Defaults to "swift-tunnel".
    public init(logger: TunnelLogger = OSLogTunnelLogger(), tunnelNamePrefix: String = "swift-tunnel") {
        self.logger = logger
        self.tunnelNamePrefix = tunnelNamePrefix
    }

    // MARK: - Configuration

    /// Load persisted tunnel configuration.
    public func configure(with config: TunnelConfiguration?) {
        self.tunnelConfig = config
    }

    /// Set the handler that processes incoming HTTP requests from the tunnel.
    ///
    /// Your handler receives the parsed request and optional body data,
    /// and returns a ``ProxyResponse`` to send back to the client.
    public func setRequestHandler(
        _ handler: @escaping @Sendable (IncomingRequest, Data?) async -> ProxyResponse
    ) {
        self.requestHandler = handler
    }

    /// Set callback for connection state changes.
    public func setStateCallback(_ callback: @escaping @Sendable (ConnectionState) -> Void) {
        self.stateCallback = callback
    }

    /// Current tunnel configuration.
    public func configuration() -> TunnelConfiguration? {
        tunnelConfig
    }

    // MARK: - Quick Tunnel (No Account Needed)

    /// Start a Quick Tunnel. Gets a temporary trycloudflare.com URL instantly.
    ///
    /// No API token or Cloudflare account required. The URL changes on every restart.
    /// Perfect for development, demos, and testing.
    ///
    /// - Returns: A ``QuickTunnelResult`` with the temporary hostname.
    public func startQuickTunnel() async throws -> QuickTunnelResult {
        logger.info("Creating Quick Tunnel...")

        let credentials = try await api.createQuickTunnel()
        quickTunnelCredentials = credentials

        guard let hostname = credentials.hostname else {
            throw TunnelError.quickTunnelFailed("No hostname returned")
        }

        var info = DomainStatus(domain: hostname, routeIdentifier: "quick-tunnel")
        info.connectionStatus = .connecting
        info.publicURL = "https://\(hostname)"
        domains[hostname] = info

        let conn = try TunnelConnection(logger: logger)
        self.connection = conn

        await conn.setStateCallback { [weak self] state in
            guard let self else { return }
            Task {
                await self.handleConnectionState(state, domain: hostname)
            }
        }

        if let handler = requestHandler {
            await conn.setRequestHandler(handler)
        }

        try await conn.connect(credentials: credentials)

        domains[hostname]?.connectionStatus = .connected
        domains[hostname]?.connectedSince = Date()

        logger.info("Quick Tunnel ready: https://\(hostname)")
        return QuickTunnelResult(hostname: hostname)
    }

    // MARK: - Named Tunnel (Custom Domains)

    /// Set up a Named Tunnel with an API token.
    ///
    /// Creates the tunnel on Cloudflare if one doesn't already exist in the configuration.
    /// The returned ``TunnelConfiguration`` should be persisted by your app.
    ///
    /// - Parameter apiToken: A Cloudflare API token with tunnel permissions.
    /// - Returns: The tunnel configuration to persist.
    public func setup(apiToken: String) async throws -> TunnelConfiguration {
        logger.info("Setting up Named Tunnel...")

        let verification = try await api.verifyToken(apiToken: apiToken)
        guard verification.valid else {
            throw TunnelError.tokenInvalid
        }

        var config = TunnelConfiguration(
            apiToken: apiToken,
            accountId: verification.accountId
        )

        if tunnelConfig?.tunnelId == nil {
            let tunnelName = "\(tunnelNamePrefix)-\(ProcessInfo.processInfo.globallyUniqueString.prefix(8))"
            let credentials = try await api.createNamedTunnel(
                name: tunnelName,
                apiToken: apiToken,
                accountId: verification.accountId
            )
            config.tunnelId = credentials.tunnelID.uuidString.lowercased()
            config.tunnelName = tunnelName
            config.tunnelSecret = credentials.tunnelSecret
            logger.info("Created tunnel: \(tunnelName) (\(config.tunnelId ?? ""))")
        } else {
            config.tunnelId = tunnelConfig?.tunnelId
            config.tunnelName = tunnelConfig?.tunnelName
            config.tunnelSecret = tunnelConfig?.tunnelSecret
            config.domainMappings = tunnelConfig?.domainMappings ?? [:]
        }

        tunnelConfig = config
        return config
    }

    /// Add a custom domain to the Named Tunnel.
    ///
    /// This creates a DNS CNAME record and updates the tunnel ingress rules.
    ///
    /// - Parameters:
    ///   - domain: The domain to add (e.g., "myapp.example.com").
    ///   - routeIdentifier: Opaque identifier your app uses to route requests for this domain.
    ///   - serviceURL: The local service URL for ingress rules. Defaults to the configuration's `defaultServiceURL`.
    public func addDomain(_ domain: String, routeIdentifier: String, serviceURL: String? = nil) async throws {
        guard var config = tunnelConfig, config.hasTunnel else {
            throw TunnelError.notConfigured
        }

        guard let tunnelId = config.tunnelId else {
            throw TunnelError.notConfigured
        }

        let rootDomain = extractRootDomain(domain)
        let zones = try await api.listZones(apiToken: config.apiToken, name: rootDomain)
        guard let zone = zones.first else {
            throw CloudflareAPIError.apiError("Domain '\(rootDomain)' not found in your Cloudflare account. Make sure it's added to Cloudflare.")
        }

        try await api.createDNSRecord(
            domain: domain,
            tunnelId: tunnelId,
            apiToken: config.apiToken,
            zoneId: zone.id
        )

        let records = try await api.listDNSRecords(apiToken: config.apiToken, zoneId: zone.id)
        let recordId = records.first(where: { $0.name == domain })?.id

        let mapping = DomainMapping(
            domain: domain,
            routeIdentifier: routeIdentifier,
            zoneId: zone.id,
            dnsRecordId: recordId,
            serviceURL: serviceURL ?? config.defaultServiceURL
        )
        config.domainMappings[domain] = mapping
        tunnelConfig = config

        try await syncIngressRules()

        var info = DomainStatus(domain: domain, routeIdentifier: routeIdentifier)
        info.connectionStatus = connection != nil ? .connected : .disconnected
        info.publicURL = "https://\(domain)"
        domains[domain] = info

        logger.info("Domain added: \(domain) -> route \(routeIdentifier)")
    }

    /// Remove a custom domain from the Named Tunnel.
    public func removeDomain(_ domain: String) async throws {
        guard var config = tunnelConfig else {
            throw TunnelError.notConfigured
        }

        if let mapping = config.domainMappings[domain] {
            if let recordId = mapping.dnsRecordId {
                do {
                    try await api.deleteDNSRecord(
                        recordId: recordId,
                        apiToken: config.apiToken,
                        zoneId: mapping.zoneId
                    )
                } catch {
                    logger.error("Failed to delete DNS record \(recordId) for \(domain): \(error)")
                }
            }
            config.domainMappings.removeValue(forKey: domain)
            tunnelConfig = config

            do {
                try await syncIngressRules()
            } catch {
                logger.error("Failed to sync ingress rules after removing \(domain): \(error)")
            }
        }

        domains.removeValue(forKey: domain)
        logger.info("Domain removed: \(domain)")
    }

    /// Connect the Named Tunnel to Cloudflare edge.
    ///
    /// Call this on every app launch after restoring your persisted ``TunnelConfiguration``.
    public func connect() async throws {
        guard let config = tunnelConfig,
              let tunnelId = config.tunnelId,
              let tunnelSecret = config.tunnelSecret else {
            throw TunnelError.notConfigured
        }

        guard let uuid = UUID(uuidString: tunnelId) else {
            throw TunnelError.connectionFailed("Invalid tunnel ID")
        }

        let credentials = TunnelCredentials(
            accountTag: config.accountId,
            tunnelSecret: tunnelSecret,
            tunnelID: uuid
        )

        let conn = try TunnelConnection(logger: logger)
        self.connection = conn

        let domainKeys = Array(config.domainMappings.keys)
        await conn.setStateCallback { [weak self] state in
            guard let self else { return }
            Task {
                for domain in domainKeys {
                    await self.handleConnectionState(state, domain: domain)
                }
            }
        }

        if let handler = requestHandler {
            await conn.setRequestHandler(handler)
        }

        try await conn.connect(credentials: credentials)

        for domain in domainKeys {
            domains[domain]?.connectionStatus = .connected
            domains[domain]?.connectedSince = Date()
        }

        logger.info("Named Tunnel connected with \(domainKeys.count) domain(s)")
    }

    // MARK: - Lifecycle

    /// Disconnect a specific domain. If no domains remain, the connection is closed.
    public func disconnect(domain: String) async {
        domains[domain]?.connectionStatus = .disconnected
        domains.removeValue(forKey: domain)

        if domains.isEmpty {
            await connection?.disconnect()
            connection = nil
            quickTunnelCredentials = nil
        }

        logger.info("Tunnel stopped: \(domain)")
    }

    /// Disconnect all tunnels and release resources.
    public func disconnect() async {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        await connection?.disconnect()
        connection = nil
        domains.removeAll()
        quickTunnelCredentials = nil
        logger.info("All tunnels stopped")
    }

    /// Whether the tunnel connection is currently active.
    public func isConnected() async -> Bool {
        if let conn = connection {
            let state = await conn.currentState()
            if case .connected = state { return true }
        }
        return false
    }

    /// Get status of all tunneled domains.
    public func domainStatuses() -> [String: DomainStatus] {
        domains
    }

    /// Get status of a specific domain.
    public func domainStatus(for domain: String) -> DomainStatus? {
        domains[domain]
    }

    // MARK: - Restore

    /// Restore and reconnect tunnels from persisted configuration.
    ///
    /// Call this on app launch after calling ``configure(with:)`` and ``setRequestHandler(_:)``.
    public func restoreFromConfig() async {
        guard let config = tunnelConfig, config.hasTunnel, !config.domainMappings.isEmpty else {
            return
        }

        logger.info("Restoring tunnel with \(config.domainMappings.count) domain(s)")

        for (domain, mapping) in config.domainMappings {
            var info = DomainStatus(domain: domain, routeIdentifier: mapping.routeIdentifier)
            info.connectionStatus = .connecting
            info.publicURL = "https://\(domain)"
            domains[domain] = info
        }

        do {
            try await connect()
        } catch {
            logger.error("Failed to restore tunnel: \(error)")
            for domain in config.domainMappings.keys {
                domains[domain]?.connectionStatus = .error
                domains[domain]?.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Private

    private func handleConnectionState(_ state: ConnectionState, domain: String) {
        switch state {
        case .connecting:
            domains[domain]?.connectionStatus = .connecting
        case .registering:
            domains[domain]?.connectionStatus = .connecting
        case .connected(let location):
            domains[domain]?.connectionStatus = .connected
            domains[domain]?.connectedSince = Date()
            logger.info("[\(domain)] Connected at \(location)")
        case .reconnecting(let attempt):
            domains[domain]?.connectionStatus = .reconnecting
            logger.info("[\(domain)] Reconnecting (attempt \(attempt))")
        case .failed(let error):
            domains[domain]?.connectionStatus = .error
            domains[domain]?.lastError = error.localizedDescription
            logger.error("[\(domain)] Failed: \(error)")
        case .disconnected:
            domains[domain]?.connectionStatus = .disconnected
        }

        // Forward to external callback
        stateCallback?(state)
    }

    private func syncIngressRules() async throws {
        guard let config = tunnelConfig, let tunnelId = config.tunnelId else { return }

        let rules: [IngressRule] = config.domainMappings.values.map { mapping in
            IngressRule(hostname: mapping.domain, service: mapping.serviceURL)
        }

        guard !rules.isEmpty else { return }

        try await api.configureTunnel(
            tunnelId: tunnelId,
            ingress: rules,
            apiToken: config.apiToken,
            accountId: config.accountId
        )
    }

    /// Extract the root domain (e.g., "sub.example.com" -> "example.com").
    private func extractRootDomain(_ domain: String) -> String {
        let parts = domain.split(separator: ".")
        if parts.count > 2 {
            return parts.suffix(2).joined(separator: ".")
        }
        return domain
    }
}
