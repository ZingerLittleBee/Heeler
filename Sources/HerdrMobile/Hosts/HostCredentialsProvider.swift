import Foundation

enum HostCredentialsError: Error, Equatable {
    /// The Host authenticates by password but none is stored.
    case passwordNotSet
}

/// Resolves a Host's `SSHCredentials`: the device key (generated on first
/// use) or the Keychain-stored password. Secrets stay inside the stores;
/// this type only hands them onward to the transport.
struct HostCredentialsProvider: Sendable {
    private let deviceKeys: DeviceKeyStore
    private let secrets: any SecretStore

    init(
        deviceKeys: DeviceKeyStore = DeviceKeyStore(),
        secrets: any SecretStore = KeychainSecretStore(service: "dev.herdr.mobile.ssh")
    ) {
        self.deviceKeys = deviceKeys
        self.secrets = secrets
    }

    func credentials(for host: Host) throws -> SSHCredentials {
        switch host.authMethod {
        case .deviceKey:
            return .ed25519(try deviceKeys.loadOrCreate().privateKey)
        case .password:
            guard
                let data = try secrets.read(account: HostStore.passwordAccount(for: host.id)),
                !data.isEmpty
            else {
                throw HostCredentialsError.passwordNotSet
            }
            return .password(String(decoding: data, as: UTF8.self))
        }
    }

    /// The device public key material shown during Host setup.
    func deviceKey() throws -> DeviceKey {
        try deviceKeys.loadOrCreate()
    }

    /// User-approved recovery for a corrupt device key. Callers must explain
    /// that every device-key Host will need the replacement public key.
    func replaceDeviceKey() throws -> DeviceKey {
        try deviceKeys.replaceStoredKey()
    }
}
