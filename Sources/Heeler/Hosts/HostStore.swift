import Foundation
import Observation

enum HostStoreError: Error, Equatable {
    /// `update`/`remove` addressed a Host id the catalog does not contain.
    case unknownHost
    /// `update` was handed a Host of another Server Kind, or a confirmation
    /// named no kind (ADR 0031).
    case serverKindChanged
    /// The Host's Server Kind is already confirmed, and stays as it is.
    case serverKindAlreadyConfirmed
    /// The kind's server would refuse the Host's session name, for this reason.
    case sessionNameRefused(reason: String)
    /// Persisted bytes could not be decoded. They are deliberately left
    /// untouched so a later write cannot turn a recoverable catalog into loss.
    case catalogUnreadable
}

/// Owns the Host catalog: add/edit/remove plus persistence. Host records go
/// to UserDefaults (no secrets in them); passwords go straight to the
/// injected `SecretStore` (the Keychain in the app), keyed by Host id.
///
/// The catalog is stored in two parts of one shape. Herdr TUI Hosts and Hosts
/// not yet confirmed stay in the shared one every build reads. herdr-core Hosts
/// live in a second one, with the merged Host order, that builds before Server
/// Kinds never read, so such a build can neither show one nor re-save it as
/// Herdr TUI (ADR 0031).
@MainActor
@Observable
final class HostStore {
    private static let defaultsKey = "hosts"
    private static let coreDefaultsKey = "herdrCoreHosts"
    private static let catalogVersion = 1

    /// Decodes each Host through its own decoder so a future authentication
    /// method, Server Kind, or herdr endpoint this build cannot read hides only that
    /// Host from an older build. Other malformed Host data still fails the
    /// catalog instead of being discarded silently. The unrecognized future
    /// entries survive later writes from this build.
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
                if let serverKind = rawHost["serverKind"]?.stringValue,
                    ServerKind(rawValue: serverKind) == nil
                {
                    entries.append(.unknown(rawHost))
                    continue
                }
                // Dropping an endpoint would point the Host at the user's own
                // herdr, so a Host whose endpoint does not decode stays hidden.
                if let rawEndpoint = rawHost["herdrEndpoint"], rawEndpoint != .null,
                    !Self.isReadableEndpoint(rawEndpoint)
                {
                    entries.append(.unknown(rawHost))
                    continue
                }
                let data = try JSONEncoder().encode(rawHost)
                entries.append(.known(try JSONDecoder().decode(Host.self, from: data)))
            }
            self.entries = entries
        }

        private static func isReadableEndpoint(_ rawEndpoint: JSONValue) -> Bool {
            guard let data = try? JSONEncoder().encode(rawEndpoint) else { return false }
            return (try? JSONDecoder().decode(HerdrEndpoint.self, from: data)) != nil
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
        /// The merged Host order, kept only with the herdr-core catalog. Ids it
        /// lacks follow it in the shared catalog's order, which is how a Host
        /// added since, here or by an older build, stays last.
        var order: [Host.ID]?
    }

    private(set) var hosts: [Host]
    private(set) var catalogLoadError: HostStoreError?
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults?
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private var catalogEntries: [PersistedHosts.Entry]
    @ObservationIgnored private var coreCatalogEntries: [PersistedHosts.Entry]

    init(
        defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainSecretStore(service: "dev.bybee.heeler.ssh")
    ) {
        self.defaults = defaults
        self.secrets = secrets
        do {
            var shared = try Self.loadSharedEntries(from: defaults)
            let core = try Self.loadCoreCatalog(from: defaults)
            let coreEntries = core?.hosts.entries ?? []
            // A Host found in both is herdr-core. Its shared copy goes now, so
            // an older build cannot show it and removing the Host cannot bring
            // it back as Herdr TUI.
            let coreIDs = Set(coreEntries.compactMap(\.knownHostID))
            let sharedCount = shared.count
            shared.removeAll { $0.knownHostID.map(coreIDs.contains) == true }
            if shared.count != sharedCount {
                defaults.set(try Self.encodedCatalog(entries: shared), forKey: Self.defaultsKey)
            }
            hosts = Self.mergedHosts(shared: shared, core: coreEntries, order: core?.order ?? [])
            catalogEntries = shared
            coreCatalogEntries = coreEntries
            catalogLoadError = nil
        } catch {
            hosts = []
            catalogEntries = []
            coreCatalogEntries = []
            catalogLoadError = .catalogUnreadable
        }
    }

    private static func loadSharedEntries(
        from defaults: UserDefaults
    ) throws -> [PersistedHosts.Entry] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        let decoder = JSONDecoder()
        if let catalog = try? decoder.decode(PersistedCatalog.self, from: data) {
            guard catalog.version == catalogVersion else {
                throw HostStoreError.catalogUnreadable
            }
            return catalog.hosts.entries
        }
        // Version 0 was the bare Host array. Decode it once, then
        // immediately persist the versioned envelope.
        let legacyHosts = try decoder.decode(PersistedHosts.self, from: data)
        defaults.set(try encodedCatalog(entries: legacyHosts.entries), forKey: defaultsKey)
        return legacyHosts.entries
    }

    private static func loadCoreCatalog(from defaults: UserDefaults) throws -> PersistedCatalog? {
        guard let data = defaults.data(forKey: coreDefaultsKey) else { return nil }
        let catalog = try JSONDecoder().decode(PersistedCatalog.self, from: data)
        guard catalog.version == catalogVersion else {
            throw HostStoreError.catalogUnreadable
        }
        return catalog
    }

    private static func mergedHosts(
        shared: [PersistedHosts.Entry], core: [PersistedHosts.Entry], order: [Host.ID]
    ) -> [Host] {
        let unordered = (shared + core).compactMap(\.knownHost)
        let positions = Dictionary(
            order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = unordered.filter { positions[$0.id] != nil }
            .sorted { (positions[$0.id] ?? 0) < (positions[$1.id] ?? 0) }
        return ordered + unordered.filter { positions[$0.id] == nil }
    }

    /// A process-local catalog for previews and development compositions.
    /// Mutations remain in memory, and secrets use process-local storage.
    init(volatileHosts: [Host]) {
        defaults = nil
        secrets = VolatileSecretStore()
        hosts = volatileHosts
        catalogEntries = volatileHosts.filter { $0.serverKind != .herdrCore }
            .map(PersistedHosts.Entry.known)
        coreCatalogEntries = volatileHosts.filter { $0.serverKind == .herdrCore }
            .map(PersistedHosts.Entry.known)
        catalogLoadError = nil
    }

    /// Adds a Host, storing `password` in the secret store when given.
    func add(_ host: Host, password: String? = nil) throws {
        try ensureCatalogIsWritable()
        try applyPassword(password, to: host)
        hosts.append(host)
        if host.serverKind == .herdrCore {
            coreCatalogEntries.append(.known(host))
            try persistCoreCatalog()
        } else {
            catalogEntries.append(.known(host))
            try persistSharedCatalog()
        }
    }

    /// Replaces the stored Host with the same id, which must keep its Server
    /// Kind (ADR 0031). `password` nil leaves any stored password untouched, so
    /// editing unrelated fields never requires re-entering it.
    func update(_ host: Host, password: String? = nil) throws {
        try ensureCatalogIsWritable()
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else {
            throw HostStoreError.unknownHost
        }
        guard hosts[index].serverKind == host.serverKind else {
            throw HostStoreError.serverKindChanged
        }
        try applyPassword(password, to: host)
        hosts[index] = host
        if let entryIndex = coreCatalogEntries.firstIndex(where: { $0.knownHostID == host.id }) {
            coreCatalogEntries[entryIndex] = .known(host)
            try persistCoreCatalog()
        } else if let entryIndex = catalogEntries.firstIndex(where: { $0.knownHostID == host.id }) {
            catalogEntries[entryIndex] = .known(host)
            try persistSharedCatalog()
        } else {
            throw HostStoreError.catalogUnreadable
        }
    }

    /// Confirms a Host added unconfirmed, once. A herdr-core Host's catalog
    /// entry is written before the shared one goes: a Host found in both loads
    /// as herdr-core, so an interrupted confirmation is still a confirmation.
    @discardableResult
    func confirmServerKind(_ kind: ServerKind, for id: Host.ID) throws -> Host {
        try ensureCatalogIsWritable()
        guard let index = hosts.firstIndex(where: { $0.id == id }) else {
            throw HostStoreError.unknownHost
        }
        guard hosts[index].serverKind == .unconfirmed else {
            throw HostStoreError.serverKindAlreadyConfirmed
        }
        guard kind.isConfirmed else {
            throw HostStoreError.serverKindChanged
        }
        if let reason = kind.sessionNameRefusal(hosts[index].sessionName) {
            throw HostStoreError.sessionNameRefused(reason: reason)
        }
        guard let entryIndex = catalogEntries.firstIndex(where: { $0.knownHostID == id }) else {
            throw HostStoreError.catalogUnreadable
        }
        var confirmed = hosts[index]
        confirmed.serverKind = kind
        confirmed.sessionName = kind.storedSessionName(confirmed.sessionName)
        hosts[index] = confirmed
        if kind == .herdrCore {
            coreCatalogEntries.append(.known(confirmed))
            try persistCoreCatalog()
            catalogEntries.remove(at: entryIndex)
        } else {
            catalogEntries[entryIndex] = .known(confirmed)
        }
        try persistSharedCatalog()
        return confirmed
    }

    /// The Hosts the Console, Usage and its pickers show. A Host waiting for its
    /// Server Kind is only in the Hosts list.
    var consoleHosts: [Host] {
        hosts.filter(\.serverKind.isConfirmed)
    }

    /// Only a Herdr TUI Host has a plugin to receive Live Activity updates.
    func supportsLiveActivities(for id: Host.ID) -> Bool {
        hosts.first(where: { $0.id == id })?.serverKind == .herdrTUI
    }

    /// Removes the Host, its stored password, and the device's consent to
    /// read its Claude Code limits.
    func remove(_ id: Host.ID) throws {
        try ensureCatalogIsWritable()
        guard let index = hosts.firstIndex(where: { $0.id == id }) else {
            throw HostStoreError.unknownHost
        }
        try secrets.removeSecret(account: Self.passwordAccount(for: id))
        defaults?.removeObject(forKey: AgentUsageStore.claudeLimitsPreferenceKey(for: id))
        hosts.remove(at: index)
        if coreCatalogEntries.contains(where: { $0.knownHostID == id }) {
            coreCatalogEntries.removeAll { $0.knownHostID == id }
            try persistCoreCatalog()
        } else {
            catalogEntries.removeAll { $0.knownHostID == id }
            try persistSharedCatalog()
        }
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

    private func persistSharedCatalog() throws {
        defaults?.set(
            try Self.encodedCatalog(entries: catalogEntries),
            forKey: Self.defaultsKey)
    }

    private func persistCoreCatalog() throws {
        defaults?.set(
            try Self.encodedCatalog(entries: coreCatalogEntries, order: hosts.map(\.id)),
            forKey: Self.coreDefaultsKey)
    }

    private static func encodedCatalog(
        entries: [PersistedHosts.Entry], order: [Host.ID]? = nil
    ) throws -> Data {
        try JSONEncoder().encode(
            PersistedCatalog(
                version: catalogVersion,
                hosts: PersistedHosts(entries: entries),
                order: order))
    }
}
