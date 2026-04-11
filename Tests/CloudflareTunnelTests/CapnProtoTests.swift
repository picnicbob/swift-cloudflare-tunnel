import Foundation
import Testing
@testable import CloudflareTunnel

// MARK: - Cap'n Proto Tests

@Suite("CapnProto")
struct CapnProtoTests {

    @Test("CapnProtoMessage builds valid message")
    func messageBuilder() {
        var msg = CapnProtoMessage()
        let _ = msg.allocate(words: 2)
        let data = msg.serialize()

        // Header (8 bytes) + 2 words (16 bytes) = 24 bytes
        #expect(data.count == 24)
        #expect(data.count % 8 == 0)
    }

    @Test("TunnelRPCBuilder builds Bootstrap message")
    func bootstrapMessage() {
        let msg = TunnelRPCBuilder.buildBootstrap(questionId: 0)
        #expect(msg.count > 0)
        #expect(msg.count % 8 == 0)
    }

    @Test("TunnelRPCBuilder builds RegisterConnection message")
    func registerConnectionMessage() {
        let credentials = TunnelCredentials(
            accountTag: "test-account",
            tunnelSecret: Data(repeating: 0xAB, count: 32),
            tunnelID: UUID()
        )

        let msg = TunnelRPCBuilder.buildRegisterConnection(
            questionId: 1,
            credentials: credentials,
            connIndex: 0,
            clientId: Data(repeating: 0x01, count: 16),
            features: ["serialized_headers"],
            version: "2024.1.0",
            arch: "darwin_arm64"
        )

        #expect(msg.count > 0)
        #expect(msg.count % 8 == 0)
    }

    @Test("TunnelRPCBuilder builds Finish message")
    func finishMessage() {
        let msg = TunnelRPCBuilder.buildFinish(questionId: 0)
        #expect(msg.count > 0)
        #expect(msg.count % 8 == 0)
    }

    @Test("CapnProtoReader can parse a Bootstrap message")
    func readerCanParse() throws {
        let bootstrapData = TunnelRPCBuilder.buildBootstrap(questionId: 0)
        let reader = try CapnProtoReader(data: bootstrapData)
        let root = try reader.rootStruct()
        let _ = root.dataWord(0)
    }

    @Test("TunnelCredentials stores values correctly")
    func tunnelCredentials() {
        let uuid = UUID()
        let secret = Data(repeating: 0xFF, count: 32)
        let creds = TunnelCredentials(
            accountTag: "acc-tag",
            tunnelSecret: secret,
            tunnelID: uuid
        )

        #expect(creds.accountTag == "acc-tag")
        #expect(creds.tunnelSecret == secret)
        #expect(creds.tunnelID == uuid)
        #expect(creds.hostname == nil)
    }

    @Test("TunnelCredentials is Codable")
    func tunnelCredentialsCodable() throws {
        let uuid = UUID()
        let creds = TunnelCredentials(
            accountTag: "acc-tag",
            tunnelSecret: Data([1, 2, 3]),
            tunnelID: uuid,
            hostname: "test.trycloudflare.com"
        )

        let data = try JSONEncoder().encode(creds)
        let decoded = try JSONDecoder().decode(TunnelCredentials.self, from: data)

        #expect(decoded.accountTag == "acc-tag")
        #expect(decoded.tunnelSecret == Data([1, 2, 3]))
        #expect(decoded.tunnelID == uuid)
        #expect(decoded.hostname == "test.trycloudflare.com")
    }
}

// MARK: - DataStreamBuilder Tests

@Suite("DataStreamBuilder")
struct DataStreamBuilderTests {

    @Test("ConnectResponse can be built")
    func buildConnectResponse() {
        let response = DataStreamBuilder.buildConnectResponse(
            status: 200,
            headers: [("Content-Type", "text/html")]
        )
        #expect(response.count > 0)
    }

    @Test("ConnectResponse with error status")
    func buildErrorResponse() {
        let response = DataStreamBuilder.buildConnectResponse(
            status: 502,
            headers: [("X-Error", "upstream failed")]
        )
        #expect(response.count > 0)
    }

    @Test("ConnectResponse with multiple headers")
    func buildMultiHeaderResponse() {
        let response = DataStreamBuilder.buildConnectResponse(
            status: 200,
            headers: [
                ("Content-Type", "application/json"),
                ("Cache-Control", "no-cache"),
                ("X-Custom", "value"),
            ]
        )
        #expect(response.count > 0)
        #expect(response.count % 8 == 0)
    }
}
