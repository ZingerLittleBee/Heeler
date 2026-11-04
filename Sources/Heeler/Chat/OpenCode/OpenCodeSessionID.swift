import Foundation

/// An OpenCode session id as herdr's OpenCode integration reports it: `ses_`,
/// 12 lowercase hexadecimal digits and 14 ASCII letters or digits
/// (OpenCode 2.0.32). Checked before the id reaches a query, a cache key or
/// a Host script (ADR 0025), and kept as reported: OpenCode ids are
/// case-sensitive.
struct OpenCodeSessionID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    private static let prefix = Array("ses_".utf8)
    private static let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
    private static let lowercaseHex = UInt8(ascii: "a")...UInt8(ascii: "f")
    private static let lowercase = UInt8(ascii: "a")...UInt8(ascii: "z")
    private static let uppercase = UInt8(ascii: "A")...UInt8(ascii: "Z")

    init?(_ value: String) {
        let bytes = Array(value.utf8)
        guard bytes.count == 30, bytes.starts(with: Self.prefix),
            bytes[4..<16].allSatisfy({ Self.digits.contains($0) || Self.lowercaseHex.contains($0) }),
            bytes[16...].allSatisfy({
                Self.digits.contains($0) || Self.lowercase.contains($0) || Self.uppercase.contains($0)
            })
        else { return nil }
        rawValue = value
    }

    var description: String { rawValue }
}
