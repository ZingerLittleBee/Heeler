import Foundation
import Testing

@testable import Heeler

@Suite("Hosts and their Servers")
@MainActor
struct HostMachineTests {
    private func record(
        name: String = "Studio", address: String = "studio.example", username: String = "dev",
        authMethod: Host.AuthMethod = .deviceKey, kind: ServerKind = .herdrTUI, session: String = ""
    ) -> Host {
        Host(
            name: name, address: address, username: username, authMethod: authMethod,
            serverKind: kind, sessionName: session)
    }

    @Test func recordsReachedTheSameWayAreOneHost() {
        let tui = record()
        let tmux = record(kind: .tmux)
        let other = record(name: "Build", address: "build.example")
        // Case and stray spaces in an address name the same machine.
        let core = record(address: " Studio.Example ", kind: .herdrCore)

        let machines = HostMachine.grouped([tui, other, tmux, core])

        #expect(machines.map { $0.members.map(\.id) } == [[tui.id, tmux.id, core.id], [other.id]])
        #expect(machines.map(\.name) == ["Studio", "Build"])
    }

    @Test func anotherAccountOrPortIsAnotherHost() {
        let base = record()
        let otherUser = record(username: "ops")
        let otherAuth = record(authMethod: .password)
        let otherPort = Host(name: "Studio", address: "studio.example", port: 2222, username: "dev")

        #expect(HostMachine.grouped([base, otherUser, otherAuth, otherPort]).count == 4)
    }

    @Test func aHostWithNoServerOnIsHeldByOneUnconfirmedRecord() throws {
        let held = record(kind: .unconfirmed)
        let machine = try #require(HostMachine.grouped([held]).first)

        #expect(machine.servers.isEmpty)
        #expect(machine.spareRecord == held)
        #expect(held.serverKey == nil)
    }

    @Test func serversThatReadAlikeAreLabelledAndOthersAreNot() {
        let tui = record()
        let work = record(session: "work")
        let tmux = record(kind: .tmux)
        let namedApart = record(name: "Studio sockets", kind: .tmux, session: "second")
        let alone = record(name: "Build", address: "build.example", kind: .herdrCore)

        let labels = HostMachine.serverLabels(for: [tui, work, tmux, namedApart, alone])

        #expect(labels[tui.id] == "Herdr TUI")
        #expect(labels[work.id] == "Herdr TUI · work")
        #expect(labels[tmux.id] == "tmux")
        #expect(labels[namedApart.id] == nil)
        #expect(labels[alone.id] == nil)
    }

    @Test func theCatalogNamesEachServerOfAHost() throws {
        let tui = record()
        let store = HostStore(volatileHosts: [tui])
        #expect(store.hosts.map(\.displayName) == ["Studio"])

        let tmux = HostServerKey(kind: .tmux, name: "")
        #expect(store.machine(containing: tui.id)?.needsRecord(for: tmux) == true)
        let recordID = UUID()
        let added = try store.turnOn(tmux, onHostOf: tui.id, newRecordID: recordID)

        #expect(added.id == recordID)
        #expect(added.sessionName == "default")
        #expect(store.hosts.map(\.displayName) == ["Studio · Herdr TUI", "Studio · tmux"])
        #expect(store.machines.count == 1)
        #expect(store.machine(containing: tui.id)?.needsRecord(for: tmux) == false)

        try store.remove(added.id)
        #expect(store.hosts.map(\.displayName) == ["Studio"])
    }

    @Test func turningOnTheFirstServerTakesTheRecordThatHeldTheHost() throws {
        let held = record(kind: .unconfirmed)
        let store = HostStore(volatileHosts: [held])

        let core = HostServerKey(kind: .herdrCore, name: "")
        #expect(store.machine(containing: held.id)?.needsRecord(for: core) == false)
        let first = try store.turnOn(core, onHostOf: held.id)
        let again = try store.turnOn(core, onHostOf: held.id)

        #expect(first.id == held.id)
        #expect(first.serverKind == .herdrCore)
        #expect(again.id == held.id)
        #expect(store.hosts.count == 1)
    }

    @Test func aServerTurnedOnCarriesTheHostsPassword() throws {
        let secrets = InMemorySecretStore()
        let suiteName = "HostMachineTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = HostStore(defaults: defaults, secrets: secrets)
        let tui = record(authMethod: .password)
        try store.add(tui, password: "hunter2")

        let added = try store.turnOn(HostServerKey(kind: .tmux, name: "work"), onHostOf: tui.id)

        #expect(try store.password(for: added) == "hunter2")
        #expect(HostStore(defaults: defaults, secrets: secrets).machines.map(\.members.count) == [2])
    }

    @Test func theLastServerLeavesARecordHoldingItsHost() throws {
        let tui = record()
        let store = HostStore(volatileHosts: [tui])
        let tmux = try store.turnOn(HostServerKey(kind: .tmux, name: ""), onHostOf: tui.id)

        #expect(try store.holdHost(beyond: tmux.id) == nil)
        try store.remove(tmux.id)

        let held = try #require(try store.holdHost(beyond: tui.id))
        try store.remove(tui.id)

        #expect(store.hosts.map(\.id) == [held.id])
        #expect(store.hosts.first?.serverKind == .unconfirmed)
        #expect(store.machines.first?.name == "Studio")
        #expect(store.consoleHosts.isEmpty)
    }

    @Test func editingAHostReachesEveryRecord() throws {
        let tui = record()
        let store = HostStore(volatileHosts: [tui, record(name: "Build", address: "build.example")])
        let tmux = try store.turnOn(HostServerKey(kind: .tmux, name: ""), onHostOf: tui.id)

        var edited = try #require(store.hosts.first { $0.id == tui.id })
        edited.name = "Studio Mac"
        edited.username = "ops"
        edited.routes = [HostRoute(address: "10.0.0.5", port: 2222)]
        try store.updateHost(with: edited)

        let machine = try #require(store.machine(containing: tmux.id))
        #expect(machine.members.map(\.id) == [tui.id, tmux.id])
        #expect(machine.members.map(\.displayName) == ["Studio Mac · Herdr TUI", "Studio Mac · tmux"])
        #expect(machine.members.allSatisfy { $0.username == "ops" && $0.address == "10.0.0.5" && $0.port == 2222 })
        #expect(machine.members.map(\.serverKind) == [.herdrTUI, .tmux])
        #expect(store.machines.count == 2)
    }

    @Test func labelsAreNotStored() throws {
        let tui = record()
        let store = HostStore(volatileHosts: [tui])
        try store.turnOn(HostServerKey(kind: .tmux, name: ""), onHostOf: tui.id)
        let labelled = try #require(store.hosts.first)
        #expect(labelled.serverLabel == "Herdr TUI")

        let decoded = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(labelled))

        #expect(decoded.serverLabel == nil)
        #expect(decoded.displayName == "Studio")
    }

    // MARK: Holding a Host with no Server on

    @Test func theRecordHoldingAHostKeepsItsNameConnectionAndPassword() throws {
        let secrets = InMemorySecretStore()
        let suiteName = "HostMachineTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = HostStore(defaults: defaults, secrets: secrets)
        let tui = Host(
            name: "Studio", address: "studio.example", port: 2222, username: "dev", authMethod: .password)
        try store.add(tui, password: "hunter2")

        let held = try #require(try store.holdHost(beyond: tui.id))
        try store.remove(tui.id)

        #expect(held.id != tui.id)
        #expect(held.serverKind == .unconfirmed)
        #expect(held.name == "Studio")
        #expect(HostMachine.Connection(held) == HostMachine.Connection(tui))
        #expect(try store.password(for: held) == "hunter2")
        // The Host is the same one after a relaunch, with no Server on.
        let reloaded = HostStore(defaults: defaults, secrets: secrets)
        #expect(reloaded.machines.map(\.name) == ["Studio"])
        #expect(reloaded.machines.first?.spareRecord?.id == held.id)
    }

    @Test func aHostThatIsHeldAlreadyTakesNoSecondHolder() throws {
        let held = record(kind: .unconfirmed)
        let store = HostStore(volatileHosts: [held])

        #expect(try store.holdHost(beyond: held.id) == nil)
        #expect(store.hosts.map(\.id) == [held.id])
        #expect(throws: HostStoreError.unknownHost) { try store.holdHost(beyond: UUID()) }
    }

    // MARK: Turning a Server off

    /// What turning a Server off cleaned up, in order.
    @MainActor
    private final class TurnOffLog {
        var steps: [String] = []
    }

    /// The cleanup the app wires, over stand-ins: the trust store is real, and
    /// `keyed` are the records this device holds a Notification Key for.
    private func turnOffDependencies(
        knownHosts: InMemoryKnownHostsStore = InMemoryKnownHostsStore(), keyed: Set<Host.ID> = [],
        connected: Set<Host.ID> = [], log: TurnOffLog = TurnOffLog()
    ) -> HostRemovalDependencies {
        HostRemovalDependencies(
            isConnected: { connected.contains($0) },
            hasNotificationKey: { keyed.contains($0) },
            revokeNotifications: { log.steps.append("revoke \($0.id)") },
            forgetNotificationKey: { log.steps.append("forget key \($0)") },
            didRemoveHost: { log.steps.append("removed \($0)") },
            forgetHostRecords: { id in
                await knownHosts.forgetHost(id)
                log.steps.append("forget records \(id)")
            },
            copyHostKeyTrust: { source, record in
                await knownHosts.copyTrust(from: source, to: record)
                log.steps.append("copy trust \(source) \(record)")
            })
    }

    private func trustedKey(for id: Host.ID, in knownHosts: InMemoryKnownHostsStore) async -> HostKeyFingerprint? {
        let key = HostKeyTrust.hostKey(id)
        return await knownHosts.fingerprint(host: key.host, port: key.port)
    }

    /// A switch takes effect as it is thrown: the Server's record goes as a
    /// removed Host's does, and its Host stays with the Servers still on.
    @Test func turningAServerOffRemovesItsRecordAtOnceAndKeepsTheHost() async throws {
        let tui = record()
        let store = HostStore(volatileHosts: [tui])
        let tmux = try store.turnOn(HostServerKey(kind: .tmux, name: "work"), onHostOf: tui.id)
        let removal = HostRemovalStore(store: store)
        let log = TurnOffLog()

        await removal.turnOff(tmux.id, dependencies: turnOffDependencies(log: log))

        #expect(removal.pendingRequest == nil)
        #expect(removal.errorMessage == nil)
        #expect(store.hosts.map(\.id) == [tui.id])
        #expect(store.machines.first?.servers.map(\.id) == [tui.id])
        // Another Server holds the Host, so no trust is carried anywhere.
        #expect(
            log.steps == [
                "revoke \(tmux.id)", "forget key \(tmux.id)", "removed \(tmux.id)", "forget records \(tmux.id)",
            ])
    }

    @Test func turningOffAServerWithANotificationKeyAsksFirst() async throws {
        let tui = record()
        let store = HostStore(volatileHosts: [tui])
        let tmux = try store.turnOn(HostServerKey(kind: .tmux, name: "work"), onHostOf: tui.id)
        let removal = HostRemovalStore(store: store)
        let dependencies = turnOffDependencies(keyed: [tmux.id])

        await removal.turnOff(tmux.id, dependencies: dependencies)

        let request = try #require(removal.pendingRequest)
        #expect(store.hosts.map(\.id) == [tui.id, tmux.id])
        #expect(request.hosts.map(\.id) == [tmux.id])
        #expect(request.turnsOffServer == "tmux · work")
        #expect(request.deletesNotificationKey)
        // Not connected, so its registration of this device cannot be revoked.
        #expect(request.leavesNotificationsBehind)

        await removal.confirmRemoval(request, dependencies: dependencies)

        #expect(removal.pendingRequest == nil)
        #expect(store.hosts.map(\.id) == [tui.id])
    }

    @Test func aServerThatCanBeToldToStopNotifyingLeavesNothingBehind() async throws {
        let tui = record()
        let store = HostStore(volatileHosts: [tui])
        let removal = HostRemovalStore(store: store)

        await removal.turnOff(tui.id, dependencies: turnOffDependencies(keyed: [tui.id], connected: [tui.id]))

        let request = try #require(removal.pendingRequest)
        #expect(request.turnsOffServer == "Herdr TUI")
        #expect(request.deletesNotificationKey)
        #expect(!request.leavesNotificationsBehind)
    }

    /// The Host outlives its last Server: a record with none holds it from
    /// then on, trusting the keys the Server's record did.
    @Test func turningTheLastServerOffKeepsTheHostAndItsTrust() async throws {
        let tui = record()
        let store = HostStore(volatileHosts: [tui])
        let knownHosts = InMemoryKnownHostsStore()
        let trusted = HostKeyFingerprint(publicKeyBlob: Data("fake-host-key".utf8))
        let trust = HostKeyTrust.hostKey(tui.id)
        await knownHosts.setFingerprint(trusted, host: trust.host, port: trust.port)
        let removal = HostRemovalStore(store: store)
        let log = TurnOffLog()

        await removal.turnOff(tui.id, dependencies: turnOffDependencies(knownHosts: knownHosts, log: log))

        let held = try #require(store.hosts.first)
        #expect(store.hosts.count == 1)
        #expect(held.id != tui.id)
        #expect(held.serverKind == .unconfirmed)
        #expect(store.machines.map(\.name) == ["Studio"])
        #expect(store.machines.first?.servers.isEmpty == true)
        #expect(store.consoleHosts.isEmpty)
        // The trust is carried over before the Server's own is forgotten.
        #expect(log.steps.first == "copy trust \(tui.id) \(held.id)")
        #expect(log.steps.last == "forget records \(tui.id)")
        #expect(await trustedKey(for: held.id, in: knownHosts) == trusted)
        #expect(await trustedKey(for: tui.id, in: knownHosts) == nil)

        // Turned back on, the Server takes the record that held the Host.
        let again = try store.turnOn(HostServerKey(kind: .herdrTUI, name: ""), onHostOf: held.id)
        #expect(again.id == held.id)
        #expect(store.hosts.count == 1)
    }

    @Test func turningOffARecordTheCatalogDoesNotHaveDoesNothing() async {
        let tui = record()
        let store = HostStore(volatileHosts: [tui])
        let removal = HostRemovalStore(store: store)
        let log = TurnOffLog()

        await removal.turnOff(UUID(), dependencies: turnOffDependencies(log: log))

        #expect(removal.pendingRequest == nil)
        #expect(store.hosts.map(\.id) == [tui.id])
        #expect(log.steps.isEmpty)
    }

    /// The confirmation names the Server and the Host it stays on, and says
    /// what leaves with it instead of what a removed Host loses.
    @Test func turningAServerOffIsWordedAsASwitchAndNotARemoval() {
        let tmux = record(kind: .tmux, session: "work")
        let request = HostRemovalRequest(
            hosts: [tmux], deletesNotificationKey: true, turnsOffServer: "tmux · work")

        #expect(request.title == "Turn off tmux · work on Studio?")
        #expect(request.actionTitle == "Turn Off")
        #expect(
            request.message
                == "Its Agents, Terminals and notifications leave this device, and its Notification Key is "
                + "deleted from the Keychain.")

        var unreachable = request
        unreachable.leavesNotificationsBehind = true
        #expect(
            unreachable.message
                == "Its Agents, Terminals and notifications leave this device, and its Notification Key is "
                + "deleted from the Keychain. Heeler can't reach this Host, so it may keep sending "
                + "notifications to this device. Connect to it first to stop them.")
    }

    /// Removing a Host takes every record of it, and still names one Host.
    @Test func removingAHostWithSeveralServersIsWordedAsOneHost() throws {
        let tui = record()
        let store = HostStore(volatileHosts: [tui, record(name: "Build", address: "build.example")])
        let tmux = try store.turnOn(HostServerKey(kind: .tmux, name: ""), onHostOf: tui.id)
        let removal = HostRemovalStore(store: store)

        removal.requestRemoval([tui.id, tmux.id])

        let request = try #require(removal.pendingRequest)
        #expect(request.title == "Remove Studio?")
        #expect(request.actionTitle == "Remove Host")
        #expect(request.turnsOffServer == nil)

        removal.requestRemoval(store.hosts.map(\.id))
        #expect(removal.pendingRequest?.title == "Remove 2 Hosts?")
        #expect(removal.pendingRequest?.actionTitle == "Remove Hosts")
    }
}
