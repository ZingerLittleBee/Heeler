import Foundation
import Observation

enum HostStoreError: Error, Equatable {
    /// `update`/`remove` addressed a Host id the catalog does not contain.
    case unknownHost
}

/// Owns the Host catalog: add/edit/remove plus persistence. Host records go
/// to UserDefaults (no secrets in them); passwords go straight to the
/// injected `SecretStore` (the Keychain in the app), keyed by Host id.
@MainActor
@Observable
final class HostStore {
    private static let defaultsKey = "hosts"

    private(set) var hosts: [Host]
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStore

    init(
        defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainSecretStore(service: "dev.herdr.mobile.ssh")
    ) {
        self.defaults = defaults
        self.secrets = secrets
        if let data = defaults.data(forKey: Self.defaultsKey),
            let stored = try? JSONDecoder().decode([Host].self, from: data)
        {
            hosts = stored
        } else {
            hosts = []
        }
    }

    /// Adds a Host, storing `password` in the secret store when given.
    func add(_ host: Host, password: String? = nil) throws {
        try applyPassword(password, to: host)
        hosts.append(host)
        try persist()
    }

    /// Replaces the stored Host with the same id. `password` nil leaves any
    /// stored password untouched, so editing unrelated fields never requires
    /// re-entering it.
    func update(_ host: Host, password: String? = nil) throws {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else {
            throw HostStoreError.unknownHost
        }
        try applyPassword(password, to: host)
        hosts[index] = host
        try persist()
    }

    /// Removes the Host and its stored password.
    func remove(_ id: Host.ID) throws {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else {
            throw HostStoreError.unknownHost
        }
        try secrets.removeSecret(account: Self.passwordAccount(for: id))
        hosts.remove(at: index)
        try persist()
    }

    /// The stored password for a Host, or nil when none was saved.
    func password(for host: Host) throws -> String? {
        try secrets.read(account: Self.passwordAccount(for: host.id))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Keychain account for a Host's password; shared with
    /// `HostCredentialsProvider` so lookup and storage cannot drift.
    static func passwordAccount(for id: Host.ID) -> String {
        "host-password-\(id.uuidString)"
    }

    private func applyPassword(_ password: String?, to host: Host) throws {
        let account = Self.passwordAccount(for: host.id)
        switch host.authMethod {
        case .deviceKey:
            // Secret hygiene: a Host switched off password auth keeps no
            // stale password around.
            try secrets.removeSecret(account: account)
        case .password:
            if let password {
                try secrets.write(Data(password.utf8), account: account)
            }
        }
    }

    private func persist() throws {
        defaults.set(try JSONEncoder().encode(hosts), forKey: Self.defaultsKey)
    }
}
