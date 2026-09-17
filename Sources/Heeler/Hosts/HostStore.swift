import Foundation
import Observation

enum HostStoreError: Error, Equatable {
    /// `update`/`remove` addressed a Host id the catalog does not contain.
    case unknownHost
    /// Persisted bytes could not be decoded. They are deliberately left
    /// untouched so a later write cannot turn a recoverable catalog into loss.
    case catalogUnreadable
}

/// Owns the Host catalog: add/edit/remove plus persistence. Host records go
/// to UserDefaults (no secrets in them); passwords go straight to the
/// injected `SecretStore` (the Keychain in the app), keyed by Host id.
@MainActor
@Observable
final class HostStore {
    private static let defaultsKey = "hosts"
    private static let catalogVersion = 1

    /// Decodes each Host through its own decoder so a future authentication
    /// method hides only that Host from an older build. Other malformed Host
    /// data still fails the catalog instead of being discarded silently. The
    /// unrecognized future entries survive later writes from this build.
    private struct PersistedHosts: Codable {
        enum Entry {
            case known(Host)
            case unknown(JSONValue)

            var knownHost: Host? {
                guard case .known(let host) = self else { return nil }
                return host
            }

            var knownHostID: Host.ID? { knownHost?.id }
        }

        let entries: [Entry]
        var values: [Host] { entries.compactMap(\.knownHost) }

        init(entries: [Entry]) {
            self.entries = entries
        }

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var entries: [Entry] = []
            while !container.isAtEnd {
                let rawHost = try container.decode(JSONValue.self)
                guard let authMethodValue = rawHost["authMethod"]?.stringValue else {
                    throw HostStoreError.catalogUnreadable
                }
                guard Host.AuthMethod(rawValue: authMethodValue) != nil else {
                    entries.append(.unknown(rawHost))
                    continue
                }
                let data = try JSONEncoder().encode(rawHost)
                entries.append(.known(try JSONDecoder().decode(Host.self, from: data)))
            }
            self.entries = entries
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            for entry in entries {
                switch entry {
                case .known(let host):
                    try container.encode(host)
                case .unknown(let rawHost):
                    try container.encode(rawHost)
                }
            }
        }
    }

    private struct PersistedCatalog: Codable {
        let version: Int
        let hosts: PersistedHosts
    }

    private(set) var hosts: [Host]
    private(set) var catalogLoadError: HostStoreError?
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults?
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private var catalogEntries: [PersistedHosts.Entry]

    init(
        defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainSecretStore(service: "dev.bybee.heeler.ssh")
    ) {
        self.defaults = defaults
        self.secrets = secrets
        catalogEntries = []
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            hosts = []
            catalogLoadError = nil
            return
        }
        do {
            let decoder = JSONDecoder()
            if let catalog = try? decoder.decode(PersistedCatalog.self, from: data) {
                guard catalog.version == Self.catalogVersion else {
                    throw HostStoreError.catalogUnreadable
                }
                hosts = catalog.hosts.values
                catalogEntries = catalog.hosts.entries
            } else {
                // Version 0 was the bare Host array. Decode it once, then
                // immediately persist the versioned envelope.
                let legacyHosts = try decoder.decode(PersistedHosts.self, from: data)
                hosts = legacyHosts.values
                catalogEntries = legacyHosts.entries
                defaults.set(
                    try Self.encodedCatalog(entries: catalogEntries),
                    forKey: Self.defaultsKey)
            }
            catalogLoadError = nil
        } catch {
            hosts = []
            catalogEntries = []
            catalogLoadError = .catalogUnreadable
        }
    }

    /// A process-local catalog for previews and development compositions.
    /// Mutations remain in memory, and secrets use process-local storage.
    init(volatileHosts: [Host]) {
        defaults = nil
        secrets = VolatileSecretStore()
        hosts = volatileHosts
        catalogEntries = volatileHosts.map(PersistedHosts.Entry.known)
        catalogLoadError = nil
    }

    /// Adds a Host, storing `password` in the secret store when given.
    func add(_ host: Host, password: String? = nil) throws {
        try ensureCatalogIsWritable()
        try applyPassword(password, to: host)
        hosts.append(host)
        catalogEntries.append(.known(host))
        try persist()
    }

    /// Replaces the stored Host with the same id. `password` nil leaves any
    /// stored password untouched, so editing unrelated fields never requires
    /// re-entering it.
    func update(_ host: Host, password: String? = nil) throws {
        try ensureCatalogIsWritable()
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else {
            throw HostStoreError.unknownHost
        }
        try applyPassword(password, to: host)
        hosts[index] = host
        guard let entryIndex = catalogEntries.firstIndex(where: {
            $0.knownHostID == host.id
        }) else {
            throw HostStoreError.catalogUnreadable
        }
        catalogEntries[entryIndex] = .known(host)
        try persist()
    }

    /// Removes the Host and its stored password.
    func remove(_ id: Host.ID) throws {
        try ensureCatalogIsWritable()
        guard let index = hosts.firstIndex(where: { $0.id == id }) else {
            throw HostStoreError.unknownHost
        }
        try secrets.removeSecret(account: Self.passwordAccount(for: id))
        hosts.remove(at: index)
        catalogEntries.removeAll { $0.knownHostID == id }
        try persist()
    }

    /// The stored password for a Host, or nil when none was saved.
    func password(for host: Host) throws -> String? {
        try secrets.read(account: Self.passwordAccount(for: host.id))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Keychain account for a Host's password; shared with
    /// `HostCredentialsProvider` so lookup and storage cannot drift.
    nonisolated static func passwordAccount(for id: Host.ID) -> String {
        "host-password-\(id.uuidString)"
    }

    private func applyPassword(_ password: String?, to host: Host) throws {
        let account = Self.passwordAccount(for: host.id)
        switch host.authMethod {
        case .deviceKey, .rsaKey:
            // Secret hygiene: a Host switched off password auth keeps no
            // stale password around.
            try secrets.removeSecret(account: account)
        case .password:
            if let password {
                try secrets.write(Data(password.utf8), account: account)
            }
        }
    }

    private func ensureCatalogIsWritable() throws {
        if catalogLoadError != nil {
            throw HostStoreError.catalogUnreadable
        }
    }

    private func persist() throws {
        defaults?.set(
            try Self.encodedCatalog(entries: catalogEntries),
            forKey: Self.defaultsKey)
    }

    private static func encodedCatalog(entries: [PersistedHosts.Entry]) throws -> Data {
        try JSONEncoder().encode(
            PersistedCatalog(
                version: catalogVersion,
                hosts: PersistedHosts(entries: entries)))
    }
}
