import Foundation

enum RSAKeyStoreError: Error, Equatable {
    /// The stored bytes no longer parse as an RSA key. Never silently replace
    /// them because every registered public key would stop working.
    case storedKeyCorrupt
}

/// Loads the RSA identity, generating it on first use. Its private
/// PKCS#1 bytes live only in the backing `SecretStore` (Keychain in the app)
/// and in memory while the key is used.
struct RSAKeyStore: Sendable {
    private let secrets: any SecretStore
    private let account: String

    init(
        secrets: any SecretStore = KeychainSecretStore(service: "dev.bybee.heeler.ssh"),
        account: String = "rsa-private-key"
    ) {
        self.secrets = secrets
        self.account = account
    }

    func loadOrCreate() throws -> RSAKey {
        if let stored = try secrets.read(account: account) {
            guard let key = try? RSAKey(privateKeyDER: stored) else {
                throw RSAKeyStoreError.storedKeyCorrupt
            }
            return key
        }
        let key = try RSAKey.generate()
        try secrets.write(key.privateKeyDER, account: account)
        return key
    }

    /// Replaces the identity only after a user-approved recovery flow. Every
    /// Host registration for the previous public key then needs updating.
    func replaceStoredKey() throws -> RSAKey {
        let key = try RSAKey.generate()
        try secrets.write(key.privateKeyDER, account: account)
        return key
    }
}
