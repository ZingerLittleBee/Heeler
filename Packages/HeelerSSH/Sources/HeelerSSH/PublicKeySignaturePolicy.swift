import Foundation

/// Decides whether a public-key user-auth request may be signed at all.
///
/// libssh2 upgrades an `ssh-rsa` key to the pinned `LIBSSH2_METHOD_SIGN_ALGO`
/// preference only when the server advertised `server-sig-algs`. Without that
/// extension it keeps the legacy `ssh-rsa` (SHA-1) algorithm name, which
/// contradicts the RSA-SHA2-512 signature the signer always produces, and the
/// server then reports an ordinary authentication failure. The algorithm
/// libssh2 settled on is part of the data it asks the signer to sign
/// (RFC 4252 section 7), so the choice is checked there rather than trusting
/// that the preference applied.
enum PublicKeySignaturePolicy {
    private static let userAuthRequest: UInt8 = 50

    /// Whether the signer may sign `signedData` for the key in `publicKey`.
    /// Keys other than `ssh-rsa` carry a single signature algorithm and are
    /// not constrained here.
    static func permits(publicKey: Data, signedData: Data) -> Bool {
        var key = SSHWireReader(publicKey)
        guard let keyType = key.readString() else { return false }
        guard keyType == Data("ssh-rsa".utf8) else { return true }
        guard let algorithm = requestedAlgorithm(in: signedData) else { return false }
        return SessionDriver.signatureAlgorithms.contains(algorithm)
    }

    /// The public-key algorithm name inside the user-auth data to be signed:
    /// `string session_id`, `byte SSH_MSG_USERAUTH_REQUEST`, `string user`,
    /// `string "ssh-connection"`, `string "publickey"`, `bool TRUE`,
    /// `string algorithm`, `string public_key`.
    static func requestedAlgorithm(in signedData: Data) -> String? {
        var reader = SSHWireReader(signedData)
        guard
            reader.readString() != nil,
            reader.readByte() == userAuthRequest,
            reader.readString() != nil,
            reader.readString() == Data("ssh-connection".utf8),
            reader.readString() == Data("publickey".utf8),
            reader.readByte() == 1,
            let algorithm = reader.readString()
        else { return nil }
        return String(data: algorithm, encoding: .utf8)
    }
}

private struct SSHWireReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    mutating func readByte() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readString() -> Data? {
        guard bytes.count - offset >= 4 else { return nil }
        let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        guard length <= bytes.count - offset - 4 else { return nil }
        let start = offset + 4
        offset = start + length
        return Data(bytes[start..<offset])
    }
}
