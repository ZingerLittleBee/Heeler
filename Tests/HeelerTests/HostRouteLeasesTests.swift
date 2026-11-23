import Foundation
import Synchronization
import Testing

@testable import Heeler

@Suite("Host route leases")
struct HostRouteLeasesTests {
    /// A connection a test can end.
    private final class Link: Sendable {
        let route: Int
        private let alive = Mutex(true)

        init(route: Int) {
            self.route = route
        }

        var isAlive: Bool { alive.withLock { $0 } }

        func end() {
            alive.withLock { $0 = false }
        }
    }

    /// What each dial was asked to follow, and the links it closed.
    private final class Dials: Sendable {
        private let asked = Mutex<[Int?]>([])
        private let closed = Mutex<[Int]>([])

        var followed: [Int?] { asked.withLock { $0 } }
        var closedRoutes: [Int] { closed.withLock { $0 } }

        func note(_ leased: Int?) {
            asked.withLock { $0.append(leased) }
        }

        func close(_ link: Link) {
            link.end()
            closed.withLock { $0.append(link.route) }
        }
    }

    private let host = HostMachine.Connection(
        Host(
            username: "dev",
            routes: [HostRoute(address: "10.0.0.5"), HostRoute(address: "100.64.0.5")]))

    /// Dials through `leases`, racing to `raced` when the Host holds no route.
    private func connect(
        _ leases: HostRouteLeases, racingTo raced: Int, dials: Dials
    ) async throws -> Link {
        try await leases.connect(
            to: host,
            dial: { leased in
                dials.note(leased)
                let link = Link(route: leased ?? raced)
                return (link, link.route)
            },
            isAlive: { $0.isAlive },
            close: { dials.close($0) })
    }

    @Test func theFirstConnectionSettlesTheRouteAndLaterDialsFollowIt() async throws {
        let leases = HostRouteLeases()
        let dials = Dials()

        let first = try await connect(leases, racingTo: 1, dials: dials)
        let second = try await connect(leases, racingTo: 0, dials: dials)

        #expect(dials.followed == [nil, 1])
        #expect(await leases.route(for: host) == 1)
        #expect(first.route == 1)
        #expect(second.route == 1)
    }

    @Test func aConnectionThatRacedElsewhereGivesWayToTheHostsRoute() async throws {
        let leases = HostRouteLeases()
        let dials = Dials()
        let sibling = Link(route: 0)

        // The sibling reaches the Host while this dial is still racing.
        let link = try await leases.connect(
            to: host,
            dial: { leased in
                dials.note(leased)
                if leased == nil {
                    _ = await leases.hold(0, for: host) { sibling.isAlive }
                }
                let link = Link(route: leased ?? 1)
                return (link, link.route)
            },
            isAlive: { $0.isAlive },
            close: { dials.close($0) })

        #expect(link.route == 0)
        #expect(dials.followed == [nil, 0])
        #expect(dials.closedRoutes == [1])
    }

    @Test func theHostRacesAgainOnceEveryConnectionIsGone() async throws {
        let leases = HostRouteLeases()
        let dials = Dials()

        let first = try await connect(leases, racingTo: 0, dials: dials)
        let second = try await connect(leases, racingTo: 1, dials: dials)
        first.end()
        #expect(await leases.route(for: host) == 0)
        second.end()
        #expect(await leases.route(for: host) == nil)

        let third = try await connect(leases, racingTo: 1, dials: dials)
        #expect(third.route == 1)
        #expect(dials.followed == [nil, 0, nil])
    }

    @Test func aConnectionNobodyKeepsHoldsNothing() async throws {
        let leases = HostRouteLeases()
        let dials = Dials()

        _ = try await connect(leases, racingTo: 1, dials: dials)

        #expect(await leases.route(for: host) == nil)
    }

    @Test func aFailedDialOnTheHostsRouteKeepsTheRoute() async throws {
        struct Unreachable: Error {}
        let leases = HostRouteLeases()
        let dials = Dials()
        let first = try await connect(leases, racingTo: 0, dials: dials)

        await #expect(throws: Unreachable.self) {
            _ = try await leases.connect(
                to: host,
                dial: { _ -> (connection: Link, route: Int) in throw Unreachable() },
                isAlive: { $0.isAlive },
                close: { dials.close($0) })
        }

        #expect(await leases.route(for: host) == 0)
        #expect(first.isAlive)
    }

    @Test func aMovedRouteStandsWhileTheServersRedial() async throws {
        let clock = Mutex(ContinuousClock.now)
        let leases = HostRouteLeases(now: { clock.withLock { $0 } })
        let dials = Dials()
        let old = try await connect(leases, racingTo: 1, dials: dials)

        await leases.move(host, to: 0)

        // The connection on the route the Host left no longer holds it there.
        #expect(old.isAlive)
        #expect(await leases.route(for: host) == 0)
        let redialed = try await connect(leases, racingTo: 1, dials: dials)
        #expect(redialed.route == 0)

        clock.withLock { $0 = $0.advanced(by: HostRouteLeases.moveGrace) }
        #expect(await leases.route(for: host) == 0)
        redialed.end()
        #expect(await leases.route(for: host) == nil)
    }

    @Test func aMoveNobodyFollowsLapses() async throws {
        let clock = Mutex(ContinuousClock.now)
        let leases = HostRouteLeases(now: { clock.withLock { $0 } })

        await leases.move(host, to: 0)
        clock.withLock { $0 = $0.advanced(by: HostRouteLeases.moveGrace) }

        #expect(await leases.route(for: host) == nil)
    }

    @Test func releasingTheRouteLetsTheNextDialRace() async throws {
        let leases = HostRouteLeases()
        let dials = Dials()
        let first = try await connect(leases, racingTo: 0, dials: dials)

        await leases.release(host)
        let second = try await connect(leases, racingTo: 1, dials: dials)

        #expect(first.isAlive)
        #expect(second.route == 1)
        #expect(dials.followed == [nil, nil])
    }

    @Test func hostsKeepRoutesOfTheirOwn() async throws {
        let leases = HostRouteLeases()
        let dials = Dials()
        let other = HostMachine.Connection(
            Host(
                username: "ops",
                routes: [HostRoute(address: "10.0.0.5"), HostRoute(address: "100.64.0.5")]))

        let link = try await connect(leases, racingTo: 1, dials: dials)

        #expect(await leases.route(for: other) == nil)
        #expect(await leases.route(for: host) == 1)
        #expect(link.isAlive)
    }

    @Test func catalogSettingsCarryTheirHostsLease() {
        let leases = HostRouteLeases()
        let record = Host(
            username: "dev",
            routes: [HostRoute(address: "10.0.0.5"), HostRoute(address: "100.64.0.5")])

        let settings = SSHTransportSettings(
            host: record,
            credentials: .password("secret"),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false },
            routeLeases: leases)

        #expect(settings.routeLease?.host == host)
        #expect(settings.routeLease?.leases === leases)
    }

    @Test func lastWinningRouteRemembersRouteAcrossDropsAndClearsOnRelease() async throws {
        let leases = HostRouteLeases()
        let dials = Dials()

        #expect(await leases.lastWinningRoute(for: host) == nil)
        let first = try await connect(leases, racingTo: 1, dials: dials)
        #expect(await leases.lastWinningRoute(for: host) == 1)

        // Dropping the last connection clears the active lease so the next dial
        // races again, while remembering route 1 so it skips the deferred stagger.
        first.end()
        #expect(await leases.route(for: host) == nil)
        #expect(await leases.lastWinningRoute(for: host) == 1)

        // Explicit release (e.g. user tapping Reconnect) clears the hint too.
        await leases.release(host)
        #expect(await leases.lastWinningRoute(for: host) == nil)
    }
}
