import Foundation
import Testing

@testable import Heeler

@Suite("Rex Host model")
struct RexHostModelTests {
    private static let socketPath = "/Users/dev/Library/Application Support/rex/server.sock"

    private func makeSocket() throws -> RexSocket {
        try #require(RexSocket(path: Self.socketPath))
    }

    /// Rex has no session to type: whatever the form held, nothing is refused
    /// and nothing is stored.
    @Test(arguments: ["", "work", "a/b", "/run/rex/server.sock", "two words"])
    func aRexHostNamesNoSession(_ typed: String) {
        #expect(ServerKind.rex.sessionNameRefusal(typed) == nil)
        #expect(ServerKind.rex.storedSessionName(typed) == "")
    }

    @Test func rexIsConfirmedWithoutHostIntegrations() {
        #expect(ServerKind.rex.isConfirmed)
        #expect(!ServerKind.rex.hasHostIntegrations)
        #expect(ServerKind.rex.displayName == "Rex")
        #expect(ServerKind.rex.rawValue == "rex")
    }

    @Test func aSocketPathIsAbsoluteAndQuotableAndMayHaveSpaces() throws {
        #expect(RexSocket(path: Self.socketPath)?.path == Self.socketPath)
        #expect(RexSocket(path: "/run/user/1000/rex/server.sock") != nil)
        #expect(RexSocket(path: "rex/server.sock") == nil)
        #expect(RexSocket(path: "/run/rex/") == nil)
        #expect(RexSocket(path: "/home/it's/server.sock") == nil)
        #expect(RexSocket(path: "/run/a\nb/server.sock") == nil)
    }

    @Test func aRexHostRoundTripsWithItsSocket() throws {
        let socket = try makeSocket()
        let host = Host(
            name: "Mac", address: "mac.example", username: "dev", serverKind: .rex, rexSocket: socket)

        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(Host.self, from: data)

        #expect(decoded == host)
        #expect(decoded.rexSocket == socket)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(raw["serverKind"] as? String == "rex")
        #expect((raw["rexSocket"] as? [String: Any])?["path"] as? String == Self.socketPath)
    }

    @Test func onlyARexHostKeepsASocket() throws {
        let host = Host(address: "box.example", username: "dev", serverKind: .tmux, rexSocket: try makeSocket())
        #expect(host.rexSocket == nil)
        let raw = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        #expect(raw["rexSocket"] == nil)
    }

    /// A socket this build would not name is a lookup to make again, never a
    /// Host to hide.
    @Test(arguments: [#""rexSocket":{"path":"relative/server.sock"}"#, #""rexSocket":"not an object""#])
    func anUnusableSocketOnDiskIsDroppedNotFatal(_ field: String) throws {
        let json = """
            {"id":"\(UUID().uuidString)","name":"","username":"dev","authMethod":"deviceKey","serverKind":"rex",
             "sessionName":"",\(field),"address":"box.example","port":22}
            """
        let host = try JSONDecoder().decode(Host.self, from: Data(json.utf8))
        #expect(host.serverKind == .rex)
        #expect(host.rexSocket == nil)
    }

    @Test func editKeepsTheSocketAndACopyLooksItUpAgain() throws {
        let socket = try makeSocket()
        let host = Host(address: "mac.example", username: "dev", serverKind: .rex, rexSocket: socket)

        var draft = HostDraft(host: host)
        draft.name = "Studio"
        let edited = try #require(draft.makeHost(id: host.id))
        #expect(edited.serverKind == .rex)
        #expect(edited.rexSocket == socket)
        #expect(edited.sessionName == "")

        let copy = HostDraft(duplicating: host, password: nil, existingNames: [])
        #expect(copy.serverKind == .rex)
        #expect(copy.makeHost()?.rexSocket == nil)
    }
}

@Suite("Rex Host catalog")
@MainActor
struct RexHostCatalogTests {
    private static let rexKey = "rexHosts"
    private static let tmuxKey = "tmuxHosts"
    private static let coreKey = "herdrCoreHosts"

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-rex-hosts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func persistedHostIDs(in defaults: UserDefaults, key: String) throws -> [UUID] {
        let data = try #require(defaults.data(forKey: key))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hosts = try #require(catalog["hosts"] as? [[String: Any]])
        return try hosts.map { host in
            let id = try #require(host["id"] as? String)
            return try #require(UUID(uuidString: id))
        }
    }

    private func makeStore(_ defaults: UserDefaults, secrets: InMemorySecretStore, rex: Bool = true) -> HostStore {
        HostStore(defaults: defaults, secrets: secrets, offersRexHosts: rex)
    }

    private func unconfirmedHost(name: String = "New", session: String = "") -> Host {
        Host(name: name, address: "new.example", username: "dev", serverKind: .unconfirmed, sessionName: session)
    }

    private func rexHost(name: String = "Rex") -> Host {
        Host(name: name, address: "rex.example", username: "dev", serverKind: .rex, rexSocket: socket)
    }

    private func tmuxHost(name: String = "tmux") -> Host {
        Host(name: name, address: "tmux.example", username: "dev", serverKind: .tmux, sessionName: "default")
    }

    private func coreHost(name: String = "Core") -> Host {
        Host(name: name, address: "core.example", username: "dev", serverKind: .herdrCore, sessionName: "work")
    }

    private var socket: RexSocket? { RexSocket(path: "/run/user/1000/rex/server.sock") }

    @Test func confirmingRexMovesTheHostToItsOwnCatalogWithItsSocket() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let store = makeStore(defaults, secrets: secrets)
        let host = unconfirmedHost(session: "work")
        try store.add(host)

        let confirmed = try store.confirmServerKind(.rex, for: host.id, rexSocket: socket)

        #expect(confirmed.serverKind == .rex)
        #expect(confirmed.sessionName == "")
        #expect(confirmed.rexSocket == socket)
        #expect(store.hosts == [confirmed])
        #expect(try persistedHostIDs(in: defaults, key: "hosts").isEmpty)
        #expect(try persistedHostIDs(in: defaults, key: Self.rexKey) == [host.id])
        #expect(defaults.data(forKey: Self.coreKey) == nil)
        #expect(defaults.data(forKey: Self.tmuxKey) == nil)
        #expect(makeStore(defaults, secrets: secrets).hosts == [confirmed])
        #expect(throws: HostStoreError.serverKindAlreadyConfirmed) {
            try store.confirmServerKind(.herdrTUI, for: host.id)
        }
    }

    @Test func aSocketGoesOnlyToARexHost() throws {
        let store = HostStore(volatileHosts: [unconfirmedHost()])
        let id = try #require(store.hosts.first?.id)

        let confirmed = try store.confirmServerKind(.herdrCore, for: id, rexSocket: socket)

        #expect(confirmed.rexSocket == nil)
    }

    /// What a build before Rex Hosts reads: the shared catalog, herdr-core's and
    /// tmux's. None of them ever names a Rex Host.
    @Test func noCatalogAnOlderBuildReadsNamesARexHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = makeStore(defaults, secrets: InMemorySecretStore())
        let tui = Host.fixture(name: "TUI")
        let core = coreHost()
        let tmux = tmuxHost()
        var rex = rexHost()
        let confirmedLater = unconfirmedHost()
        for host in [tui, core, tmux, rex, confirmedLater] { try store.add(host) }
        rex.name = "Edited Rex"
        try store.update(rex)
        try store.confirmServerKind(.rex, for: confirmedLater.id, rexSocket: socket)

        for key in ["hosts", Self.coreKey, Self.tmuxKey] {
            let text = String(decoding: try #require(defaults.data(forKey: key)), as: UTF8.self)
            #expect(!text.contains(rex.id.uuidString))
            #expect(!text.contains(confirmedLater.id.uuidString))
            #expect(!text.contains("Edited Rex"))
            #expect(!text.contains("\"rex\""))
            #expect(!text.contains("server.sock"))
        }
        #expect(try persistedHostIDs(in: defaults, key: Self.rexKey) == [rex.id, confirmedLater.id])
    }

    @Test func theMergedOrderOfFourCatalogsSurvivesAReload() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let store = makeStore(defaults, secrets: secrets)
        let first = Host.fixture(name: "First")
        let rex = rexHost()
        let tmux = tmuxHost()
        let core = coreHost()
        let waiting = unconfirmedHost(name: "Waiting")
        let last = Host.fixture(name: "Last")
        for host in [first, rex, tmux, core, waiting, last] { try store.add(host) }
        #expect(makeStore(defaults, secrets: secrets).hosts == store.hosts)

        let confirmed = try store.confirmServerKind(.rex, for: waiting.id, rexSocket: socket)
        #expect(store.hosts == [first, rex, tmux, core, confirmed, last])
        #expect(makeStore(defaults, secrets: secrets).hosts == store.hosts)

        try store.remove(rex.id)
        #expect(store.hosts == [first, tmux, core, confirmed, last])
        #expect(makeStore(defaults, secrets: secrets).hosts == store.hosts)
    }

    /// A build that knows tmux and not Rex rewrites the other catalogs with an
    /// order that lacks every Rex Host, and never touches Rex's.
    @Test func rexHostsSurviveAnOlderBuildsWrites() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let store = makeStore(defaults, secrets: secrets)
        let tui = Host.fixture(name: "TUI")
        let rex = rexHost()
        let tmux = tmuxHost()
        for host in [tui, rex, tmux] { try store.add(host) }
        let rexCatalog = defaults.data(forKey: Self.rexKey)

        let added = tmuxHost(name: "Added by the older build")
        let entries = try [tmux, added].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let order = [tui.id, tmux.id, added.id].map { "\"\($0.uuidString)\"" }.joined(separator: ",")
        defaults.set(
            Data(#"{"version":1,"hosts":[\#(entries.joined(separator: ","))],"order":[\#(order)]}"#.utf8),
            forKey: Self.tmuxKey)

        let reloaded = makeStore(defaults, secrets: secrets)

        #expect(reloaded.catalogLoadError == nil)
        #expect(reloaded.hosts == [tui, rex, tmux, added])
        #expect(defaults.data(forKey: Self.rexKey) == rexCatalog)
    }

    /// With the switch off this build is a build that does not know Rex: its
    /// Hosts stay stored, unlisted, kept by every write, and out of sight
    /// rather than gone, so nothing this device remembers of them is swept.
    @Test func withTheSwitchOffRexHostsAreKeptButNotListed() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let on = makeStore(defaults, secrets: secrets)
        let tui = Host.fixture(name: "TUI")
        let rex = rexHost()
        let core = coreHost()
        for host in [tui, rex, core] { try on.add(host) }
        let rexCatalog = defaults.data(forKey: Self.rexKey)

        let off = makeStore(defaults, secrets: secrets, rex: false)

        #expect(off.hosts == [tui, core])
        #expect(off.consoleHosts == [tui, core])
        #expect(off.rexCatalogLoadError == nil)
        #expect(off.hostsOutOfSight == [rex.id])
        // Nothing reaches its catalog while it is not listed.
        #expect(throws: HostStoreError.catalogUnreadable) { try off.add(rexHost(name: "Another")) }
        let waiting = unconfirmedHost()
        try off.add(waiting)
        #expect(throws: HostStoreError.catalogUnreadable) {
            try off.confirmServerKind(.rex, for: waiting.id, rexSocket: socket)
        }
        #expect(throws: HostStoreError.unknownHost) { try off.update(rex) }
        #expect(throws: HostStoreError.unknownHost) { try off.remove(rex.id) }
        try off.remove(core.id)
        #expect(defaults.data(forKey: Self.rexKey) == rexCatalog)

        // Turned back on, the Host is where it was.
        let again = makeStore(defaults, secrets: secrets)
        #expect(again.hosts == [tui, rex, waiting])
        #expect(again.hostsOutOfSight == [])
    }

    @Test func aHostInTheSharedAndTheRexCatalogLoadsAsRex() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let store = makeStore(defaults, secrets: secrets)
        let tui = Host.fixture(name: "TUI")
        let rex = rexHost()
        try store.add(tui)
        try store.add(rex)
        var stale = rex
        stale.serverKind = .unconfirmed
        let entries = try [tui, stale].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        defaults.set(
            Data(#"{"version":1,"hosts":[\#(entries.joined(separator: ","))]}"#.utf8), forKey: "hosts")

        let reloaded = makeStore(defaults, secrets: secrets)

        #expect(reloaded.hosts == [tui, rex])
        #expect(try persistedHostIDs(in: defaults, key: "hosts") == [tui.id])
    }

    @Test func anUnreadableRexCatalogLeavesTheOtherHostsAlone() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let tui = Host.fixture(name: "TUI")
        let tmux = tmuxHost()
        let seeded = makeStore(defaults, secrets: secrets)
        try seeded.add(tui)
        try seeded.add(tmux)
        let corrupt = Data("{not json".utf8)
        defaults.set(corrupt, forKey: Self.rexKey)

        let store = makeStore(defaults, secrets: secrets)

        #expect(store.hosts == [tui, tmux])
        #expect(store.catalogLoadError == nil)
        #expect(store.tmuxCatalogLoadError == nil)
        #expect(store.rexCatalogLoadError == .catalogUnreadable)
        #expect(store.hostsOutOfSight == nil)
        let waiting = unconfirmedHost()
        try store.add(waiting)
        #expect(throws: HostStoreError.catalogUnreadable) {
            try store.confirmServerKind(.rex, for: waiting.id, rexSocket: socket)
        }
        #expect(defaults.data(forKey: Self.rexKey) == corrupt)
        #expect(try store.confirmServerKind(.tmux, for: waiting.id).serverKind == .tmux)
    }

    /// A Rex Host this build cannot read, such as one with an authentication
    /// method from a later build, stays hidden and survives writes.
    @Test func anUnreadableRexHostIsKeptOutOfSight() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let future = UUID()
        let rex = rexHost()
        let known = String(decoding: try JSONEncoder().encode(rex), as: UTF8.self)
        let unknown = """
            {"id":"\(future.uuidString)","name":"","username":"dev","authMethod":"passkey","serverKind":"rex",
             "sessionName":"","address":"box.example","port":22}
            """
        defaults.set(Data(#"{"version":1,"hosts":[\#(known),\#(unknown)]}"#.utf8), forKey: Self.rexKey)

        let store = makeStore(defaults, secrets: secrets)
        #expect(store.hosts == [rex])
        #expect(store.hostsOutOfSight == [future])

        var edited = rex
        edited.name = "Edited"
        try store.update(edited)
        #expect(try persistedHostIDs(in: defaults, key: Self.rexKey) == [rex.id, future])
    }

    @Test func aRexHostIsAConsoleHostWithoutIntegrationsOrLiveActivities() throws {
        let rex = rexHost()
        let store = HostStore(volatileHosts: [rex, unconfirmedHost()])

        #expect(store.consoleHosts == [rex])
        #expect(store.integratedHosts.isEmpty)
        #expect(!store.supportsLiveActivities(for: rex.id))
    }
}
