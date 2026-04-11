import Foundation
import Testing
@testable import CloudflareTunnel

// MARK: - ConnectionStatus Tests

@Suite("ConnectionStatus")
struct ConnectionStatusTests {

    @Test("ConnectionStatus has correct raw values")
    func connectionStatusRawValues() {
        #expect(ConnectionStatus.disconnected.rawValue == "disconnected")
        #expect(ConnectionStatus.connecting.rawValue == "connecting")
        #expect(ConnectionStatus.connected.rawValue == "connected")
        #expect(ConnectionStatus.reconnecting.rawValue == "reconnecting")
        #expect(ConnectionStatus.error.rawValue == "error")
    }
}

// MARK: - DomainStatus Tests

@Suite("DomainStatus")
struct DomainStatusTests {

    @Test("DomainStatus initializes with defaults")
    func domainStatusDefaults() {
        let info = DomainStatus(domain: "example.com", routeIdentifier: "main")

        #expect(info.domain == "example.com")
        #expect(info.routeIdentifier == "main")
        #expect(info.connectionStatus == .disconnected)
        #expect(info.publicURL == nil)
        #expect(info.connectedSince == nil)
        #expect(info.lastError == nil)
        #expect(info.requestsProxied == 0)
        #expect(info.bytesIn == 0)
        #expect(info.bytesOut == 0)
    }

    @Test("DomainStatus can be configured with custom status")
    func domainStatusCustomStatus() {
        let info = DomainStatus(domain: "test.com", routeIdentifier: "api", connectionStatus: .connected)
        #expect(info.connectionStatus == .connected)
    }
}

// MARK: - Error Tests

@Suite("TunnelError")
struct TunnelErrorTests {

    @Test("TunnelError provides localized descriptions")
    func tunnelErrorDescriptions() {
        let errors: [TunnelError] = [
            .notConfigured,
            .connectionFailed("timeout"),
            .tokenInvalid,
            .quickTunnelFailed("rate limited"),
        ]

        for error in errors {
            #expect(error.errorDescription != nil)
        }

        #expect(TunnelError.connectionFailed("timeout").errorDescription?.contains("timeout") == true)
        #expect(TunnelError.quickTunnelFailed("rate limited").errorDescription?.contains("rate limited") == true)
    }
}

@Suite("TunnelConnectionError")
struct TunnelConnectionErrorTests {

    @Test("Error descriptions are non-empty")
    func errorDescriptions() {
        let errors: [TunnelConnectionError] = [
            .noEdgeServers,
            .connectionFailed("timeout"),
            .registrationFailed("auth error"),
            .registrationRejected("duplicate"),
            .notConfigured,
            .noData,
            .maxReconnectAttemptsReached
        ]

        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }
}

@Suite("CloudflareAPIError")
struct CloudflareAPIErrorTests {

    @Test("Error descriptions are non-empty")
    func errorDescriptions() {
        let errors: [CloudflareAPIError] = [
            .requestFailed(statusCode: 403, body: "Forbidden"),
            .apiError("Account not found"),
            .invalidResponse("Missing field"),
            .invalidToken
        ]

        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test("requestFailed includes status code")
    func requestFailedIncludesCode() {
        let error = CloudflareAPIError.requestFailed(statusCode: 401, body: "Unauthorized")
        #expect(error.errorDescription?.contains("401") == true)
    }
}
