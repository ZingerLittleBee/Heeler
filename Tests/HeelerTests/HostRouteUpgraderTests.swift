import Foundation
import Synchronization
import Testing

@testable import Heeler

@Suite("Host route upgrade")
@MainActor
struct HostRouteUpgraderTests {
    private static let overlay = UUID()

    /// LAN first, then the same machine over an Overlay Network and behind a
    /// Jump Host.
    private let routes = [
        HostRoute(address: "10.0.0.5"),
        HostRoute(address: "100.64.0.5", overlayNetworkID: HostRouteUpgraderTests.overlay),
        HostRoute(address: "127.0.0.1", port: 2222, jumpAddress: "vps.example"),
    ]

    private func machine(servers: [ServerKind] = [.herdrTUI, .tmux]) -> HostMachine {
        let records = servers.map { Host(username: "dev", serverKind: $0, routes: routes) }
        return HostMachine.grouped(records)[0]
    }

    /// What a check asked of the network and of the Console.
    private final class Calls: Sendable {
        private let probed = Mutex<[[Int]]>([])
        private let redialed = Mutex<[Host.ID]>([])

        var probes: [[Int]] { probed.withLock { $0 } }
        var redials: [Host.ID] { redialed.withLock { $0 } }

        func noteProbe(_ candidates: [Int]) {
            probed.withLock { $0.append(candidates) }
        }

        func noteRedial(_ id: Host.ID) {
            redialed.withLock { $0.append(id) }
        }
    }

    private func upgrader(
        _ machine: HostMachine, leases: HostRouteLeases, calls: Calls,
        connected: Set<Host.ID>? = nil, reaching reachable: Int?
    ) -> HostRouteUpgrader {
        let connected = connected ?? Set(machine.servers.map(\.id))
        return HostRouteUpgrader(
            leases: leases,
            machines: { [machine] },
            isConnected: { connected.contains($0) },
            probe: { _, candidates in
                calls.noteProbe(candidates)
                return reachable
            },
            redial: { calls.noteRedial($0) })
    }

    @Test func onlyAHostOnASlowerRouteHasRoutesToLookAt() {
        #expect(HostRouteUpgrade.candidates(among: routes, holding: 1) == [0])
        #expect(HostRouteUpgrade.candidates(among: routes, holding: 2) == [0])
        #expect(HostRouteUpgrade.candidates(among: routes, holding: 0).isEmpty)
        #expect(HostRouteUpgrade.candidates(among: routes, holding: nil).isEmpty)
        #expect(HostRouteUpgrade.candidates(among: Array(routes.dropFirst()), holding: 0).isEmpty)
    }

    @Test func aDirectRouteInReachMovesTheHostAndRedialsItsServers() async {
        let machine = machine()
        let leases = HostRouteLeases()
        let calls = Calls()
        _ = await leases.hold(1, for: machine.id) { true }

        await upgrader(machine, leases: leases, calls: calls, reaching: 0).check()

        #expect(calls.probes == [[0]])
        #expect(Set(calls.redials) == Set(machine.servers.map(\.id)))
        #expect(await leases.route(for: machine.id) == 0)
    }

    @Test func aDirectRouteUpgradeRedialsAllConnectedServersConcurrently() async {
        let machine = machine()
        let leases = HostRouteLeases()
        _ = await leases.hold(1, for: machine.id) { true }
        var entered: Set<Host.ID> = []
        var waiters: [CheckedContinuation<Void, Never>] = []

        let upgrader = HostRouteUpgrader(
            leases: leases,
            machines: { [machine] },
            isConnected: { _ in true },
            probe: { _, _ in 0 },
            redial: { id in
                entered.insert(id)
                if entered.count == machine.servers.count {
                    let pending = waiters
                    waiters.removeAll()
                    for waiter in pending { waiter.resume() }
                } else {
                    await withCheckedContinuation { waiters.append($0) }
                }
            })

        await upgrader.check()

        #expect(entered == Set(machine.servers.map(\.id)))
        #expect(await leases.route(for: machine.id) == 0)
    }

    @Test func aHostStaysWhereItIsWhileNoDirectRouteAnswers() async {
        let machine = machine()
        let leases = HostRouteLeases()
        let calls = Calls()
        _ = await leases.hold(1, for: machine.id) { true }

        await upgrader(machine, leases: leases, calls: calls, reaching: nil).check()

        #expect(calls.probes == [[0]])
        #expect(calls.redials.isEmpty)
        #expect(await leases.route(for: machine.id) == 1)
    }

    @Test func aHostOnADirectRouteIsNotProbed() async {
        let machine = machine()
        let leases = HostRouteLeases()
        let calls = Calls()
        _ = await leases.hold(0, for: machine.id) { true }

        await upgrader(machine, leases: leases, calls: calls, reaching: 0).check()

        #expect(calls.probes.isEmpty)
        #expect(calls.redials.isEmpty)
    }

    @Test func aHostWithNoServerConnectedIsLeftToItsOwnDial() async {
        let machine = machine()
        let leases = HostRouteLeases()
        let calls = Calls()
        _ = await leases.hold(1, for: machine.id) { true }

        await upgrader(machine, leases: leases, calls: calls, connected: [], reaching: 0).check()

        #expect(calls.probes.isEmpty)
        #expect(calls.redials.isEmpty)
    }

    @Test func onlyTheConnectedServersAreRedialed() async {
        let machine = machine()
        let leases = HostRouteLeases()
        let calls = Calls()
        let connected = machine.servers[1].id
        _ = await leases.hold(2, for: machine.id) { true }

        await upgrader(machine, leases: leases, calls: calls, connected: [connected], reaching: 0).check()

        #expect(calls.redials == [connected])
        #expect(await leases.route(for: machine.id) == 0)
    }

    @Test func aHostThatLeftItsRouteMeanwhileIsNotMoved() async {
        let machine = machine()
        let leases = HostRouteLeases()
        let calls = Calls()
        _ = await leases.hold(1, for: machine.id) { true }
        let upgrader = HostRouteUpgrader(
            leases: leases,
            machines: { [machine] },
            isConnected: { _ in true },
            probe: { _, _ in
                // Its connections ended and a dial settled it elsewhere.
                await leases.move(machine.id, to: 2)
                return 0
            },
            redial: { calls.noteRedial($0) })

        await upgrader.check()

        #expect(calls.redials.isEmpty)
        #expect(await leases.route(for: machine.id) == 2)
    }

    @Test func theFirstPathIsNotAChange() {
        let wifi = NetworkPathChanges.Signature(
            isSatisfied: true, interfaces: ["wifi:en0"], gateways: ["192.168.1.1"])
        let cellular = NetworkPathChanges.Signature(
            isSatisfied: true, interfaces: ["cellular:pdp_ip0"], gateways: [])

        #expect(!NetworkPathChanges.isChange(from: nil, to: wifi))
        #expect(!NetworkPathChanges.isChange(from: wifi, to: wifi))
        #expect(NetworkPathChanges.isChange(from: wifi, to: cellular))
    }
}
