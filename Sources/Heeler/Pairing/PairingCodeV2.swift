import Darwin
import Foundation

/// One recognized QR code as the scan pipeline delivered it: Vision's decoded
/// text when it produced any, and the exact data content recovered from the
/// symbol's error-corrected codewords when the barcode descriptor was
/// available. At least one is expected to be present; which one is
/// trustworthy is the dispatch's problem (see `PairingCode.decodeScanned`).
struct ScannedQRCode: Sendable, Equatable {
    var string: String?
    var bytes: Data?
}

/// Pairing Code v2: the compact binary envelope the plugin renders as a
/// byte-mode QR segment, replacing v1's `HERDR-PAIR:1:<base64url JSON>` text
/// (see `docs/research/terminal-qr-rendering.md` for why it is raw binary).
/// v1 codes keep decoding forever — older Hosts keep their older plugin — so
/// the scan entry dispatches on what was scanned.
///
/// Wire format (all integers big-endian):
///
///     0  2   magic "HP" (0x48 0x50)
///     2  1   version 0x02
///     3  1   flags: bit0 = bootstrap credential present; other bits reserved
///     4  2   port, u16, 1...65535
///     6  1   usernameLen, 1...255
///     7  n   username, UTF-8, no whitespace
///     +  32  hostKeyFingerprint, raw SHA-256 digest bytes
///     [flags bit0: 32 bytes bootstrapSeed, u32 expiresAt unix seconds]
///     +  1   addressCount, 1...255
///     then per address: type 0x04 (4 raw IPv4 bytes), 0x06 (16 raw IPv6
///     bytes, no zone), or 0x00 (u8 hostname length 1...255 + UTF-8)
///
/// Errors map onto the v1 taxonomy: wrong magic → `badPrefix`, wrong version
/// → `unsupportedVersion`, truncated input / trailing bytes / a scanned
/// string that cannot be byte-recovered → `badEncoding`, every field-level
/// violation → `badPayload`.
extension PairingCode {
    static let v2Magic: [UInt8] = [0x48, 0x50]  // "HP"
    static let v2Version: UInt8 = 0x02

    /// Decodes whatever the scanner delivered for one QR code, dispatching
    /// between the v1 text envelope and the v2 binary envelope.
    ///
    /// Delivery order: a string with the v1 prefix takes the proven v1 path
    /// unchanged. Otherwise the descriptor-recovered bytes are authoritative
    /// — measured on this OS generation (macOS 26.5 Vision, shared codebase
    /// with iOS), `payloadStringValue` for a binary byte-mode payload is nil
    /// when the bytes are not valid UTF-8 and is truncated at the first NUL
    /// when they are, so it is NOT the Latin-1 byte-per-scalar surface this
    /// dispatch's string fallback assumes; a real v2 envelope essentially
    /// never survives it. The string fallback stays for older OS decoders
    /// that do surface Latin-1 text.
    static func decodeScanned(_ scanned: ScannedQRCode) throws(PairingCodeError) -> PairingCode {
        if let string = scanned.string, string.hasPrefix("\(prefix):") {
            return try decode(string)
        }
        if let bytes = scanned.bytes {
            return try decodeScannedBytes(bytes)
        }
        guard let string = scanned.string else {
            throw .badPrefix
        }
        return try decodeScanned(string)
    }

    /// Decodes a scanned string on its own: leading v2 magic → recover bytes
    /// (one Unicode scalar per byte, the Latin-1 reading of a byte-mode
    /// segment) and decode v2; anything else → the v1 path with its existing
    /// errors. A v1 code can never start with "HP" ("HERDR-PAIR" begins
    /// "HE"), and any scalar above U+00FF cannot come from a byte-mode
    /// payload, so recovery rejects it as `badEncoding`.
    static func decodeScanned(_ string: String) throws(PairingCodeError) -> PairingCode {
        var scalars = string.unicodeScalars.makeIterator()
        guard scalars.next() == "H", scalars.next() == "P" else {
            return try decode(string)
        }
        var bytes = Data()
        bytes.reserveCapacity(string.unicodeScalars.count)
        for scalar in string.unicodeScalars {
            guard scalar.value <= 0xFF else {
                throw .badEncoding
            }
            bytes.append(UInt8(scalar.value))
        }
        return try decodeV2(bytes)
    }

    /// Decodes recovered payload bytes: v2 magic → the binary decoder;
    /// anything else is v1 text (or not a Pairing Code at all).
    static func decodeScannedBytes(_ data: Data) throws(PairingCodeError) -> PairingCode {
        if data.starts(with: v2Magic) {
            return try decodeV2(data)
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw .badPrefix
        }
        return try decode(string)
    }

    /// Decodes and validates a v2 binary envelope.
    static func decodeV2(_ data: Data) throws(PairingCodeError) -> PairingCode {
        var reader = V2Reader(data)
        guard try reader.take(2) == v2Magic else {
            throw .badPrefix
        }
        let version = try reader.byte()
        guard version == v2Version else {
            throw .unsupportedVersion(found: String(version))
        }
        let flags = try reader.byte()
        guard flags & ~0x01 == 0 else {
            throw .badPayload(reason: "reserved flag bits set (flags \(flags))")
        }
        let port = try reader.uint16()
        guard port > 0 else {
            throw .badPayload(reason: "port must be in 1..65535")
        }
        let usernameLength = try reader.byte()
        guard usernameLength > 0 else {
            throw .badPayload(reason: "usernameLen must be in 1..255")
        }
        let username = try utf8String(reader.take(Int(usernameLength)), field: "username")
        guard !containsWhitespace(username) else {
            throw .badPayload(reason: "username must not contain whitespace")
        }
        // The wire carries the raw digest; in memory the fingerprint keeps
        // its v1 form and re-encodes to "SHA256:<unpadded base64>" on demand.
        let fingerprint = HostKeyFingerprint(digest: Data(try reader.take(32)))

        let bootstrap: Bootstrap?
        if flags & 0x01 != 0 {
            let seed = Data(try reader.take(32))
            let expiresAt = try reader.uint32()
            guard expiresAt > 0 else {
                throw .badPayload(reason: "expiresAt must be a positive unix-seconds integer")
            }
            bootstrap = Bootstrap(
                seed: seed, expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAt)))
        } else {
            bootstrap = nil
        }

        let addressCount = try reader.byte()
        guard addressCount > 0 else {
            throw .badPayload(reason: "addressCount must be in 1..255")
        }
        var addresses: [String] = []
        addresses.reserveCapacity(Int(addressCount))
        for _ in 0..<addressCount {
            addresses.append(try address(&reader))
        }
        guard reader.isAtEnd else {
            throw .badEncoding
        }

        return PairingCode(
            addresses: addresses, port: Int(port), username: username,
            hostKeyFingerprint: fingerprint, bootstrap: bootstrap)
    }

    private static func address(_ reader: inout V2Reader) throws(PairingCodeError) -> String {
        switch try reader.byte() {
        case 0x04:
            return try reader.take(4).map { String($0) }.joined(separator: ".")
        case 0x06:
            guard let text = ipv6String(try reader.take(16)) else {
                throw .badPayload(reason: "unrepresentable IPv6 address")
            }
            return text
        case 0x00:
            let length = try reader.byte()
            guard length > 0 else {
                throw .badPayload(reason: "hostname length must be in 1..255")
            }
            let hostname = try utf8String(reader.take(Int(length)), field: "hostname")
            guard !containsWhitespace(hostname) else {
                throw .badPayload(reason: "hostname must not contain whitespace")
            }
            return hostname
        case let type:
            throw .badPayload(reason: "unknown address type \(type)")
        }
    }

    private static func utf8String(
        _ bytes: [UInt8], field: String
    ) throws(PairingCodeError) -> String {
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw .badPayload(reason: "\(field) is not valid UTF-8")
        }
        return text
    }

    /// RFC 5952 canonical text for 16 raw IPv6 bytes. Darwin's `inet_ntop`
    /// already produces it: lowercase hex, the first longest all-zero run
    /// compressed to `::`, never a single group.
    private static func ipv6String(_ raw: [UInt8]) -> String? {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: raw) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return nil
        }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Sequential big-endian reader over the v2 envelope. Running out of bytes is
/// always the truncated-input rejection, `badEncoding`.
private struct V2Reader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func byte() throws(PairingCodeError) -> UInt8 {
        guard offset < bytes.count else { throw .badEncoding }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func take(_ count: Int) throws(PairingCodeError) -> [UInt8] {
        guard bytes.count - offset >= count else { throw .badEncoding }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func uint16() throws(PairingCodeError) -> UInt16 {
        let raw = try take(2)
        return UInt16(raw[0]) << 8 | UInt16(raw[1])
    }

    mutating func uint32() throws(PairingCodeError) -> UInt32 {
        try take(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
