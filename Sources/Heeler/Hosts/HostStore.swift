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
/// in a second one, tmux Hosts in a third and Rex Hosts in a fourth, each with
/// the merged Host order, that builds before its kind never read, so such a
/// build can neither show one nor re-save it as another kind (ADRs 0031, 0044
/// and 0049).
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
        case core, tmux, rex

        var kind: ServerKind {
            switch self {
            case .core: .herdrCore
            case .tmux: .tmux
            case .rex: .rex
            }
        }

        var defaultsKey: String {
            switch self {
            case .core: "herdrCoreHosts"
            case .tmux: "tmuxHosts"
            case .rex: "rexHosts"
            }
        }

        init?(_ kind: ServerKind) {
            switch kind {
            case .herdrCore: self = .core
            case .tmux: self = .tmux
            case .rex: self = .rex
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
    var rexCatalogLoadError: HostStoreError? { kindCatalogLoadErrors[.rex] }
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
            labelServers()
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
        labelServers()
    }

    /// Adds a Host, storing `password` in the secret store when given.
    func add(_ host: Host, password: String? = nil) throws {
        try ensureCatalogIsWritable()
        let own = KindCatalog(host.serverKind)
        if let own { try ensureIsWritable(own) }
        try applyPassword(password, to: host)
        hosts.append(host)
        labelServers()
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
        labelServers()
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
    /// resolved, kept only by a tmux Host (ADR 0044), and `rexSocket` the socket
    /// it found, kept only by a Rex Host (ADR 0049).
    @discardableResult
    func confirmServerKind(
        _ kind: ServerKind, for id: Host.ID, sessionName: String? = nil, tmuxPaths: TmuxPaths? = nil,
        rexSocket: RexSocket? = nil
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
        confirmed.rexSocket = kind == .rex ? rexSocket : nil
        hosts[index] = confirmed
        labelServers()
        if let own {
            kindCatalogEntries[own, default: []].append(.known(confirmed))
            try persist(own)
            catalogEntries.remove(at: entryIndex)
        } else {
            catalogEntries[entryIndex] = .known(confirmed)
        }
        try persistSharedCatalog()
        return hosts[index]
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

    /// Stores the socket a lookup found for a Rex Host that stored none, as
    /// when its stored path did not read (ADR 0049). A Host that already holds
    /// a socket keeps it.
    func noteRexSocket(_ socket: RexSocket, for id: Host.ID) throws {
        try ensureCatalogIsWritable()
        guard let index = hosts.firstIndex(where: { $0.id == id }) else {
            throw HostStoreError.unknownHost
        }
        guard hosts[index].serverKind == .rex else {
            throw HostStoreError.serverKindChanged
        }
        guard hosts[index].rexSocket == nil else { return }
        var host = hosts[index]
        host.rexSocket = socket
        try replaceEntry(of: host, at: index)
    }

    /// The catalog as the Hosts it reaches (ADR 0047).
    var machines: [HostMachine] { HostMachine.grouped(hosts) }

    func machine(containing id: Host.ID) -> HostMachine? {
        machines.first { $0.contains(id) }
    }

    /// Turns `server` on for the Host that `member` is a record of. A record with
    /// no Server yet becomes it; otherwise the Host gains a record under
    /// `newRecordID`, with the same connection and password. Host key trust lives
    /// outside the catalog, so a caller that sees `HostMachine.needsRecord` puts it
    /// in place under that id first: the record's first connection then finds it.
    /// `tmuxPaths` and `rexSocket` are what a look read of the Server, kept only
    /// by a record of their kind.
    @discardableResult
    func turnOn(
        _ server: HostServerKey, onHostOf member: Host.ID, tmuxPaths: TmuxPaths? = nil,
        rexSocket: RexSocket? = nil, newRecordID: Host.ID = UUID()
    ) throws -> Host {
        guard let machine = machine(containing: member) else { throw HostStoreError.unknownHost }
        guard server.kind.isConfirmed, server.endpointSocketPath == nil else {
            throw HostStoreError.serverKindChanged
        }
        if let record = machine.record(of: server) { return record }
        if let spare = machine.spareRecord {
            return try confirmServerKind(
                server.kind, for: spare.id, sessionName: server.name, tmuxPaths: tmuxPaths, rexSocket: rexSocket)
        }
        if let reason = server.kind.sessionNameRefusal(server.name) {
            throw HostStoreError.sessionNameRefused(reason: reason)
        }
        let source = machine.representative
        let record = Host(
            id: newRecordID,
            name: machine.givenName,
            username: source.username,
            authMethod: source.authMethod,
            serverKind: server.kind,
            sessionName: server.name,
            tmuxPaths: tmuxPaths,
            rexSocket: rexSocket,
            routes: source.routes)
        try add(record, password: source.authMethod == .password ? try password(for: source) : nil)
        return hosts.first { $0.id == record.id } ?? record
    }

    /// Keeps a Host in the catalog once `server`, its last Server on, is removed:
    /// adds the record with no Server that holds it from then on. Nil while
    /// another record of the Host stays. The caller carries the host key trust
    /// over from `server` before removing it.
    func holdHost(beyond server: Host.ID) throws -> Host? {
        guard let machine = machine(containing: server) else { throw HostStoreError.unknownHost }
        guard machine.members.count == 1, machine.spareRecord == nil else { return nil }
        let source = machine.representative
        let record = Host(
            name: source.name,
            username: source.username,
            authMethod: source.authMethod,
            serverKind: .unconfirmed,
            routes: source.routes)
        try add(record, password: source.authMethod == .password ? try password(for: source) : nil)
        return record
    }

    /// Gives every record of the Host that `edited` belonged to its name,
    /// account, authentication and Routes. `edited` is one of those records,
    /// with the changes made. `password` nil leaves each stored password alone.
    func updateHost(with edited: Host, password: String? = nil) throws {
        guard let machine = machine(containing: edited.id) else { throw HostStoreError.unknownHost }
        try update(edited, password: password)
        for member in machine.members where member.id != edited.id {
            var record = member
            record.name = edited.name
            record.username = edited.username
            record.authMethod = edited.authMethod
            record.routes = edited.routes
            try update(record, password: password)
        }
    }

    /// Hosts the catalog keeps that this build cannot read, as an older build
    /// finds a newer one's. Nil when a catalog itself could not be read, which
    /// says nothing of which Hosts exist: device memory of a Host goes only when
    /// the Host is known to be gone.
    var hostsOutOfSight: Set<Host.ID>? {
        guard catalogLoadError == nil, kindCatalogLoadErrors.isEmpty else { return nil }
        return Set((catalogEntries + kindCatalogEntries.values.joined()).compactMap(\.unknownHostID))
    }

    /// The confirmed Hosts: those the Console lists Agents and Terminals for,
    /// and those Usage and the pickers look Hosts up in. A Host waiting for its
    /// Server Kind is only in the Hosts list.
    var consoleHosts: [Host] {
        hosts.filter(\.serverKind.isConfirmed)
    }

    /// The Hosts Usage and Settings' Agents & Accounts show: those of a kind
    /// Heeler has a plugin or a Host Helper for.
    var integratedHosts: [Host] {
        hosts.filter(\.serverKind.hasHostIntegrations)
    }

    /// The Hosts Settings › Agent List Fields lays out: every Host whose
    /// Agent rows the Console lists, a Rex Host's too, since a row layout is
    /// kept on this device and asks nothing of the Host (ADR 0049).
    var rowLayoutHosts: [Host] {
        consoleHosts
    }

    /// Whether Rex Servers are all that is on: Hosts lists them, and Usage and
    /// Settings' Agents & Accounts have no Host to read (ADR 0049).
    var hasOnlyRexServersOn: Bool {
        integratedHosts.isEmpty && hosts.contains { $0.serverKind == .rex }
    }

    /// A Host waiting for its Server Kind stays out of Live Activities, and so
    /// does a Rex Host, whose Agents notify nothing (ADR 0054). Whether a herdr-core or tmux
    /// Host may show one is its registration's call, see `LiveActivityGate`.
    func supportsLiveActivities(for id: Host.ID) -> Bool {
        switch hosts.first(where: { $0.id == id })?.serverKind {
        case .herdrTUI, .herdrCore, .tmux: true
        case .rex, .unconfirmed, nil: false
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
        defaults?.removeObject(forKey: AgentUsageStore.codexLimitsPreferenceKey(for: id))
        defaults?.removeObject(forKey: AgentUsageStore.agyLimitsPreferenceKey(for: id))
        hosts.remove(at: index)
        labelServers()
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

    /// Words each record among its Host's Servers, and gives it its Host's
    /// name where its own is not that. Only a label or name that moved is
    /// written, so a change elsewhere in the catalog leaves the rest as it was.
    private func labelServers() {
        let labels = HostMachine.serverLabels(for: hosts)
        let names = HostMachine.sharedNames(for: hosts)
        for index in hosts.indices {
            let id = hosts[index].id
            if hosts[index].serverLabel != labels[id] { hosts[index].serverLabel = labels[id] }
            if hosts[index].sharedHostName != names[id] { hosts[index].sharedHostName = names[id] }
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
