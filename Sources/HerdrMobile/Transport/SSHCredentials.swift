import CryptoKit
import Foundation

/// How the app authenticates to a Host. Key auth uses the device key from
/// `DeviceKeyStore`; password is the fallback for Hosts where key setup has
/// not happened yet.
enum SSHCredentials: Sendable {
    case ed25519(Curve25519.Signing.PrivateKey)
    case password(String)
}
