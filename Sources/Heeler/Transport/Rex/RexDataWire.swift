import Foundation

/// The handshake of a Rex data connection (ADR 0051), written by hand from
/// what Rex 0.1.0-preview.14 (API revision 12) was seen to do. A data
/// connection is a one-way WebSocket at `/api/data`: one block's output flows
/// to this side. This side speaks first, either a HELLO that spends a
/// `data.connect` ticket or a RESUME that picks a dropped stream back up from
/// the last WELCOME's token and this side's own count of stream bytes. One
/// binary message answers it, a WELCOME or a REJECT. Every number in them is
/// an unsigned little-endian integer.
enum RexDataProtocol {
    static let path = "/api/data"
    /// The subprotocol of a terminal's stream.
    static let terminalSubprotocol = "rex.data.terminal.v1"
    /// The data source a terminal block offers its output under.
    static let terminalDataSource = "terminal"
    /// The size of a ticket and of a resume token.
    static let credentialByteCount = 16

    static let helloType: UInt8 = 0x01
    static let resumeType: UInt8 = 0x02
    static let welcomeType: UInt8 = 0x81
    static let rejectType: UInt8 = 0x82
    static let welcomeByteCount = 32
    static let rejectByteCount = 2
}

/// The single-use ticket `data.connect` hands out for one HELLO. It is a
/// credential: it never appears in a description, a log, or an error.
struct RexDataTicket: Sendable, Equatable {
    fileprivate let bytes: [UInt8]

    /// The ticket as `data.connect` writes it: 16 bytes in base64url with no
    /// padding. Nil for anything else.
    init?(text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !base64.contains("=") else { return nil }
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        self.init(bytes: [UInt8](data))
    }

    init?(bytes: [UInt8]) {
        guard bytes.count == RexDataProtocol.credentialByteCount else { return nil }
        self.bytes = bytes
    }
}

/// The token a WELCOME hands out for resuming its stream on a new
/// connection. Each WELCOME replaces the one before. It is a credential: it
/// never appears in a description, a log, or an error.
struct RexDataResumeToken: Sendable, Equatable {
    fileprivate let bytes: [UInt8]

    init?(bytes: [UInt8]) {
        guard bytes.count == RexDataProtocol.credentialByteCount else { return nil }
        self.bytes = bytes
    }
}

extension RexDataTicket: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "RexDataTicket(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

extension RexDataResumeToken: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "RexDataResumeToken(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// What a WELCOME says about the stream it opened or resumed.
struct RexDataWelcome: Sendable, Equatable {
    let resumeToken: RexDataResumeToken
    /// How long a dropped stream waits on the server for a RESUME.
    let retention: Duration
    /// Tags the sequences the stream adds itself, which is how they differ
    /// from copies a program prints. A resumed stream keeps it.
    let nonce: UInt64
}

/// Why the server turned a handshake down. Neither kind can be tried again
/// as it was: a refused HELLO has spent its ticket, and a refused RESUME's
/// stream no longer exists. The way on is always a new ticket and a HELLO.
enum RexDataRefusal: Sendable, Equatable {
    /// 1: the server will not take the credential: it does not know it, it
    /// is stale or spent, it is another client's, or its session has gone.
    case unknownCredential
    /// 2: the server still counts a link of this client's to the block's
    /// data source, and allows a client only one.
    case alreadyConnected
    /// 3: there is no stream to serve: its block closed, say, or a RESUME
    /// claimed fewer bytes than had been sent.
    case streamUnavailable
    /// 4: the server is at a limit; worth trying later.
    case limitReached
    /// 5: the handshake was garbled or came too late, or a RESUME claimed
    /// more bytes than had been sent.
    case malformedHandshake
    /// 6: something failed on the server's side.
    case serverFailed
    /// 7: the credential belongs to a different subprotocol.
    case wrongSubprotocol
    /// A reason this build does not know: a failure all the same.
    case other(UInt8)

    init(reason: UInt8) {
        switch reason {
        case 1: self = .unknownCredential
        case 2: self = .alreadyConnected
        case 3: self = .streamUnavailable
        case 4: self = .limitReached
        case 5: self = .malformedHandshake
        case 6: self = .serverFailed
        case 7: self = .wrongSubprotocol
        default: self = .other(reason)
        }
    }

    var reason: UInt8 {
        switch self {
        case .unknownCredential: 1
        case .alreadyConnected: 2
        case .streamUnavailable: 3
        case .limitReached: 4
        case .malformedHandshake: 5
        case .serverFailed: 6
        case .wrongSubprotocol: 7
        case .other(let reason): reason
        }
    }
}

/// The handshake messages as bytes.
enum RexDataHandshake {
    /// What the server answered a HELLO or a RESUME with.
    enum Answer: Sendable, Equatable {
        case welcome(RexDataWelcome)
        case refused(RexDataRefusal)
        /// Not a WELCOME or a REJECT of the right size.
        case unreadable
    }

    /// HELLO: the type byte, then the ticket's 16 bytes.
    static func hello(_ ticket: RexDataTicket) -> Data {
        Data([RexDataProtocol.helloType] + ticket.bytes)
    }

    /// RESUME: the type byte and the newest token's 16 bytes, followed by a
    /// 64-bit count of the stream bytes read so far.
    static func resume(_ token: RexDataResumeToken, receivedByteCount: UInt64) -> Data {
        Data([RexDataProtocol.resumeType] + token.bytes + littleEndianBytes(receivedByteCount))
    }

    /// Reads the server's answer. A WELCOME has a fixed 32 bytes: type,
    /// token, three bytes of zero padding, a 32-bit retention in milliseconds
    /// and a 64-bit nonce. A REJECT is two bytes, its type and then a reason.
    static func answer(_ message: Data) -> Answer {
        let bytes = [UInt8](message)
        switch bytes.first {
        case RexDataProtocol.welcomeType where bytes.count == RexDataProtocol.welcomeByteCount:
            guard let token = RexDataResumeToken(bytes: Array(bytes[1...16])) else { return .unreadable }
            let retention = littleEndian(bytes[20..<24])
            let nonce = littleEndian(bytes[24..<32])
            return .welcome(RexDataWelcome(resumeToken: token, retention: .milliseconds(retention), nonce: nonce))
        case RexDataProtocol.rejectType where bytes.count == RexDataProtocol.rejectByteCount:
            return .refused(RexDataRefusal(reason: bytes[1]))
        default:
            return .unreadable
        }
    }

    private static func littleEndianBytes(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
}
