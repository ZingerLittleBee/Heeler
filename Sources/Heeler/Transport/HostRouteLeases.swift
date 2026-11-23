import Foundation

/// The Host a connection is one of several to, and where its route is kept
/// (ADR 0058).
struct HostRouteLease: Sendable {
    let host: HostMachine.Connection
    var leases: HostRouteLeases = .shared
}

/// The one route each Host's connections take (ADR 0058).
///
/// A Host's Servers each keep an SSH connection of their own. The first
/// connection to reach the Host settles its route, and while any connection
/// still holds that route every later dial takes it alone: another Server, a
/// reconnect, Preflight, a plugin install. Only a Host with no connection
/// left races its routes again.
///
/// A route is an index into the Host's routes: its records each give the
/// same route an id of their own.
actor HostRouteLeases {
    static let shared = HostRouteLeases()

    /// How long a route the Host was moved to stands with no connection on
    /// it, while the Host's Servers redial.
    static let moveGrace: Duration = .seconds(15)

    /// How often one dial gives way to a route the Host settled on meanwhile.
    /// Once is all a cold start needs; the bound keeps a route that keeps
    /// moving from holding a dial for good.
    private static let dialPasses = 3

    typealias Liveness = @Sendable () async -> Bool

    private struct Lease {
        var route: Int
        var holders: [UUID: Liveness] = [:]
        var standsUntil: ContinuousClock.Instant?
    }

    private var leases: [HostMachine.Connection: Lease] = [:]
    /// Last route that reached each Host, remembered across drops so a
    /// reconnect does not pay the full deferred stagger before trying it again.
    private var lastWinningRoutes: [HostMachine.Connection: Int] = [:]
    private let now: @Sendable () -> ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// The route the Host's connections hold, or nil when none does and the
    /// next dial races.
    func route(for host: HostMachine.Connection) async -> Int? {
        await prune(host)
        return leases[host]?.route
    }

    /// The route that most recently connected to `host`, or nil when none is
    /// remembered (or `release` cleared it for a fresh race).
    func lastWinningRoute(for host: HostMachine.Connection) -> Int? {
        lastWinningRoutes[host]
    }

    /// Records a connection that reached `route`, held for as long as
    /// `isAlive` says. Returns the Host's route: `route` when the connection
    /// now holds it, another when the Host settled there first and this
    /// connection has to give way.
    func hold(
        _ route: Int, for host: HostMachine.Connection, while isAlive: @escaping Liveness
    ) async -> Int {
        await prune(host)
        if let lease = leases[host], lease.route != route {
            lastWinningRoutes[host] = lease.route
            return lease.route
        }
        leases[host, default: Lease(route: route)].holders[UUID()] = isAlive
        lastWinningRoutes[host] = route
        return route
    }

    /// Settles the Host on `route` whatever its connections hold. They are
    /// on the route it leaves, so they hold nothing until they redial.
    func move(_ host: HostMachine.Connection, to route: Int) {
        leases[host] = Lease(route: route, standsUntil: now().advanced(by: Self.moveGrace))
        lastWinningRoutes[host] = route
    }

    /// Forgets the Host's route, so that its next dial races.
    func release(_ host: HostMachine.Connection) {
        leases[host] = nil
        lastWinningRoutes[host] = nil
    }

    /// Dials the Host on its route. `dial` takes the route to follow, or nil
    /// to race, and says which route it reached. A connection that raced to
    /// another route than the Host settled on meanwhile is closed, and the
    /// dial follows the Host's.
    nonisolated func connect<Connection: AnyObject & Sendable>(
        to host: HostMachine.Connection,
        dial: @Sendable (_ leased: Int?) async throws -> (connection: Connection, route: Int),
        isAlive: @escaping @Sendable (Connection) async -> Bool,
        close: @Sendable (Connection) async -> Void
    ) async throws -> Connection {
        var leased = await route(for: host)
        for _ in 0..<Self.dialPasses {
            let dialed = try await dial(leased)
            let settled = await hold(dialed.route, for: host) { [weak connection = dialed.connection] in
                guard let connection else { return false }
                return await isAlive(connection)
            }
            if settled == dialed.route { return dialed.connection }
            await close(dialed.connection)
            guard !Task.isCancelled else { throw TransportError.cancelled }
            leased = settled
        }
        throw TransportError.timedOut
    }

    /// Drops the connections that are gone, and the lease with the last one.
    /// The liveness checks suspend, so holders are dropped by id: a lease
    /// moved or released meanwhile keeps what it was given since.
    private func prune(_ host: HostMachine.Connection) async {
        guard let holders = leases[host]?.holders else { return }
        var gone: [UUID] = []
        for (id, isAlive) in holders where !(await isAlive()) {
            gone.append(id)
        }
        guard var lease = leases[host] else { return }
        for id in gone {
            lease.holders[id] = nil
        }
        let stands = lease.standsUntil.map { now() < $0 } ?? false
        leases[host] = lease.holders.isEmpty && !stands ? nil : lease
    }
}
