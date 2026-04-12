import Foundation

// MARK: - Cloudflare API Client

/// REST API client for Cloudflare Tunnel management.
public actor CloudflareAPI {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Quick Tunnel

    /// Create a Quick Tunnel (no account needed).
    /// Returns credentials and a temporary trycloudflare.com hostname.
    public func createQuickTunnel() async throws -> TunnelCredentials {
        let url = URL(string: "https://api.trycloudflare.com/tunnel")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("swift-cloudflare-tunnel/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudflareAPIError.requestFailed(statusCode: statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(QuickTunnelAPIResponse.self, from: data)
        guard decoded.success, let result = decoded.result else {
            let errorMsg = decoded.errors?.first?.message ?? "Unknown error"
            throw CloudflareAPIError.apiError(errorMsg)
        }

        guard let tunnelID = UUID(uuidString: result.id) else {
            throw CloudflareAPIError.invalidResponse("Invalid tunnel ID: \(result.id)")
        }

        return TunnelCredentials(
            accountTag: result.accountTag,
            tunnelSecret: Data(result.secret),
            tunnelID: tunnelID,
            hostname: result.hostname
        )
    }

    // MARK: - Named Tunnel Management

    /// Create a named tunnel (requires API token).
    public func createNamedTunnel(
        name: String,
        apiToken: String,
        accountId: String
    ) async throws -> TunnelCredentials {
        let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountId)/cfd_tunnel")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        var secretBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &secretBytes) == errSecSuccess else {
            throw CloudflareAPIError.apiError("Failed to generate secure random tunnel secret")
        }
        let secretBase64 = Data(secretBytes).base64EncodedString()

        let body: [String: Any] = [
            "name": name,
            "tunnel_secret": secretBase64,
            "config_src": "cloudflare"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let result: CFAPITunnelResult = try decodeResponse(data: data, response: response)

        guard let tunnelID = UUID(uuidString: result.id) else {
            throw CloudflareAPIError.invalidResponse("Invalid tunnel ID")
        }

        return TunnelCredentials(
            accountTag: result.accountTag ?? accountId,
            tunnelSecret: Data(secretBytes),
            tunnelID: tunnelID,
            hostname: nil
        )
    }

    /// Configure tunnel ingress rules.
    public func configureTunnel(
        tunnelId: String,
        ingress: [IngressRule],
        apiToken: String,
        accountId: String
    ) async throws {
        let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountId)/cfd_tunnel/\(tunnelId)/configurations")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        var ingressJSON: [[String: Any]] = ingress.map { rule in
            var entry: [String: Any] = ["service": rule.service]
            if let hostname = rule.hostname {
                entry["hostname"] = hostname
            }
            if let path = rule.path {
                entry["path"] = path
            }
            return entry
        }
        // Always add catch-all rule
        ingressJSON.append(["service": "http_status:404"])

        let body: [String: Any] = [
            "config": ["ingress": ingressJSON]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateResponse(data: data, response: response)
    }

    /// Create a DNS CNAME record pointing a domain to the tunnel.
    public func createDNSRecord(
        domain: String,
        tunnelId: String,
        apiToken: String,
        zoneId: String
    ) async throws {
        let url = URL(string: "https://api.cloudflare.com/client/v4/zones/\(zoneId)/dns_records")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "type": "CNAME",
            "name": domain,
            "content": "\(tunnelId).cfargotunnel.com",
            "proxied": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateResponse(data: data, response: response)
    }

    /// Delete a DNS record.
    public func deleteDNSRecord(
        recordId: String,
        apiToken: String,
        zoneId: String
    ) async throws {
        let url = URL(string: "https://api.cloudflare.com/client/v4/zones/\(zoneId)/dns_records/\(recordId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateResponse(data: data, response: response)
    }

    /// List DNS records for a zone to find existing tunnel CNAMEs.
    public func listDNSRecords(
        apiToken: String,
        zoneId: String,
        type: String = "CNAME"
    ) async throws -> [DNSRecord] {
        let url = URL(string: "https://api.cloudflare.com/client/v4/zones/\(zoneId)/dns_records?type=\(type)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let result: DNSListResponse = try decodeAPIResponse(data: data, response: response)
        return result.result ?? []
    }

    /// Delete a tunnel.
    public func deleteTunnel(
        tunnelId: String,
        apiToken: String,
        accountId: String
    ) async throws {
        let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountId)/cfd_tunnel/\(tunnelId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateResponse(data: data, response: response)
    }

    /// List zones to find zone IDs for domains.
    public func listZones(
        apiToken: String,
        name: String? = nil
    ) async throws -> [CloudflareZone] {
        var components = URLComponents(string: "https://api.cloudflare.com/client/v4/zones")!
        if let name {
            components.queryItems = [URLQueryItem(name: "name", value: name)]
        }
        guard let url = components.url else {
            throw CloudflareAPIError.invalidResponse("Failed to construct zones URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let result: ZoneListResponse = try decodeAPIResponse(data: data, response: response)
        return result.result ?? []
    }

    /// Verify API token is valid and get account info.
    public func verifyToken(apiToken: String) async throws -> TokenVerification {
        let url = URL(string: "https://api.cloudflare.com/client/v4/user/tokens/verify")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (_, verifyResponse) = try await session.data(for: request)
        guard let httpResponse = verifyResponse as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CloudflareAPIError.invalidToken
        }

        let accountUrl = URL(string: "https://api.cloudflare.com/client/v4/accounts")!
        var accountRequest = URLRequest(url: accountUrl)
        accountRequest.httpMethod = "GET"
        accountRequest.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (accountData, accountResponse) = try await session.data(for: accountRequest)
        let accountResult: AccountListResponse = try decodeAPIResponse(data: accountData, response: accountResponse)
        guard let accountId = accountResult.result?.first?.id, !accountId.isEmpty else {
            throw CloudflareAPIError.apiError("No Cloudflare account found for this API token. Ensure the token has account-level permissions.")
        }

        return TokenVerification(valid: true, accountId: accountId)
    }

    // MARK: - Edge Discovery

    private static let srvName = "_v2-origintunneld._tcp.argotunnel.com"
    private static let fallbackAddresses: [EdgeAddress] = [
        EdgeAddress(host: "region1.v2.argotunnel.com", port: 7844),
        EdgeAddress(host: "region2.v2.argotunnel.com", port: 7844),
    ]

    /// Discover Cloudflare edge servers via DNS SRV lookup with static fallback.
    ///
    /// Uses DNS-over-HTTPS to resolve SRV records for `_v2-origintunneld._tcp.argotunnel.com`.
    /// Falls back to hardcoded region hostnames if the lookup fails.
    public func discoverEdgeIPs() async throws -> [EdgeAddress] {
        do {
            let srvResults = try await resolveSRV(name: Self.srvName)
            if !srvResults.isEmpty {
                return srvResults
            }
        } catch {
            // SRV lookup failed; fall through to static addresses
        }
        return Self.fallbackAddresses
    }

    /// Resolve DNS SRV records using DNS-over-HTTPS (Google Public DNS).
    private func resolveSRV(name: String) async throws -> [EdgeAddress] {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://dns.google/resolve?name=\(encoded)&type=SRV") else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return []
        }

        let dnsResponse = try JSONDecoder().decode(DoHResponse.self, from: data)
        guard dnsResponse.Status == 0, let answers = dnsResponse.Answer else {
            return []
        }

        var addresses: [EdgeAddress] = []
        for answer in answers where answer.type == 33 { // SRV record type
            // SRV data format: "priority weight port target"
            let parts = answer.data.split(separator: " ")
            guard parts.count >= 4,
                  let port = UInt16(parts[2]) else { continue }
            let target = String(parts[3]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            addresses.append(EdgeAddress(host: target, port: port))
        }

        // Sort by priority (lower = preferred), then shuffle within same priority
        addresses.sort { a, _ in a.port == 7844 }
        return addresses
    }

    // MARK: - Private Helpers

    private func decodeResponse<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudflareAPIError.requestFailed(statusCode: 0, body: "No HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudflareAPIError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func decodeAPIResponse<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudflareAPIError.requestFailed(statusCode: 0, body: "No HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudflareAPIError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func validateResponse(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudflareAPIError.requestFailed(statusCode: 0, body: "No HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudflareAPIError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }
    }
}

// MARK: - Private API Response Types

private struct QuickTunnelAPIResponse: Decodable {
    let success: Bool
    let result: QuickTunnelResult?
    let errors: [QuickTunnelAPIError]?

    struct QuickTunnelResult: Decodable {
        let id: String
        let name: String
        let hostname: String
        let accountTag: String
        let secret: [UInt8]

        enum CodingKeys: String, CodingKey {
            case id, name, hostname
            case accountTag = "account_tag"
            case secret
        }
    }

    struct QuickTunnelAPIError: Decodable {
        let message: String
    }
}

private struct CFAPITunnelResult: Decodable {
    let id: String
    let name: String
    let accountTag: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case accountTag = "account_tag"
    }
}

private struct AccountListResponse: Decodable {
    let result: [AccountInfo]?

    struct AccountInfo: Decodable {
        let id: String
        let name: String
    }
}

private struct ZoneListResponse: Decodable {
    let result: [CloudflareZone]?
}

private struct DNSListResponse: Decodable {
    let result: [DNSRecord]?
}

// DNS-over-HTTPS response (Google Public DNS JSON API)
private struct DoHResponse: Decodable {
    let Status: Int
    let Answer: [DoHAnswer]?
}

private struct DoHAnswer: Decodable {
    let type: Int
    let data: String
}
