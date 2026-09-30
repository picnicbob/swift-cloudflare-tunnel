import Foundation
import Network
import os

// MARK: - QUIC Tunnel Connection

/// Manages a QUIC connection to Cloudflare edge for tunnel proxying.
/// Uses Network.framework's native QUIC support (iOS 15+ / macOS 12+).
public actor TunnelConnection {

    private var connectionGroup: NWConnectionGroup?
    private var controlStream: NWConnection?
    private let queue = DispatchQueue(label: "com.cloudflare.tunnel.connection", qos: .userInitiated)
    private var credentials: TunnelCredentials?
    private var edgeAddress: EdgeAddress?
    private var state: ConnectionState = .disconnected
    private var stateCallback: (@Sendable (ConnectionState) -> Void)?
    private var requestHandler: (@Sendable (IncomingRequest, Data?) async -> ProxyResponse)?
    private var streamHandler: (@Sendable (IncomingRequest) async -> StreamSession)?
    private var reconnectTask: Task<Void, Never>?
    private var activeStreams: Set<ObjectIdentifier> = []
    private let maxReconnectAttempts = 10
    private let clientId: Data
    let connIndex: UInt8
    let logger: TunnelLogger

    public init(connIndex: UInt8 = 0, logger: TunnelLogger) throws {
        self.connIndex = connIndex
        self.logger = logger
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &bytes) == errSecSuccess else {
            throw TunnelConnectionError.connectionFailed("Failed to generate secure random client ID")
        }
        self.clientId = Data(bytes)
    }

    // MARK: - Public API

    /// Set callback for state changes.
    public func setStateCallback(_ callback: @escaping @Sendable (ConnectionState) -> Void) {
        self.stateCallback = callback
    }

    /// Set handler for incoming tunnel requests.
    public func setRequestHandler(_ handler: @escaping @Sendable (IncomingRequest, Data?) async -> ProxyResponse) {
        self.requestHandler = handler
    }

    /// Set handler for bidirectional streaming (WebSocket/TCP).
    public func setStreamHandler(_ handler: @escaping @Sendable (IncomingRequest) async -> StreamSession) {
        self.streamHandler = handler
    }

    /// Connect to Cloudflare edge and register the tunnel.
    public func connect(credentials: TunnelCredentials) async throws {
        self.credentials = credentials
        reconnectTask?.cancel()
        reconnectTask = nil

        try await connectToEdge()
    }

    /// Connect to a specific Cloudflare edge server.
    public func connect(credentials: TunnelCredentials, edgeAddress: EdgeAddress) async throws {
        self.credentials = credentials
        self.edgeAddress = edgeAddress
        reconnectTask?.cancel()
        reconnectTask = nil

        try await connectToEdge(edgeAddress: edgeAddress)
    }

    /// Disconnect the tunnel gracefully.
    /// Sends UnregisterConnection RPC before closing the QUIC connection.
    public func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil

        // Send UnregisterConnection on a fresh stream to avoid conflicting
        // with the monitor's outstanding receive on the control stream.
        if let group = connectionGroup {
            do {
                guard let unregStream = NWConnection(from: group) else {
                    throw TunnelConnectionError.connectionFailed("Failed to create unregister stream")
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    unregStream.stateUpdateHandler = { [weak unregStream] state in
                        switch state {
                        case .ready:
                            unregStream?.stateUpdateHandler = nil
                            continuation.resume()
                        case .failed(let error):
                            unregStream?.stateUpdateHandler = nil
                            continuation.resume(throwing: error)
                        default:
                            break
                        }
                    }
                    unregStream.start(queue: queue)
                }
/* DON'T
                let signature = Data(CloudflareRPC.rpcStreamSignature)
                try await sendData(signature, on: unregStream)
*/
                let unregisterMsg = TunnelRPCBuilder.buildUnregisterConnection(questionId: 2)
                try await sendData(unregisterMsg, on: unregStream)

                let finishMsg = TunnelRPCBuilder.buildFinish(questionId: 2)
                try await sendData(finishMsg, on: unregStream)

                unregStream.cancel()
            } catch {
                logger.warning("Failed to send UnregisterConnection: \(error)")
            }
        }

        controlStream?.cancel()
        controlStream = nil
        connectionGroup?.cancel()
        connectionGroup = nil
        if let continuation = pendingConnectionContinuation {
            pendingConnectionContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        updateState(.disconnected)
    }

    /// Current connection state.
    public func currentState() -> ConnectionState {
        return state
    }

    // MARK: - Connection Setup

    private func connectToEdge(edgeAddress: EdgeAddress? = nil) async throws {
        updateState(.connecting)

        let edge: EdgeAddress
        if let provided = edgeAddress {
            edge = provided
        } else if let stored = self.edgeAddress {
            edge = stored
        } else {
            let api = CloudflareAPI()
            let edges = try await api.discoverEdgeIPs()
            guard let first = edges.first else {
                throw TunnelConnectionError.noEdgeServers
            }
            edge = first
        }
        self.edgeAddress = edge

        let host = NWEndpoint.Host(edge.host)
        let port = NWEndpoint.Port(integerLiteral: edge.port)
        let endpoint = NWEndpoint.hostPort(host: host, port: port)

        // Configure QUIC with argotunnel ALPN
        let quicOptions = NWProtocolQUIC.Options(alpn: ["argotunnel"])
        quicOptions.direction = .bidirectional
        quicOptions.idleTimeout = 5_000 // 5 seconds (matches cloudflared quic/constants.go)

        let securityOptions = quicOptions.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(securityOptions, "quic.cftunnel.com")
#if DEBUG
		sec_protocol_options_set_verify_block(securityOptions, { [logger] _, secTrust, complete in
			let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
			var error: CFError?
			let ok = SecTrustEvaluateWithError(trust, &error)
			logger.warning("DEBUG: bypassing trust. system eval ok=\(ok), error=\(String(describing: error))")
			complete(true)
		}, queue)
#endif
        let parameters = NWParameters(quic: quicOptions)

        let multiplexGroup = NWMultiplexGroup(to: endpoint)
        let group = NWConnectionGroup(with: multiplexGroup, using: parameters)

        let groupRef = group
        group.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            Task { await self.handleGroupState(newState, group: groupRef) }
        }

        group.newConnectionHandler = { [weak self] stream in
            guard let self else { return }
            Task { await self.handleIncomingStream(stream) }
        }

        self.connectionGroup = group
        group.start(queue: queue)

        try await waitForConnection()
    }

    private func waitForConnection() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.pendingConnectionContinuation = continuation
        }
    }

    private var pendingConnectionContinuation: CheckedContinuation<Void, Error>?

    private func handleGroupState(_ newState: NWConnectionGroup.State, group: NWConnectionGroup) {
        switch newState {
        case .ready:
            logger.info("QUIC connection to Cloudflare edge established")
            if let continuation = pendingConnectionContinuation {
                pendingConnectionContinuation = nil
                Task {
                    do {
                        try await performRegistration()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

        case .failed(let error):
            logger.error("QUIC connection failed: \(error)")
            if let continuation = pendingConnectionContinuation {
                pendingConnectionContinuation = nil
                continuation.resume(throwing: TunnelConnectionError.connectionFailed(error.localizedDescription))
            } else {
                scheduleReconnect()
            }

        case .waiting(let error):
            logger.warning("QUIC connection waiting: \(error)")

        case .cancelled:
            logger.info("QUIC connection cancelled")

        default:
            break
        }
    }

    // MARK: - Control Stream Registration

    private func performRegistration() async throws {
        guard let group = connectionGroup, let credentials = credentials else {
            throw TunnelConnectionError.notConfigured
        }

        updateState(.registering)

        guard let stream = NWConnection(from: group) else {
            throw TunnelConnectionError.connectionFailed("Failed to create control stream")
        }
        self.controlStream = stream

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.stateUpdateHandler = { [weak stream] state in
                switch state {
                case .ready:
                    stream?.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    stream?.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            stream.start(queue: queue)
        }
/* DONT
        // Write RPC stream signature
        let signature = Data(CloudflareRPC.rpcStreamSignature)
        try await sendData(signature, on: stream)
*/
        // Step 1: Send Bootstrap message
        let bootstrapMsg = TunnelRPCBuilder.buildBootstrap(questionId: 0)
        try await sendData(bootstrapMsg, on: stream)

        // Step 2: Read Bootstrap return (proper Cap'n Proto framing)
        let bootstrapReturn = try await receiveCapnProtoMessage(on: stream)
        logger.info("Bootstrap return received (\(bootstrapReturn.count) bytes)")

        // Step 3: Send Finish for bootstrap
        let finishBootstrap = TunnelRPCBuilder.buildFinish(questionId: 0)
        try await sendData(finishBootstrap, on: stream)

        // Step 4: Send RegisterConnection call
        let registerMsg = TunnelRPCBuilder.buildRegisterConnection(
            questionId: 1,
            credentials: credentials,
            connIndex: connIndex,
            clientId: clientId,
            features: ["serialized_headers"],
            version: "2024.1.0",
            arch: "darwin_arm64"
        )
        try await sendData(registerMsg, on: stream)

        // Step 5: Read RegisterConnection return (proper Cap'n Proto framing)
        let registerReturn = try await receiveCapnProtoMessage(on: stream)
        let result = try TunnelRPCBuilder.parseReturnMessage(data: registerReturn)

        switch result {
        case .success(let details):
            logger.info("Tunnel registered at \(details.locationName) (remotely managed: \(details.tunnelIsRemotelyManaged))")
            updateState(.connected(location: details.locationName))

        case .registrationError(let cause, _, let shouldRetry):
            logger.error("Registration failed: \(cause)")
            if shouldRetry {
                throw TunnelConnectionError.registrationFailed(cause)
            } else {
                throw TunnelConnectionError.registrationRejected(cause)
            }

        case .error(let msg):
            logger.error("Registration error: \(msg)")
            throw TunnelConnectionError.registrationFailed(msg)
        }

        // Step 6: Send Finish for registration
        let finishRegister = TunnelRPCBuilder.buildFinish(questionId: 1)
        try await sendData(finishRegister, on: stream)

        // Keep control stream alive for the tunnel duration
        monitorControlStream(stream, logger: logger)
    }

    private nonisolated func monitorControlStream(_ stream: NWConnection, logger: TunnelLogger) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if isComplete || error != nil {
                logger.warning("Control stream closed")
                if let self { Task { await self.scheduleReconnect() } }
            } else if data != nil {
                self?.monitorControlStream(stream, logger: logger)
            }
        }
    }

    // MARK: - Data Stream Handling

    private func handleIncomingStream(_ stream: NWConnection) {
        let streamId = ObjectIdentifier(stream)

        stream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.processDataStream(stream, id: streamId) }
            case .failed, .cancelled:
                Task { await self.removeStream(streamId) }
            default:
                break
            }
        }
        stream.start(queue: queue)

        Task { activeStreams.insert(streamId) }
    }

    private func removeStream(_ id: ObjectIdentifier) {
        activeStreams.remove(id)
    }

    private func processDataStream(_ stream: NWConnection, id: ObjectIdentifier) async {
        defer {
            Task { self.removeStream(id) }
            stream.cancel()
        }

        do {
            // Read protocol signature (6 bytes) + version (2 bytes)
            let header = try await receiveExactly(8, on: stream)
            let sig = Array(header.prefix(6))
            guard sig == CloudflareRPC.dataStreamSignature else {
                logger.warning("Unknown stream signature: \(sig)")
                return
            }

            // Read Cap'n Proto ConnectRequest message
            let segTable = try await receiveExactly(8, on: stream)
            let segCountMinusOne = segTable.withUnsafeBytes { $0.load(as: UInt32.self) }
            guard segCountMinusOne == 0 else {
                logger.warning("Multi-segment message not supported")
                return
            }
            let segSize = segTable.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
            // Cap segment size to prevent remote memory exhaustion.
            // Control messages are small; 4096 words (32 KB) is generous.
            let maxSegWords: UInt32 = 4096
            guard segSize <= maxSegWords else {
                logger.warning("Rejecting oversized Cap'n Proto segment: \(segSize) words")
                return
            }

            let segData = try await receiveExactly(Int(segSize) * 8, on: stream)
            let fullMessage = segTable + segData

            let request = try DataStreamBuilder.parseConnectRequest(data: fullMessage)
            logger.info("Tunnel request: \(request.method) \(request.host)\(request.dest)")

            switch request.connectionType {
            case .http:
                try await handleHTTPStream(stream, request: request)
            case .websocket, .tcp:
                try await handleBidirectionalStream(stream, request: request)
            }

        } catch {
            logger.error("Data stream error: \(error)")
        }
    }

    private func handleHTTPStream(_ stream: NWConnection, request: IncomingRequest) async throws {
        let body = try await readStreamBody(stream)

        guard let handler = requestHandler else {
            logger.warning("No request handler configured")
            return
        }

        let response = await handler(request, body)
        try await sendResponse(response, on: stream)
        stream.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }

    private func handleBidirectionalStream(_ stream: NWConnection, request: IncomingRequest) async throws {
        // Fall back to one-shot HTTP handler if no stream handler is set
        guard let handler = streamHandler else {
            try await handleHTTPStream(stream, request: request)
            return
        }

        let session = await handler(request)

        // Send initial response headers
        try await sendResponse(session.initialResponse, on: stream)

        // Bidirectional relay with cleanup on cancellation
        defer { session.close() }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Inbound: QUIC stream -> handler (client -> origin)
                group.addTask {
                    defer { session.close() }
                    while !Task.isCancelled {
                        let (data, isComplete) = try await self.receiveChunk(on: stream, minLength: 1, maxLength: 65536)
                        if let data, !data.isEmpty {
                            await session.handleData(data)
                        }
                        if isComplete {
                            await session.handleClose()
                            return
                        }
                    }
                }

                // Outbound: handler -> QUIC stream (origin -> client)
                group.addTask {
                    for await data in session.outbound {
                        try await self.sendData(data, on: stream)
                    }
                    stream.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                }

                // Wait for either direction to complete, then cancel the other
                try await group.next()
                group.cancelAll()
            }
        } catch {
            session.close()
            throw error
        }
    }

    private func sendResponse(_ response: ProxyResponse, on stream: NWConnection) async throws {
        var responseData = Data(CloudflareRPC.dataStreamSignature)
        responseData.append(contentsOf: CloudflareRPC.protocolVersion)

        let connectResponse = DataStreamBuilder.buildConnectResponse(
            status: response.statusCode,
            headers: response.headers.map { ($0.0, $0.1) }
        )
        responseData.append(connectResponse)

        try await sendData(responseData, on: stream)

        if !response.body.isEmpty {
            try await sendData(response.body, on: stream)
        }
    }

    private static let maxBodySize = 10_485_760 // 10 MB

    private func readStreamBody(_ stream: NWConnection) async throws -> Data? {
        // First read with minimumIncompleteLength: 0 to handle no-body case without blocking
        let (firstData, firstComplete) = try await receiveChunk(on: stream, minLength: 0, maxLength: 1_048_576)

        guard let firstData, !firstData.isEmpty else {
            return nil
        }

        var buffer = firstData
        if firstComplete {
            return buffer
        }

        // Loop until stream completes or max body size reached
        while buffer.count < Self.maxBodySize {
            let remaining = min(1_048_576, Self.maxBodySize - buffer.count)
            let (data, isComplete) = try await receiveChunk(on: stream, minLength: 1, maxLength: remaining)
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            if isComplete {
                break
            }
        }
        return buffer
    }

    private func receiveChunk(on connection: NWConnection, minLength: Int, maxLength: Int) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: minLength, maximumLength: maxLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        guard credentials != nil else { return }

        reconnectTask?.cancel()
        reconnectTask = Task {
            var attempt = 0
            while !Task.isCancelled && attempt < maxReconnectAttempts {
                attempt += 1
                updateState(.reconnecting(attempt: attempt))

                let delay = min(Double(1 << (attempt - 1)), 60.0)
                logger.info("Reconnecting in \(Int(delay))s (attempt \(attempt)/\(self.maxReconnectAttempts))")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                guard !Task.isCancelled else { return }

                do {
                    cleanupConnection()
                    try await connectToEdge()
                    logger.info("Reconnection successful")
                    return
                } catch {
                    logger.warning("Reconnection attempt \(attempt) failed: \(error)")
                }
            }

            if !Task.isCancelled {
                updateState(.failed(TunnelConnectionError.maxReconnectAttemptsReached))
            }
        }
    }

    private func cleanupConnection() {
        controlStream?.cancel()
        controlStream = nil
        connectionGroup?.cancel()
        connectionGroup = nil
    }

    // MARK: - Network I/O Helpers

    private func sendData(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveData(on connection: NWConnection, minLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: minLength, maximumLength: 1_048_576) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: TunnelConnectionError.noData)
                }
            }
        }
    }

    private static let maxReceiveSize = 1_048_576 // 1 MB

    private func receiveExactly(_ count: Int, on connection: NWConnection) async throws -> Data {
        guard count <= Self.maxReceiveSize else {
            throw TunnelConnectionError.connectionFailed("Message too large: \(count) bytes (max \(Self.maxReceiveSize))")
        }
        var buffer = Data()
        while buffer.count < count {
            let remaining = count - buffer.count
            let chunk = try await receiveData(on: connection, minLength: min(remaining, 1))
            guard !chunk.isEmpty else {
                throw TunnelConnectionError.noData
            }
            buffer.append(chunk)
        }
        return buffer
    }

    /// Read a complete Cap'n Proto message using proper segment framing.
    /// Reads the 8-byte segment table header, validates the segment size,
    /// then reads exactly the right number of bytes for the segment data.
    private func receiveCapnProtoMessage(on connection: NWConnection) async throws -> Data {
        let segTable = try await receiveExactly(8, on: connection)
        let segCountMinusOne = segTable.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard segCountMinusOne == 0 else {
            throw TunnelConnectionError.connectionFailed("Multi-segment Cap'n Proto messages not supported")
        }
        let segSize = segTable.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        let maxSegWords: UInt32 = 4096
        guard segSize <= maxSegWords else {
            throw TunnelConnectionError.connectionFailed("Oversized Cap'n Proto segment: \(segSize) words")
        }
        let segData = try await receiveExactly(Int(segSize) * 8, on: connection)
        return segTable + segData
    }

    private func updateState(_ newState: ConnectionState) {
        state = newState
        let callback = stateCallback
        Task { @Sendable in
            callback?(newState)
        }
    }
}
