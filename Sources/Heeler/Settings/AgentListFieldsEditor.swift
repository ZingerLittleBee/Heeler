import Foundation
import Observation

/// Per-Host layout edits. The draft session (`beginEditing`, `update`,
/// `save`, `cancel`) validates a batch and writes it in one step; `commit`
/// and `replaceWithPluginFields` wrap that session around a single change so
/// the Agent List Fields screen can edit inline and persist immediately.
/// Hosts without a saved choice show their herdr fields, or Heeler's
/// fallback when the plugin has none.
@MainActor
@Observable
final class AgentListFieldsEditor {
    enum SyncState: Equatable {
        case syncing
        case filled(String)
        case failed(String)

        var message: String? {
            switch self {
            case .syncing: nil
            case .filled(let message), .failed(let message): message
            }
        }
    }

    enum LayoutSource: Equatable {
        case draft, saved, plugin, pluginDefaults, loading, missing, unavailable
    }

    typealias Fetch = @MainActor (Host.ID) async -> HerdrSidebarSnapshotStore.HostState?

    let layouts: AgentRowLayoutStore
    let snapshots: HerdrSidebarSnapshotStore
    private let fetch: Fetch
    private(set) var isEditing = false
    private(set) var drafts: [Host.ID: AgentRowLayout] = [:]
    private(set) var syncStates: [Host.ID: SyncState] = [:]
    var errorMessage: String?
    @ObservationIgnored private var syncRequests: [Host.ID: UUID] = [:]

    init(layouts: AgentRowLayoutStore, snapshots: HerdrSidebarSnapshotStore, fetch: @escaping Fetch) {
        self.layouts = layouts
        self.snapshots = snapshots
        self.fetch = fetch
    }

    /// The Console's layout for this Host, or its draft while editing.
    func layout(for hostID: Host.ID) -> AgentRowLayout {
        if isEditing, let draft = drafts[hostID] { return draft }
        return layouts.resolvedLayout(for: hostID, pluginSnapshot: snapshots.snapshot(for: hostID))
    }

    func source(for hostID: Host.ID) -> LayoutSource {
        if isEditing, drafts[hostID] != nil { return .draft }
        return underlyingSource(for: hostID)
    }

    /// Saved or snapshot provenance, ignoring an in-memory draft. Never `.draft`.
    func underlyingSource(for hostID: Host.ID) -> LayoutSource {
        if layouts.hostLayouts[hostID] != nil { return .saved }
        switch snapshots.states[hostID] {
        case .loading: return .loading
        case .loaded(let snapshot?): return snapshot.diagnostics.isEmpty ? .plugin : .pluginDefaults
        case .loaded(nil): return .missing
        case .unavailable, nil: return .unavailable
        }
    }

    /// Hosts whose draft would be written by Save. Compared to the optional
    /// saved layout, not to effective plugin rows: syncing a plugin copy onto
    /// a Host with no saved choice stays dirty.
    var dirtyHostIDs: Set<Host.ID> {
        Set(drafts.compactMap { hostID, layout in
            layout != layouts.hostLayouts[hostID] ? hostID : nil
        })
    }

    /// True when Save would change the persisted catalog.
    var hasUnsavedChanges: Bool {
        !dirtyHostIDs.isEmpty
    }

    func beginEditing() {
        isEditing = true
        clearDrafts()
    }

    func cancel() {
        isEditing = false
        clearDrafts()
    }

    /// All changed Hosts are written in one validated step; a failed write
    /// keeps the drafts and stays in edit mode.
    func save() {
        guard isEditing else { return }
        let changes = drafts.filter { $0.value != layouts.hostLayouts[$0.key] }
            .mapValues { Optional($0) }
        do {
            try layouts.setLayouts(changes)
            errorMessage = nil
            isEditing = false
            clearDrafts()
        } catch {
            report(error)
        }
    }

    func update(_ hostID: Host.ID, _ edit: (inout AgentRowLayout) -> Void) {
        guard isEditing else { return }
        var next = layout(for: hostID)
        edit(&next)
        do {
            try next.validate()
            try next.validateForConsole()
        } catch {
            report(error)
            return
        }
        drafts[hostID] = next
        // A later edit wins over an in-flight or finished sync.
        syncRequests[hostID] = nil
        syncStates[hostID] = nil
        errorMessage = nil
    }

    func setRows(_ rows: [AgentRow], kind: String?, for hostID: Host.ID) {
        update(hostID) {
            if let kind { $0.rowsByAgent[kind] = rows }
            else { $0.rows = rows }
        }
    }

    /// One inline change, validated and persisted at once. A no-op or invalid
    /// change writes nothing and returns false; an invalid one keeps its
    /// message in `errorMessage`. Inside an open draft session the change
    /// joins that session and `save` writes every dirty Host.
    @discardableResult
    func commit(_ hostID: Host.ID, _ edit: (inout AgentRowLayout) -> Void) -> Bool {
        let wasEditing = isEditing
        if !wasEditing { beginEditing() }
        let before = layout(for: hostID)
        update(hostID, edit)
        if errorMessage != nil {
            if !wasEditing { discardKeepingError() }
            return false
        }
        guard layout(for: hostID) != before else {
            if !wasEditing { cancel() }
            return false
        }
        save()
        return !isEditing
    }

    /// Inline Sync from plugin: fills the Host from its plugin snapshot and
    /// saves immediately. The resulting `syncStates` entry survives the save
    /// so the screen can report what happened; the next change clears it.
    func replaceWithPluginFields(_ hostID: Host.ID, hostName: String = "this Host") async {
        let wasEditing = isEditing
        if !wasEditing { beginEditing() }
        await syncFromPlugin(hostID, hostName: hostName)
        guard let state = syncStates[hostID] else {
            // Dropped: a later edit or an ended session won.
            if !wasEditing && isEditing { cancel() }
            return
        }
        if case .filled = state {
            save()
        } else if !wasEditing {
            cancel()
        }
        syncStates[hostID] = state
    }

    /// Fetches the Host's plugin snapshot and fills its draft, including
    /// overrides, row gap, and token styles, reduced to the Console's three
    /// row slots. A missing snapshot fills Heeler's fallback fields; a failed
    /// read leaves the draft unchanged. Results are dropped once editing
    /// ended or the draft was edited since. Draft-only; the screen uses
    /// `replaceWithPluginFields`.
    ///
    /// `hostName` is only interpolated into the unread-snapshot failure copy.
    /// The one-argument call stays valid and uses "this Host".
    func syncFromPlugin(_ hostID: Host.ID, hostName: String = "this Host") async {
        guard isEditing else { return }
        let request = UUID()
        syncRequests[hostID] = request
        syncStates[hostID] = .syncing
        let state = await fetch(hostID)
        guard isEditing, syncRequests[hostID] == request else { return }
        syncRequests[hostID] = nil
        switch state {
        case .loaded(let snapshot?):
            drafts[hostID] = snapshot.layout.normalizedForConsole()
            syncStates[hostID] = .filled(snapshot.diagnostics.isEmpty
                ? "Replaced with plugin fields."
                : "herdr reported a configuration problem, so its default fields were used.")
        case .loaded(nil):
            drafts[hostID] = .consoleDefault
            syncStates[hostID] = .filled(
                "This Host has no plugin fields snapshot, so Heeler's fallback fields were used.")
        case .unavailable:
            syncStates[hostID] = .failed("Couldn't reach \(hostName). Rows unchanged.")
        case .loading, nil:
            syncStates[hostID] = .failed("You're offline. Rows unchanged.")
        }
        errorMessage = nil
    }

    private func discardKeepingError() {
        let message = errorMessage
        cancel()
        errorMessage = message
    }

    private func clearDrafts() {
        drafts = [:]
        syncStates = [:]
        syncRequests = [:]
        errorMessage = nil
    }

    private func report(_ error: any Error) {
        errorMessage = error is AgentRowLayoutStoreError
            ? "The saved Agent List Fields could not be read. Nothing was changed."
            : "This layout could not be saved. Use at most 3 rows and 16 fields per row, with valid field names."
    }
}
