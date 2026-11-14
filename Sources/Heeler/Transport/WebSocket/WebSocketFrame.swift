import Foundation

/// Which end of a connection a codec serves. RFC 6455 has a client mask every
/// frame it sends and a server mask none, and each side fails a frame that
/// breaks the rule for the other.
enum WebSocketRole: Sendable {
    case client
    case server
}

enum WebSocketOpcode: UInt8, Sendable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA

    var isControl: Bool { rawValue & 0x8 != 0 }
}

/// A close frame's status code (RFC 6455 section 7.4).
struct WebSocketCloseCode: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt16

    init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    static let normalClosure = Self(rawValue: 1000)
    static let goingAway = Self(rawValue: 1001)
    static let protocolError = Self(rawValue: 1002)
    static let unsupportedData = Self(rawValue: 1003)
    /// Reported for a close frame that carried no code. Never sent.
    static let noStatusReceived = Self(rawValue: 1005)
    static let invalidPayload = Self(rawValue: 1007)
    static let policyViolation = Self(rawValue: 1008)
    static let messageTooBig = Self(rawValue: 1009)
    static let internalError = Self(rawValue: 1011)
    static let tryAgainLater = Self(rawValue: 1013)

    /// Whether a close frame may carry this code: the codes RFC 6455 and the
    /// IANA registry define, and the 3000-4999 range for libraries and
    /// applications. 1005, 1006 and 1015 only ever describe a connection.
    var mayBeSent: Bool {
        switch rawValue {
        case 1000...1003, 1007...1014, 3000...4999: true
        default: false
        }
    }
}

/// What a peer's close frame said. A frame with no payload reads as
/// `.noStatusReceived` with an empty reason.
struct WebSocketClose: Sendable, Equatable {
    let code: WebSocketCloseCode
    let reason: String

    init(code: WebSocketCloseCode, reason: String = "") {
        self.code = code
        self.reason = reason
    }

    init(payload: Data) throws(WebSocketViolation) {
        let bytes = [UInt8](payload)
        guard !bytes.isEmpty else {
            self.init(code: .noStatusReceived)
            return
        }
        guard bytes.count >= 2 else { throw .malformedClosePayload }
        let code = WebSocketCloseCode(rawValue: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        guard code.mayBeSent else { throw .invalidCloseCode }
        guard let reason = String(validating: bytes.dropFirst(2), as: UTF8.self) else { throw .invalidUTF8 }
        self.init(code: code, reason: reason)
    }
}

/// One way a peer broke RFC 6455. Each fails the connection with its close code.
enum WebSocketViolation: Error, Sendable, Equatable {
    case reservedBitsSet
    case unknownOpcode
    case maskedServerFrame
    case unmaskedClientFrame
    case fragmentedControlFrame
    case oversizedControlFrame
    /// A 64-bit length with its most significant bit set.
    case invalidLength
    /// A continuation frame with no message in progress.
    case unexpectedContinuation
    /// A new text or binary frame while a fragmented message is in progress.
    case expectedContinuation
    /// A close frame with a one-byte payload.
    case malformedClosePayload
    case invalidCloseCode
    case invalidUTF8
    case messageTooBig

    var closeCode: WebSocketCloseCode {
        switch self {
        case .invalidUTF8: .invalidPayload
        case .messageTooBig: .messageTooBig
        default: .protocolError
        }
    }
}

/// One frame with its payload unmasked.
struct WebSocketFrame: Sendable, Equatable {
    static let maximumControlPayloadBytes = 125
    /// A close frame's reason fits beside its two-byte code.
    static let maximumCloseReasonBytes = maximumControlPayloadBytes - 2

    var opcode: WebSocketOpcode
    var payload: Data
    var isFinal: Bool
    /// The key the payload arrived masked with. Encoding takes its key separately.
    var maskKey: UInt32?

    init(opcode: WebSocketOpcode, payload: Data = Data(), isFinal: Bool = true, maskKey: UInt32? = nil) {
        self.opcode = opcode
        self.payload = payload
        self.isFinal = isFinal
        self.maskKey = maskKey
    }

    /// A close frame. With no code it has no payload; a reason too long for
    /// the frame is cut at the last whole character that fits.
    static func close(_ code: WebSocketCloseCode?, reason: String = "") -> WebSocketFrame {
        guard let code else { return WebSocketFrame(opcode: .close) }
        var payload = Data([UInt8(code.rawValue >> 8), UInt8(code.rawValue & 0xFF)])
        var reasonBytes = 0
        for character in reason {
            let count = character.utf8.count
            guard reasonBytes + count <= maximumCloseReasonBytes else { break }
            payload.append(contentsOf: character.utf8)
            reasonBytes += count
        }
        return WebSocketFrame(opcode: .close, payload: payload)
    }

    /// The frame's bytes on the wire, its payload masked with `maskKey` when
    /// there is one. A client passes a fresh random key for every frame; a
    /// server passes nil.
    func encoded(maskKey: UInt32?) -> Data {
        let count = payload.count
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count + 14)
        bytes.append((isFinal ? 0x80 : 0) | opcode.rawValue)
        let maskBit: UInt8 = maskKey == nil ? 0 : 0x80
        if count < 126 {
            bytes.append(maskBit | UInt8(count))
        } else if count <= Int(UInt16.max) {
            bytes.append(maskBit | 126)
            bytes.append(UInt8(truncatingIfNeeded: count >> 8))
            bytes.append(UInt8(truncatingIfNeeded: count))
        } else {
            bytes.append(maskBit | 127)
            let length = UInt64(count)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: length >> UInt64(shift)))
            }
        }
        guard let maskKey else {
            bytes.append(contentsOf: payload)
            return Data(bytes)
        }
        let key = Self.keyBytes(maskKey)
        bytes.append(contentsOf: key)
        let start = bytes.count
        bytes.append(contentsOf: payload)
        Self.applyMask(key, to: &bytes, from: start)
        return Data(bytes)
    }

    fileprivate static func keyBytes(_ key: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: key >> 24), UInt8(truncatingIfNeeded: key >> 16),
            UInt8(truncatingIfNeeded: key >> 8), UInt8(truncatingIfNeeded: key),
        ]
    }

    /// Masking and unmasking are the same XOR.
    fileprivate static func applyMask(_ key: [UInt8], to bytes: inout [UInt8], from start: Int) {
        var index = 0
        for position in start..<bytes.count {
            bytes[position] ^= key[index & 3]
            index += 1
        }
    }
}

/// Reads whole frames from a byte stream, however its bytes are split across
/// reads. Every check runs on bytes that have arrived, never on where a read
/// happened to end, so any split gives the same frames and the same violation.
/// After a violation the decoder stays where it was and throws it again.
struct WebSocketFrameDecoder: Sendable {
    let role: WebSocketRole
    private var buffer: [UInt8] = []
    private var start = 0

    init(role: WebSocketRole) {
        self.role = role
    }

    /// Bytes that have arrived but are not yet part of a returned frame.
    var bufferedByteCount: Int { buffer.count - start }

    mutating func append(_ bytes: Data) {
        if start > 0 {
            buffer.removeFirst(start)
            start = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// The next whole frame, or nil until one has arrived. A data frame whose
    /// length passes `payloadLimit` fails with `.messageTooBig` as soon as its
    /// header is in, before any of its payload is kept.
    mutating func next(payloadLimit: Int) throws(WebSocketViolation) -> WebSocketFrame? {
        let available = buffer.count - start
        guard available >= 2 else { return nil }
        let first = buffer[start]
        let second = buffer[start + 1]
        guard first & 0x70 == 0 else { throw .reservedBitsSet }
        guard let opcode = WebSocketOpcode(rawValue: first & 0x0F) else { throw .unknownOpcode }
        let isFinal = first & 0x80 != 0
        let isMasked = second & 0x80 != 0
        switch role {
        case .client where isMasked: throw .maskedServerFrame
        case .server where !isMasked: throw .unmaskedClientFrame
        default: break
        }
        let shortLength = Int(second & 0x7F)
        if opcode.isControl {
            guard isFinal else { throw .fragmentedControlFrame }
            guard shortLength <= WebSocketFrame.maximumControlPayloadBytes else { throw .oversizedControlFrame }
        }
        let lengthBytes = shortLength == 126 ? 2 : shortLength == 127 ? 8 : 0
        let headerBytes = 2 + lengthBytes + (isMasked ? 4 : 0)
        guard available >= headerBytes else { return nil }
        var length = UInt64(shortLength)
        if lengthBytes > 0 {
            length = 0
            for offset in 0..<lengthBytes {
                length = length << 8 | UInt64(buffer[start + 2 + offset])
            }
            guard length >> 63 == 0 else { throw .invalidLength }
        }
        if !opcode.isControl, length > UInt64(max(payloadLimit, 0)) { throw .messageTooBig }
        // Below the limit, or at most 125 for a control frame, so it fits an Int.
        let total = headerBytes + Int(length)
        guard available >= total else { return nil }
        var payload = Array(buffer[(start + headerBytes)..<(start + total)])
        var maskKey: UInt32?
        if isMasked {
            let keyStart = start + 2 + lengthBytes
            let key = Array(buffer[keyStart..<(keyStart + 4)])
            maskKey = key.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            WebSocketFrame.applyMask(key, to: &payload, from: 0)
        }
        start += total
        return WebSocketFrame(opcode: opcode, payload: Data(payload), isFinal: isFinal, maskKey: maskKey)
    }
}

/// A whole message: text is valid UTF-8, binary is any bytes.
enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)

    var byteCount: Int {
        switch self {
        case .text(let text): text.utf8.count
        case .binary(let data): data.count
        }
    }
}

/// What a reader hands up: whole messages, and control frames as they arrive,
/// including between the fragments of a message.
enum WebSocketInbound: Sendable, Equatable {
    case message(WebSocketMessage)
    case ping(Data)
    case pong(Data)
    case close(WebSocketClose)
}

/// Joins frames into messages and checks what RFC 6455 asks of a message:
/// fragments in order, text that is UTF-8 once whole, and at most
/// `maximumMessageBytes` of payload, which fails before the excess is kept.
struct WebSocketMessageReader: Sendable {
    let maximumMessageBytes: Int
    private var decoder: WebSocketFrameDecoder
    private var fragmentOpcode: WebSocketOpcode?
    private var fragments = Data()

    init(role: WebSocketRole = .client, maximumMessageBytes: Int) {
        decoder = WebSocketFrameDecoder(role: role)
        self.maximumMessageBytes = maximumMessageBytes
    }

    mutating func append(_ bytes: Data) {
        decoder.append(bytes)
    }

    mutating func next() throws(WebSocketViolation) -> WebSocketInbound? {
        while true {
            let limit = maximumMessageBytes - fragments.count
            guard let frame = try decoder.next(payloadLimit: limit) else { return nil }
            switch frame.opcode {
            case .ping:
                return .ping(frame.payload)
            case .pong:
                return .pong(frame.payload)
            case .close:
                return .close(try WebSocketClose(payload: frame.payload))
            case .text, .binary:
                guard fragmentOpcode == nil else { throw .expectedContinuation }
                if frame.isFinal { return .message(try Self.message(frame.opcode, frame.payload)) }
                fragmentOpcode = frame.opcode
                fragments = frame.payload
            case .continuation:
                guard let opcode = fragmentOpcode else { throw .unexpectedContinuation }
                fragments.append(frame.payload)
                guard frame.isFinal else { continue }
                let payload = fragments
                fragmentOpcode = nil
                fragments = Data()
                return .message(try Self.message(opcode, payload))
            }
        }
    }

    private static func message(_ opcode: WebSocketOpcode, _ payload: Data) throws(WebSocketViolation)
        -> WebSocketMessage
    {
        guard opcode == .text else { return .binary(payload) }
        guard let text = String(validating: payload, as: UTF8.self) else { throw .invalidUTF8 }
        return .text(text)
    }
}
