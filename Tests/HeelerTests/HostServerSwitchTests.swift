import Foundation
import Testing

@testable import Heeler

/// Known hosts that can say everything they hold, for trust that must not be
/// left behind under a record that never came to be.
private actor ListedKnownHosts: KnownHostsStore {
    private var stored: [String: [HostKeyFingerprint]] = [:]

    /// The store keys that hold a fingerprint.
    var trustedHosts: Set<String> { Set(stored.filter { !$0.value.isEmpty }.keys) }

    func fingerprints(host: String, port: Int) -> [HostKeyFingerprint] {
        stored[host] ?? []
    }

    func fingerprint(host: String, port: Int, algorithm: String) -> HostKeyFingerprint? {
        stored[host]?.first { $0.algorithm == algorithm }
    }

    func setFingerprint(_ fingerprint: HostKeyFingerprint, host: String, port: Int) {
        stored[host, default: []].removeAll { $0.algorithm == fingerprint.algorithm }
        stored[host, default: []].append(fingerprint)
    }

    func forgetHost(_ id: UUID) {
        stored[HostKeyTrust.hostKey(id).host] = nil
    }
}

@MainActor
@Suite("Host server switch")
struct HostServerSwitchTests {
    /// The records a native Windows core was noted for.
    @MainActor
    private final class NotedCores {
        var ids: [Host.ID] = []
    }

    private static let tmuxPath = "/home/dev/.local/bin/tmux"
    private static let defaultTUI = HostServerKey(kind: .herdrTUI, name: "")
    private static let defaultCore = HostServerKey(kind: .herdrCore, name: "")
    private static let defaultTmux = HostServerKey(kind: .tmux, name: "")
    private static let trusted = HostKeyFingerprint(publicKeyBlob: Data("fake-host-key".utf8))

    private func record(
        address: String = "studio.example", kind: ServerKind = .herdrTUI, session: String = ""
    ) -> Host {
        Host(name: "Studio", address: address, username: "dev", serverKind: kind, sessionName: session)
    }

    private func makeSwitch(
        _ catalog: HostStore, knownHosts: any KnownHostsStore = InMemoryKnownHostsStore(),
        noted: NotedCores = NotedCores()
    ) -> HostServerSwitch {
        HostServerSwitch(
            catalog: catalog,
            dependencies: HostOnboardingDependencies(
                connector: FakeTransportConnector(outcome: .connectFails(.cancelled)),
                knownHosts: knownHosts,
                credentials: HostCredentialsProvider(
                    deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                    rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                    secrets: InMemorySecretStore()),
                noteWindowsCore: { noted.ids.append($0) }))
    }

    private func trust(_ fingerprint: HostKeyFingerprint, for id: Host.ID, in knownHosts: any KnownHostsStore) async {
        let key = HostKeyTrust.hostKey(id)
        await knownHosts.setFingerprint(fingerprint, host: key.host, port: key.port)
    }

    private func trustedKey(for id: Host.ID, in knownHosts: any KnownHostsStore) async -> HostKeyFingerprint? {
        let key = HostKeyTrust.hostKey(id)
        return await knownHosts.fingerprint(host: key.host, port: key.port)
    }

    /// One look at a Linux Host with a core and a tmux server on each of `sockets`.
    private func linuxScan(sockets: [String] = ["default", "work"]) async throws -> HostServerScan {
        let host = ScriptedCoreHost(
            tmuxProbe: ScriptedCoreHost.tmuxLines(executable: Self.tmuxPath, sockets: sockets), channel: .refused)
        return HostServerScan(try await ServerKindDetection.run(over: host, session: ""))
    }

    /// One look at a native Windows Host with a core.
    private func windowsScan() async throws -> HostServerScan {
        let host = ScriptedCoreHost(windowsLocator: ScriptedCoreHost.windowsLocatorLines(), channel: .refused)
        return HostServerScan(try await ServerKindDetection.run(over: host, session: ""))
    }

    // MARK: Turning a Server on

    /// The Console's first connection to the new record never meets an unknown key.
    @Test func aRecordAddedForAServerHasTheHostsTrustedKeys() async throws {
        let tui = record()
        let catalog = HostStore(volatileHosts: [tui])
        let knownHosts = InMemoryKnownHostsStore()
        await trust(Self.trusted, for: tui.id, in: knownHosts)

        let added = try await makeSwitch(catalog, knownHosts: knownHosts).turnOn(Self.defaultTmux, onHostOf: tui.id)

        #expect(added.id != tui.id)
        #expect(added.serverKey == Self.defaultTmux)
        #expect(catalog.machines.map { $0.members.map(\.id) } == [[tui.id, added.id]])
        #expect(await trustedKey(for: added.id, in: knownHosts) == Self.trusted)
        #expect(await trustedKey(for: tui.id, in: knownHosts) == Self.trusted)
    }

    /// A Host with no Server on is held by one record: its first Server takes
    /// that record, and the trust already under it.
    @Test func theFirstServerTakesTheRecordThatHeldTheHost() async throws {
        let held = record(kind: .unconfirmed)
        let catalog = HostStore(volatileHosts: [held])
        let knownHosts = ListedKnownHosts()
        await trust(Self.trusted, for: held.id, in: knownHosts)

        let on = try await makeSwitch(catalog, knownHosts: knownHosts).turnOn(Self.defaultCore, onHostOf: held.id)

        #expect(on.id == held.id)
        #expect(on.serverKey == Self.defaultCore)
        #expect(catalog.hosts.map(\.id) == [held.id])
        #expect(await knownHosts.trustedHosts == [HostKeyTrust.hostKey(held.id).host])
    }

    @Test func aServerThatIsOnAlreadyIsLeftAsItIs() async throws {
        let tui = record()
        let catalog = HostStore(volatileHosts: [tui])
        let knownHosts = ListedKnownHosts()

        let on = try await makeSwitch(catalog, knownHosts: knownHosts).turnOn(Self.defaultTUI, onHostOf: tui.id)

        #expect(on.id == tui.id)
        #expect(catalog.hosts.map(\.id) == [tui.id])
        #expect(await knownHosts.trustedHosts.isEmpty)
    }

    /// The look's login shell just resolved both paths, so the record's first
    /// connection does not ask it again (ADR 0044).
    @Test func aTmuxServerStoresItsSocketAndThePathsTheLookResolved() async throws {
        let tui = record()
        let catalog = HostStore(volatileHosts: [tui])
        let switcher = makeSwitch(catalog)
        let scan = try await linuxScan()
        let work = HostServerKey(kind: .tmux, name: "work")

        let onDefault = try await switcher.turnOn(Self.defaultTmux, onHostOf: tui.id, scan: scan)
        let onWork = try await switcher.turnOn(work, onHostOf: tui.id, scan: scan)

        #expect(onDefault.sessionName == TmuxSocketName.defaultName)
        #expect(onDefault.tmuxPaths == TmuxPaths(executable: Self.tmuxPath, socket: "/tmp/tmux-1000/default"))
        #expect(onWork.sessionName == "work")
        #expect(onWork.tmuxPaths == TmuxPaths(executable: Self.tmuxPath, socket: "/tmp/tmux-1000/work"))
        #expect(catalog.machines.first?.servers.compactMap(\.serverKey) == [Self.defaultTUI, Self.defaultTmux, work])
    }

    @Test func aTmuxServerTurnedOnWithNoLookStoresNoPaths() async throws {
        let held = record(kind: .unconfirmed)
        let catalog = HostStore(volatileHosts: [held])

        let on = try await makeSwitch(catalog).turnOn(Self.defaultTmux, onHostOf: held.id)

        #expect(on.serverKind == .tmux)
        #expect(on.tmuxPaths == nil)
    }

    /// A native Windows core's first connection may never get far enough to
    /// say what it runs on, so the look's word is kept.
    @Test func aCoreFoundOnNativeWindowsIsNoted() async throws {
        let tui = record()
        let catalog = HostStore(volatileHosts: [tui])
        let noted = NotedCores()
        let switcher = makeSwitch(catalog, noted: noted)
        let scan = try await windowsScan()
        #expect(scan.isNativeWindows)

        let core = try await switcher.turnOn(Self.defaultCore, onHostOf: tui.id, scan: scan)

        #expect(noted.ids == [core.id])
    }

    @Test func onlyAWindowsCoreIsNoted() async throws {
        let tui = record()
        let catalog = HostStore(volatileHosts: [tui])
        let noted = NotedCores()
        let switcher = makeSwitch(catalog, noted: noted)

        // A core on Linux, a core turned on with no look, and Herdr TUI on Windows.
        try await switcher.turnOn(Self.defaultCore, onHostOf: tui.id, scan: try await linuxScan())
        try await switcher.turnOn(HostServerKey(kind: .herdrCore, name: "work"), onHostOf: tui.id)
        try await switcher.turnOn(
            HostServerKey(kind: .herdrTUI, name: "work"), onHostOf: tui.id, scan: try await windowsScan())

        #expect(catalog.hosts.count == 4)
        #expect(noted.ids.isEmpty)
    }

    // MARK: A Server the catalog refuses

    /// A name the kind's server would refuse is refused here, in that kind's
    /// words, before a record or its trust is left behind.
    @Test(arguments: [
        (ServerKind.tmux, "/tmp/tmux-1000/default", "A socket path is not supported"),
        (ServerKind.herdrCore, "a/b", "herdr-core refuses the session name"),
        (ServerKind.herdrTUI, "../x", "herdr refuses the session name"),
    ])
    func aRefusedNameLeavesNoRecordAndNoTrustBehind(kind: ServerKind, name: String, words: String) async throws {
        let tui = record()
        let catalog = HostStore(volatileHosts: [tui])
        let knownHosts = ListedKnownHosts()
        await trust(Self.trusted, for: tui.id, in: knownHosts)
        let switcher = makeSwitch(catalog, knownHosts: knownHosts)
        let server = HostServerKey(kind: kind, name: name)
        let reason = try #require(kind.sessionNameRefusal(server.name))

        let refusal = await #expect(throws: HostStoreError.sessionNameRefused(reason: reason)) {
            try await switcher.turnOn(server, onHostOf: tui.id)
        }

        #expect(catalog.hosts.map(\.id) == [tui.id])
        #expect(await knownHosts.trustedHosts == [HostKeyTrust.hostKey(tui.id).host])
        #expect(reason.contains(words))
        #expect(switcher.refusal(try #require(refusal), turningOn: server) == reason)
    }

    @Test func aRefusedNameLeavesTheRecordHoldingTheHostAsItWas() async throws {
        let held = record(kind: .unconfirmed)
        let catalog = HostStore(volatileHosts: [held])
        let switcher = makeSwitch(catalog)
        let socketPath = HostServerKey(kind: .tmux, name: "/tmp/tmux-1000/default")

        await #expect(throws: HostStoreError.self) {
            try await switcher.turnOn(socketPath, onHostOf: held.id)
        }

        #expect(catalog.hosts == [held])
        #expect(catalog.machines.first?.servers.isEmpty == true)
    }

    /// A kind whose saved Hosts did not read takes no new one, so nothing can
    /// write over what is there. The refusal says which.
    @Test(arguments: [
        (ServerKind.tmux, "tmuxHosts", "The saved tmux Hosts could not be read, so no tmux Host can be added."),
        (
            ServerKind.herdrCore, "herdrCoreHosts",
            "The saved herdr-core Hosts could not be read, so no herdr-core Host can be added."
        ),
    ])
    func aKindWhoseSavedHostsDidNotReadRefusesInWords(
        kind: ServerKind, defaultsKey: String, words: String
    ) async throws {
        let suiteName = "HostServerSwitchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("{not json".utf8), forKey: defaultsKey)
        let catalog = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let tui = record()
        try catalog.add(tui)
        let knownHosts = ListedKnownHosts()
        await trust(Self.trusted, for: tui.id, in: knownHosts)
        let switcher = makeSwitch(catalog, knownHosts: knownHosts)
        let server = HostServerKey(kind: kind, name: "")

        let refusal = await #expect(throws: HostStoreError.catalogUnreadable) {
            try await switcher.turnOn(server, onHostOf: tui.id)
        }

        #expect(switcher.refusal(try #require(refusal), turningOn: server) == words)
        #expect(catalog.hosts.map(\.id) == [tui.id])
        #expect(await knownHosts.trustedHosts == [HostKeyTrust.hostKey(tui.id).host])
    }

    @Test func aRecordThatIsNotInTheCatalogHasNoHostToTurnAServerOnFor() async throws {
        let catalog = HostStore(volatileHosts: [record()])
        let switcher = makeSwitch(catalog)

        let refusal = await #expect(throws: HostStoreError.unknownHost) {
            try await switcher.turnOn(Self.defaultTmux, onHostOf: UUID())
        }

        #expect(
            switcher.refusal(try #require(refusal), turningOn: Self.defaultTmux)
                == "The Server could not be turned on. (unknownHost)")
        #expect(catalog.hosts.count == 1)
    }

    // MARK: Sharing trust

    /// After a look reached the Host through one record, the others that trust
    /// no key yet take its keys. One with a key of its own keeps it: only the
    /// user replaces a trusted key.
    @Test func sharingTrustFillsOnlyTheRecordsThatTrustNoKey() async throws {
        let tui = record()
        let tmux = record(kind: .tmux)
        let core = record(kind: .herdrCore)
        let elsewhere = record(address: "build.example")
        let catalog = HostStore(volatileHosts: [tui, tmux, core, elsewhere])
        let knownHosts = InMemoryKnownHostsStore()
        let own = HostKeyFingerprint(publicKeyBlob: Data("another-host-key".utf8))
        await trust(Self.trusted, for: tui.id, in: knownHosts)
        await trust(own, for: core.id, in: knownHosts)

        await makeSwitch(catalog, knownHosts: knownHosts).shareTrust(of: tui.id)

        #expect(await trustedKey(for: tmux.id, in: knownHosts) == Self.trusted)
        #expect(await trustedKey(for: core.id, in: knownHosts) == own)
        #expect(await trustedKey(for: tui.id, in: knownHosts) == Self.trusted)
        // Another Host is another machine, with a key of its own to show.
        #expect(await trustedKey(for: elsewhere.id, in: knownHosts) == nil)
    }
}
