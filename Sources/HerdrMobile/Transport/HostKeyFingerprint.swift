import CryptoKit
import Foundation

/// An OpenSSH-style host key fingerprint: SHA-256 over the SSH wire-format
/// public key blob. This is what the user confirms on first connect and what
/// the known-hosts store persists for TOFU.
struct HostKeyFingerprint: Sendable, Hashable {
    /// The 32-byte SHA-256 digest.
    let digest: Data

    init(publicKeyBlob: Data) {
        digest = Data(SHA256.hash(data: publicKeyBlob))
    }

    /// Reconstructs a fingerprint from a previously stored digest.
    init(digest: Data) {
        self.digest = digest
    }

    /// The presentation OpenSSH prints: `SHA256:<base64 without padding>`.
    var displayString: String {
        "SHA256:" + digest.base64EncodedString().trimmingCharacters(in: ["="])
    }
}
