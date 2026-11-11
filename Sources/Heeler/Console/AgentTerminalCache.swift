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
        fileprivate let corePin: TerminalCorePin
        fileprivate let lifetime: Lifetime
        fileprivate var expiry: Task<Void, Never>?
        fileprivate var presentationOwnerID: UUID
        /// The window the owner shows in; see `isSameWindow`.
        fileprivate var presentationSceneID: UUID?
        /// The detail that retains this entry. It comes back to the entry for
        /// as long as it lives, hidden or not.
        fileprivate weak var holder: AnyObject?
        var isRetained: Bool { lifetime.retained }

        fileprivate init(
            agentID: ConsoleAgent.ID, terminalID: String,
            attach: AgentAttachStore, corePin: TerminalCorePin, lifetime: Lifetime, ownerID: UUID,
            sceneID: UUID?, holder: AnyObject?
        ) {
            self.agentID = agentID
            self.terminalID = terminalID
            self.attach = attach
            self.corePin = corePin
            self.lifetime = lifetime
            self.presentationOwnerID = ownerID
            self.presentationSceneID = sceneID
            self.holder = holder
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
    /// Second windows' viewers by window; see `addViewer`.
    private var viewers: [UUID: [AgentAttachStore]] = [:]
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
    ///
    /// `sceneID` is passed for a core Terminal only, whose entry the detail's
    /// replacement takes over; see `isSameWindow`. A Herdr TUI Terminal has one
    /// owner at a time, so its replacement closes the entry and attaches anew.
    ///
    /// `corePin` is the detail's, for a core Terminal: an entry that keeps to another
    /// core holds another Terminal at this address, however its id reads.
    func acquire(
        agent: ConsoleAgent, console: ConsoleStore, ownerID: UUID, sceneID: UUID? = nil,
        holder: AnyObject? = nil, corePin: TerminalCorePin? = nil,
        isPresented: @escaping @MainActor () -> Bool = { true }
    ) -> Entry {
        if let current = entries[agent.id], current.terminalID == agent.agent.terminalID,
            corePin.map(current.corePin.keepsToSameCore) ?? true,
            !isOverAndLeft(current),
            !current.lifetime.visible || current.presentationOwnerID == ownerID
                || isSameWindow(current, sceneID: sceneID)
        {
            current.presentationOwnerID = ownerID
            current.presentationSceneID = sceneID
            current.holder = holder
            activate(current, ownerID: ownerID, isPresented: isPresented)
            return current
        }
        if let old = entries[agent.id] { evict(old) }
        let predecessor = teardowns[agent.id]
        let pin = corePin ?? TerminalCorePin()
        let runner = console.terminalRunner(for: agent.hostID, keepingTo: pin)
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
            closePane: { [weak console] in
                guard let console else { throw CancellationError() }
                try await console.closePane(agent.agent.paneID, on: agent.hostID, keepingTo: pin)
            })
        attach.input.isEnabled = console.isHostReadyForInput(agent.hostID)
        let entry = Entry(
            agentID: agent.id, terminalID: agent.agent.terminalID,
            attach: attach, corePin: pin, lifetime: lifetime, ownerID: ownerID, sceneID: sceneID, holder: holder)
        entries[agent.id] = entry
        return entry
    }

    /// Only a core Terminal ends this way. Nobody is looking at it, so opening its
    /// address again means whatever runs there now, on another core if need be.
    private func isOverAndLeft(_ entry: Entry) -> Bool {
        !entry.lifetime.visible && entry.attach.terminalStatus == .finished
    }

    /// Another detail shows this Agent's retained terminal, or has it hidden
    /// and will come back to it: its surface can only be in one window.
    func isHeldByAnotherDetail(_ agent: ConsoleAgent, ownerID: UUID, sceneID: UUID? = nil) -> Bool {
        guard let current = entries[agent.id], current.terminalID == agent.agent.terminalID,
            current.presentationOwnerID != ownerID, !isSameWindow(current, sceneID: sceneID)
        else { return false }
        return current.lifetime.visible || current.holder != nil
    }

    /// A window mounts one detail, so another detail in the owner's window is
    /// the one SwiftUI replaced it with, as a size-class change does. The
    /// replaced detail still reads as selected when it disappears, so it never
    /// releases; its late release, keyed to its own `ownerID`, finds nothing
    /// to undo.
    private func isSameWindow(_ entry: Entry, sceneID: UUID?) -> Bool {
        sceneID != nil && entry.presentationSceneID == sceneID
    }

    /// A closed window's detail still reads as selected when it disappears,
    /// so it never releases, and with core Terminals no other window's
    /// acquire closes the entry instead. Nothing there comes back to what it
    /// retains, so another window may take it; an entry it had already left
    /// keeps the timer it started.
    func sceneDidEnd(_ sceneID: UUID) {
        for viewer in viewers.removeValue(forKey: sceneID) ?? [] {
            viewer.leaveForTerminalHandoff()
        }
        for entry in entries.values where entry.presentationSceneID == sceneID {
            entry.holder = nil
            if entry.lifetime.visible {
                release(entry, ownerID: entry.presentationOwnerID)
            }
        }
    }

    /// A second window's viewer holds no entry and closes with its detail's
    /// `onDisappear`, which SwiftUI does not promise for a closed window. Held
    /// strongly: a store that goes away unstopped leaves its channel open.
    func addViewer(_ attach: AgentAttachStore, sceneID: UUID) {
        viewers[sceneID, default: []].removeAll(where: \.hasLeft)
        viewers[sceneID, default: []].append(attach)
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
        entry.attach.setTerminalViewed(true)
    }

    /// `keepingKeyboard` is a departure whose keyboard the next screen takes
    /// over; the surface then keeps first responder until that claim.
    func release(_ entry: Entry, ownerID: UUID, keepingKeyboard: Bool = false) {
        guard entries[entry.agentID] === entry, entry.presentationOwnerID == ownerID else { return }
        entry.lifetime.visible = false
        entry.lifetime.isPresented = nil
        entry.attach.leaveInteractionsForRetention()
        entry.attach.setTerminalViewed(false)
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

    func reconcile(
        hostID: Host.ID, agents: [ConsoleAgent], inventoryCore: String? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async {
        for entry in entries.values.filter({ $0.agentID.hostID == hostID }) {
            guard isCurrent() else { return }
            let leftCore = !entry.lifetime.visible && inventoryCore.map { !entry.corePin.admits($0) } == true
            if leftCore || !agents.contains(where: {
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
