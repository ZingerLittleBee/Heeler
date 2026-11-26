import Foundation
import Observation

/// The Agents list's Changes totals, read by the list itself: one store per
/// Agent, made when its row first shows and kept while the Agent is in the
/// catalog. Agent detail's status line shows the same totals and counts as
/// one more row. A store reads once its row has settled on screen, then after
/// each exit from Working. Those reads wait while no row shows the Agent,
/// so an exit seen with the list off screen reads when a row comes back,
/// and while open Changes of the same Checkout read in its place: closing
/// them hands their newer read over. Rows in every window share one store,
/// so a second window costs the Host no second read.
@MainActor
@Observable
final class AgentRowChanges {
    struct ResolvedBranch: Equatable, Sendable {
        let topLevelPath: String
        let branch: CheckoutHead.Branch
    }

    @MainActor
    private final class Entry {
        let store: ChangesStore
        /// Open Changes from this Agent's detail. Weak, so Changes whose
        /// detail went away without closing them stop standing in.
        var shown: [WeakChangesStore] = []

        init(store: ChangesStore) { self.store = store }

        /// Open Changes read the Checkout this store would read now.
        var isStoodInFor: Bool {
            shown.contains { box in
                guard let other = box.store else { return false }
                return store.readsSameCheckout(as: other)
            }
        }
    }

    private struct WeakChangesStore {
        weak var store: ChangesStore?
    }

    /// Cached branch per Agent from the latest loaded CheckoutChanges, updated
    /// only when `(topLevelPath, branch)` actually changes so By Workspace
    /// checkout headers never subscribe `ConsoleView.content` to unrelated
    /// `ChangesStore.phase` transitions.
    private var branchesByAgent: [ConsoleAgent.ID: ResolvedBranch] = [:]

    @ObservationIgnored private var entries: [ConsoleAgent.ID: Entry] = [:]
    /// Each store's reads, kept apart from the entries so the registry's
    /// deinit can end them.
    @ObservationIgnored private var followings: [ConsoleAgent.ID: Task<Void, Never>] = [:]
    /// Rows on screen per Agent, across windows, kept apart from the stores
    /// so a row shown before its Agent reports a directory still counts.
    @ObservationIgnored private var visibleRows: [ConsoleAgent.ID: Int] = [:]
    @ObservationIgnored private var isScrollActive = false
    @ObservationIgnored private var deferredForegroundHosts: [Host.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var bypassedForegroundYieldUntil: [Host.ID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private let reads: @MainActor (ConsoleAgent) -> Bool
    @ObservationIgnored private let defersForForegroundLoad: @MainActor (Host.ID) -> Bool
    @ObservationIgnored private let yieldToForegroundLoad: @MainActor (Host.ID) async -> Void
    @ObservationIgnored private let makeStore: @MainActor (ConsoleAgent) -> ChangesStore

    /// `makeStore` reads the Checkout the Agent is in at the time of each
    /// read, following its status. `reads` says whether an Agent's row reads
    /// at all: a Rex Agent's, whose Host runs nothing for them, does not
    /// (ADR 0056).
    init(
        reads: @escaping @MainActor (ConsoleAgent) -> Bool = { _ in true },
        defersForForegroundLoad: @escaping @MainActor (Host.ID) -> Bool = { _ in false },
        yieldToForegroundLoad: @escaping @MainActor (Host.ID) async -> Void = { _ in },
        makeStore: @escaping @MainActor (ConsoleAgent) -> ChangesStore
    ) {
        self.reads = reads
        self.defersForForegroundLoad = defersForForegroundLoad
        self.yieldToForegroundLoad = yieldToForegroundLoad
        self.makeStore = makeStore
    }

    deinit {
        for following in followings.values { following.cancel() }
        for waiter in deferredForegroundHosts.values { waiter.cancel() }
    }

    /// Defers automatic row git reads while the user is actively scrolling,
    /// flushing any waiting reads for visible rows as soon as scrolling settles.
    func setScrollActive(_ active: Bool) {
        guard isScrollActive != active else { return }
        isScrollActive = active
        if !active {
            for id in visibleRows.keys {
                entries[id]?.store.runPendingAutomaticRefresh()
            }
        }
    }

    /// Returns the proven git branch for `checkoutPath` from any of `agents`,
    /// observing only branch changes rather than every `ChangesStore.phase` tick.
    func branch(at checkoutPath: String?, for agents: [ConsoleAgent]) -> CheckoutHead.Branch? {
        guard let checkoutPath else { return nil }
        for agent in agents {
            if let resolved = branchesByAgent[agent.id], resolved.topLevelPath == checkoutPath {
                return resolved.branch
            }
        }
        return nil
    }

    /// The row's store, made on first use; nil for an Agent that has not
    /// reported a directory, which has nothing to read yet, and for one whose
    /// row reads nothing.
    func store(for agent: ConsoleAgent) -> ChangesStore? {
        entry(for: agent)?.store
    }

    /// A row showing the Agent came on screen. The first starts following;
    /// a row returning runs the read an exit left waiting.
    func rowAppeared(_ agent: ConsoleAgent) {
        let count = (visibleRows[agent.id] ?? 0) + 1
        visibleRows[agent.id] = count
        guard let entry = entry(for: agent) else { return }
        if followings[agent.id] == nil {
            startFollowing(entry, for: agent.id)
        } else if count == 1 {
            entry.store.runPendingAutomaticRefresh()
        }
    }

    func rowDisappeared(_ id: ConsoleAgent.ID) {
        guard let count = visibleRows[id] else { return }
        visibleRows[id] = count > 1 ? count - 1 : nil
    }

    /// An Agent on screen that had no directory reported one: its row
    /// starts reading as if it had just appeared.
    func agentReportedDirectory(_ agent: ConsoleAgent) {
        guard visibleRows[agent.id] != nil, followings[agent.id] == nil,
            let entry = entry(for: agent)
        else { return }
        startFollowing(entry, for: agent.id)
    }

    /// Changes opened from the Agent's detail. Its own Changes (`startsFromRow`)
    /// show the row's read at once; either kind reads in the row's place
    /// while it shows the Checkout the row would read.
    func changesOpened(_ shown: ChangesStore, for id: ConsoleAgent.ID, startsFromRow: Bool) {
        guard let entry = entries[id] else { return }
        if startsFromRow { shown.seed(from: entry.store) }
        entry.shown.removeAll { $0.store == nil || $0.store === shown }
        entry.shown.append(WeakChangesStore(store: shown))
    }

    /// Those Changes closed, or their detail left the screen: the row takes
    /// a newer read of its Checkout, and runs a read they left waiting.
    func changesClosed(_ shown: ChangesStore, for id: ConsoleAgent.ID) {
        guard let entry = entries[id] else { return }
        entry.shown.removeAll { $0.store == nil || $0.store === shown }
        entry.store.adoptNewerRead(of: shown)
        recordBranch(from: entry.store, for: id)
        entry.store.resumeAutomaticRefresh(after: shown)
    }

    /// Drops the stores of Agents `isCurrent` no longer names, ending their
    /// reads. An Agent that comes back reads afresh.
    func retain(where isCurrent: (ConsoleAgent.ID) -> Bool) {
        for (id, entry) in entries where !isCurrent(id) {
            followings.removeValue(forKey: id)?.cancel()
            entry.store.stopFollowingForRowTotals()
            entries[id] = nil
            if branchesByAgent[id] != nil {
                branchesByAgent[id] = nil
            }
        }
        let activeHosts = Set(entries.keys.map(\.hostID))
        for hostID in Array(deferredForegroundHosts.keys) where !activeHosts.contains(hostID) {
            deferredForegroundHosts.removeValue(forKey: hostID)?.cancel()
            bypassedForegroundYieldUntil[hostID] = nil
        }
    }

    private func startFollowing(_ entry: Entry, for id: ConsoleAgent.ID) {
        let store = entry.store
        followings[id] = Task { await store.followForRowTotals() }
    }

    private func shouldDeferForForegroundLoad(on hostID: Host.ID) -> Bool {
        guard defersForForegroundLoad(hostID) else {
            bypassedForegroundYieldUntil[hostID] = nil
            return false
        }
        if let bypassUntil = bypassedForegroundYieldUntil[hostID], ContinuousClock.now < bypassUntil {
            return false
        }
        scheduleForegroundLoadFlush(for: hostID)
        return true
    }

    private func scheduleForegroundLoadFlush(for hostID: Host.ID) {
        guard deferredForegroundHosts[hostID] == nil else { return }
        deferredForegroundHosts[hostID] = Task { [weak self] in
            guard let self else { return }
            await self.yieldToForegroundLoad(hostID)
            guard !Task.isCancelled else { return }
            self.deferredForegroundHosts[hostID] = nil
            if self.defersForForegroundLoad(hostID) {
                self.bypassedForegroundYieldUntil[hostID] = ContinuousClock.now + .seconds(1)
            } else {
                self.bypassedForegroundYieldUntil[hostID] = nil
            }
            for id in self.visibleRows.keys where id.hostID == hostID {
                self.entries[id]?.store.runPendingAutomaticRefresh()
            }
        }
    }

    private func entry(for agent: ConsoleAgent) -> Entry? {
        if let entry = entries[agent.id] { return entry }
        guard agent.directory != nil, reads(agent) else { return nil }
        let store = makeStore(agent)
        store.announcesAutomaticUpdates = false
        let entry = Entry(store: store)
        let id = agent.id
        store.defersAutomaticRefresh = { [weak self, weak entry] in
            guard let self, let entry else { return true }
            if self.isScrollActive || self.visibleRows[id] == nil || entry.isStoodInFor {
                return true
            }
            return self.shouldDeferForForegroundLoad(on: id.hostID)
        }
        store.onReadCompleted = { [weak self] completed in
            self?.recordBranch(from: completed, for: id)
            self?.shareCompletedRead(from: completed, hostID: id.hostID)
        }
        recordBranch(from: store, for: id)
        entries[agent.id] = entry
        return entry
    }

    /// Shares a just-completed row read with sibling rows on the same Host
    /// that read the same directory or proven Checkout, avoiding duplicate
    /// queued git execs when multiple Agents share one repository.
    private func shareCompletedRead(from source: ChangesStore, hostID: Host.ID) {
        for (siblingID, siblingEntry) in entries where siblingID.hostID == hostID {
            siblingEntry.store.adoptFreshSiblingRead(of: source)
            recordBranch(from: siblingEntry.store, for: siblingID)
        }
    }

    private func recordBranch(from store: ChangesStore, for id: ConsoleAgent.ID) {
        guard case .loaded(let changes) = store.phase else { return }
        let next = ResolvedBranch(
            topLevelPath: String(decoding: changes.checkout.topLevel, as: UTF8.self),
            branch: changes.head.branch)
        if branchesByAgent[id] != next {
            branchesByAgent[id] = next
        }
    }
}

/// One Agent's list store, as Agent detail's status line shows it.
@MainActor
struct AgentDetailChanges {
    let rows: AgentRowChanges
    let agent: ConsoleAgent
    /// Opens the Agent's Changes, as the Agent menu's entry does; nil when
    /// that entry is hidden.
    var open: (() -> Void)? = nil

    var store: ChangesStore? { rows.store(for: agent) }
}
