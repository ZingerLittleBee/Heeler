import CryptoKit
import Foundation

enum DeviceKeyStoreError: Error, Equatable {
    /// The stored bytes no longer parse as an Ed25519 key. Surfaced, never
    /// silently regenerated: a new key would lock the user out of every Host
    /// without explanation.
    case storedKeyCorrupt
}

/// Loads the device's SSH key, generating it on first use. The private key's
/// raw bytes exist only inside the backing `SecretStore` (the Keychain in the
/// app) and the in-memory CryptoKit object; there is no export path.
struct DeviceKeyStore: Sendable {
    private let secrets: any SecretStore
    private let account: String

    init(
        secrets: any SecretStore = KeychainSecretStore(service: "dev.herdr.mobile.ssh"),
        account: String = "device-ed25519-private-key"
    ) {
        self.secrets = secrets
        self.account = account
    }

    func loadOrCreate() throws -> DeviceKey {
        if let stored = try secrets.read(account: account) {
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: stored) else {
                throw DeviceKeyStoreError.storedKeyCorrupt
            }
            return DeviceKey(privateKey: key)
        }
        let key = Curve25519.Signing.PrivateKey()
        try secrets.write(key.rawRepresentation, account: account)
        return DeviceKey(privateKey: key)
    }
}
