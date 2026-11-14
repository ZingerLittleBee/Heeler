import Foundation
import Testing

@testable import Heeler

@Suite("tmux Host model")
struct TmuxHostModelTests {
    @Test(arguments: [("", "default"), ("  ", "default"), ("default", "default"), (" work ", "work")])
    func aBlankSocketNameIsTheDefaultSocket(typed: String, stored: String) {
        #expect(TmuxSocketName.normalized(typed) == stored)
        #expect(ServerKind.tmux.storedSessionName(typed) == stored)
        #expect(ServerKind.tmux.isValidSessionName(typed))
    }

    @Test(arguments: ["work", "a.b_c-d", "0", String(repeating: "a", count: 64)])
    func aPlainSocketNameIsTaken(_ name: String) {
        #expect(TmuxSocketName.refusal(name) == nil)
    }

    /// A socket path is not a socket name, and nothing here may become shell
    /// or tmux syntax.
    @Test(arguments: [
        "/tmp/tmux-501/default", "a/b", ".", "..", "-L", "two words", "it's", "a\\b", "a\tb", "作業",
        String(repeating: "a", count: 65),
    ])
    func anythingElseIsRefusedInWords(_ name: String) throws {
        let refusal = try #require(ServerKind.tmux.sessionNameRefusal(name))
        #expect(refusal.contains("tmux"))
        #expect(!ServerKind.tmux.isValidSessionName(name))
    }

    @Test func storedPathsAreAbsoluteAndQuotable() throws {
        #expect(TmuxPaths(executable: "/opt/homebrew/bin/tmux", socket: "/private/tmp/tmux-501/default") != nil)
        #expect(TmuxPaths(executable: "tmux", socket: "/tmp/tmux-501/default") == nil)
        #expect(TmuxPaths(executable: "/usr/bin/tmux", socket: "tmux-501/default") == nil)
        #expect(TmuxPaths(executable: "/usr/bin/it's", socket: "/tmp/tmux-501/default") == nil)
        #expect(TmuxPaths(executable: "/usr/bin/tmux", socket: "/tmp/a\nb/default") == nil)
    }

    @Test func storedPathsServeOnlyTheSocketTheyWereResolvedFor() throws {
        let paths = try #require(TmuxPaths(executable: "/usr/bin/tmux", socket: "/tmp/tmux-501/work"))
        var host = Host(
            address: "box.example", username: "dev", serverKind: .tmux, sessionName: "work", tmuxPaths: paths)
        #expect(host.tmuxSocketName == "work")
        #expect(host.storedTmuxPaths == paths)

        host.sessionName = "default"
        #expect(host.storedTmuxPaths == nil)
    }

    @Test func aTmuxHostRoundTripsWithItsPaths() throws {
        let paths = try #require(
            TmuxPaths(executable: "/opt/homebrew/bin/tmux", socket: "/private/tmp/tmux-501/default"))
        let host = Host(
            name: "Mac", address: "mac.example", username: "dev", serverKind: .tmux, sessionName: "default",
            tmuxPaths: paths)

        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(Host.self, from: data)

        #expect(decoded == host)
        #expect(decoded.serverKind == .tmux)
        #expect(decoded.tmuxPaths == paths)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(raw["serverKind"] as? String == "tmux")
    }

    @Test func onlyATmuxHostKeepsTmuxPaths() throws {
        let paths = try #require(TmuxPaths(executable: "/usr/bin/tmux", socket: "/tmp/tmux-501/default"))
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore, tmuxPaths: paths)
        #expect(host.tmuxPaths == nil)
        let raw = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        #expect(raw["tmuxPaths"] == nil)
    }

    /// Paths this build would refuse to quote are dropped, and the next
    /// connection resolves them again.
    @Test func unusablePathsOnDiskAreDroppedNotFatal() throws {
        let id = UUID()
        let json = """
            {"id":"\(id.uuidString)","name":"","username":"dev","authMethod":"deviceKey","serverKind":"tmux",
             "sessionName":"default","tmuxPaths":{"executable":"tmux","socket":"/tmp/tmux-501/default"},
             "address":"box.example","port":22}
            """
        let host = try JSONDecoder().decode(Host.self, from: Data(json.utf8))
        #expect(host.serverKind == .tmux)
        #expect(host.tmuxPaths == nil)
    }

    @Test func aTmuxHostNamesItsSocketInTheForm() throws {
        let paths = try #require(TmuxPaths(executable: "/usr/bin/tmux", socket: "/tmp/tmux-501/default"))
        let host = Host(
            address: "box.example", username: "dev", serverKind: .tmux, sessionName: "default", tmuxPaths: paths)

        var draft = HostDraft(host: host)
        #expect(draft.serverKind == .tmux)
        #expect(draft.makeHost(id: host.id) == host)

        draft.sessionName = "a/b"
        #expect(!draft.isValid)
        #expect(draft.sessionNameRefusal()?.contains("tmux") == true)

        draft.sessionName = " work "
        let edited = try #require(draft.makeHost(id: host.id))
        #expect(edited.sessionName == "work")
        #expect(edited.storedTmuxPaths == nil)
    }
}

@Suite("tmux Host catalog")
@MainActor
struct TmuxHostCatalogTests {
    private static let tmuxKey = "tmuxHosts"
    private static let coreKey = "herdrCoreHosts"

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-tmux-hosts-\(UUID().uuidString)"
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

    private func unconfirmedHost(name: String = "New", session: String = "") -> Host {
        Host(name: name, address: "new.example", username: "dev", serverKind: .unconfirmed, sessionName: session)
    }

    private func tmuxHost(name: String = "tmux") -> Host {
        Host(name: name, address: "tmux.example", username: "dev", serverKind: .tmux, sessionName: "default")
    }

    private func coreHost(name: String = "Core") -> Host {
        Host(name: name, address: "core.example", username: "dev", serverKind: .herdrCore, sessionName: "work")
    }

    private var paths: TmuxPaths {
        get throws {
            try #require(TmuxPaths(executable: "/opt/homebrew/bin/tmux", socket: "/private/tmp/tmux-501/work"))
        }
    }

    @Test func confirmingTmuxMovesTheHostToItsOwnCatalog() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let store = HostStore(defaults: defaults, secrets: secrets)
        let host = unconfirmedHost()
        try store.add(host)

        let confirmed = try store.confirmServerKind(.tmux, for: host.id, sessionName: "work", tmuxPaths: paths)

        #expect(confirmed.serverKind == .tmux)
        #expect(confirmed.sessionName == "work")
        #expect(confirmed.storedTmuxPaths == (try paths))
        #expect(store.hosts == [confirmed])
        #expect(try persistedHostIDs(in: defaults, key: "hosts").isEmpty)
        #expect(try persistedHostIDs(in: defaults, key: Self.tmuxKey) == [host.id])
        #expect(defaults.data(forKey: Self.coreKey) == nil)
        #expect(HostStore(defaults: defaults, secrets: secrets).hosts == [confirmed])
        #expect(throws: HostStoreError.serverKindAlreadyConfirmed) {
            try store.confirmServerKind(.herdrTUI, for: host.id)
        }
    }

    @Test func confirmingTmuxWithoutASocketNameTakesTheDefaultSocket() throws {
        let store = HostStore(volatileHosts: [unconfirmedHost()])
        let id = try #require(store.hosts.first?.id)

        let confirmed = try store.confirmServerKind(.tmux, for: id)

        #expect(confirmed.sessionName == "default")
        #expect(confirmed.tmuxPaths == nil)
    }

    @Test func confirmingTmuxRefusesASocketPath() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let host = unconfirmedHost(session: "/tmp/tmux-501/default")
        try store.add(host)

        do {
            try store.confirmServerKind(.tmux, for: host.id)
            Issue.record("a socket path should be refused")
        } catch HostStoreError.sessionNameRefused(let reason) {
            #expect(reason.contains("tmux"))
        }

        #expect(store.hosts == [host])
        #expect(defaults.data(forKey: Self.tmuxKey) == nil)
    }

    /// What a build before tmux Hosts reads: the shared catalog and herdr-core's.
    /// Neither ever names a tmux Host, so that build can neither show one nor
    /// save it again as another kind.
    @Test func noCatalogAnOlderBuildReadsNamesATmuxHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let tui = Host.fixture(name: "TUI")
        let core = coreHost()
        var tmux = tmuxHost()
        let confirmedLater = unconfirmedHost()
        for host in [tui, core, tmux, confirmedLater] { try store.add(host) }
        tmux.name = "Edited tmux"
        try store.update(tmux)
        try store.confirmServerKind(.tmux, for: confirmedLater.id)

        for key in ["hosts", Self.coreKey] {
            let text = String(decoding: try #require(defaults.data(forKey: key)), as: UTF8.self)
            #expect(!text.contains(tmux.id.uuidString))
            #expect(!text.contains(confirmedLater.id.uuidString))
            #expect(!text.contains("Edited tmux"))
            #expect(!text.contains("\"tmux\""))
        }
        #expect(try persistedHostIDs(in: defaults, key: "hosts") == [tui.id])
        #expect(try persistedHostIDs(in: defaults, key: Self.coreKey) == [core.id])
        #expect(try persistedHostIDs(in: defaults, key: Self.tmuxKey) == [tmux.id, confirmedLater.id])
    }

    @Test func aHostThatOnlyRunsHerdrNeverGetsATmuxCatalog() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let tui = Host.fixture(name: "TUI")
        let core = coreHost()
        try store.add(tui)
        try store.add(core)
        try store.remove(tui.id)

        #expect(defaults.object(forKey: Self.tmuxKey) == nil)
    }

    @Test func confirmingTmuxWritesItsCatalogBeforeRemovingTheSharedEntry() throws {
        let suite = "tmux-host-store-writes-\(UUID().uuidString)"
        let defaults = try #require(TmuxCatalogWriteRecorder(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let host = unconfirmedHost()
        try store.add(host)
        defaults.startRecording()

        let confirmed = try store.confirmServerKind(.tmux, for: host.id)

        #expect(defaults.writes == [Self.tmuxKey, "hosts"])

        // The device as the first write left it: both catalogs name the Host.
        let (interrupted, cleanup) = try makeDefaults()
        defer { cleanup() }
        interrupted.set(defaults.sharedAtFirstWrite, forKey: "hosts")
        interrupted.set(defaults.tmuxAtFirstWrite, forKey: Self.tmuxKey)
        #expect(try persistedHostIDs(in: interrupted, key: "hosts") == [host.id])

        let reloaded = HostStore(defaults: interrupted, secrets: InMemorySecretStore())

        #expect(reloaded.hosts == [confirmed])
        #expect(try persistedHostIDs(in: interrupted, key: "hosts").isEmpty)
    }

    @Test func theMergedOrderOfThreeCatalogsSurvivesAReload() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let store = HostStore(defaults: defaults, secrets: secrets)
        let first = Host.fixture(name: "First")
        let tmux = tmuxHost()
        let second = Host.fixture(name: "Second")
        let core = coreHost()
        let waiting = unconfirmedHost(name: "Waiting")
        let third = Host.fixture(name: "Third")
        let lastTmux = tmuxHost(name: "Last tmux")
        for host in [first, tmux, second, core, waiting, third] { try store.add(host) }
        #expect(HostStore(defaults: defaults, secrets: secrets).hosts == store.hosts)

        // A Host confirmed in place keeps its place, whichever catalog wrote the order last.
        let confirmed = try store.confirmServerKind(.herdrCore, for: waiting.id)
        #expect(store.hosts == [first, tmux, second, core, confirmed, third])
        #expect(HostStore(defaults: defaults, secrets: secrets).hosts == store.hosts)

        try store.add(lastTmux)
        try store.remove(second.id)
        #expect(store.hosts == [first, tmux, core, confirmed, third, lastTmux])
        #expect(HostStore(defaults: defaults, secrets: secrets).hosts == store.hosts)
    }

    /// A build that knows herdr-core and not tmux rewrites the shared catalog and
    /// herdr-core's, with an order that lacks every tmux Host.
    @Test func tmuxHostsSurviveAnOlderBuildsWrites() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let store = HostStore(defaults: defaults, secrets: secrets)
        let tui = Host.fixture(name: "TUI")
        let tmux = tmuxHost()
        let core = coreHost()
        for host in [tui, tmux, core] { try store.add(host) }
        let tmuxCatalog = defaults.data(forKey: Self.tmuxKey)

        // The older build adds a herdr-core Host and saves its own order.
        let added = coreHost(name: "Added by the older build")
        let coreEntries = try [core, added].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let order = [tui.id, core.id, added.id].map { "\"\($0.uuidString)\"" }.joined(separator: ",")
        defaults.set(
            Data(#"{"version":1,"hosts":[\#(coreEntries.joined(separator: ","))],"order":[\#(order)]}"#.utf8),
            forKey: Self.coreKey)

        let reloaded = HostStore(defaults: defaults, secrets: secrets)

        #expect(reloaded.catalogLoadError == nil)
        #expect(reloaded.hosts == [tui, tmux, core, added])
        #expect(defaults.data(forKey: Self.tmuxKey) == tmuxCatalog)
    }

    @Test func editsAndPathsWriteOnlyTheTmuxCatalog() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let store = HostStore(defaults: defaults, secrets: secrets)
        let tui = Host.fixture(name: "TUI")
        let core = coreHost()
        var tmux = tmuxHost()
        tmux.sessionName = "work"
        for host in [tui, core, tmux] { try store.add(host) }
        let shared = defaults.data(forKey: "hosts")
        let coreCatalog = defaults.data(forKey: Self.coreKey)

        try store.noteTmuxPaths(paths, for: tmux.id)

        #expect(store.hosts.last?.storedTmuxPaths == (try paths))
        #expect(HostStore(defaults: defaults, secrets: secrets).hosts == store.hosts)
        #expect(defaults.data(forKey: "hosts") == shared)
        #expect(defaults.data(forKey: Self.coreKey) == coreCatalog)

        // The same paths again write nothing.
        let tmuxCatalog = defaults.data(forKey: Self.tmuxKey)
        try store.noteTmuxPaths(paths, for: tmux.id)
        #expect(defaults.data(forKey: Self.tmuxKey) == tmuxCatalog)

        // Paths are a tmux Host's alone, and never change a Host's kind.
        #expect(throws: HostStoreError.serverKindChanged) { try store.noteTmuxPaths(paths, for: core.id) }
        #expect(throws: HostStoreError.unknownHost) { try store.noteTmuxPaths(paths, for: UUID()) }

        try store.remove(tmux.id)
        #expect(try persistedHostIDs(in: defaults, key: Self.tmuxKey).isEmpty)
        #expect(defaults.data(forKey: "hosts") == shared)
        #expect(HostStore(defaults: defaults, secrets: secrets).hosts == [tui, core])
    }

    @Test(arguments: [ServerKind.herdrTUI, .herdrCore])
    func aTmuxHostNeverSwitchesKind(_ other: ServerKind) throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let host = tmuxHost()
        try store.add(host)
        var switched = host
        switched.serverKind = other

        #expect(throws: HostStoreError.serverKindChanged) { try store.update(switched) }
        #expect(store.hosts == [host])
    }

    @Test func aHostInTheSharedAndTheTmuxCatalogLoadsAsTmux() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let store = HostStore(defaults: defaults, secrets: secrets)
        let tui = Host.fixture(name: "TUI")
        let tmux = tmuxHost()
        try store.add(tui)
        try store.add(tmux)
        var stale = tmux
        stale.serverKind = .unconfirmed
        let entries = try [tui, stale].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        defaults.set(
            Data(#"{"version":1,"hosts":[\#(entries.joined(separator: ","))]}"#.utf8), forKey: "hosts")

        let reloaded = HostStore(defaults: defaults, secrets: secrets)

        #expect(reloaded.hosts == [tui, tmux])
        #expect(try persistedHostIDs(in: defaults, key: "hosts") == [tui.id])
    }

    @Test func anUnreadableTmuxCatalogLeavesTheOtherHostsAlone() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let tui = Host.fixture(name: "TUI")
        let core = coreHost()
        let seeded = HostStore(defaults: defaults, secrets: secrets)
        try seeded.add(tui)
        try seeded.add(core)
        let corrupt = Data("{not json".utf8)
        defaults.set(corrupt, forKey: Self.tmuxKey)

        let store = HostStore(defaults: defaults, secrets: secrets)

        #expect(store.hosts == [tui, core])
        #expect(store.catalogLoadError == nil)
        #expect(store.coreCatalogLoadError == nil)
        #expect(store.tmuxCatalogLoadError == .catalogUnreadable)
        #expect(store.hostsOutOfSight == nil)
        // Nothing goes to a catalog that could not be read.
        #expect(throws: HostStoreError.catalogUnreadable) { try store.add(tmuxHost()) }
        let waiting = unconfirmedHost()
        try store.add(waiting)
        #expect(throws: HostStoreError.catalogUnreadable) { try store.confirmServerKind(.tmux, for: waiting.id) }
        #expect(defaults.data(forKey: Self.tmuxKey) == corrupt)
        // The other kinds carry on.
        #expect(try store.confirmServerKind(.herdrCore, for: waiting.id).serverKind == .herdrCore)
    }

    @Test func aTmuxHostIsAConsoleHost() throws {
        let tmux = tmuxHost()
        let store = HostStore(volatileHosts: [tmux, unconfirmedHost()])

        #expect(store.consoleHosts == [tmux])
    }
}

/// Notes which catalog each write touched, and the shared and tmux catalogs as
/// the first write left them.
private final class TmuxCatalogWriteRecorder: UserDefaults {
    private(set) var writes: [String] = []
    private(set) var sharedAtFirstWrite: Data?
    private(set) var tmuxAtFirstWrite: Data?
    private var isRecording = false

    func startRecording() {
        isRecording = true
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        guard isRecording else { return }
        writes.append(defaultName)
        if writes.count == 1 {
            sharedAtFirstWrite = data(forKey: "hosts")
            tmuxAtFirstWrite = data(forKey: "tmuxHosts")
        }
    }
}
