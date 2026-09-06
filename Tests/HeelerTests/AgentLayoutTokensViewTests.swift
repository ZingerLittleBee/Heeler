import Foundation
import SwiftUI
import Testing

@testable import Heeler

@MainActor
@Suite("Agent layout tokens view")
struct AgentLayoutTokensViewTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suite = "tokens-view-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    private func makeEditor(defaults: UserDefaults) -> (AgentListFieldsEditor, AgentRowLayoutStore) {
        let layouts = AgentRowLayoutStore(defaults: defaults)
        let editor = AgentListFieldsEditor(
            layouts: layouts, snapshots: HerdrSidebarSnapshotStore(), fetch: { _ in nil })
        return (editor, layouts)
    }

    @Test func fourArgumentInitializerRemainsSourceCompatible() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (editor, _) = makeEditor(defaults: defaults)
        let hostID = UUID()
        _ = AgentLayoutTokensView(editor: editor, hostID: hostID, kind: nil, rowIndex: 0)
        _ = AgentLayoutTokensView(
            editor: editor, hostID: hostID, kind: "claude", rowIndex: 1, hostName: "Studio Mac")
    }

    @Test func pickerOmitsPresentTokensAndRejectsInvalidOrDuplicateCustomNames() {
        let present: AgentRow = [
            .init(.workspace), .init(.custom("pin_icon")), .init(.stateIcon),
        ]
        #expect(
            AgentLayoutTokensEditing.availableBuiltins(in: present)
                == AgentRowToken.builtins.filter { $0 != .workspace && $0 != .stateIcon })
        #expect(AgentLayoutTokensEditing.customToken(from: "$pin_icon", alreadyIn: []) == .custom("pin_icon"))
        #expect(AgentLayoutTokensEditing.customToken(from: "$pin_icon", alreadyIn: present) == nil)
        #expect(AgentLayoutTokensEditing.customToken(from: "workspace", alreadyIn: []) == nil)
        #expect(AgentLayoutTokensEditing.customToken(from: "$", alreadyIn: []) == nil)
        #expect(AgentLayoutTokensEditing.customToken(from: "$a b", alreadyIn: []) == nil)
        let sixteen = (0..<AgentRowLayout.maximumTokensPerRow).map {
            AgentRowStyledToken(.custom("t\($0)"))
        }
        #expect(
            AgentLayoutTokensEditing.canAddField(to: sixteen, rows: [sixteen], rowIndex: 0) == false)
        #expect(AgentLayoutTokensEditing.canAddField(to: present, rows: [present], rowIndex: 0))
        #expect(AgentLayoutTokensEditing.canAddField(to: present, rows: [present], rowIndex: 1) == false)
    }

    @Test func defaultClearsDimAndSecondarySetsTrueWithoutTouchingOtherStyle() throws {
        let colored = try #require(HexColor("#abc"))
        let secondary = AgentRowStyledToken(.workspace, fg: colored, bold: false, dim: true)
        let cleared = AgentLayoutTokensEditing.applying(.default, to: secondary)
        #expect(cleared.token == .workspace)
        #expect(cleared.fg == colored)
        #expect(cleared.bold == false)
        #expect(cleared.dim == nil)
        let promoted = AgentLayoutTokensEditing.applying(
            .secondary, to: AgentRowStyledToken(.custom("pin_icon"), fg: colored, bold: true))
        #expect(promoted.token == .custom("pin_icon"))
        #expect(promoted.fg == colored && promoted.bold == true && promoted.dim == true)
        #expect(AgentLayoutTokensEditing.style(of: secondary) == .secondary)
        #expect(AgentLayoutTokensEditing.style(of: cleared) == .default)
        #expect(
            AgentLayoutTokensEditing.style(of: AgentRowStyledToken(.agent, dim: false)) == .default)
    }

    @Test func subtitleAndStatusDescriptionsMatchHostKindAndStatusColumn() {
        #expect(AgentLayoutTokensEditing.navigationSubtitle(hostName: "Studio Mac", kind: nil) == "Studio Mac")
        #expect(
            AgentLayoutTokensEditing.navigationSubtitle(hostName: "Studio Mac", kind: "claude")
                == "Studio Mac · claude override")
        #expect(AgentLayoutTokensEditing.navigationSubtitle(hostName: "", kind: "claude") == "claude override")
        #expect(AgentLayoutTokensEditing.navigationSubtitle(hostName: "", kind: nil).isEmpty)
        let statusIcon = AgentLayoutTokensEditing.description(for: .stateIcon)
        let statusText = AgentLayoutTokensEditing.description(for: .stateText)
        #expect(statusIcon.contains("status column"))
        #expect(statusText.contains("status column"))
        #expect(AgentLayoutTokensEditing.description(for: .workspace) == "Workspace or repo folder name")
    }

    @Test func mutationsStayInTheDraftAndTargetOnlyThatHostAndKind() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (editor, layouts) = makeEditor(defaults: defaults)
        let hostID = UUID(), otherID = UUID()
        let colored = try #require(HexColor("#abc"))
        editor.beginEditing()
        editor.setRows(
            [[
                .init(.workspace, fg: colored, bold: false, dim: true),
                .init(.custom("pin_icon")),
                .init(.agent),
            ]],
            kind: nil, for: hostID)
        editor.setRows([[.init(.pane)]], kind: "claude", for: hostID)
        editor.setRows([[.init(.tab)]], kind: nil, for: otherID)

        #expect(AgentLayoutTokensEditing.add(
            .terminalTitle, editor: editor, hostID: hostID, kind: nil, rowIndex: 0))
        #expect(AgentLayoutTokensEditing.add(
            .custom("build_status"), editor: editor, hostID: hostID, kind: nil, rowIndex: 0))
        #expect(
            AgentLayoutTokensEditing.add(.workspace, editor: editor, hostID: hostID, kind: nil, rowIndex: 0)
                == false)
        #expect(AgentLayoutTokensEditing.delete(
            IndexSet(integer: 2), editor: editor, hostID: hostID, kind: nil, rowIndex: 0))
        #expect(AgentLayoutTokensEditing.move(
            IndexSet(integer: 0), to: 3, editor: editor, hostID: hostID, kind: nil, rowIndex: 0))
        #expect(AgentLayoutTokensEditing.setStyle(
            .default, at: 2, editor: editor, hostID: hostID, kind: nil, rowIndex: 0))
        #expect(AgentLayoutTokensEditing.setStyle(
            .secondary, at: 0, editor: editor, hostID: hostID, kind: "claude", rowIndex: 0))

        let hostRow = editor.layout(for: hostID).rows[0]
        #expect(hostRow.map(\.token) == [.custom("pin_icon"), .terminalTitle, .workspace, .custom("build_status")])
        #expect(hostRow[0].token == .custom("pin_icon"))
        #expect(hostRow[2].token == .workspace && hostRow[2].fg == colored && hostRow[2].bold == false)
        #expect(hostRow[2].dim == nil)
        #expect(hostRow[1].dim == nil && hostRow[3].dim == nil)
        #expect(editor.layout(for: hostID).rowsByAgent["claude"] == [[.init(.pane, dim: true)]])
        #expect(editor.layout(for: otherID).rows == [[.init(.tab)]])
        #expect(layouts.hostLayouts.isEmpty)

        editor.save()
        #expect(layouts.hostLayouts[hostID]?.rows == [hostRow])
        #expect(layouts.hostLayouts[hostID]?.rowsByAgent["claude"] == [[.init(.pane, dim: true)]])
        #expect(layouts.hostLayouts[otherID]?.rows == [[.init(.tab)]])
    }

    @Test func staleIndexReadOnlyAndCapacityGuardsNeverRetargetAnotherRow() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (editor, layouts) = makeEditor(defaults: defaults)
        let hostID = UUID()
        let twoRows: [AgentRow] = [[.init(.workspace), .init(.agent)], [.init(.pane)]]
        editor.setRows(twoRows, kind: nil, for: hostID)
        editor.setRows([[.init(.tab)]], kind: "claude", for: hostID)
        #expect(
            AgentLayoutTokensEditing.add(.terminalTitle, editor: editor, hostID: hostID, kind: nil, rowIndex: 0)
                == false)
        #expect(editor.drafts.isEmpty && layouts.hostLayouts.isEmpty)

        editor.beginEditing()
        editor.setRows(twoRows, kind: nil, for: hostID)
        editor.setRows([[.init(.tab)]], kind: "claude", for: hostID)
        let before = editor.layout(for: hostID)

        #expect(
            AgentLayoutTokensEditing.add(.terminalTitle, editor: editor, hostID: hostID, kind: nil, rowIndex: 2)
                == false)
        #expect(
            AgentLayoutTokensEditing.add(.terminalTitle, editor: editor, hostID: hostID, kind: "codex", rowIndex: 0)
                == false)
        #expect(
            AgentLayoutTokensEditing.delete(
                IndexSet(integer: 0), editor: editor, hostID: hostID, kind: nil, rowIndex: 5)
                == false)
        #expect(
            AgentLayoutTokensEditing.move(
                IndexSet(integer: 0), to: 1, editor: editor, hostID: hostID, kind: nil, rowIndex: 2)
                == false)
        #expect(
            AgentLayoutTokensEditing.setStyle(
                .secondary, at: 0, editor: editor, hostID: hostID, kind: nil, rowIndex: 2)
                == false)
        #expect(editor.layout(for: hostID) == before)
        #expect(editor.layout(for: hostID).rowsByAgent["codex"] == nil)

        let sixteen = (0..<AgentRowLayout.maximumTokensPerRow).map {
            AgentRowStyledToken(.custom("t\($0)"))
        }
        editor.setRows([sixteen, [.init(.pane)]], kind: nil, for: hostID)
        #expect(
            AgentLayoutTokensEditing.add(.workspace, editor: editor, hostID: hostID, kind: nil, rowIndex: 0)
                == false)
        #expect(editor.layout(for: hostID).rows[0].count == AgentRowLayout.maximumTokensPerRow)
        #expect(editor.layout(for: hostID).rows[1] == [.init(.pane)])
        #expect(layouts.hostLayouts.isEmpty)
    }
}
