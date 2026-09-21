import Foundation

/// Agent attaches share the Host's bounded LRU retention budget with shells.
/// Entries are lazy: listing or constructing a detail never opens a PTY.
@MainActor
final class AgentTerminalCache {
    @MainActor
    final class Entry {
        let agentID: ConsoleAgent.ID
        let terminalID: String
        let attach: AgentAttachStore
        let surfaceRetention = TerminalSurfaceRetention()
        fileprivate let lifetime: Lifetime
        fileprivate var expiry: Task<Void, Never>?
        fileprivate var presentationOwnerID: UUID
        var isRetained: Bool { lifetime.retained }

        fileprivate init(
            agentID: ConsoleAgent.ID, terminalID: String,
            attach: AgentAttachStore, lifetime: Lifetime, ownerID: UUID
        ) {
            self.agentID = agentID
            self.terminalID = terminalID
            self.attach = attach
            self.lifetime = lifetime
            self.presentationOwnerID = ownerID
        }
    }

    @MainActor
    fileprivate final class Lifetime {
        let ownerID = UUID()
        var retained = true
        var visible = true
        var isPresented: (@MainActor () -> Bool)?
    }

    private(set) var entries: [ConsoleAgent.ID: Entry] = [:]
    private var teardowns: [ConsoleAgent.ID: Task<Void, Never>] = [:]
    private let budget: TerminalRetentionBudget
    let idleTimeout: Duration

    init(
        budget: TerminalRetentionBudget = TerminalRetentionBudget(),
        idleTimeout: Duration = .seconds(300)
    ) {
        self.budget = budget
        self.idleTimeout = idleTimeout
    }

    /// Only the window holding the Host's Agent presentation may acquire.
    /// Offstage details keep private stores until they are activated.
    func acquire(
        agent: ConsoleAgent, console: ConsoleStore, composer: AgentComposerStore,
        ownerID: UUID,
        isPresented: @escaping @MainActor () -> Bool = { true }
    ) -> Entry {
        if let current = entries[agent.id], current.terminalID == agent.agent.terminalID,
            !current.lifetime.visible || current.presentationOwnerID == ownerID
        {
            current.presentationOwnerID = ownerID
            activate(current, ownerID: ownerID, isPresented: isPresented)
            return current
        }
        if let old = entries[agent.id] { evict(old) }
        let predecessor = teardowns[agent.id]
        let runner = console.terminalRunner(for: agent.hostID)
        let lifetime = Lifetime()
        lifetime.isPresented = isPresented
        let attach = AgentAttachStore(
            target: agent.agent.paneID,
            paneTitle: AgentTerminalView.displayTitle(for: agent),
            transportGeneration: console.hostConnectionGenerations[agent.hostID],
            isOnStage: { lifetime.retained },
            runTerminal: { [weak self] request, handler in
                await predecessor?.value
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                try await self.admit(agentID: agent.id, lifetime: lifetime)
                try Task.checkCancellation()
                try await runner(request, handler)
            },
            stageImage: console.imageStager(for: agent.hostID),
            stageFile: console.fileStager(for: agent.hostID),
            composer: composer,
            closePane: { [weak console] in
                guard let console else { throw CancellationError() }
                try await console.closePane(agent.agent.paneID, on: agent.hostID)
            },
            invalidateMosh: { [weak console] in
                guard let console else { return }
                await console.invalidateMosh(for: agent.hostID)
            })
        let entry = Entry(
            agentID: agent.id, terminalID: agent.agent.terminalID,
            attach: attach, lifetime: lifetime, ownerID: ownerID)
        entries[agent.id] = entry
        return entry
    }

    private func admit(agentID: ConsoleAgent.ID, lifetime: Lifetime) async throws {
        guard let entry = entries[agentID], entry.lifetime === lifetime, lifetime.retained else {
            throw CancellationError()
        }
        try await budget.admit(
            key: key(for: entry), ownerID: lifetime.ownerID,
            isVisible: { lifetime.retained && lifetime.visible && (lifetime.isPresented?() ?? false) },
            onEvict: { [weak self, weak entry] in
                guard let self, let entry else { return }
                await self.evict(entry).value
            })
        guard lifetime.retained else { throw CancellationError() }
    }

    func activate(
        _ entry: Entry, ownerID: UUID,
        isPresented: @escaping @MainActor () -> Bool = { true }
    ) {
        guard entries[entry.agentID] === entry, entry.presentationOwnerID == ownerID else { return }
        entry.expiry?.cancel()
        entry.expiry = nil
        entry.lifetime.visible = true
        entry.lifetime.isPresented = isPresented
        budget.touch(key: key(for: entry), ownerID: entry.lifetime.ownerID)
        entry.attach.rejoin()
    }

    /// `keepingKeyboard` is a departure whose keyboard the next screen takes
    /// over; the surface then keeps first responder until that claim.
    func release(_ entry: Entry, ownerID: UUID, keepingKeyboard: Bool = false) {
        guard entries[entry.agentID] === entry, entry.presentationOwnerID == ownerID else { return }
        entry.lifetime.visible = false
        entry.lifetime.isPresented = nil
        entry.attach.leaveInteractionsForRetention()
        entry.surfaceRetention.detachCallbacks(keepingKeyboard: keepingKeyboard)
        budget.markIdle(key: key(for: entry), ownerID: entry.lifetime.ownerID)
        entry.expiry?.cancel()
        entry.expiry = Task { @MainActor [weak self, weak entry] in
            guard let self, let entry else { return }
            do { try await Task.sleep(for: idleTimeout) } catch { return }
            guard !entry.lifetime.visible, entries[entry.agentID] === entry else { return }
            await evict(entry).value
        }
    }

    func removeHost(_ hostID: Host.ID) async {
        let identities = Set(entries.keys).union(teardowns.keys).filter { $0.hostID == hostID }
        for id in identities {
            if let entry = entries[id] { await evict(entry).value }
            await teardowns[id]?.value
            teardowns[id] = nil
        }
    }

    func suspend() async {
        let hosts = Set(entries.keys.map(\.hostID)).union(teardowns.keys.map(\.hostID))
        for hostID in hosts { await removeHost(hostID) }
    }

    func transportGenerationDidChange(
        _ generation: UInt64?, for hostID: Host.ID,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async {
        for entry in entries.values.filter({ $0.agentID.hostID == hostID }) {
            guard isCurrent() else { return }
            if entry.lifetime.visible {
                entry.attach.transportGenerationDidChange(generation)
            } else {
                await evict(entry).value
            }
        }
    }

    /// The host-level mosh capsule's tap: every visible Agent terminal on
    /// the Host still riding a live SSH session gets restarted so the
    /// runner re-selects mosh now that the Host's probe proved it.
    func upgradeSSHAttachToMosh(for hostID: Host.ID) {
        for entry in entries.values.filter({ $0.agentID.hostID == hostID })
        where entry.lifetime.visible {
            entry.attach.upgradeToMoshIfNeeded()
        }
    }

    func reconcile(
        hostID: Host.ID, agents: [ConsoleAgent],
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async {
        for entry in entries.values.filter({ $0.agentID.hostID == hostID }) {
            guard isCurrent() else { return }
            if !agents.contains(where: {
                $0.id == entry.agentID && $0.agent.terminalID == entry.terminalID
            }) {
                await evict(entry).value
            }
        }
    }

    private func key(for entry: Entry) -> TerminalRetentionBudget.Key {
        TerminalRetentionBudget.Key(hostID: entry.agentID.hostID, terminalID: entry.terminalID)
    }

    @discardableResult
    private func evict(_ entry: Entry) -> Task<Void, Never> {
        let id = entry.agentID
        guard entry.lifetime.retained else { return teardowns[id] ?? Task {} }
        entry.expiry?.cancel()
        entry.expiry = nil
        entry.lifetime.retained = false
        entry.lifetime.isPresented = nil
        if entries[id] === entry { entries[id] = nil }
        let prior = teardowns[id]
        let leaving = entry.attach.leaveForTerminalHandoff()
        let key = key(for: entry)
        let budget = budget
        let task = Task { @MainActor in
            await prior?.value
            await leaving.value
            entry.surfaceRetention.clear()
            budget.remove(key: key, ownerID: entry.lifetime.ownerID)
        }
        teardowns[id] = task
        return task
    }
}
