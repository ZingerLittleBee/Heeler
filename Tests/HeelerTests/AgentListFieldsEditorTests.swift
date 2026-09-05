import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent List Fields editor")
struct AgentListFieldsEditorTests {
    @Test func editsPreserveWholeLayoutStylesKindOverridesAndEmptyRows() async throws {
        let suite = "sidebar-editor-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layouts = AgentRowLayoutStore(defaults: defaults)
        let snapshots = HerdrSidebarSnapshotStore()
        let hostID = UUID()
        let transport = ScriptedTransport()
        let data = Data(##"{"v":1,"sidebar":{"agents":{"row_gap":2,"rows":[[{"token":"workspace","fg":"#abc","bold":false,"dim":true}]],"rows_by_agent":{"claude":[[{"token":"terminal_title_stripped"}]]}}}}"##.utf8)
        let decoded = try #require(AgentRowLayoutSnapshot.decode(data))
        #expect(decoded.layout.rowGap == 2)
        await transport.setSidebarLayout(data)
        snapshots.reconcile([hostID: .init(generation: 1, revision: 0)],
                            transports: ScriptedTransportProvider(transports: [hostID: transport]), didChange: {})
        await snapshots.waitForPendingReads()
        let editor = AgentListFieldsEditor(layouts: layouts, snapshots: snapshots)
        editor.hostID = hostID
        #expect(snapshots.snapshot(for: hostID) == decoded)
        let inherited = editor.layout
        editor.setRows(inherited.rows + [[]], kind: nil)
        #expect(layouts.hostLayouts[hostID]?.rows == inherited.rows + [[]])
        #expect(editor.layout.rowsByAgent == inherited.rowsByAgent)
        #expect(editor.layout.rowGap == 2)
        #expect(editor.layout.rows[0][0].fg == HexColor("#abc"))
        #expect(editor.layout.rows[0][0].bold == false && editor.layout.rows[0][0].dim == true)
        editor.setRows([[.init(.custom("build_status"))], []], kind: "claude")
        #expect(editor.layout.rowsByAgent["claude"] == [[.init(.custom("build_status"))], []])
        editor.setRows([], kind: nil)
        #expect(editor.layout.rows.isEmpty)
        let reloaded = AgentRowLayoutStore(defaults: defaults)
        #expect(reloaded.hostLayouts[hostID] == editor.layout)
        editor.reset()
        #expect(editor.layout == inherited)
        #expect(layouts.hostLayouts[hostID] == nil)
    }

    @Test func globalAndHostResetsRestoreTheCorrectInheritance() throws {
        let suite = "sidebar-editor-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layouts = AgentRowLayoutStore(defaults: defaults)
        let editor = AgentListFieldsEditor(layouts: layouts, snapshots: HerdrSidebarSnapshotStore())
        editor.setRows([[.init(.pane)]], kind: nil)
        let global = editor.layout
        let hostID = UUID()
        editor.hostID = hostID
        editor.setRows([], kind: nil)
        #expect(layouts.globalLayout == global && editor.layout.rows.isEmpty)
        #expect(editor.resetTitle == "Use Global Layout")
        editor.reset()
        #expect(editor.layout == global)
        editor.hostID = nil
        #expect(editor.resetTitle == "Follow herdr")
        editor.reset()
        #expect(layouts.globalLayout == nil)
        #expect(editor.layout == .heelerDefault)
    }

    @Test func throwingWritesHaveVisibleFeedbackAndDoNotPublishPartialChanges() throws {
        let suite = "sidebar-editor-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layouts = AgentRowLayoutStore(defaults: defaults)
        let editor = AgentListFieldsEditor(layouts: layouts, snapshots: HerdrSidebarSnapshotStore())
        editor.setRows(Array(repeating: [], count: 17), kind: nil)
        #expect(editor.errorMessage != nil)
        #expect(layouts.globalLayout == nil)
        defaults.set(Data("unreadable".utf8), forKey: "agent-row-layouts")
        let broken = AgentListFieldsEditor(
            layouts: AgentRowLayoutStore(defaults: defaults), snapshots: HerdrSidebarSnapshotStore())
        broken.reset()
        #expect(broken.errorMessage?.contains("Nothing was changed") == true)
        #expect(defaults.data(forKey: "agent-row-layouts") == Data("unreadable".utf8))
    }
}
