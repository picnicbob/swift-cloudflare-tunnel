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
        #expect(tunnel.tunnelNamePrefix == "my-app")
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

// MARK: - StreamSession Tests

@Suite("StreamSession")
struct StreamSessionTests {

    @Test("StreamSession sends data via outbound stream")
    func outboundDataFlow() async {
        let session = StreamSession(
            initialResponse: ProxyResponse(statusCode: 101, headers: [], body: Data()),
            onData: { _ in },
            onClose: { }
        )

        session.send(Data("hello".utf8))
        session.send(Data("world".utf8))
        session.close()

        var received: [Data] = []
        for await data in session.outbound {
            received.append(data)
        }

        #expect(received.count == 2)
        #expect(String(data: received[0], encoding: .utf8) == "hello")
        #expect(String(data: received[1], encoding: .utf8) == "world")
    }

    @Test("StreamSession initial response is preserved")
    func initialResponse() {
        let response = ProxyResponse(statusCode: 101, headers: [("Upgrade", "websocket")], body: Data())
        let session = StreamSession(
            initialResponse: response,
            onData: { _ in },
            onClose: { }
        )

        #expect(session.initialResponse.statusCode == 101)
        #expect(session.initialResponse.headers.first?.0 == "Upgrade")
    }

    @Test("StreamSession handleData calls onData callback")
    func handleDataCallback() async {
        let received = LockIsolated<Data?>(nil)
        let session = StreamSession(
            initialResponse: ProxyResponse(statusCode: 200, headers: [], body: Data()),
            onData: { data in received.setValue(data) },
            onClose: { }
        )

        await session.handleData(Data("test".utf8))
        #expect(received.value != nil)
        #expect(String(data: received.value!, encoding: .utf8) == "test")
    }
}

// MARK: - Connection Multiplexing Tests

@Suite("ConnectionMultiplexing")
struct ConnectionMultiplexingTests {

    @Test("CloudflareTunnel supports custom connection count")
    func customConnectionCount() async {
        let tunnel = CloudflareTunnel(connectionCount: 2)
        #expect(tunnel.connectionCount == 2)
    }

    @Test("Default connection count is 4")
    func defaultConnectionCount() async {
        let tunnel = CloudflareTunnel()
        #expect(tunnel.connectionCount == 4)
    }
}

// MARK: - Origin Proxy Tests

@Suite("OriginProxy")
struct OriginProxyTests {

    @Test("setOriginURL rejects invalid URLs")
    func invalidOriginURL() async {
        let tunnel = CloudflareTunnel()
        do {
            try await tunnel.setOriginURL("")
            #expect(Bool(false), "Should have thrown")
        } catch {
            // Expected
        }
    }

    @Test("setOriginURL accepts valid URLs")
    func validOriginURL() async throws {
        let tunnel = CloudflareTunnel()
        try await tunnel.setOriginURL("http://localhost:8080")
    }
}

// MARK: - Test Helpers

final class LockIsolated<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSLock()

    init(_ value: Value) { self._value = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func setValue(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        _value = newValue
    }
}

final class TestLogger: TunnelLogger, @unchecked Sendable {
    var messages: [String] = []

    func info(_ message: String) { messages.append("[INFO] \(message)") }
    func error(_ message: String) { messages.append("[ERROR] \(message)") }
    func debug(_ message: String) { messages.append("[DEBUG] \(message)") }
    func warning(_ message: String) { messages.append("[WARN] \(message)") }
}
