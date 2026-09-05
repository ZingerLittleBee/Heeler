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
        #expect(editor.syncStates[offlineID]?.message?.contains("not connected") == true)
        #expect(editor.drafts[offlineID] == nil)

        await transport.setSidebarLayoutReadFailure(NotificationRegistrationError.pluginNotInstalled)
        await editor.syncFromPlugin(hostID)
        #expect(editor.syncStates[hostID]?.message?.contains("Nothing was changed") == true)
        #expect(editor.layout(for: hostID) == saved && editor.drafts[hostID] == nil)

        await transport.setSidebarLayoutReadFailure(nil)
        await editor.syncFromPlugin(hostID)
        #expect(editor.syncStates[hostID]?.message?.contains("fallback fields") == true)
        #expect(editor.layout(for: hostID) == .heelerDefault)

        await transport.setSidebarLayout(pluginData)
        await editor.syncFromPlugin(hostID)
        let plugin = try #require(AgentRowLayoutSnapshot.decode(pluginData)).layout
        #expect(editor.syncStates[hostID] == .filled("Filled from the herdr plugin. Save to keep these fields."))
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
        #expect(defaults.data(forKey: "agent-row-layouts") == Data("unreadable".utf8))
    }
}
