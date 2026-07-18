import CryptoKit
import Foundation

/// The device's SSH identity: an Ed25519 keypair generated on this device.
/// The private key's raw bytes live only in the Keychain (`DeviceKeyStore`)
/// and are never exported; this type hands the key object to the SSH layer
/// and derives the public material shown during Host setup.
struct DeviceKey: Sendable {
    let privateKey: Curve25519.Signing.PrivateKey

    /// SSH wire-format public key blob (RFC 4253 §6.6):
    /// `string "ssh-ed25519"` + `string <32 raw key bytes>`. The same bytes
    /// OpenSSH base64-encodes in `authorized_keys` and hashes for SHA256
    /// fingerprints.
    var publicKeyBlob: Data {
        var blob = Data()
        blob.appendSSHString(Data("ssh-ed25519".utf8))
        blob.appendSSHString(privateKey.publicKey.rawRepresentation)
        return blob
    }

    /// The public key in OpenSSH one-line format, without comment.
    var openSSHPublicKey: String {
        "ssh-ed25519 " + publicKeyBlob.base64EncodedString()
    }

    /// Copy-pasteable `authorized_keys` line for Host setup.
    func authorizedKeysLine(comment: String) -> String {
        openSSHPublicKey + " " + comment
    }
}

extension Data {
    /// Appends an SSH wire-format string: big-endian UInt32 length + bytes.
    fileprivate mutating func appendSSHString(_ bytes: Data) {
        var length = UInt32(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(bytes)
    }
}
