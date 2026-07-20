import CryptoKit
import Foundation

/// An OpenSSH-style host key fingerprint: SHA-256 over the SSH wire-format
/// public key blob. This is what the user confirms on first connect and what
/// the known-hosts store persists for TOFU.
struct HostKeyFingerprint: Sendable, Hashable {
    /// Marker for legacy entries that predate algorithm-aware persistence.
    static let unknownAlgorithm = "*"

    /// The 32-byte SHA-256 digest.
    let digest: Data
    /// SSH key algorithm encoded as the first string in the public-key blob.
    let algorithm: String

    init(publicKeyBlob: Data) {
        digest = Data(SHA256.hash(data: publicKeyBlob))
        algorithm = Self.readAlgorithm(from: publicKeyBlob) ?? Self.unknownAlgorithm
    }

    /// Reconstructs a fingerprint from a previously stored digest.
    init(digest: Data, algorithm: String = HostKeyFingerprint.unknownAlgorithm) {
        self.digest = digest
        self.algorithm = algorithm
    }

    /// The presentation OpenSSH prints: `SHA256:<base64 without padding>`.
    var displayString: String {
        "SHA256:" + digest.base64EncodedString().trimmingCharacters(in: ["="])
    }

    static func == (lhs: HostKeyFingerprint, rhs: HostKeyFingerprint) -> Bool {
        lhs.digest == rhs.digest
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(digest)
    }

    private static func readAlgorithm(from blob: Data) -> String? {
        guard blob.count >= MemoryLayout<UInt32>.size else { return nil }
        let length = blob.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= 256, blob.count >= 4 + Int(length) else { return nil }
        let start = blob.index(blob.startIndex, offsetBy: 4)
        let end = blob.index(start, offsetBy: Int(length))
        guard let algorithm = String(data: blob[start..<end], encoding: .utf8) else { return nil }
        return algorithm.unicodeScalars.allSatisfy { $0.isASCII && !$0.properties.isWhitespace }
            ? algorithm : nil
    }
}
