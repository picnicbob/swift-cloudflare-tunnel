import Foundation

// MARK: - Minimal Cap'n Proto Encoder/Decoder
// Hand-coded for the specific Cloudflare Tunnel registration types.
// NOT a general-purpose Cap'n Proto library.

// MARK: - Message Builder

/// Builds a single-segment Cap'n Proto message.
struct CapnProtoMessage {
    private(set) var words: [UInt64] = []

    /// Current write position in words.
    var wordCount: Int { words.count }

    /// Reserve space and return the starting word index.
    mutating func allocate(words count: Int) -> Int {
        let start = words.count
        words.append(contentsOf: repeatElement(0, count: count))
        return start
    }

    /// Write a UInt64 at a specific word index.
    mutating func set(_ value: UInt64, at wordIndex: Int) {
        words[wordIndex] = value
    }

    /// Write a byte at a specific position.
    mutating func setByte(_ value: UInt8, wordIndex: Int, byteOffset: Int) {
        var word = words[wordIndex]
        let shift = byteOffset * 8
        word &= ~(0xFF << shift)
        word |= UInt64(value) << shift
        words[wordIndex] = word
    }

    /// Write a UInt16 at a specific position.
    mutating func setUInt16(_ value: UInt16, wordIndex: Int, byteOffset: Int) {
        var word = words[wordIndex]
        let shift = byteOffset * 8
        word &= ~(0xFFFF << shift)
        word |= UInt64(value) << shift
        words[wordIndex] = word
    }

    /// Write a Bool at a specific bit position.
    mutating func setBool(_ value: Bool, wordIndex: Int, bitOffset: Int) {
        if value {
            words[wordIndex] |= (1 << bitOffset)
        } else {
            words[wordIndex] &= ~(1 << bitOffset)
        }
    }

    /// Write a struct pointer at the given word index.
    mutating func setStructPointer(at wordIndex: Int, offset: Int32, dataWords: UInt16, pointerWords: UInt16) {
        let low: UInt32 = UInt32(bitPattern: offset) << 2 // tag = 00
        let high: UInt32 = UInt32(dataWords) | (UInt32(pointerWords) << 16)
        words[wordIndex] = UInt64(low) | (UInt64(high) << 32)
    }

    /// Write a list pointer at the given word index.
    /// elementSize: 0=Void, 1=Bit, 2=Byte, 3=TwoBytes, 4=FourBytes, 5=EightBytes, 6=Pointer, 7=Composite
    mutating func setListPointer(at wordIndex: Int, offset: Int32, elementSize: UInt8, elementCount: UInt32) {
        let low: UInt32 = (UInt32(bitPattern: offset) << 2) | 1 // tag = 01
        let high: UInt32 = UInt32(elementSize) | (elementCount << 3)
        words[wordIndex] = UInt64(low) | (UInt64(high) << 32)
    }

    /// Write text (NUL-terminated UTF-8 bytes) and return the word index where data starts.
    mutating func writeText(_ text: String, pointerWordIndex: Int) {
        let utf8 = Array(text.utf8)
        let byteCount = utf8.count + 1 // include NUL
        let wordCount = (byteCount + 7) / 8

        let offset = Int32(self.wordCount - pointerWordIndex - 1)
        setListPointer(at: pointerWordIndex, offset: offset, elementSize: 2, elementCount: UInt32(byteCount))

        let dataStart = allocate(words: wordCount)
        for (i, byte) in utf8.enumerated() {
            let wi = dataStart + i / 8
            let bi = i % 8
            setByte(byte, wordIndex: wi, byteOffset: bi)
        }
        // NUL terminator at utf8.count position (already zero from allocation)
    }

    /// Write raw data bytes.
    mutating func writeData(_ data: [UInt8], pointerWordIndex: Int) {
        let byteCount = data.count
        let wordCount = (byteCount + 7) / 8

        let offset = Int32(self.wordCount - pointerWordIndex - 1)
        setListPointer(at: pointerWordIndex, offset: offset, elementSize: 2, elementCount: UInt32(byteCount))

        if wordCount > 0 {
            let dataStart = allocate(words: wordCount)
            for (i, byte) in data.enumerated() {
                let wi = dataStart + i / 8
                let bi = i % 8
                setByte(byte, wordIndex: wi, byteOffset: bi)
            }
        }
    }

    /// Write Data from Foundation Data type.
    mutating func writeData(_ data: Data, pointerWordIndex: Int) {
        writeData(Array(data), pointerWordIndex: pointerWordIndex)
    }

    /// Serialize the message with segment table header.
    func serialize() -> Data {
        var result = Data()
        // Segment table: 1 segment
        var segCount: UInt32 = 0 // segment_count - 1
        var segSize: UInt32 = UInt32(words.count)
        result.append(Data(bytes: &segCount, count: 4))
        result.append(Data(bytes: &segSize, count: 4))
        // Segment data
        for var word in words {
            result.append(Data(bytes: &word, count: 8))
        }
        return result
    }
}

// MARK: - Message Reader

/// Reads a Cap'n Proto message from raw bytes.
struct CapnProtoReader {
    let words: [UInt64]

    static let maxSegWords: UInt32 = 4096 // 32 KB cap for control messages

    init(data: Data) throws {
        guard data.count >= 8 else {
            throw CapnProtoError.truncatedMessage
        }
        let segCountMinusOne = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard segCountMinusOne == 0 else {
            throw CapnProtoError.multipleSegments
        }
        let segSize = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        guard segSize <= Self.maxSegWords else {
            throw CapnProtoError.truncatedMessage
        }
        let headerSize = 8
        let expectedSize = headerSize + Int(segSize) * 8
        guard data.count >= expectedSize else {
            throw CapnProtoError.truncatedMessage
        }

        var words: [UInt64] = []
        for i in 0..<Int(segSize) {
            let offset = headerSize + i * 8
            let word = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt64.self) }
            words.append(word)
        }
        self.words = words
    }

    /// Read the root struct pointer (always at word 0).
    func rootStruct() throws -> StructReader {
        return try readStructPointer(at: 0)
    }

    /// Read a struct pointer at a given word index.
    func readStructPointer(at wordIndex: Int) throws -> StructReader {
        guard wordIndex < words.count else { throw CapnProtoError.outOfBounds }
        let word = words[wordIndex]

        let tag = word & 3
        guard tag == 0 else {
            if word == 0 { return StructReader(words: words, dataStart: wordIndex + 1, dataWords: 0, pointerStart: wordIndex + 1, pointerWords: 0) }
            throw CapnProtoError.unexpectedPointerType
        }

        let offsetRaw = Int32(bitPattern: UInt32(word & 0xFFFFFFFF)) >> 2
        let dataWords = UInt16((word >> 32) & 0xFFFF)
        let pointerWords = UInt16((word >> 48) & 0xFFFF)

        let dataStart = wordIndex + 1 + Int(offsetRaw)
        let pointerStart = dataStart + Int(dataWords)

        guard dataStart >= 0, pointerStart >= 0, pointerStart <= words.count else {
            throw CapnProtoError.outOfBounds
        }

        return StructReader(words: words, dataStart: dataStart, dataWords: Int(dataWords), pointerStart: pointerStart, pointerWords: Int(pointerWords))
    }
}

/// Reads fields from a Cap'n Proto struct.
struct StructReader {
    let words: [UInt64]
    let dataStart: Int
    let dataWords: Int
    let pointerStart: Int
    let pointerWords: Int

    func dataWord(_ index: Int) -> UInt64 {
        guard index < dataWords, dataStart + index < words.count else { return 0 }
        return words[dataStart + index]
    }

    func uint16(byteOffset: Int) -> UInt16 {
        let wordIndex = byteOffset / 8
        let byteInWord = byteOffset % 8
        let word = dataWord(wordIndex)
        return UInt16((word >> (byteInWord * 8)) & 0xFFFF)
    }

    func uint8(byteOffset: Int) -> UInt8 {
        let wordIndex = byteOffset / 8
        let byteInWord = byteOffset % 8
        let word = dataWord(wordIndex)
        return UInt8((word >> (byteInWord * 8)) & 0xFF)
    }

    func bool(bitOffset: Int) -> Bool {
        let wordIndex = bitOffset / 64
        let bitInWord = bitOffset % 64
        return (dataWord(wordIndex) >> bitInWord) & 1 == 1
    }

    func int64(byteOffset: Int) -> Int64 {
        let wordIndex = byteOffset / 8
        return Int64(bitPattern: dataWord(wordIndex))
    }

    /// Read a pointer field and resolve it as a struct.
    func structField(_ pointerIndex: Int) throws -> StructReader? {
        guard pointerIndex < pointerWords else { return nil }
        let ptrWordIndex = pointerStart + pointerIndex
        guard ptrWordIndex >= 0, ptrWordIndex < words.count else { return nil }
        let word = words[ptrWordIndex]
        if word == 0 { return nil }

        let tag = word & 3
        guard tag == 0 else { throw CapnProtoError.unexpectedPointerType }

        let offsetRaw = Int32(bitPattern: UInt32(word & 0xFFFFFFFF)) >> 2
        let dataWords = UInt16((word >> 32) & 0xFFFF)
        let pointerWords = UInt16((word >> 48) & 0xFFFF)

        let dataStart = ptrWordIndex + 1 + Int(offsetRaw)
        let pointerStart = dataStart + Int(dataWords)

        guard dataStart >= 0, pointerStart >= 0, pointerStart <= words.count else {
            throw CapnProtoError.outOfBounds
        }

        return StructReader(words: words, dataStart: dataStart, dataWords: Int(dataWords), pointerStart: pointerStart, pointerWords: Int(pointerWords))
    }

    /// Read a pointer field as text (NUL-terminated List(UInt8)).
    func textField(_ pointerIndex: Int) -> String? {
        guard pointerIndex < pointerWords else { return nil }
        let ptrWordIndex = pointerStart + pointerIndex
        guard ptrWordIndex >= 0, ptrWordIndex < words.count else { return nil }
        let word = words[ptrWordIndex]
        if word == 0 { return nil }

        let tag = word & 3
        guard tag == 1 else { return nil } // list pointer

        let offsetRaw = Int32(bitPattern: UInt32(word & 0xFFFFFFFF)) >> 2
        let elementCount = UInt32((word >> 35) & 0x1FFFFFFF)

        let dataStart = ptrWordIndex + 1 + Int(offsetRaw)
        guard dataStart >= 0 else { return nil }
        guard elementCount > 0 else { return "" }

        var bytes: [UInt8] = []
        let byteCount = Int(elementCount) - 1 // exclude NUL
        for i in 0..<byteCount {
            let wi = dataStart + i / 8
            let bi = i % 8
            guard wi < words.count else { break }
            bytes.append(UInt8((words[wi] >> (bi * 8)) & 0xFF))
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Read a pointer field as raw data (List(UInt8) without NUL handling).
    func dataField(_ pointerIndex: Int) -> Data? {
        guard pointerIndex < pointerWords else { return nil }
        let ptrWordIndex = pointerStart + pointerIndex
        guard ptrWordIndex >= 0, ptrWordIndex < words.count else { return nil }
        let word = words[ptrWordIndex]
        if word == 0 { return nil }

        let tag = word & 3
        guard tag == 1 else { return nil }

        let offsetRaw = Int32(bitPattern: UInt32(word & 0xFFFFFFFF)) >> 2
        let elementCount = UInt32((word >> 35) & 0x1FFFFFFF)

        let dataStart = ptrWordIndex + 1 + Int(offsetRaw)
        guard dataStart >= 0 else { return nil }
        var bytes: [UInt8] = []
        for i in 0..<Int(elementCount) {
            let wi = dataStart + i / 8
            let bi = i % 8
            guard wi < words.count else { break }
            bytes.append(UInt8((words[wi] >> (bi * 8)) & 0xFF))
        }
        return Data(bytes)
    }
}

enum CapnProtoError: Error {
    case truncatedMessage
    case multipleSegments
    case outOfBounds
    case unexpectedPointerType
    case invalidData
}

// MARK: - Cloudflare Tunnel RPC Constants

/// Interface and method IDs for the Cloudflare tunnel RPC protocol.
enum CloudflareRPC {
    static let registrationServerInterface: UInt64 = 0xf71695ec7fe85497
    static let registerConnectionMethod: UInt16 = 0
    static let unregisterConnectionMethod: UInt16 = 1

    // Stream protocol signatures
    static let dataStreamSignature: [UInt8] = [0x0A, 0x36, 0xCD, 0x12, 0xA1, 0x3E]
    static let rpcStreamSignature: [UInt8] = [0x52, 0xBB, 0x82, 0x5C, 0xDB, 0x65]
    static let protocolVersion: [UInt8] = [0x30, 0x31] // ASCII "01"

    // RPC Message discriminants
    static let messageCall: UInt16 = 2
    static let messageReturn: UInt16 = 3
    static let messageFinish: UInt16 = 4
    static let messageBootstrap: UInt16 = 8
}
