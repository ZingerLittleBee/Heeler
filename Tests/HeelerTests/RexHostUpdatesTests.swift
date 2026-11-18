import Foundation
import Testing

@testable import Heeler

/// Updates and a Rex Server (ADRs 0048 and 0049): Rex has no plugin and no
/// Host Helper, so its record is never read, listed, counted or updated,
/// beside other Servers or on a Host where it is the only one on. Records and
/// versions are invented.
@MainActor
@Suite("Rex and Plugin and Helper updates")
struct RexHostUpdatesTests {
    /// What the store asked of the Hosts, in order.
    private actor Calls {
        var pluginReads: [Host.ID] = []
        var helperReads: [Host.ID] = []
        var pluginUpdates: [Host.ID] = []
        var helperUpdates: [Host.ID] = []

        func readPlugin(_ id: Host.ID) { pluginReads.append(id) }
        func readHelper(_ id: Host.ID) { helperReads.append(id) }
        func updatePlugin(_ id: Host.ID) { pluginUpdates.append(id) }
        func updateHelper(_ id: Host.ID) { helperUpdates.append(id) }
    }

    private static let bundled = PluginVersion(9, 9, 9)
    private static let olderPlugin = HeelerPluginStatus.installed(HeelerPluginInstallation(version: "0.1.0"))

    /// A macOS Helper older than this app's, which an update fits.
    private static func olderHelper() throws -> HostHelperReading {
        let manifest = try JSONEncoder().encode(HostHelperManifest(version: "0.0.1", files: []))
        let hex = manifest.map { String(format: "%02x", $0) }.joined()
        let lines = [
            "n begin", "home /h", "data /h/d", "config /h/c", "kernel Darwin", "node /usr/bin/node",
            "app-present", "manifest \(hex)", "hash-tool-missing", "n end",
        ]
        let probe = try HostHelperProbe(stdout: Data((lines.joined(separator: "\n") + "\n").utf8), nonce: "n")
        return HostHelperReading(probe: probe, bundled: bundled)
    }

    private static func record(_ kind: ServerKind, address: String = "studio.example") -> Host {
        Host(name: "Studio", address: address, username: "dev", serverKind: kind)
    }

    private func store(_ hosts: [Host], calls: Calls) throws -> HostUpdatesStore {
        let helper = try Self.olderHelper()
        let plugin = Self.olderPlugin
        return HostUpdatesStore(
            hosts: { hosts },
            work: HostUpdatesStore.Work(
                readPlugin: { id in
                    await calls.readPlugin(id)
                    return plugin
                },
                readHelper: { id in
                    await calls.readHelper(id)
                    return helper
                },
                updatePlugin: { host in
                    await calls.updatePlugin(host.id)
                    return HeelerPluginActionRunner.Outcome(readBack: plugin)
                },
                updateHelper: { host, _ in
                    await calls.updateHelper(host.id)
                    return HostUpdatesStore.HelperOutcome(readBack: helper)
                },
                sleep: { _ in }),
            defaults: UserDefaults(suiteName: "RexHostUpdatesTests.\(UUID())") ?? .standard,
            bundledPlugin: Self.bundled, bundledHelper: Self.bundled)
    }

    /// Waits, for two seconds at most, until `done` holds.
    private func waitUntil(_ done: @MainActor () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await done() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits for every update the store started to have its turn.
    private func settle(_ store: HostUpdatesStore) async {
        await waitUntil {
            if case .running = store.snapshot.run { false } else { true }
        }
    }

    @Test func aRexServerIsServedByNoHelper() {
        #expect(!ServerKind.rex.usesHostHelper)
    }

    @Test func rexBesideOtherServersIsNeverReadListedOrUpdated() async throws {
        let tui = Self.record(.herdrTUI)
        let tmux = Self.record(.tmux)
        let rex = Self.record(.rex)
        let machine = try #require(HostMachine.grouped([tui, tmux, rex]).first)
        #expect(machine.servers.map(\.id).contains(rex.id))
        let calls = Calls()
        let store = try store([tui, tmux, rex], calls: calls)

        await store.hostsDidConnect([tui.id, tmux.id, rex.id])
        await store.refresh()
        // A Helper changed from a Server's page: read again where one serves.
        store.helpersDidChange()
        await waitUntil { await calls.helperReads.count == 3 }
        // A Server's page never notes a Rex plugin; were one noted, it lists nothing.
        store.notePlugin(Self.olderPlugin, for: rex.id)

        #expect(await calls.pluginReads == [tui.id, tui.id])
        #expect(await calls.helperReads == [tmux.id, tmux.id, tmux.id])
        let snapshot = store.snapshot
        #expect(snapshot.groups.map(\.id) == [machine.id])
        #expect(snapshot.items.map(\.id) == [.plugin(tui.id), .helper(machine.id)])
        #expect(!snapshot.items.contains { $0.record == rex.id })
        #expect(snapshot.items.allSatisfy { $0.state == .updateAvailable })
        // The Helper serves tmux alone on this Host.
        #expect(snapshot.item(.helper(machine.id))?.item.scope == "tmux")
        #expect(snapshot.badge == .count(2))
        #expect(snapshot.tag(for: machine.id) == .updates(2))
        #expect(snapshot.card == .available(updates: 2, hosts: 1, components: [.plugin, .helper]))

        store.updateAll()
        await settle(store)

        #expect(await calls.pluginUpdates == [tui.id])
        #expect(await calls.helperUpdates == [tmux.id])
    }

    @Test func aHostWithOnlyRexOnShowsNothingOfUpdates() async throws {
        let rex = Self.record(.rex, address: "lab.example")
        let machine = try #require(HostMachine.grouped([rex]).first)
        let calls = Calls()
        let store = try store([rex], calls: calls)

        await store.hostsDidConnect([rex.id])
        await store.refresh()
        store.notePlugin(Self.olderPlugin, for: rex.id)
        store.updateAll()
        store.updateAll(on: machine.id)
        await settle(store)

        #expect(await calls.pluginReads.isEmpty)
        #expect(await calls.helperReads.isEmpty)
        #expect(await calls.pluginUpdates.isEmpty)
        #expect(await calls.helperUpdates.isEmpty)
        let snapshot = store.snapshot
        #expect(snapshot.groups.isEmpty)
        #expect(snapshot.group(machine.id) == nil)
        #expect(snapshot.card == nil)
        #expect(snapshot.badge == nil)
        #expect(snapshot.tag(for: machine.id) == nil)
        #expect(snapshot.primaryAction == nil)
        #expect(snapshot.run == .idle)
    }
}
