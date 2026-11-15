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

        let added = try store.turnOn(HostServerKey(kind: .tmux, name: ""), onHostOf: tui.id)

        #expect(added.copiedFrom == tui.id)
        #expect(added.record.sessionName == "default")
        #expect(store.hosts.map(\.displayName) == ["Studio · Herdr TUI", "Studio · tmux"])
        #expect(store.machines.count == 1)

        try store.remove(added.record.id)
        #expect(store.hosts.map(\.displayName) == ["Studio"])
    }

    @Test func turningOnTheFirstServerTakesTheRecordThatHeldTheHost() throws {
        let held = record(kind: .unconfirmed)
        let store = HostStore(volatileHosts: [held])

        let first = try store.turnOn(HostServerKey(kind: .herdrCore, name: ""), onHostOf: held.id)
        let again = try store.turnOn(HostServerKey(kind: .herdrCore, name: ""), onHostOf: held.id)

        #expect(first.record.id == held.id)
        #expect(first.copiedFrom == nil)
        #expect(first.record.serverKind == .herdrCore)
        #expect(again.record.id == held.id)
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

        #expect(try store.password(for: added.record) == "hunter2")
        #expect(HostStore(defaults: defaults, secrets: secrets).machines.map(\.members.count) == [2])
    }

    @Test func theLastServerLeavesARecordHoldingItsHost() throws {
        let tui = record()
        let store = HostStore(volatileHosts: [tui])
        let tmux = try store.turnOn(HostServerKey(kind: .tmux, name: ""), onHostOf: tui.id).record

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
        let tmux = try store.turnOn(HostServerKey(kind: .tmux, name: ""), onHostOf: tui.id).record

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
        _ = try store.turnOn(HostServerKey(kind: .tmux, name: ""), onHostOf: tui.id)
        let labelled = try #require(store.hosts.first)
        #expect(labelled.serverLabel == "Herdr TUI")

        let decoded = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(labelled))

        #expect(decoded.serverLabel == nil)
        #expect(decoded.displayName == "Studio")
    }
}
