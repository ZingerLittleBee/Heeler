import Foundation
import Observation

/// One Host's session-discovery outcome for the Console session switcher
/// (#269). Declared at file scope so a task-group child can produce it.
enum HostSessionDiscovery: Equatable, Sendable {
    case loading
    case available([HerdrSession])
    case failed(String)
}

/// Discovery and selection state for the Console session switcher (#269).
/// Discovery borrows each Host's live Console connection, so an unconnected
/// Host fails loudly like every other Host-scoped RPC here.
@MainActor
@Observable
final class HostSessionSwitcherStore {
    private(set) var discoveries: [Host.ID: HostSessionDiscovery] = [:]

    /// Fetches every listed Host's sessions concurrently and publishes the
    /// results per Host, so one unreachable Host cannot blank the whole sheet.
    func load(
        hosts: [Host],
        using listSessions: @escaping @Sendable (Host.ID) async throws -> [HerdrSession]
    ) async {
        for host in hosts {
            discoveries[host.id] = .loading
        }
        await withTaskGroup(of: (Host.ID, HostSessionDiscovery).self) { group in
            for host in hosts {
                group.addTask {
                    do {
                        return (host.id, .available(try await listSessions(host.id)))
                    } catch {
                        return (host.id, .failed(Self.message(for: error)))
                    }
                }
            }
            for await (id, discovery) in group {
                discoveries[id] = discovery
            }
        }
    }

    /// Persists `session` for the Host with `hostID`. The Host is re-read from
    /// the catalog first, so a Host edited since the sheet opened is not
    /// reverted by this write. The stored `sessionName` is the single source
    /// of truth: changing it tears down the Host's session and dials the
    /// selected socket.
    func select(_ session: HerdrSession, for hostID: Host.ID, in catalog: HostStore) throws {
        guard var updated = catalog.hosts.first(where: { $0.id == hostID }) else {
            throw HostStoreError.unknownHost
        }
        updated.sessionName = HerdrSessionSelection.sessionName(for: session)
        try catalog.update(updated)
    }

    /// `nonisolated` so a task-group child can build its own failure value.
    nonisolated private static func message(for error: any Error) -> String {
        (error as? TransportError)?.presentation.message
            ?? "Could not discover this Host's sessions."
    }
}
