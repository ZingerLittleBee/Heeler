import Foundation

/// Strict unpadded base64url (RFC 4648 `-`/`_` alphabet), the byte encoding
/// shared by every cross-implementation wire format in this app (Pairing
/// Code, notification envelope). Decoding rejects other characters, padding,
/// empty input, and impossible lengths, matching the plugin.
extension Data {
    /// Decodes strict unpadded base64url text, or nil if it is not that.
    init?(base64URLEncoded text: String) {
        guard
            !text.isEmpty, text.count % 4 != 1,
            text.utf8.allSatisfy(Self.isBase64URLByte)
        else { return nil }
        let base64 =
            text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        self = data
    }

    /// Encodes as unpadded base64url.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"),
            UInt8(ascii: "-"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }
}
