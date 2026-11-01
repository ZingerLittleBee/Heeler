import Foundation

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
final class AgentRowChanges {
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

    private var entries: [ConsoleAgent.ID: Entry] = [:]
    /// Each store's reads, kept apart from the entries so the registry's
    /// deinit can end them.
    private var followings: [ConsoleAgent.ID: Task<Void, Never>] = [:]
    /// Rows on screen per Agent, across windows, kept apart from the stores
    /// so a row shown before its Agent reports a directory still counts.
    private var visibleRows: [ConsoleAgent.ID: Int] = [:]
    private let makeStore: @MainActor (ConsoleAgent) -> ChangesStore

    /// `makeStore` reads the Checkout the Agent is in at the time of each
    /// read, following its status.
    init(makeStore: @escaping @MainActor (ConsoleAgent) -> ChangesStore) {
        self.makeStore = makeStore
    }

    deinit {
        for following in followings.values { following.cancel() }
    }

    /// The row's store, made on first use; nil for an Agent that has not
    /// reported a directory, which has nothing to read yet.
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
        entry.store.resumeAutomaticRefresh(after: shown)
    }

    /// Drops the stores of Agents `isCurrent` no longer names, ending their
    /// reads. An Agent that comes back reads afresh.
    func retain(where isCurrent: (ConsoleAgent.ID) -> Bool) {
        for (id, entry) in entries where !isCurrent(id) {
            followings.removeValue(forKey: id)?.cancel()
            entry.store.stopFollowingForRowTotals()
            entries[id] = nil
        }
    }

    private func startFollowing(_ entry: Entry, for id: ConsoleAgent.ID) {
        let store = entry.store
        followings[id] = Task { await store.followForRowTotals() }
    }

    private func entry(for agent: ConsoleAgent) -> Entry? {
        if let entry = entries[agent.id] { return entry }
        guard agent.directory != nil else { return nil }
        let store = makeStore(agent)
        store.announcesAutomaticUpdates = false
        let entry = Entry(store: store)
        let id = agent.id
        store.defersAutomaticRefresh = { [weak self, weak entry] in
            guard let self, let entry else { return true }
            return self.visibleRows[id] == nil || entry.isStoodInFor
        }
        entries[agent.id] = entry
        return entry
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
