import Foundation
import Observation

/// Each Host's Heeler plugin, read on demand over the Console's existing
/// connection so Settings can say which features the Host's plugin lacks.
/// Reads happen only when a screen asks: connecting a Host sends nothing.
/// A Host without a connection reads as `.unavailable`.
@MainActor
@Observable
final class HeelerPluginStatusStore {
    private(set) var statuses: [Host.ID: HeelerPluginStatus] = [:]
    @ObservationIgnored private var requests: [Host.ID: UUID] = [:]

    func status(for hostID: Host.ID) -> HeelerPluginStatus? {
        statuses[hostID]
    }

    /// Re-reads the given Hosts concurrently. A Host keeps its last status
    /// until its new read lands, so a refresh does not flash the notes away.
    func refresh(_ hostIDs: [Host.ID], transports: any NotificationTransportProvider) async {
        await withTaskGroup { group in
            for id in hostIDs {
                let request = UUID()
                requests[id] = request
                if statuses[id] == nil { statuses[id] = .checking }
                group.addTask {
                    // Errors escape the borrow so the session can redial a
                    // dead link and retry once, as for any other RPC.
                    let result: Result<HeelerPluginInstallation?, any Error>
                    do {
                        result = .success(
                            try await transports.withNotificationTransport(for: id) {
                                try await $0.readHeelerPlugin()
                            })
                    } catch {
                        result = .failure(error)
                    }
                    await self.record(
                        HeelerPluginStatus(result), for: id, request: request,
                        cancelled: Task.isCancelled)
                }
            }
        }
    }

    /// Forgets a Host whose connection coordinates changed or that was
    /// removed. Suspension keeps statuses: a plugin rarely changes while the
    /// app is away, and the next refresh replaces them anyway.
    func invalidate(_ hostID: Host.ID) {
        requests[hostID] = nil
        statuses[hostID] = nil
    }

    /// Drops a read that a newer refresh or an invalidation superseded. A
    /// read cancelled with its screen says nothing about the plugin, so it
    /// leaves the last status in place.
    private func record(
        _ status: HeelerPluginStatus, for hostID: Host.ID, request: UUID, cancelled: Bool
    ) {
        guard requests[hostID] == request else { return }
        requests[hostID] = nil
        if cancelled {
            if statuses[hostID] == .checking { statuses[hostID] = nil }
            return
        }
        statuses[hostID] = status
    }
}
