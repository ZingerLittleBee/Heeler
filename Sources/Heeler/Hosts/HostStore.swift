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
/// The catalog is stored in parts of one shape. Herdr TUI Hosts and Hosts not
/// yet confirmed stay in the shared one every build reads. herdr-core Hosts live
/// in a second one, and tmux Hosts in a third, each with the merged Host order,
/// that builds before its kind never read, so such a build can neither show one
/// nor re-save it as another kind (ADRs 0031 and 0044).
@MainActor
@Observable
final class HostStore {
    private static let defaultsKey = "hosts"
    private static let catalogVersion = 1

    /// A Server Kind whose confirmed Hosts live outside the shared catalog. The
    /// order is the one a Host found in several is read in, and the reverse of
    /// the one their saved orders are believed in: the kind added last is
    /// written by the newest builds only, so its order names the most Hosts.
    private enum KindCatalog: CaseIterable {
        case core, tmux

        var kind: ServerKind {
            switch self {
            case .core: .herdrCore
            case .tmux: .tmux
            }
        }

        var defaultsKey: String {
            switch self {
            case .core: "herdrCoreHosts"
            case .tmux: "tmuxHosts"
            }
        }

        init?(_ kind: ServerKind) {
            switch kind {
            case .herdrCore: self = .core
            case .tmux: self = .tmux
            case .herdrTUI, .unconfirmed: return nil
            }
        }
    }

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

            var unknownHostID: Host.ID? {
                guard case .unknown(let rawHost) = self, let id = rawHost["id"]?.stringValue else {
                    return nil
                }
                return Host.ID(uuidString: id)
            }
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
        /// The merged Host order, kept with each kind's own catalog. Ids it lacks
        /// follow it, in another catalog's order where one names them and else in
        /// the shared catalog's, which is how a Host added since, here or by an
        /// older build, stays last.
        var order: [Host.ID]?
    }

    private(set) var hosts: [Host]
    /// The shared catalog could not be read, so no Host is shown or written.
    private(set) var catalogLoadError: HostStoreError?
    /// The kinds whose own catalog could not be read. The other Hosts carry on
    /// from their own keys; nothing goes to such a catalog, whose bytes stay as
    /// they are.
    private var kindCatalogLoadErrors: [KindCatalog: HostStoreError] = [:]
    var coreCatalogLoadError: HostStoreError? { kindCatalogLoadErrors[.core] }
    var tmuxCatalogLoadError: HostStoreError? { kindCatalogLoadErrors[.tmux] }
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults?
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private var catalogEntries: [PersistedHosts.Entry]
    @ObservationIgnored private var kindCatalogEntries: [KindCatalog: [PersistedHosts.Entry]] = [:]

    init(
        defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainSecretStore(service: "dev.bybee.heeler.ssh")
    ) {
        self.defaults = defaults
        self.secrets = secrets
        do {
            var shared = try Self.loadSharedEntries(from: defaults)
            var kinds: [KindCatalog: PersistedCatalog] = [:]
            var errors: [KindCatalog: HostStoreError] = [:]
            for catalog in KindCatalog.allCases {
                do {
                    kinds[catalog] = try Self.loadKindCatalog(catalog, from: defaults)
                } catch {
                    errors[catalog] = .catalogUnreadable
                }
            }
            // A Host found in the shared catalog and a kind's own is that kind's.
            // Its shared copy goes now, so an older build cannot show it and
            // removing the Host cannot bring it back as another kind.
            let kindIDs = Set(kinds.values.flatMap { $0.hosts.entries.compactMap(\.knownHostID) })
            let sharedCount = shared.count
            shared.removeAll { $0.knownHostID.map(kindIDs.contains) == true }
            if shared.count != sharedCount {
                defaults.set(try Self.encodedCatalog(entries: shared), forKey: Self.defaultsKey)
            }
            let entries = kinds.mapValues(\.hosts.entries)
            hosts = Self.mergedHosts(
                shared: shared,
                kinds: KindCatalog.allCases.flatMap { entries[$0] ?? [] },
                orders: KindCatalog.allCases.reversed().compactMap { kinds[$0]?.order })
            catalogEntries = shared
            kindCatalogEntries = entries
            kindCatalogLoadErrors = errors
            catalogLoadError = nil
        } catch {
            hosts = []
            catalogEntries = []
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

    private static func loadKindCatalog(
        _ catalog: KindCatalog, from defaults: UserDefaults
    ) throws -> PersistedCatalog? {
        guard let data = defaults.data(forKey: catalog.defaultsKey) else { return nil }
        let decoded = try JSONDecoder().decode(PersistedCatalog.self, from: data)
        guard decoded.version == catalogVersion else {
            throw HostStoreError.catalogUnreadable
        }
        return decoded
    }

    /// Hosts never trade places, so every saved order agrees on the Hosts it
    /// names, and a Host an order lacks was added after that order was saved.
    /// Each order in turn therefore places the Hosts the ones before it lack.
    private static func mergedHosts(
        shared: [PersistedHosts.Entry], kinds: [PersistedHosts.Entry], orders: [[Host.ID]]
    ) -> [Host] {
        var seen: Set<Host.ID> = []
        var remaining = (shared + kinds).compactMap(\.knownHost).filter { seen.insert($0.id).inserted }
        var merged: [Host] = []
        for order in orders {
            let positions = Dictionary(
                order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            merged += remaining.filter { positions[$0.id] != nil }
                .sorted { (positions[$0.id] ?? 0) < (positions[$1.id] ?? 0) }
            remaining.removeAll { positions[$0.id] != nil }
        }
        return merged + remaining
    }

    /// A process-local catalog for previews and development compositions.
    /// Mutations remain in memory, and secrets use process-local storage.
    init(volatileHosts: [Host]) {
        defaults = nil
        secrets = VolatileSecretStore()
        hosts = volatileHosts
        catalogEntries = volatileHosts.filter { KindCatalog($0.serverKind) == nil }
            .map(PersistedHosts.Entry.known)
        for catalog in KindCatalog.allCases {
            kindCatalogEntries[catalog] = volatileHosts.filter { $0.serverKind == catalog.kind }
                .map(PersistedHosts.Entry.known)
        }
        catalogLoadError = nil
    }

    /// Adds a Host, storing `password` in the secret store when given.
    func add(_ host: Host, password: String? = nil) throws {
        try ensureCatalogIsWritable()
        let own = KindCatalog(host.serverKind)
        if let own { try ensureIsWritable(own) }
        try applyPassword(password, to: host)
        hosts.append(host)
        if let own {
            kindCatalogEntries[own, default: []].append(.known(host))
            try persist(own)
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
        try replaceEntry(of: host, at: index)
    }

    /// Writes `host` over its entry, in whichever catalog holds it.
    private func replaceEntry(of host: Host, at index: Int) throws {
        hosts[index] = host
        if let own = KindCatalog.allCases.first(where: { holds(host.id, in: $0) }),
            let entryIndex = kindCatalogEntries[own]?.firstIndex(where: { $0.knownHostID == host.id })
        {
            kindCatalogEntries[own]?[entryIndex] = .known(host)
            try persist(own)
        } else if let entryIndex = catalogEntries.firstIndex(where: { $0.knownHostID == host.id }) {
            catalogEntries[entryIndex] = .known(host)
            try persistSharedCatalog()
        } else {
            throw HostStoreError.catalogUnreadable
        }
    }

    /// Confirms a Host added unconfirmed, once. A kind with a catalog of its own
    /// has that entry written before the shared one goes: a Host found in both
    /// loads as that kind, so an interrupted confirmation is still a confirmation.
    ///
    /// `sessionName` replaces the typed one, for a kind whose detection offered
    /// the name, as a tmux Host's socket is. `tmuxPaths` is what that detection
    /// resolved, kept only by a tmux Host (ADR 0044).
    @discardableResult
    func confirmServerKind(
        _ kind: ServerKind, for id: Host.ID, sessionName: String? = nil, tmuxPaths: TmuxPaths? = nil
    ) throws -> Host {
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
        let own = KindCatalog(kind)
        if let own { try ensureIsWritable(own) }
        let name = sessionName ?? hosts[index].sessionName
        if let reason = kind.sessionNameRefusal(name) {
            throw HostStoreError.sessionNameRefused(reason: reason)
        }
        guard let entryIndex = catalogEntries.firstIndex(where: { $0.knownHostID == id }) else {
            throw HostStoreError.catalogUnreadable
        }
        var confirmed = hosts[index]
        confirmed.serverKind = kind
        confirmed.sessionName = kind.storedSessionName(name)
        confirmed.tmuxPaths = kind == .tmux ? tmuxPaths : nil
        hosts[index] = confirmed
        if let own {
            kindCatalogEntries[own, default: []].append(.known(confirmed))
            try persist(own)
            catalogEntries.remove(at: entryIndex)
        } else {
            catalogEntries[entryIndex] = .known(confirmed)
        }
        try persistSharedCatalog()
        return confirmed
    }

    /// Stores what a tmux Host's login shell last resolved, for its next
    /// connections to run without asking that shell again (ADR 0044). Paths the
    /// Host already holds write nothing.
    func noteTmuxPaths(_ paths: TmuxPaths, for id: Host.ID) throws {
        try ensureCatalogIsWritable()
        guard let index = hosts.firstIndex(where: { $0.id == id }) else {
            throw HostStoreError.unknownHost
        }
        guard hosts[index].serverKind == .tmux else {
            throw HostStoreError.serverKindChanged
        }
        guard hosts[index].tmuxPaths != paths else { return }
        var host = hosts[index]
        host.tmuxPaths = paths
        try replaceEntry(of: host, at: index)
    }

    /// Hosts the catalog keeps that this build cannot read, as an older build
    /// finds a newer one's. Nil when a catalog itself could not be read, which
    /// says nothing of which Hosts exist: device memory of a Host goes only when
    /// the Host is known to be gone.
    var hostsOutOfSight: Set<Host.ID>? {
        guard catalogLoadError == nil, kindCatalogLoadErrors.isEmpty else { return nil }
        return Set((catalogEntries + kindCatalogEntries.values.joined()).compactMap(\.unknownHostID))
    }

    /// The Hosts the Console, Usage and its pickers show. A Host waiting for its
    /// Server Kind is only in the Hosts list.
    var consoleHosts: [Host] {
        hosts.filter(\.serverKind.isConfirmed)
    }

    /// The Hosts Usage and Settings' per-Host pages show: those of a kind
    /// Heeler has a plugin or a Host Helper for.
    var integratedHosts: [Host] {
        hosts.filter(\.serverKind.hasHostIntegrations)
    }

    /// A Host waiting for its Server Kind stays out of Live Activities. Whether a
    /// herdr-core or tmux Host may show one is its registration's call, see
    /// `LiveActivityGate`.
    func supportsLiveActivities(for id: Host.ID) -> Bool {
        switch hosts.first(where: { $0.id == id })?.serverKind {
        case .herdrTUI, .herdrCore, .tmux: true
        case .unconfirmed, nil: false
        }
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
        if let own = KindCatalog.allCases.first(where: { holds(id, in: $0) }) {
            kindCatalogEntries[own]?.removeAll { $0.knownHostID == id }
            try persist(own)
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

    private func ensureIsWritable(_ catalog: KindCatalog) throws {
        if kindCatalogLoadErrors[catalog] != nil {
            throw HostStoreError.catalogUnreadable
        }
    }

    private func holds(_ id: Host.ID, in catalog: KindCatalog) -> Bool {
        kindCatalogEntries[catalog]?.contains { $0.knownHostID == id } == true
    }

    private func persistSharedCatalog() throws {
        defaults?.set(
            try Self.encodedCatalog(entries: catalogEntries),
            forKey: Self.defaultsKey)
    }

    private func persist(_ catalog: KindCatalog) throws {
        defaults?.set(
            try Self.encodedCatalog(entries: kindCatalogEntries[catalog] ?? [], order: hosts.map(\.id)),
            forKey: catalog.defaultsKey)
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
