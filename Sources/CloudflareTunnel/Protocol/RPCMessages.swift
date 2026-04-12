import Foundation

// MARK: - Tunnel RPC Message Builders

/// Builds the RPC messages needed for tunnel registration.
enum TunnelRPCBuilder {

    /// Build the Bootstrap message (get server capability).
    static func buildBootstrap(questionId: UInt32 = 0) -> Data {
        var msg = CapnProtoMessage()

        // Root: Message struct (dataWords=1, pointerWords=1)
        let rootPtr = msg.allocate(words: 1)
        // Message data: discriminant = 8 (bootstrap) at bytes 0-1
        let msgData = msg.allocate(words: 1)
        msg.setUInt16(CloudflareRPC.messageBootstrap, wordIndex: msgData, byteOffset: 0)
        // Message pointer: points to Bootstrap struct
        let msgPtr = msg.allocate(words: 1)

        // Bootstrap struct (dataWords=1, pointerWords=1)
        let bootData = msg.allocate(words: 1)
        // questionId at bytes 0-3
        msg.set(UInt64(questionId), at: bootData)
        // deprecatedObjectId pointer (null)
        let _ = msg.allocate(words: 1)

        // Set root pointer
        msg.setStructPointer(at: rootPtr, offset: 0, dataWords: 1, pointerWords: 1)
        // Set Message pointer to Bootstrap
        msg.setStructPointer(at: msgPtr, offset: 0, dataWords: 1, pointerWords: 1)

        return msg.serialize()
    }

    /// Build the RegisterConnection Call message.
    static func buildRegisterConnection(
        questionId: UInt32 = 1,
        credentials: TunnelCredentials,
        connIndex: UInt8 = 0,
        clientId: Data,
        features: [String] = ["serialized_headers"],
        version: String = "2024.1.0",
        arch: String = "darwin_arm64"
    ) -> Data {
        var msg = CapnProtoMessage()

        // Word 0: root struct pointer (Message)
        let rootPtr = msg.allocate(words: 1)

        // Words 1-3: Message data section (3 words for Call)
        let msgData = msg.allocate(words: 3)
        msg.setUInt16(CloudflareRPC.messageCall, wordIndex: msgData, byteOffset: 0) // discriminant = call

        // Words 4-6: Message pointer section (3 pointers for Call)
        let msgPtrStart = msg.allocate(words: 3)

        // Call data section (3 words):
        // word 0: questionId(0-3), methodId(4-5), sendResultsTo discriminant(6-7)
        // word 1: interfaceId(0-7)
        // word 2: flags byte at 0
        let callData = msg.allocate(words: 3)
        var callWord0: UInt64 = UInt64(questionId)
        callWord0 |= UInt64(CloudflareRPC.registerConnectionMethod) << 32
        callWord0 |= UInt64(0) << 48 // sendResultsTo = caller (0)
        msg.set(callWord0, at: callData)
        msg.set(CloudflareRPC.registrationServerInterface, at: callData + 1) // interfaceId
        msg.set(0, at: callData + 2) // flags (all false)

        // Call pointer section (3 pointers): target, params, sendResultsTo.thirdParty
        let callPtrStart = msg.allocate(words: 3)

        // Set root -> Message
        msg.setStructPointer(at: rootPtr, offset: 0, dataWords: 3, pointerWords: 3)
        // Set Message.call pointer -> Call struct
        msg.setStructPointer(at: msgPtrStart, offset: Int32(callData - msgPtrStart - 1), dataWords: 3, pointerWords: 3)

        // -- Build MessageTarget (for Call pointer 0) --
        let targetData = msg.allocate(words: 1)
        msg.set(0, at: targetData) // importedCap=0 at bytes 0-3, discriminant=0 (importedCap) at bytes 4-5
        let targetPtr = msg.allocate(words: 1) // promisedAnswer pointer (null)
        _ = targetPtr

        msg.setStructPointer(at: callPtrStart, offset: Int32(targetData - callPtrStart - 1), dataWords: 1, pointerWords: 1)

        // -- Build Payload (for Call pointer 1: params) --
        let payloadPtrs = msg.allocate(words: 2)

        msg.setStructPointer(at: callPtrStart + 1, offset: Int32(payloadPtrs - (callPtrStart + 1) - 1), dataWords: 0, pointerWords: 2)

        // -- Build RegisterConnection_Params as Payload.content (pointer 0) --
        let paramsData = msg.allocate(words: 1)
        msg.setByte(connIndex, wordIndex: paramsData, byteOffset: 0)
        let paramsPtrs = msg.allocate(words: 3) // auth, tunnelId, options

        msg.setStructPointer(at: payloadPtrs, offset: Int32(paramsData - payloadPtrs - 1), dataWords: 1, pointerWords: 3)

        // -- Build TunnelAuth (Params pointer 0) --
        let authPtrs = msg.allocate(words: 2)
        msg.setStructPointer(at: paramsPtrs, offset: Int32(authPtrs - paramsPtrs - 1), dataWords: 0, pointerWords: 2)
        msg.writeText(credentials.accountTag, pointerWordIndex: authPtrs)
        msg.writeData(credentials.tunnelSecret, pointerWordIndex: authPtrs + 1)

        // -- Build tunnelId (Params pointer 1) --
        let tunnelIdBytes = withUnsafeBytes(of: credentials.tunnelID.uuid) { Array($0) }
        msg.writeData(tunnelIdBytes, pointerWordIndex: paramsPtrs + 1)

        // -- Build ConnectionOptions (Params pointer 2) --
        let optionsData = msg.allocate(words: 1)
        msg.set(0, at: optionsData)
        let optionsPtrs = msg.allocate(words: 2)

        msg.setStructPointer(at: paramsPtrs + 2, offset: Int32(optionsData - (paramsPtrs + 2) - 1), dataWords: 1, pointerWords: 2)

        // -- Build ClientInfo (Options pointer 0) --
        let clientPtrs = msg.allocate(words: 4)
        msg.setStructPointer(at: optionsPtrs, offset: Int32(clientPtrs - optionsPtrs - 1), dataWords: 0, pointerWords: 4)
        msg.writeData(clientId, pointerWordIndex: clientPtrs)
        buildTextList(features, pointerWordIndex: clientPtrs + 1, msg: &msg)
        msg.writeText(version, pointerWordIndex: clientPtrs + 2)
        msg.writeText(arch, pointerWordIndex: clientPtrs + 3)

        return msg.serialize()
    }

    /// Build a List(Text) at the given pointer location.
    private static func buildTextList(_ texts: [String], pointerWordIndex: Int, msg: inout CapnProtoMessage) {
        guard !texts.isEmpty else { return }

        let offset = Int32(msg.wordCount - pointerWordIndex - 1)
        msg.setListPointer(at: pointerWordIndex, offset: offset, elementSize: 6, elementCount: UInt32(texts.count))

        let listStart = msg.allocate(words: texts.count)

        for (i, text) in texts.enumerated() {
            msg.writeText(text, pointerWordIndex: listStart + i)
        }
    }

    /// Build an UnregisterConnection Call message.
    /// Uses method 1 on the same registration interface with empty params.
    static func buildUnregisterConnection(questionId: UInt32 = 2) -> Data {
        var msg = CapnProtoMessage()

        let rootPtr = msg.allocate(words: 1)

        let msgData = msg.allocate(words: 3)
        msg.setUInt16(CloudflareRPC.messageCall, wordIndex: msgData, byteOffset: 0)

        let msgPtrStart = msg.allocate(words: 3)

        let callData = msg.allocate(words: 3)
        var callWord0: UInt64 = UInt64(questionId)
        callWord0 |= UInt64(CloudflareRPC.unregisterConnectionMethod) << 32
        callWord0 |= UInt64(0) << 48 // sendResultsTo = caller
        msg.set(callWord0, at: callData)
        msg.set(CloudflareRPC.registrationServerInterface, at: callData + 1)
        msg.set(0, at: callData + 2)

        let callPtrStart = msg.allocate(words: 3)

        msg.setStructPointer(at: rootPtr, offset: 0, dataWords: 3, pointerWords: 3)
        msg.setStructPointer(at: msgPtrStart, offset: Int32(callData - msgPtrStart - 1), dataWords: 3, pointerWords: 3)

        // MessageTarget: importedCap = 0
        let targetData = msg.allocate(words: 1)
        msg.set(0, at: targetData)
        let _ = msg.allocate(words: 1) // promisedAnswer pointer (null)
        msg.setStructPointer(at: callPtrStart, offset: Int32(targetData - callPtrStart - 1), dataWords: 1, pointerWords: 1)

        // Payload with empty params
        let payloadPtrs = msg.allocate(words: 2)
        msg.setStructPointer(at: callPtrStart + 1, offset: Int32(payloadPtrs - (callPtrStart + 1) - 1), dataWords: 0, pointerWords: 2)

        return msg.serialize()
    }

    /// Build a Finish message.
    static func buildFinish(questionId: UInt32) -> Data {
        var msg = CapnProtoMessage()

        let rootPtr = msg.allocate(words: 1)
        let msgData = msg.allocate(words: 1)
        msg.setUInt16(CloudflareRPC.messageFinish, wordIndex: msgData, byteOffset: 0)
        let msgPtr = msg.allocate(words: 1)

        let finishData = msg.allocate(words: 1)
        let finishWord: UInt64 = UInt64(questionId)
        msg.set(finishWord, at: finishData)

        msg.setStructPointer(at: rootPtr, offset: 0, dataWords: 1, pointerWords: 1)
        msg.setStructPointer(at: msgPtr, offset: 0, dataWords: 1, pointerWords: 0)

        return msg.serialize()
    }

    /// Parse a Return message to extract ConnectionResponse.
    static func parseReturnMessage(data: Data) throws -> ConnectionResult {
        let reader = try CapnProtoReader(data: data)
        let root = try reader.rootStruct()

        let discriminant = root.uint16(byteOffset: 0)
        guard discriminant == CloudflareRPC.messageReturn else {
            throw CapnProtoError.invalidData
        }

        guard let returnStruct = try root.structField(0) else {
            throw CapnProtoError.invalidData
        }

        let answerId = UInt32(returnStruct.dataWord(0) & 0xFFFFFFFF)
        let returnDiscriminant = returnStruct.uint16(byteOffset: 6)

        if returnDiscriminant == 1 {
            return .error("RPC exception (answerId=\(answerId))")
        }

        guard returnDiscriminant == 0 else {
            return .error("Unexpected return variant: \(returnDiscriminant)")
        }

        guard let payload = try returnStruct.structField(0) else {
            throw CapnProtoError.invalidData
        }

        guard let results = try payload.structField(0) else {
            throw CapnProtoError.invalidData
        }

        guard let connResponse = try results.structField(0) else {
            throw CapnProtoError.invalidData
        }

        let responseDiscriminant = connResponse.uint16(byteOffset: 0)

        if responseDiscriminant == 0 {
            if let errStruct = try connResponse.structField(0) {
                let cause = errStruct.textField(0) ?? "Unknown error"
                let retryAfter = errStruct.int64(byteOffset: 0)
                let shouldRetry = errStruct.bool(bitOffset: 64)
                return .registrationError(cause: cause, retryAfter: retryAfter, shouldRetry: shouldRetry)
            }
            return .error("Registration failed with unknown error")
        } else if responseDiscriminant == 1 {
            if let details = try connResponse.structField(0) {
                let isRemotelyManaged = details.bool(bitOffset: 0)
                let uuid = details.dataField(0)
                let locationName = details.textField(1) ?? ""
                return .success(ConnectionRegistrationResult(
                    uuid: uuid ?? Data(),
                    locationName: locationName,
                    tunnelIsRemotelyManaged: isRemotelyManaged
                ))
            }
            return .error("Could not read connection details")
        }

        return .error("Unknown ConnectionResponse discriminant: \(responseDiscriminant)")
    }
}

// MARK: - Data Stream Messages

/// Builds and parses Cap'n Proto messages for QUIC data streams.
enum DataStreamBuilder {

    /// Build a ConnectResponse message with HTTP status and headers.
    static func buildConnectResponse(status: Int, headers: [(String, String)]) -> Data {
        var msg = CapnProtoMessage()

        let rootPtr = msg.allocate(words: 1)

        // ConnectResponse: dataWords=0, pointerWords=2 (error, metadata)
        let responsePtrs = msg.allocate(words: 2)
        msg.setStructPointer(at: rootPtr, offset: 0, dataWords: 0, pointerWords: 2)

        // error (pointer 0) = empty string (success)
        msg.writeText("", pointerWordIndex: responsePtrs)

        // metadata (pointer 1) = List(Metadata) with status + headers
        var metadataEntries: [(String, String)] = [("HttpStatus", String(status))]
        for (name, value) in headers {
            metadataEntries.append(("HttpHeader:\(name)", value))
        }

        buildMetadataList(metadataEntries, pointerWordIndex: responsePtrs + 1, msg: &msg)

        return msg.serialize()
    }

    /// Parse a ConnectRequest from QUIC data stream.
    static func parseConnectRequest(data: Data) throws -> IncomingRequest {
        let reader = try CapnProtoReader(data: data)
        let root = try reader.rootStruct()

        let connectionType = root.uint16(byteOffset: 0)
        let dest = root.textField(0) ?? ""

        // Parse metadata list
        var metadata: [(String, String)] = []
        if root.pointerWords > 1 {
            let listPtrIndex = root.pointerStart + 1
            if listPtrIndex < root.words.count {
                let listWord = root.words[listPtrIndex]
                if listWord != 0 && (listWord & 3) == 1 {
                    let elementSize = UInt8((listWord >> 32) & 7)
                    let elementCount = UInt32((listWord >> 35) & 0x1FFFFFFF)
                    let offsetRaw = Int32(bitPattern: UInt32(listWord & 0xFFFFFFFF)) >> 2
                    let listDataStart = listPtrIndex + 1 + Int(offsetRaw)

                    if elementSize == 7 {
                        // Composite list: tag word first
                        if listDataStart < root.words.count {
                            let tagWord = root.words[listDataStart]
                            let itemDataWords = UInt16((tagWord >> 32) & 0xFFFF)
                            let itemPtrWords = UInt16((tagWord >> 48) & 0xFFFF)
                            let itemTotalWords = Int(itemDataWords) + Int(itemPtrWords)
                            let realCount = Int(elementCount)

                            if itemTotalWords > 0 {
                                let itemCount = realCount / itemTotalWords
                                for i in 0..<itemCount {
                                    let itemStart = listDataStart + 1 + i * itemTotalWords
                                    let itemDataStart = itemStart
                                    let itemPtrStart = itemStart + Int(itemDataWords)

                                    let sr = StructReader(
                                        words: root.words,
                                        dataStart: itemDataStart,
                                        dataWords: Int(itemDataWords),
                                        pointerStart: itemPtrStart,
                                        pointerWords: Int(itemPtrWords)
                                    )
                                    let key = sr.textField(0) ?? ""
                                    let val = sr.textField(1) ?? ""
                                    metadata.append((key, val))
                                }
                            }
                        }
                    }
                }
            }
        }

        // Extract HTTP info from metadata
        var method = "GET"
        var host = ""
        var httpHeaders: [(String, String)] = []
        for (key, val) in metadata {
            if key == "HttpMethod" { method = val }
            else if key == "HttpHost" { host = val }
            else if key.hasPrefix("HttpHeader:") {
                let headerName = String(key.dropFirst("HttpHeader:".count))
                httpHeaders.append((headerName, val))
            }
        }

        return IncomingRequest(
            dest: dest,
            connectionType: connectionType == 0 ? .http : (connectionType == 1 ? .websocket : .tcp),
            method: method,
            host: host,
            headers: httpHeaders,
            rawMetadata: metadata
        )
    }

    private static func buildMetadataList(_ entries: [(String, String)], pointerWordIndex: Int, msg: inout CapnProtoMessage) {
        guard !entries.isEmpty else { return }

        let itemDataWords: UInt16 = 0
        let itemPtrWords: UInt16 = 2
        let itemTotalWords = Int(itemDataWords) + Int(itemPtrWords)
        let totalWords = entries.count * itemTotalWords

        let offset = Int32(msg.wordCount - pointerWordIndex - 1)
        msg.setListPointer(at: pointerWordIndex, offset: offset, elementSize: 7, elementCount: UInt32(totalWords))

        // Tag word
        let tagWordIndex = msg.allocate(words: 1)
        let tagLow = UInt32(entries.count) << 2
        let tagHigh = UInt32(itemDataWords) | (UInt32(itemPtrWords) << 16)
        msg.set(UInt64(tagLow) | (UInt64(tagHigh) << 32), at: tagWordIndex)

        let entriesStart = msg.allocate(words: totalWords)

        for (i, entry) in entries.enumerated() {
            let entryPtrStart = entriesStart + i * itemTotalWords + Int(itemDataWords)
            msg.writeText(entry.0, pointerWordIndex: entryPtrStart)
            msg.writeText(entry.1, pointerWordIndex: entryPtrStart + 1)
        }
    }
}
