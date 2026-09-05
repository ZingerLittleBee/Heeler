import Foundation
import Observation

/// Read-only snapshots borrowed from the Console's existing connections.
/// A request identity also protects against removal/re-addition of a Host
/// whose replacement projection starts its generation counter over.
@MainActor
@Observable
final class HerdrSidebarSnapshotStore {
    enum HostState: Equatable, Sendable {
        case loading
        case loaded(AgentRowLayoutSnapshot?)
        case unavailable
    }

    struct Connection: Equatable, Sendable {
        let generation: UInt64
        let revision: UInt64
    }

    private(set) var states: [Host.ID: HostState] = [:]
    @ObservationIgnored private var connections: [Host.ID: Connection] = [:]
    @ObservationIgnored private var requests: [Host.ID: UUID] = [:]
    @ObservationIgnored private var tasks: [Host.ID: Task<Void, Never>] = [:]

    func snapshot(for hostID: Host.ID) -> AgentRowLayoutSnapshot? {
        guard case .loaded(let snapshot) = states[hostID] else { return nil }
        return snapshot
    }

    /// Call synchronously at every Console projection/lifecycle transition.
    /// Only connected, snapshot-ready Hosts are eligible to borrow transport.
    func reconcile(
        _ next: [Host.ID: Connection],
        transports: any NotificationTransportProvider,
        didChange: @escaping @MainActor @Sendable () -> Void
    ) {
        for id in Array(connections.keys) where next[id] == nil {
            invalidate(id)
        }
        for (id, connection) in next where connections[id] != connection {
            let generationChanged = connections[id]?.generation != connection.generation
            connections[id] = connection
            startRead(id, transports: transports, clear: generationChanged, didChange: didChange)
        }
    }

    func invalidate(_ hostID: Host.ID) {
        tasks.removeValue(forKey: hostID)?.cancel()
        requests[hostID] = nil
        connections[hostID] = nil
        states[hostID] = nil
    }

    func invalidateAll() {
        for id in Array(connections.keys) { invalidate(id) }
    }

    /// Explicit refresh also retries missing/error snapshots without a
    /// plugin-version gate. The editor uses it after a Host config edit.
    func refresh(
        transports: any NotificationTransportProvider,
        didChange: @escaping @MainActor @Sendable () -> Void
    ) async {
        for id in Array(connections.keys) {
            startRead(id, transports: transports, clear: false, didChange: didChange)
        }
        await waitForPendingReads()
    }

    /// Sync from plugin: re-reads one Host on its current connection and
    /// returns the resulting state, or nil when the Host has no connection
    /// to borrow. A read superseded by reconciliation reports that newer state.
    func refresh(
        _ hostID: Host.ID,
        transports: any NotificationTransportProvider,
        didChange: @escaping @MainActor @Sendable () -> Void
    ) async -> HostState? {
        guard connections[hostID] != nil else { return nil }
        startRead(hostID, transports: transports, clear: false, didChange: didChange)
        while let task = tasks[hostID] { await task.value }
        return states[hostID]
    }

    func waitForPendingReads() async {
        while !tasks.isEmpty {
            let pending = Array(tasks.values)
            for task in pending { await task.value }
        }
    }

    private func startRead(
        _ id: Host.ID,
        transports: any NotificationTransportProvider,
        clear: Bool,
        didChange: @escaping @MainActor @Sendable () -> Void
    ) {
        tasks[id]?.cancel()
        let request = UUID()
        requests[id] = request
        if clear || states[id] == nil { states[id] = .loading }
        tasks[id] = Task { [weak self] in
            let result: HostState
            do {
                let data = try await transports.withNotificationTransport(for: id) {
                    try await $0.readSidebarLayout()
                }
                result = .loaded(AgentRowLayoutSnapshot.decode(data))
            } catch {
                result = .unavailable
            }
            guard let self, !Task.isCancelled, requests[id] == request,
                connections[id] != nil
            else { return }
            states[id] = result
            tasks[id] = nil
            didChange()
        }
    }
}
