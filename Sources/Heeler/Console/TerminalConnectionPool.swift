import Foundation
import Observation

/// Retains lazily opened shell PTYs across destination changes, sharing
/// the Host-wide three-terminal budget with retained Agent Attach.
@MainActor
@Observable
final class TerminalConnectionPool {
    enum Failure: Error, LocalizedError {
        case alreadyVisible
        case allConnectionsVisible

        var errorDescription: String? {
            switch self {
            case .alreadyVisible:
                "This terminal is already open in another window."
            case .allConnectionsVisible:
                "Close another terminal view on this Host before opening this terminal."
            }
        }
    }

    struct Key: Hashable {
        let hostID: Host.ID
        let identity: ShellTerminalIdentity
    }

    @MainActor
    final class Entry {
        let store: ShellTerminalStore
        let surfaceRetention = TerminalSurfaceRetention()
        fileprivate let retentionID = UUID()
        fileprivate let lifetime: Lifetime
        fileprivate var ownerID: UUID?
        fileprivate var isPresented: (@MainActor () -> Bool)?
        fileprivate var selectionID: UUID
        fileprivate var idleSince: Date?
        fileprivate var idleID: UUID?
        fileprivate var expiry: Task<Void, Never>?

        fileprivate var isVisible: Bool { ownerID != nil && (isPresented?() ?? false) }

        fileprivate init(
            store: ShellTerminalStore, lifetime: Lifetime, ownerID: UUID, selectionID: UUID,
            isPresented: @escaping @MainActor () -> Bool
        ) {
            self.store = store
            self.lifetime = lifetime
            self.ownerID = ownerID
            self.selectionID = selectionID
            self.isPresented = isPresented
        }
    }

    @MainActor
    fileprivate final class Lifetime {
        var retained = true
    }

    private(set) var entries: [Key: Entry] = [:]
    let idleTimeout: Duration
    let maximumShellsPerHost: Int
    @ObservationIgnored private let budget: TerminalRetentionBudget
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var mutationTail: Task<Void, Never>?

    init(
        idleTimeout: Duration = .seconds(300),
        maximumShellsPerHost: Int = 3,
        budget: TerminalRetentionBudget = TerminalRetentionBudget(),
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.idleTimeout = idleTimeout
        self.maximumShellsPerHost = max(1, min(maximumShellsPerHost, 3))
        self.budget = budget
        self.now = now
    }

    /// Returns the existing renderer and PTY for a target, or creates an
    /// unstarted pipeline. Its first layout supplies the size and opens SSH.
    /// Mutations serialize through teardown, so eviction never temporarily
    /// exceeds the budget and a second tap cannot create another owner.
    func select(
        hostID: Host.ID,
        identity: ShellTerminalIdentity,
        ownerID: UUID,
        generation: UInt64?,
        isPresented: @escaping @MainActor () -> Bool = { true },
        runTerminal: @escaping TerminalSessionRunner
    ) async throws -> Entry {
        let selectionID = UUID()
        let previous = mutationTail
        let task = Task { @MainActor [self] in
            await previous?.value
            try Task.checkCancellation()
            let key = Key(hostID: hostID, identity: identity)
            if let entry = entries[key] {
                guard entry.ownerID == nil || entry.ownerID == ownerID else {
                    throw Failure.alreadyVisible
                }
                entry.expiry?.cancel()
                entry.expiry = nil
                entry.ownerID = ownerID
                entry.selectionID = selectionID
                entry.isPresented = isPresented
                entry.idleSince = nil
                entry.idleID = nil
                budget.touch(key: budgetKey(key), ownerID: entry.retentionID)
                entry.store.transportGenerationDidChange(generation)
                return entry
            }
            while entries.keys.filter({ $0.hostID == hostID }).count >= maximumShellsPerHost {
                let candidate = entries.filter { $0.key.hostID == hostID && !$0.value.isVisible }
                    .min { ($0.value.idleSince ?? .distantFuture) < ($1.value.idleSince ?? .distantFuture) }
                guard let candidate else { throw Failure.allConnectionsVisible }
                await removeEntry(candidate.key)
                try Task.checkCancellation()
            }
            let lifetime = Lifetime()
            let store = ShellTerminalStore(
                identity: identity,
                transportGeneration: generation,
                takeover: false,
                isOnStage: { lifetime.retained },
                runTerminal: runTerminal)
            let entry = Entry(
                store: store, lifetime: lifetime, ownerID: ownerID, selectionID: selectionID,
                isPresented: isPresented)
            entries[key] = entry
            do {
                try await budget.admit(
                    key: budgetKey(key), ownerID: entry.retentionID,
                    isVisible: { [weak entry] in entry?.isVisible ?? false },
                    onEvict: { [weak self, weak entry] in
                        guard let self, let entry, self.entries[key] === entry else { return }
                        await self.removeEntry(key)
                    })
                try Task.checkCancellation()
                return entry
            } catch {
                await removeEntry(key)
                throw error
            }
        }
        mutationTail = Task { _ = await task.result }
        return try await withTaskCancellationHandler {
            let entry = try await task.value
            if Task.isCancelled {
                if entry.selectionID == selectionID {
                    release(hostID: hostID, identity: identity, ownerID: ownerID)
                }
                throw CancellationError()
            }
            return entry
        } onCancel: {
            task.cancel()
        }
    }

    /// Deselecting stops accepting user input but preserves the renderer and
    /// live output until expiry, eviction, Host replacement, or suspension.
    ///
    /// `keepingKeyboard` is a departure whose keyboard the next screen takes
    /// over; the surface then keeps first responder until that claim.
    func release(
        hostID: Host.ID, identity: ShellTerminalIdentity, ownerID: UUID, keepingKeyboard: Bool = false
    ) {
        let key = Key(hostID: hostID, identity: identity)
        guard let entry = entries[key], entry.ownerID == ownerID else { return }
        entry.ownerID = nil
        entry.isPresented = nil
        entry.idleSince = now()
        let idleID = UUID()
        entry.idleID = idleID
        budget.markIdle(key: budgetKey(key), ownerID: entry.retentionID)
        entry.store.cancelPaste()
        entry.surfaceRetention.detachCallbacks(keepingKeyboard: keepingKeyboard)
        entry.expiry?.cancel()
        let timeout = idleTimeout
        entry.expiry = Task { @MainActor [weak self, weak entry] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, let entry else { return }
            await self.mutate {
                guard entry.ownerID == nil, entry.idleID == idleID,
                    self.entries[key] === entry else { return }
                await self.removeEntry(key)
            }
        }
    }

    func remove(hostID: Host.ID, identity: ShellTerminalIdentity) async {
        await mutate { await self.removeEntry(Key(hostID: hostID, identity: identity)) }
    }

    func removeHost(_ hostID: Host.ID) async {
        await mutate {
            for key in self.entries.keys.filter({ $0.hostID == hostID }) {
                await self.removeEntry(key)
            }
        }
    }

    func suspend() async {
        await mutate {
            for key in Array(self.entries.keys) { await self.removeEntry(key) }
        }
    }

    /// Discard idle pipelines from an obsolete transport; a visible pipeline
    /// keeps its identity and uses the existing foreground recovery logic.
    func transportGenerationDidChange(
        _ generation: UInt64?, for hostID: Host.ID,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async {
        await mutate {
            guard isCurrent() else { return }
            for key in self.entries.keys.filter({ $0.hostID == hostID }) {
                guard isCurrent() else { return }
                guard let entry = self.entries[key] else { continue }
                if entry.ownerID == nil {
                    await self.removeEntry(key)
                } else {
                    entry.store.transportGenerationDidChange(generation)
                }
            }
        }
    }

    /// Reconcile only with an authoritative snapshot from the current Host.
    func reconcile(
        hostID: Host.ID,
        identities: Set<ShellTerminalIdentity>,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async {
        await mutate {
            guard isCurrent() else { return }
            for key in self.entries.keys.filter({ $0.hostID == hostID && !identities.contains($0.identity) }) {
                guard isCurrent() else { return }
                await self.removeEntry(key)
            }
        }
    }

    func expireIdle() async {
        await mutate {
            let cutoff = self.now().addingTimeInterval(-self.idleTimeout.timeInterval)
            for key in Array(self.entries.keys) {
                guard let entry = self.entries[key], entry.ownerID == nil,
                    let idleSince = entry.idleSince, idleSince <= cutoff else { continue }
                await self.removeEntry(key)
            }
        }
    }

    private func removeEntry(_ key: Key) async {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.expiry?.cancel()
        entry.lifetime.retained = false
        entry.isPresented = nil
        await entry.store.leave().value
        entry.surfaceRetention.clear()
        budget.remove(key: budgetKey(key), ownerID: entry.retentionID)
    }

    private func budgetKey(_ key: Key) -> TerminalRetentionBudget.Key {
        .init(hostID: key.hostID, terminalID: key.identity.terminalID)
    }

    private func mutate(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = mutationTail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        mutationTail = task
        await task.value
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let value = components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}
