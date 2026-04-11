import Foundation
import Testing
@testable import CloudflareTunnel

// MARK: - TunnelConfiguration Tests

@Suite("TunnelConfiguration")
struct TunnelConfigurationTests {

    @Test("TunnelConfiguration default init")
    func defaultInit() {
        let config = TunnelConfiguration()
        #expect(config.apiToken == "")
        #expect(config.accountId == "")
        #expect(config.tunnelId == nil)
        #expect(config.tunnelName == nil)
        #expect(config.tunnelSecret == nil)
        #expect(config.domainMappings.isEmpty)
        #expect(config.defaultServiceURL == "http://localhost:8080")
    }

    @Test("TunnelConfiguration hasToken")
    func hasToken() {
        var config = TunnelConfiguration()
        #expect(!config.hasToken)

        config.apiToken = "token"
        #expect(!config.hasToken) // needs accountId too

        config.accountId = "account"
        #expect(config.hasToken)
    }

    @Test("TunnelConfiguration hasTunnel")
    func hasTunnel() {
        var config = TunnelConfiguration()
        #expect(!config.hasTunnel)

        config.tunnelId = "some-uuid"
        #expect(config.hasTunnel)
    }

    @Test("TunnelConfiguration is Codable")
    func codableRoundTrip() throws {
        let config = TunnelConfiguration(
            apiToken: "test-token",
            accountId: "acc-123",
            tunnelId: "tunnel-456",
            tunnelName: "swift-tunnel-abc",
            tunnelSecret: Data([1, 2, 3, 4]),
            domainMappings: [
                "example.com": DomainMapping(
                    domain: "example.com",
                    routeIdentifier: "main",
                    zoneId: "zone-789",
                    dnsRecordId: "dns-101",
                    serviceURL: "http://localhost:3000"
                )
            ],
            defaultServiceURL: "http://localhost:8080"
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TunnelConfiguration.self, from: data)

        #expect(decoded.apiToken == "test-token")
        #expect(decoded.accountId == "acc-123")
        #expect(decoded.tunnelId == "tunnel-456")
        #expect(decoded.tunnelName == "swift-tunnel-abc")
        #expect(decoded.tunnelSecret == Data([1, 2, 3, 4]))
        #expect(decoded.defaultServiceURL == "http://localhost:8080")
        #expect(decoded.domainMappings.count == 1)
        #expect(decoded.domainMappings["example.com"]?.routeIdentifier == "main")
        #expect(decoded.domainMappings["example.com"]?.zoneId == "zone-789")
        #expect(decoded.domainMappings["example.com"]?.dnsRecordId == "dns-101")
        #expect(decoded.domainMappings["example.com"]?.serviceURL == "http://localhost:3000")
    }

    @Test("DomainMapping is Codable")
    func domainMappingCodable() throws {
        let mapping = DomainMapping(domain: "test.com", routeIdentifier: "api", zoneId: "z1")
        let data = try JSONEncoder().encode(mapping)
        let decoded = try JSONDecoder().decode(DomainMapping.self, from: data)

        #expect(decoded.domain == "test.com")
        #expect(decoded.routeIdentifier == "api")
        #expect(decoded.zoneId == "z1")
        #expect(decoded.dnsRecordId == nil)
        #expect(decoded.serviceURL == "http://localhost:8080")
    }

    @Test("DomainMapping custom serviceURL")
    func domainMappingCustomServiceURL() {
        let mapping = DomainMapping(
            domain: "app.example.com",
            routeIdentifier: "web",
            zoneId: "z1",
            serviceURL: "http://localhost:3000"
        )
        #expect(mapping.serviceURL == "http://localhost:3000")
    }
}
