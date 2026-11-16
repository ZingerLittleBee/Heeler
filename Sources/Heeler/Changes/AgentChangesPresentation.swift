import Observation
import UIKit

/// Changes pushed over Agent detail. Held in Agent detail's own state, so it
/// closes with Agent detail (another Agent or terminal selected, the Host
/// leaving Connected, the Agent exiting), and it holds the only reference to
/// its store, so closing discards the content.
///
/// The Agents list reads each Agent's Checkout for its row totals
/// (`AgentRowChanges`). The Agent's own Changes open on that read while
/// reading again, and any open Changes read in the row's place while their
/// detail is on screen; closing hands their read back to the row.
@MainActor
@Observable
final class AgentChangesPresentation {
    /// The open Changes; nil while Agent detail shows its terminal. The
    /// push follows it, and the system's Back closes it.
    private(set) var store: ChangesStore?
    @ObservationIgnored private var pendingInsertion: String?
    /// Whether the row's store currently counts the open Changes as reading
    /// in its place.
    @ObservationIgnored private var isStandingInForRow = false
    /// Changes' screens on screen: the list, and a file's diff pushed over
    /// it. Changes as a whole come with the first and leave with the last.
    @ObservationIgnored private var shownScreens = 0

    /// Nil follows the Agent. A Worktree directory stays fixed for the
    /// life of that store, even if the Agent later moves.
    @ObservationIgnored private let makeStoreIn: @MainActor (String?) -> ChangesStore
    @ObservationIgnored private let row: (changes: AgentRowChanges, agentID: ConsoleAgent.ID)?

    init(
        row: (changes: AgentRowChanges, agentID: ConsoleAgent.ID)? = nil,
        makeStoreIn: @escaping @MainActor (_ directory: String?) -> ChangesStore
    ) {
        self.row = row
        self.makeStoreIn = makeStoreIn
    }

    /// The Agent menu, which follows the Agent's current directory.
    convenience init(makeStore: @escaping @MainActor () -> ChangesStore) {
        self.init(makeStoreIn: { _ in makeStore() })
    }

    /// Opens Changes. `directory` is a Worktree's checkout path; nil follows
    /// the Agent. A second open while one is shown keeps it.
    func open(directory: String? = nil) {
        guard store == nil else { return }
        pendingInsertion = nil
        let store = makeStoreIn(directory)
        store.referencesFollowAgentDirectory = directory == nil
        if store.copyToPasteboard == nil {
            store.copyToPasteboard = { UIPasteboard.general.string = $0 }
        }
        store.insertReference = { [weak self, weak store] text in
            guard let self, let store, self.store === store else { return }
            self.pendingInsertion = text
            self.leaveShown()
        }
        self.store = store
        if let row {
            row.changes.changesOpened(store, for: row.agentID, startsFromRow: directory == nil)
            isStandingInForRow = true
        }
    }

    /// Back: returns to Agent detail and drops the document, after the row
    /// has taken any newer read from it.
    func close() {
        pendingInsertion = nil
        leaveShown()
    }

    /// Agent detail takes this after acquiring the Attach it will actually show.
    func takePendingInsertion() -> String? {
        defer { pendingInsertion = nil }
        return pendingInsertion
    }

    /// One of Changes' screens appeared. True when it is the first, so
    /// Changes as a whole came on screen.
    func screenAppeared() -> Bool {
        shownScreens += 1
        return shownScreens == 1
    }

    /// One of Changes' screens left. True when it was the last, so Changes
    /// as a whole left the screen.
    func screenDisappeared() -> Bool {
        shownScreens = max(0, shownScreens - 1)
        return shownScreens == 0
    }

    /// Changes came back on screen still open: they read in the row's place
    /// again.
    func detailAppeared() {
        guard let row, let store, !isStandingInForRow else { return }
        row.changes.changesOpened(store, for: row.agentID, startsFromRow: false)
        isStandingInForRow = true
    }

    /// Changes left the screen with Agent detail, most often for good: the
    /// row takes their read now and reads for itself again.
    func detailDisappeared() {
        guard let store else { return }
        handBack(store)
    }

    private func leaveShown() {
        guard let shown = store else { return }
        store = nil
        handBack(shown)
    }

    private func handBack(_ shown: ChangesStore) {
        guard let row, isStandingInForRow else { return }
        isStandingInForRow = false
        row.changes.changesClosed(shown, for: row.agentID)
    }
}

extension AgentChangesPresentation {
    /// Agent detail's Changes: the Console's reads through the Host's git
    /// exec gate, following the Agent's directory and status, handing their
    /// reads to the Agents list's row.
    static func forAgentDetail(
        agentID: ConsoleAgent.ID,
        hostID: Host.ID,
        openingDirectory: String?,
        console: ConsoleStore
    ) -> AgentChangesPresentation {
        AgentChangesPresentation(row: (console.rowChanges, agentID)) { [console] fixedDirectory in
            console.makeChangesStore(
                agentID: agentID, hostID: hostID, fixedDirectory: fixedDirectory,
                openingDirectory: openingDirectory)
        }
    }
}

extension ConsoleStore {
    /// A store reading, through the Host's git exec gate, `fixedDirectory`
    /// or else the directory the Agent is in at the time of each read, and
    /// following the Agent's status.
    func makeChangesStore(
        agentID: ConsoleAgent.ID,
        hostID: Host.ID,
        fixedDirectory: String? = nil,
        openingDirectory: String?
    ) -> ChangesStore {
        ChangesStore(
            // Where the Agent is now: a later read follows it into another
            // Checkout.
            directory: { [weak self] in
                fixedDirectory ?? self?.agents.first { $0.id == agentID }?.directory
                    ?? openingDirectory
            },
            read: { [weak self] request in
                guard let self else { throw TransportError.cancelled }
                await self.yieldToForegroundChatLoad(on: hostID)
                try Task.checkCancellation()
                return try await self.readChanges(request, on: hostID)
            },
            readPatch: { [weak self] request in
                guard let self else { throw TransportError.cancelled }
                return try await self.readFilePatch(request, on: hostID)
            },
            listUntrackedDirectory: { [weak self] request in
                guard let self else { throw TransportError.cancelled }
                return try await self.listUntrackedDirectory(request, on: hostID)
            },
            gate: gitExecGate(for: hostID),
            agentStatus: { [weak self] in
                self?.agentStatusUpdates(for: agentID) ?? AsyncStream { $0.finish() }
            })
    }
}
