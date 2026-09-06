import Foundation
import Observation

/// Read-only until Edit. Every change, including a Sync from plugin fill,
/// lands in a per-Host draft that only Save persists; Cancel and leaving the
/// screen discard drafts. Hosts without a saved choice show their herdr
/// fields, or Heeler's fallback when the plugin has none.
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

    /// Saved or snapshot provenance, ignoring an in-memory draft.
    func underlyingSource(for hostID: Host.ID) -> LayoutSource {
        if layouts.hostLayouts[hostID] != nil { return .saved }
        switch snapshots.states[hostID] {
        case .loading: return .loading
        case .loaded(let snapshot?): return snapshot.diagnostics.isEmpty ? .plugin : .pluginDefaults
        case .loaded(nil): return .missing
        case .unavailable, nil: return .unavailable
        }
    }

    /// Hosts whose draft would be written by Save, using the same comparison.
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

    /// Fetches the Host's plugin snapshot and fills its draft. A missing
    /// snapshot fills Heeler's fallback fields; a failed read changes nothing.
    /// Results are dropped once editing ended or the draft was edited since.
    func syncFromPlugin(_ hostID: Host.ID) async {
        guard isEditing else { return }
        let request = UUID()
        syncRequests[hostID] = request
        syncStates[hostID] = .syncing
        let state = await fetch(hostID)
        guard isEditing, syncRequests[hostID] == request else { return }
        syncRequests[hostID] = nil
        switch state {
        case .loaded(let snapshot?):
            drafts[hostID] = snapshot.layout
            syncStates[hostID] = .filled(snapshot.diagnostics.isEmpty
                ? "Filled from the herdr plugin. Save to keep these fields."
                : "herdr reported a configuration problem, so its default fields were filled. Save to keep them.")
        case .loaded(nil):
            drafts[hostID] = .heelerDefault
            syncStates[hostID] = .filled(
                "The herdr plugin on this Host has no fields snapshot, so Heeler's fallback fields were filled. Save to keep them.")
        case .unavailable:
            syncStates[hostID] = .failed("herdr fields could not be read from this Host. Nothing was changed.")
        case .loading, nil:
            syncStates[hostID] = .failed("This Host is not connected. Nothing was changed.")
        }
        errorMessage = nil
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
            : "This layout could not be saved. Use at most 16 rows and 16 fields per row, with valid field names."
    }
}
