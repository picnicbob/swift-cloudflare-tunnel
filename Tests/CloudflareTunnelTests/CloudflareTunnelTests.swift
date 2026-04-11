import Foundation
import Testing
@testable import CloudflareTunnel

// MARK: - CloudflareTunnel Tests

@Suite("CloudflareTunnel")
struct CloudflareTunnelTests {

    @Test("CloudflareTunnel starts empty")
    func startsEmpty() async {
        let tunnel = CloudflareTunnel()
        let statuses = await tunnel.domainStatuses()
        #expect(statuses.isEmpty)
    }

    @Test("CloudflareTunnel starts not connected")
    func startsDisconnected() async {
        let tunnel = CloudflareTunnel()
        let connected = await tunnel.isConnected()
        #expect(!connected)
    }

    @Test("CloudflareTunnel config is nil by default")
    func configNilByDefault() async {
        let tunnel = CloudflareTunnel()
        let config = await tunnel.configuration()
        #expect(config == nil)
    }

    @Test("Configure with TunnelConfiguration")
    func configureWithConfig() async {
        let tunnel = CloudflareTunnel()
        let cfConfig = TunnelConfiguration(
            apiToken: "test-token",
            accountId: "test-account",
            tunnelId: "test-tunnel-id",
            tunnelName: "swift-tunnel-test"
        )
        await tunnel.configure(with: cfConfig)

        let stored = await tunnel.configuration()
        #expect(stored != nil)
        #expect(stored?.apiToken == "test-token")
        #expect(stored?.accountId == "test-account")
        #expect(stored?.tunnelId == "test-tunnel-id")
        #expect(stored?.tunnelName == "swift-tunnel-test")
    }

    @Test("Disconnect domain removes from statuses")
    func disconnectDomain() async {
        let tunnel = CloudflareTunnel()
        await tunnel.disconnect(domain: "nonexistent.com")
        let statuses = await tunnel.domainStatuses()
        #expect(statuses.isEmpty)
    }

    @Test("Disconnect all clears statuses")
    func disconnectAll() async {
        let tunnel = CloudflareTunnel()
        await tunnel.disconnect()
        let statuses = await tunnel.domainStatuses()
        #expect(statuses.isEmpty)
    }

    @Test("Custom tunnel name prefix")
    func customTunnelNamePrefix() async {
        let tunnel = CloudflareTunnel(tunnelNamePrefix: "my-app")
        #expect(await tunnel.tunnelNamePrefix == "my-app")
    }

    @Test("Custom logger is accepted")
    func customLogger() async {
        let logger = TestLogger()
        let tunnel = CloudflareTunnel(logger: logger)
        // Just verify it compiles and can be constructed
        let config = await tunnel.configuration()
        #expect(config == nil)
    }
}

// MARK: - ProxyResponse Tests

@Suite("ProxyResponse")
struct ProxyResponseTests {

    @Test("ProxyResponse notFound convenience")
    func notFound() {
        let response = ProxyResponse.notFound()
        #expect(response.statusCode == 404)
        #expect(!response.body.isEmpty)
    }

    @Test("ProxyResponse error convenience")
    func errorResponse() {
        let response = ProxyResponse.error("Something broke")
        #expect(response.statusCode == 502)
        #expect(String(data: response.body, encoding: .utf8) == "Something broke")
    }
}

// MARK: - QuickTunnelResult Tests

@Suite("QuickTunnelResult")
struct QuickTunnelResultTests {

    @Test("QuickTunnelResult generates correct URL")
    func urlGeneration() {
        let result = QuickTunnelResult(hostname: "abc-def.trycloudflare.com")
        #expect(result.url == "https://abc-def.trycloudflare.com")
    }
}

// MARK: - Test Helpers

final class TestLogger: TunnelLogger, @unchecked Sendable {
    var messages: [String] = []

    func info(_ message: String) { messages.append("[INFO] \(message)") }
    func error(_ message: String) { messages.append("[ERROR] \(message)") }
    func debug(_ message: String) { messages.append("[DEBUG] \(message)") }
    func warning(_ message: String) { messages.append("[WARN] \(message)") }
}
