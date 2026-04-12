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
    private var connections: [UInt8: TunnelConnection] = [:]
    private var connectionStates: [UInt8: ConnectionState] = [:]
    private var tunnelConfig: TunnelConfiguration?
    private var quickTunnelCredentials: TunnelCredentials?
    private let api = CloudflareAPI()
    private var healthCheckTask: Task<Void, Never>?
    private var requestHandler: (@Sendable (IncomingRequest, Data?) async -> ProxyResponse)?
    private var streamHandler: (@Sendable (IncomingRequest) async -> StreamSession)?
    private var stateCallback: (@Sendable (ConnectionState) -> Void)?
    private var originURL: URL?
    private let logger: TunnelLogger

    /// Number of redundant edge connections (matches cloudflared default).
    public nonisolated let connectionCount: UInt8

    /// Prefix for auto-generated tunnel names. Only used with named tunnels.
    public nonisolated let tunnelNamePrefix: String

    /// Create a new CloudflareTunnel instance.
    ///
    /// - Parameters:
    ///   - logger: Logger implementation. Defaults to `OSLogTunnelLogger`.
    ///   - tunnelNamePrefix: Prefix for auto-generated tunnel names. Defaults to "swift-tunnel".
    ///   - connectionCount: Number of edge connections for redundancy. Defaults to 4.
    public init(
        logger: TunnelLogger = OSLogTunnelLogger(),
        tunnelNamePrefix: String = "swift-tunnel",
        connectionCount: UInt8 = 4
    ) {
        self.logger = logger
        self.tunnelNamePrefix = tunnelNamePrefix
        self.connectionCount = connectionCount
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

    /// Set handler for bidirectional streaming connections (WebSocket/TCP).
    ///
    /// When a WebSocket or TCP connection arrives, this handler is called to create
    /// a ``StreamSession`` that manages the bidirectional data relay.
    /// If not set, WebSocket/TCP requests fall through to the regular request handler.
    public func setStreamHandler(
        _ handler: @escaping @Sendable (IncomingRequest) async -> StreamSession
    ) {
        self.streamHandler = handler
    }

    /// Set a local origin server URL for automatic request forwarding.
    ///
    /// When set and no custom request handler is configured, incoming requests are
    /// automatically forwarded to this URL via URLSession. This mimics standard
    /// cloudflared behavior.
    ///
    /// Per-domain routing is supported via ``DomainMapping/serviceURL``.
    /// Custom `requestHandler` takes priority if both are set.
    public func setOriginURL(_ url: String) throws {
        guard let parsed = URL(string: url) else {
            throw TunnelError.connectionFailed("Invalid origin URL: \(url)")
        }
        self.originURL = parsed

        if requestHandler == nil {
            installOriginProxyHandler()
        }
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

        try await createConnections(credentials: credentials, domainKeys: [hostname])

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

        let rootDomain = Self.extractRootDomain(domain)
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
        info.connectionStatus = !connections.isEmpty ? .connected : .disconnected
        info.publicURL = "https://\(domain)"
        domains[domain] = info

        // Re-install origin proxy handler if active (captures updated mappings)
        if originURL != nil && requestHandler != nil {
            installOriginProxyHandler()
        }

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

        let domainKeys = Array(config.domainMappings.keys)
        try await createConnections(credentials: credentials, domainKeys: domainKeys)

        for domain in domainKeys {
            domains[domain]?.connectionStatus = .connected
            domains[domain]?.connectedSince = Date()
        }

        logger.info("Named Tunnel connected with \(domainKeys.count) domain(s)")
    }

    // MARK: - Lifecycle

    /// Disconnect a specific domain. If no domains remain, all connections are closed.
    public func disconnect(domain: String) async {
        domains[domain]?.connectionStatus = .disconnected
        domains.removeValue(forKey: domain)

        if domains.isEmpty {
            for conn in connections.values {
                await conn.disconnect()
            }
            connections.removeAll()
            connectionStates.removeAll()
            quickTunnelCredentials = nil
        }

        logger.info("Tunnel stopped: \(domain)")
    }

    /// Disconnect all tunnels and release resources.
    public func disconnect() async {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        for conn in connections.values {
            await conn.disconnect()
        }
        connections.removeAll()
        connectionStates.removeAll()
        domains.removeAll()
        quickTunnelCredentials = nil
        logger.info("All tunnels stopped")
    }

    /// Whether the tunnel connection is currently active.
    public func isConnected() async -> Bool {
        for conn in connections.values {
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

    // MARK: - Multi-Connection Management

    private func createConnections(credentials: TunnelCredentials, domainKeys: [String]) async throws {
        let edges = try await api.discoverEdgeIPs()
        guard !edges.isEmpty else {
            throw TunnelError.connectionFailed("No edge servers available")
        }

        var firstError: Error?

        for i: UInt8 in 0..<connectionCount {
            let edge = edges[Int(i) % edges.count]

            do {
                let conn = try TunnelConnection(connIndex: i, logger: logger)

                let connIndex = i
                await conn.setStateCallback { [weak self] state in
                    guard let self else { return }
                    Task {
                        await self.handleSingleConnectionState(state, connIndex: connIndex, domainKeys: domainKeys)
                    }
                }

                if let handler = requestHandler {
                    await conn.setRequestHandler(handler)
                }
                if let sHandler = streamHandler {
                    await conn.setStreamHandler(sHandler)
                }

                connections[i] = conn

                try await conn.connect(credentials: credentials, edgeAddress: edge)
                logger.info("Connection \(i) established to \(edge.host)")
            } catch {
                logger.warning("Connection \(i) to \(edge.host) failed: \(error)")
                if firstError == nil { firstError = error }
            }
        }

        // Fail only if ALL connections failed
        if connections.isEmpty, let error = firstError {
            throw error
        }
    }

    private func handleSingleConnectionState(_ state: ConnectionState, connIndex: UInt8, domainKeys: [String]) {
        connectionStates[connIndex] = state

        // Forward individual connection state
        stateCallback?(state)

        // Aggregate: domains are connected if ANY connection is up
        let anyConnected = connectionStates.values.contains {
            if case .connected = $0 { return true }
            return false
        }

        let allFailed = !connectionStates.isEmpty && connectionStates.values.allSatisfy {
            if case .failed = $0 { return true }
            return false
        }

        for domain in domainKeys {
            if anyConnected {
                if domains[domain]?.connectionStatus != .connected {
                    domains[domain]?.connectionStatus = .connected
                    domains[domain]?.connectedSince = Date()
                }
            } else if allFailed {
                domains[domain]?.connectionStatus = .error
                if case .failed(let error) = state {
                    domains[domain]?.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Origin HTTP Proxying

    private func installOriginProxyHandler() {
        let mappings = tunnelConfig?.domainMappings ?? [:]
        let defaultURL = self.originURL

        self.requestHandler = { request, body in
            let origin: URL
            if let mapping = mappings[request.host],
               let url = URL(string: mapping.serviceURL) {
                origin = url
            } else if let defaultURL {
                origin = defaultURL
            } else {
                return ProxyResponse.error("No origin configured for \(request.host)")
            }

            return await Self.proxyToOrigin(request: request, body: body, originURL: origin)
        }
    }

    /// Build the target URL by appending the request path to the origin base path.
    static func buildOriginURL(originURL: URL, dest: String) -> URL? {
        var components = URLComponents(url: originURL, resolvingAgainstBaseURL: false)

        let destParts = dest.split(separator: "?", maxSplits: 1)
        let requestPath = String(destParts[0])
        let basePath = components?.path ?? ""
        let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        let trimmedRequest = requestPath.hasPrefix("/") ? requestPath : "/\(requestPath)"
        components?.path = trimmedBase + trimmedRequest
        if destParts.count > 1 {
            components?.query = String(destParts[1])
        }

        return components?.url
    }

    private static func proxyToOrigin(
        request: IncomingRequest,
        body: Data?,
        originURL: URL
    ) async -> ProxyResponse {
        guard let targetURL = buildOriginURL(originURL: originURL, dest: request.dest) else {
            return ProxyResponse.error("Failed to construct origin URL for \(request.dest)")
        }

        var urlRequest = URLRequest(url: targetURL)
        urlRequest.httpMethod = request.method

        let hopByHopHeaders: Set<String> = [
            "connection", "keep-alive", "proxy-authenticate",
            "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"
        ]
        for (name, value) in request.headers {
            if !hopByHopHeaders.contains(name.lowercased()) {
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
        }

        urlRequest.setValue(originURL.host, forHTTPHeaderField: "Host")
        urlRequest.httpBody = body

        do {
            let (responseData, response) = try await URLSession.shared.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                return ProxyResponse.error("Invalid response from origin")
            }

            var responseHeaders: [(String, String)] = []
            for (key, value) in httpResponse.allHeaderFields {
                if let name = key as? String, let val = value as? String {
                    responseHeaders.append((name, val))
                }
            }

            return ProxyResponse(
                statusCode: httpResponse.statusCode,
                headers: responseHeaders,
                body: responseData
            )
        } catch {
            return ProxyResponse.error("Origin request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

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

    // Common two-part TLDs (country-code second-level domains).
    // Not exhaustive, but covers the most common cases.
    private static let twoPartTLDs: Set<String> = [
        "co.uk", "org.uk", "me.uk", "net.uk", "ac.uk",
        "com.au", "net.au", "org.au", "edu.au",
        "co.nz", "net.nz", "org.nz",
        "co.za", "org.za", "web.za",
        "com.br", "net.br", "org.br",
        "co.in", "net.in", "org.in",
        "co.jp", "or.jp", "ne.jp",
        "co.kr", "or.kr", "ne.kr",
        "com.cn", "net.cn", "org.cn",
        "com.tw", "org.tw", "net.tw",
        "com.hk", "org.hk", "net.hk",
        "com.sg", "org.sg", "net.sg",
        "com.my", "org.my", "net.my",
        "co.id", "or.id", "web.id",
        "co.th", "or.th", "in.th",
        "com.mx", "org.mx", "net.mx",
        "com.ar", "org.ar", "net.ar",
        "co.il", "org.il", "net.il",
        "com.tr", "org.tr", "net.tr",
        "co.ke", "or.ke", "ne.ke",
        "com.ng", "org.ng", "net.ng",
        "com.eg", "org.eg", "net.eg",
        "co.za", "org.za",
        "com.pl", "org.pl", "net.pl",
        "com.ua", "org.ua", "net.ua",
        "com.ph", "org.ph", "net.ph",
    ]

    /// Extract the root domain, handling common two-part TLDs.
    /// "sub.example.com" -> "example.com"
    /// "app.example.co.uk" -> "example.co.uk"
    static func extractRootDomain(_ domain: String) -> String {
        let parts = domain.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return domain }

        // Check if the last two parts form a known two-part TLD
        let lastTwo = parts.suffix(2).joined(separator: ".")
        if twoPartTLDs.contains(lastTwo) {
            // "example.co.uk" (3 parts) is already the root; return as-is
            // "app.example.co.uk" (4+ parts) -> take last 3
            if parts.count <= 3 { return domain }
            return parts.suffix(3).joined(separator: ".")
        }

        return parts.suffix(2).joined(separator: ".")
    }
}
