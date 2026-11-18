import Foundation
import OSLog

/// Which routes are worth a look for a Host that settled on a slower one
/// (ADR 0058).
enum HostRouteUpgrade {
    /// The Host's direct routes, as indices, when its connections hold a
    /// route through an Overlay Network or a Jump Host. None otherwise: a
    /// Host on a direct route has nothing faster to move to, and one that
    /// holds no route races them all on its next dial anyway.
    static func candidates(among routes: [HostRoute], holding held: Int?) -> [Int] {
        guard let held, routes.indices.contains(held), !routes[held].isDirect else { return [] }
        return routes.indices.filter { routes[$0].isDirect }
    }
}

/// Moves a Host onto a direct route once one comes into reach (ADR 0058).
///
/// A race settles a Host on a route through an Overlay Network or a Jump
/// Host only when no direct route answered, and its connections then keep
/// that route for as long as they live. So each time the device's network
/// changes or the app comes back, this looks at the direct routes of every
/// such Host; when one presents the Host's key, the Host moves to it and its
/// Servers dial again. It never looks on a timer: away from home, a LAN
/// address belongs to somebody else's machine.
@MainActor
final class HostRouteUpgrader {
    private static let log = Logger(subsystem: "dev.bybee.heeler", category: "Routes")

    private let leases: HostRouteLeases
    private let machines: @MainActor () -> [HostMachine]
    private let isConnected: @MainActor (Host.ID) -> Bool
    private let probe: @Sendable (Host, [Int]) async -> Int?
    private let redial: @MainActor (Host.ID) async -> Void
    private var tail: Task<Void, Never>?

    /// `probe` answers which of a Host's routes, by index, reaches it now.
    /// `redial` restarts one Server's connection.
    init(
        leases: HostRouteLeases = .shared,
        machines: @escaping @MainActor () -> [HostMachine],
        isConnected: @escaping @MainActor (Host.ID) -> Bool,
        probe: @escaping @Sendable (Host, [Int]) async -> Int?,
        redial: @escaping @MainActor (Host.ID) async -> Void
    ) {
        self.leases = leases
        self.machines = machines
        self.isConnected = isConnected
        self.probe = probe
        self.redial = redial
    }

    /// Looks once at every connected Host on a slower route. A look asked
    /// for while one runs waits its turn, so two never move the same Host.
    func check() async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await self.look()
        }
        tail = task
        await task.value
    }

    private func look() async {
        let connected = machines().filter { machine in
            machine.servers.contains { isConnected($0.id) }
        }
        await withTaskGroup(of: Void.self) { group in
            for machine in connected {
                group.addTask { await self.upgrade(machine) }
            }
        }
    }

    private func upgrade(_ machine: HostMachine) async {
        let record = machine.representative
        let held = await leases.route(for: machine.id)
        let candidates = HostRouteUpgrade.candidates(among: record.routes, holding: held)
        guard !candidates.isEmpty, let faster = await probe(record, candidates) else { return }
        // The Host may have left that route while the probe was out.
        guard await leases.route(for: machine.id) == held else { return }
        Self.log.notice("Moving a Host to a direct route that came into reach")
        await leases.move(machine.id, to: faster)
        // A Server that is dialing already follows the Host's route there.
        for server in machine.servers where isConnected(server.id) {
            await redial(server.id)
        }
    }
}
