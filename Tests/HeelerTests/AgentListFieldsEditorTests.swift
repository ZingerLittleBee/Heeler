import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent List Fields editor")
struct AgentListFieldsEditorTests {
    private let pluginData = Data(##"{"v":1,"sidebar":{"agents":{"row_gap":2,"rows":[[{"token":"workspace","fg":"#abc","bold":false,"dim":true}]],"rows_by_agent":{"claude":[[{"token":"terminal_title_stripped"}]]}}}}"##.utf8)

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suite = "sidebar-editor-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    /// A connected Host whose plugin snapshot the editor can read and sync.
    private func makeSnapshots(hostID: Host.ID, transport: ScriptedTransport) async
        -> (HerdrSidebarSnapshotStore, AgentListFieldsEditor.Fetch)
    {
        let snapshots = HerdrSidebarSnapshotStore()
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        snapshots.reconcile([hostID: .init(generation: 1, revision: 0)], transports: provider, didChange: {})
        await snapshots.waitForPendingReads()
        return (snapshots, { await snapshots.refresh($0, transports: provider, didChange: {}) })
    }

    @Test func readOnlyUntilEditAndDraftsPersistOnlyOnSave() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let layouts = AgentRowLayoutStore(defaults: defaults)
        let hostID = UUID(), otherID = UUID()
        let transport = ScriptedTransport()
        await transport.setSidebarLayout(pluginData)
        let (snapshots, fetch) = await makeSnapshots(hostID: hostID, transport: transport)
        let plugin = try #require(AgentRowLayoutSnapshot.decode(pluginData)).layout
        let editor = AgentListFieldsEditor(layouts: layouts, snapshots: snapshots, fetch: fetch)
        #expect(editor.isEditing == false)
        #expect(editor.layout(for: hostID) == plugin)
        #expect(editor.layout(for: otherID) == .heelerDefault)
        #expect(editor.source(for: hostID) == .plugin)
        #expect(editor.source(for: otherID) == .unavailable)

        // Read-only: nothing is drafted or saved.
        editor.setRows([], kind: nil, for: hostID)
        #expect(editor.layout(for: hostID) == plugin && editor.drafts.isEmpty)
        #expect(layouts.hostLayouts.isEmpty)

        editor.beginEditing()
        editor.setRows(plugin.rows + [[]], kind: nil, for: hostID)
        #expect(editor.source(for: hostID) == .draft)
        #expect(editor.hasUnsavedChanges)
        #expect(editor.layout(for: hostID).rows == plugin.rows + [[]])
        #expect(editor.layout(for: hostID).rowsByAgent == plugin.rowsByAgent)
        #expect(editor.layout(for: hostID).rowGap == 2)
        #expect(editor.layout(for: hostID).rows[0][0].fg == HexColor("#abc"))
        #expect(editor.layout(for: hostID).rows[0][0].bold == false && editor.layout(for: hostID).rows[0][0].dim == true)
        editor.setRows([[.init(.custom("build_status"))], []], kind: "claude", for: hostID)
        #expect(editor.layout(for: hostID).rowsByAgent["claude"] == [[.init(.custom("build_status"))], []])
        #expect(layouts.hostLayouts.isEmpty)
        #expect(editor.layout(for: otherID) == .heelerDefault && editor.source(for: otherID) == .unavailable)

        editor.cancel()
        #expect(editor.isEditing == false && editor.drafts.isEmpty && !editor.hasUnsavedChanges)
        #expect(editor.layout(for: hostID) == plugin)
        #expect(layouts.hostLayouts.isEmpty)

        editor.beginEditing()
        editor.setRows([[.init(.pane)]], kind: nil, for: hostID)
        editor.update(otherID) { $0.rowGap = 3 }
        editor.save()
        #expect(editor.isEditing == false && editor.drafts.isEmpty)
        #expect(layouts.hostLayouts[hostID]?.rows == [[.init(.pane)]])
        #expect(layouts.hostLayouts[hostID]?.rowsByAgent == plugin.rowsByAgent)
        #expect(layouts.hostLayouts[otherID] == AgentRowLayout(rows: AgentRowLayout.heelerDefault.rows, rowGap: 3))
        #expect(editor.source(for: hostID) == .saved)

        // Reopening shows the saved choice, and an untouched edit session saves nothing new.
        let reopened = AgentListFieldsEditor(
            layouts: AgentRowLayoutStore(defaults: defaults), snapshots: snapshots, fetch: fetch)
        #expect(reopened.layout(for: hostID).rows == [[.init(.pane)]])
        reopened.beginEditing()
        #expect(!reopened.hasUnsavedChanges)
        reopened.save()
        #expect(reopened.isEditing == false)
        #expect(AgentRowLayoutStore(defaults: defaults).hostLayouts.count == 2)
    }

    @Test func syncFromPluginFillsTheDraftAndReportsFailures() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let layouts = AgentRowLayoutStore(defaults: defaults)
        let hostID = UUID(), offlineID = UUID()
        let transport = ScriptedTransport()
        let (snapshots, fetch) = await makeSnapshots(hostID: hostID, transport: transport)
        #expect(snapshots.states[hostID] == .loaded(nil))
        let saved = AgentRowLayout(rows: [[.init(.pane)]])
        try layouts.setLayout(saved, for: hostID)
        let editor = AgentListFieldsEditor(layouts: layouts, snapshots: snapshots, fetch: fetch)

        await editor.syncFromPlugin(hostID)
        #expect(editor.syncStates.isEmpty && editor.drafts.isEmpty)

        editor.beginEditing()
        await editor.syncFromPlugin(offlineID)
        #expect(editor.syncStates[offlineID] == .failed("You're offline. Draft unchanged."))
        #expect(editor.drafts[offlineID] == nil)

        await transport.setSidebarLayoutReadFailure(NotificationRegistrationError.pluginNotInstalled)
        await editor.syncFromPlugin(hostID, hostName: "Studio Mac")
        #expect(editor.syncStates[hostID] == .failed("Couldn't reach Studio Mac. Draft unchanged."))
        #expect(editor.layout(for: hostID) == saved && editor.drafts[hostID] == nil)

        await transport.setSidebarLayoutReadFailure(nil)
        await editor.syncFromPlugin(hostID)
        #expect(editor.syncStates[hostID] == .filled(
            "This Host has no plugin fields snapshot, so Heeler's fallback fields were filled. Unsaved until you save."))
        #expect(editor.layout(for: hostID) == .heelerDefault)

        await transport.setSidebarLayout(pluginData)
        await editor.syncFromPlugin(hostID)
        let plugin = try #require(AgentRowLayoutSnapshot.decode(pluginData)).layout
        #expect(editor.syncStates[hostID] == .filled("Filled from plugin. Unsaved until you save."))
        #expect(editor.layout(for: hostID) == plugin)
        #expect(layouts.hostLayouts[hostID] == saved)
        editor.save()
        #expect(layouts.hostLayouts[hostID] == plugin)
        #expect(editor.syncStates.isEmpty)
    }

    @Test func staleSyncResultsNeverOverwriteALaterDraftOrEndedSession() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let layouts = AgentRowLayoutStore(defaults: defaults)
        let hostID = UUID()
        let transport = ScriptedTransport()
        await transport.setSidebarLayout(pluginData)
        let (snapshots, fetch) = await makeSnapshots(hostID: hostID, transport: transport)
        let editor = AgentListFieldsEditor(layouts: layouts, snapshots: snapshots, fetch: fetch)

        editor.beginEditing()
        var gate = ScriptedTransportCallGate()
        await transport.gateNextSidebarLayoutRead(gate)
        var sync = Task { await editor.syncFromPlugin(hostID) }
        await gate.waitForEntry()
        #expect(editor.syncStates[hostID] == .syncing)
        editor.setRows([[.init(.pane)]], kind: nil, for: hostID)
        #expect(editor.syncStates[hostID] == nil)
        await gate.open()
        await sync.value
        #expect(editor.layout(for: hostID).rows == [[.init(.pane)]])
        #expect(editor.syncStates[hostID] == nil)

        gate = ScriptedTransportCallGate()
        await transport.gateNextSidebarLayoutRead(gate)
        sync = Task { await editor.syncFromPlugin(hostID) }
        await gate.waitForEntry()
        editor.cancel()
        await gate.open()
        await sync.value
        #expect(editor.isEditing == false && editor.drafts.isEmpty && editor.syncStates.isEmpty)
        #expect(layouts.hostLayouts.isEmpty)
    }

    @Test func throwingWritesHaveVisibleFeedbackAndDoNotPublishPartialChanges() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let layouts = AgentRowLayoutStore(defaults: defaults)
        let hostID = UUID()
        let editor = AgentListFieldsEditor(
            layouts: layouts, snapshots: HerdrSidebarSnapshotStore(), fetch: { _ in nil })
        editor.beginEditing()
        editor.setRows(Array(repeating: [], count: 17), kind: nil, for: hostID)
        #expect(editor.errorMessage != nil)
        #expect(editor.drafts.isEmpty)
        editor.setRows([[.init(.pane)]], kind: nil, for: hostID)
        #expect(editor.errorMessage == nil)

        defaults.set(Data("unreadable".utf8), forKey: "agent-row-layouts")
        let broken = AgentListFieldsEditor(
            layouts: AgentRowLayoutStore(defaults: defaults), snapshots: HerdrSidebarSnapshotStore(),
            fetch: { _ in nil })
        broken.beginEditing()
        broken.setRows([[.init(.pane)]], kind: nil, for: hostID)
        broken.save()
        #expect(broken.errorMessage?.contains("Nothing was changed") == true)
        #expect(broken.isEditing && broken.drafts[hostID]?.rows == [[.init(.pane)]])
        #expect(broken.dirtyHostIDs == Set([hostID]))
        #expect(defaults.data(forKey: "agent-row-layouts") == Data("unreadable".utf8))
    }

    @Test func dirtyHostIDsCompareDraftToOptionalSavedLayoutNotEffectiveRows() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let layouts = AgentRowLayoutStore(defaults: defaults)
        let unsavedID = UUID(), savedID = UUID(), otherID = UUID()
        let transport = ScriptedTransport()
        await transport.setSidebarLayout(pluginData)
        let (snapshots, fetch) = await makeSnapshots(hostID: unsavedID, transport: transport)
        let plugin = try #require(AgentRowLayoutSnapshot.decode(pluginData)).layout
        let saved = AgentRowLayout(rows: [[.init(.pane)]], rowGap: 1)
        try layouts.setLayout(saved, for: savedID)
        let editor = AgentListFieldsEditor(layouts: layouts, snapshots: snapshots, fetch: fetch)

        #expect(editor.dirtyHostIDs.isEmpty)
        editor.beginEditing()
        #expect(editor.dirtyHostIDs.isEmpty && !editor.hasUnsavedChanges)
        #expect(editor.layout(for: unsavedID) == plugin)

        // No saved choice: syncing the same effective plugin rows is still an explicit write.
        await editor.syncFromPlugin(unsavedID)
        #expect(editor.layout(for: unsavedID) == plugin)
        #expect(layouts.hostLayouts[unsavedID] == nil)
        #expect(editor.dirtyHostIDs == Set([unsavedID]))
        #expect(editor.hasUnsavedChanges)

        editor.setRows([[.init(.agent)]], kind: nil, for: savedID)
        #expect(editor.dirtyHostIDs == Set([unsavedID, savedID]))
        editor.setRows(saved.rows, kind: nil, for: savedID)
        #expect(editor.layout(for: savedID) == saved)
        #expect(editor.dirtyHostIDs == Set([unsavedID]))
        #expect(editor.layout(for: otherID) == .heelerDefault)
        #expect(!editor.dirtyHostIDs.contains(otherID))
    }

    @Test func underlyingSourceStaysTruthfulDuringDrafts() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let layouts = AgentRowLayoutStore(defaults: defaults)
        let hostID = UUID(), savedID = UUID(), loadingID = UUID()
        let transport = ScriptedTransport()
        await transport.setSidebarLayout(pluginData)
        let loadingTransport = ScriptedTransport()
        let gate = ScriptedTransportCallGate()
        await loadingTransport.gateNextSidebarLayoutRead(gate)
        let snapshots = HerdrSidebarSnapshotStore()
        let provider = ScriptedTransportProvider(transports: [
            hostID: transport, loadingID: loadingTransport,
        ])
        snapshots.reconcile(
            [hostID: .init(generation: 1, revision: 0)], transports: provider, didChange: {})
        await snapshots.waitForPendingReads()
        snapshots.reconcile(
            [
                hostID: .init(generation: 1, revision: 0),
                loadingID: .init(generation: 1, revision: 0),
            ], transports: provider, didChange: {})
        #expect(snapshots.states[loadingID] == .loading)
        try layouts.setLayout(AgentRowLayout(rows: [[.init(.pane)]]), for: savedID)
        let editor = AgentListFieldsEditor(
            layouts: layouts, snapshots: snapshots,
            fetch: { await snapshots.refresh($0, transports: provider, didChange: {}) })

        #expect(editor.underlyingSource(for: hostID) == .plugin)
        #expect(editor.source(for: hostID) == .plugin)
        #expect(editor.underlyingSource(for: savedID) == .saved)
        #expect(editor.underlyingSource(for: loadingID) == .loading)
        #expect(editor.underlyingSource(for: UUID()) == .unavailable)

        editor.beginEditing()
        editor.setRows([[.init(.agent)]], kind: nil, for: hostID)
        editor.setRows([[.init(.agent)]], kind: nil, for: savedID)
        editor.setRows([[.init(.agent)]], kind: nil, for: loadingID)
        #expect(editor.source(for: hostID) == .draft)
        #expect(editor.underlyingSource(for: hostID) == .plugin)
        #expect(editor.source(for: savedID) == .draft)
        #expect(editor.underlyingSource(for: savedID) == .saved)
        #expect(editor.source(for: loadingID) == .draft)
        #expect(editor.underlyingSource(for: loadingID) == .loading)

        let diagnosticData = Data(#"""
            {"v":1,"sidebar":{"agents":{"row_gap":2,"rows":[[{"token":"workspace"}]],
              "rows_by_agent":{"claude":[[{"token":"terminal_title_stripped"}]]}}},
             "diagnostics":["using defaults"]}
            """#.utf8)
        await transport.setSidebarLayout(diagnosticData)
        _ = await snapshots.refresh(hostID, transports: provider, didChange: {})
        #expect(editor.source(for: hostID) == .draft)
        #expect(editor.underlyingSource(for: hostID) == .pluginDefaults)

        await transport.setSidebarLayout(nil)
        _ = await snapshots.refresh(hostID, transports: provider, didChange: {})
        #expect(editor.underlyingSource(for: hostID) == .missing)

        await transport.setSidebarLayoutReadFailure(NotificationRegistrationError.pluginNotInstalled)
        _ = await snapshots.refresh(hostID, transports: provider, didChange: {})
        #expect(editor.underlyingSource(for: hostID) == .unavailable)

        await gate.open()
        await snapshots.waitForPendingReads()
    }

    @Test func syncCopiesFullLayoutAndKeepsDraftOnFailureWithDistinctCopy() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let layouts = AgentRowLayoutStore(defaults: defaults)
        let snapshot = AgentRowLayoutSnapshot(
            layout: AgentRowLayout(
                rows: [[.init(.workspace, fg: HexColor("#abc"), bold: false, dim: true)]],
                rowGap: 2,
                rowsByAgent: ["claude": [[.init(.custom("build_status"))]]]),
            diagnostics: ["using defaults"])
        let fetchState = FetchState(value: .loaded(snapshot))
        let editor = AgentListFieldsEditor(
            layouts: layouts, snapshots: HerdrSidebarSnapshotStore(),
            fetch: { _ in fetchState.value })
        let hostID = UUID()
        editor.beginEditing()
        editor.setRows([[.init(.pane)]], kind: nil, for: hostID)
        let prior = editor.layout(for: hostID)

        fetchState.value = .unavailable
        await editor.syncFromPlugin(hostID, hostName: "Studio Mac")
        #expect(editor.layout(for: hostID) == prior)
        #expect(editor.syncStates[hostID] == .failed("Couldn't reach Studio Mac. Draft unchanged."))

        fetchState.value = nil
        await editor.syncFromPlugin(hostID)
        #expect(editor.layout(for: hostID) == prior)
        #expect(editor.syncStates[hostID] == .failed("You're offline. Draft unchanged."))

        fetchState.value = .loading
        await editor.syncFromPlugin(hostID)
        #expect(editor.layout(for: hostID) == prior)
        #expect(editor.syncStates[hostID] == .failed("You're offline. Draft unchanged."))

        fetchState.value = .loaded(nil)
        await editor.syncFromPlugin(hostID)
        #expect(editor.layout(for: hostID) == .heelerDefault)
        #expect(editor.syncStates[hostID] == .filled(
            "This Host has no plugin fields snapshot, so Heeler's fallback fields were filled. Unsaved until you save."))

        fetchState.value = .loaded(snapshot)
        await editor.syncFromPlugin(hostID)
        #expect(editor.layout(for: hostID) == snapshot.layout)
        #expect(editor.layout(for: hostID).rowsByAgent == snapshot.layout.rowsByAgent)
        #expect(editor.layout(for: hostID).rowGap == 2)
        #expect(editor.layout(for: hostID).rows[0][0].fg == HexColor("#abc"))
        #expect(editor.layout(for: hostID).rows[0][0].bold == false)
        #expect(editor.layout(for: hostID).rows[0][0].dim == true)
        #expect(editor.syncStates[hostID] == .filled(
            "herdr reported a configuration problem, so its default fields were filled. Unsaved until you save."))
        #expect(layouts.hostLayouts.isEmpty)

        fetchState.value = .loaded(AgentRowLayoutSnapshot(layout: snapshot.layout))
        await editor.syncFromPlugin(hostID)
        #expect(editor.syncStates[hostID] == .filled("Filled from plugin. Unsaved until you save."))
        #expect(editor.layout(for: hostID) == snapshot.layout)
        #expect(layouts.hostLayouts.isEmpty)
    }

    @Test func successfulSaveDropsAnInFlightSyncResult() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let layouts = AgentRowLayoutStore(defaults: defaults)
        let hostID = UUID()
        let transport = ScriptedTransport()
        await transport.setSidebarLayout(pluginData)
        let (snapshots, fetch) = await makeSnapshots(hostID: hostID, transport: transport)
        let editor = AgentListFieldsEditor(layouts: layouts, snapshots: snapshots, fetch: fetch)

        editor.beginEditing()
        editor.setRows([[.init(.pane)]], kind: nil, for: hostID)
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSidebarLayoutRead(gate)
        let sync = Task { await editor.syncFromPlugin(hostID) }
        await gate.waitForEntry()
        #expect(editor.syncStates[hostID] == .syncing)
        editor.save()
        #expect(editor.isEditing == false && editor.drafts.isEmpty)
        #expect(layouts.hostLayouts[hostID]?.rows == [[.init(.pane)]])
        await gate.open()
        await sync.value
        #expect(editor.drafts.isEmpty && editor.syncStates.isEmpty)
        #expect(layouts.hostLayouts[hostID]?.rows == [[.init(.pane)]])

        editor.beginEditing()
        #expect(editor.drafts.isEmpty && editor.dirtyHostIDs.isEmpty)
        #expect(editor.layout(for: hostID).rows == [[.init(.pane)]])
    }

    private final class FetchState {
        var value: HerdrSidebarSnapshotStore.HostState?

        init(value: HerdrSidebarSnapshotStore.HostState?) {
            self.value = value
        }
    }
}
