import Foundation
import SwiftUI
import Testing

@testable import Heeler

@MainActor
@Suite("Agent layout tokens editing")
struct AgentLayoutTokensEditingTests {
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
        #expect(AgentLayoutTokensEditing.customToken(from: "state_icon", alreadyIn: []) == nil)
        #expect(AgentLayoutTokensEditing.customToken(from: "agent", alreadyIn: []) == nil)
        #expect(AgentLayoutTokensEditing.customToken(from: "terminal_title", alreadyIn: []) == nil)
        #expect(AgentLayoutTokensEditing.customToken(from: "$", alreadyIn: []) == nil)
        #expect(AgentLayoutTokensEditing.customToken(from: "$a b", alreadyIn: []) == nil)
        let sixteen = (0..<AgentRowLayout.maximumTokensPerRow).map {
            AgentRowStyledToken(.custom("t\($0)"))
        }
        #expect(
            AgentLayoutTokensEditing.canAddField(to: sixteen, rows: [sixteen], rowIndex: 0) == false)
        #expect(AgentLayoutTokensEditing.canAddField(to: present, rows: [present], rowIndex: 0))
        #expect(AgentLayoutTokensEditing.canAddField(to: present, rows: [present], rowIndex: 1))
        #expect(AgentLayoutTokensEditing.canAddField(to: [], rows: [present], rowIndex: 3) == false)
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
        #expect(AgentLayoutTokenStyle.default.badge == nil)
        #expect(AgentLayoutTokenStyle.secondary.badge == "Secondary")
        #expect(AgentLayoutTokenStyle.default.toggled == .secondary)
        #expect(AgentLayoutTokenStyle.secondary.toggled == .default)
        #expect(AgentLayoutTokenStyle.default.toggleActionTitle == "Secondary Style")
        #expect(AgentLayoutTokenStyle.secondary.toggleActionTitle == "Default Style")
        #expect(
            AgentLayoutTokensEditing.style(of: AgentRowStyledToken(.agent, dim: false)) == .default)
    }

    @Test func subtitleAndStatusDescriptionsMatchHostKindAndStatusColumn() {
        #expect(AgentLayoutTokensEditing.navigationSubtitle(hostName: "Studio Mac") == "Studio Mac")
        #expect(AgentLayoutTokensEditing.navigationSubtitle(hostName: "").isEmpty)
        let statusIcon = AgentLayoutTokensEditing.description(for: .stateIcon)
        let statusText = AgentLayoutTokensEditing.description(for: .stateText)
        #expect(statusIcon.contains("status column"))
        #expect(statusText.contains("status column"))
        #expect(AgentLayoutTokensEditing.description(for: .workspace) == "Workspace or repo folder name")
        #expect(AgentLayoutTokensEditing.description(for: .host) == "Host name")
        #expect(AgentLayoutTokensEditing.description(for: .status) == "Agent Status as text")
        #expect(AgentLayoutTokensEditing.description(for: .directory) == "Working directory")
        #expect(
            AgentLayoutTokensEditing.availableBuiltins(in: [], from: AgentRowToken.heelerBuiltins)
                == [.host, .status, .directory])
        #expect(
            AgentLayoutTokensEditing.availableBuiltins(
                in: [.init(.host)], from: AgentRowToken.heelerBuiltins)
                == [.status, .directory])
        #expect(AgentRowToken(rawValue: "host") == .host)
        #expect(AgentRowToken(rawValue: "status") == .status)
        #expect(AgentRowToken(rawValue: "directory") == .directory)
        #expect(AgentRowToken(rawValue: "$host") == .custom("host"))
    }

    @Test func mutationsPersistAtOnceAndTargetOnlyThatHostAndKind() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (editor, layouts) = makeEditor(defaults: defaults)
        let hostID = UUID(), otherID = UUID()
        let colored = try #require(HexColor("#abc"))
        try layouts.setLayouts([
            hostID: AgentRowLayout(
                rows: [[
                    .init(.workspace, fg: colored, bold: false, dim: true),
                    .init(.custom("pin_icon")),
                    .init(.agent),
                ]]),
            otherID: AgentRowLayout(rows: [[.init(.tab)]]),
        ])

        #expect(AgentLayoutTokensEditing.add(
            .terminalTitle, editor: editor, hostID: hostID, rowIndex: 0))
        #expect(AgentLayoutTokensEditing.add(
            .custom("build_status"), editor: editor, hostID: hostID, rowIndex: 0))
        #expect(
            AgentLayoutTokensEditing.add(.workspace, editor: editor, hostID: hostID, rowIndex: 0)
                == false)
        #expect(AgentLayoutTokensEditing.delete(
            IndexSet(integer: 2), editor: editor, hostID: hostID, rowIndex: 0))
        #expect(AgentLayoutTokensEditing.move(
            IndexSet(integer: 0), to: 3, editor: editor, hostID: hostID, rowIndex: 0))
        #expect(AgentLayoutTokensEditing.setStyle(
            .default, at: 2, editor: editor, hostID: hostID, rowIndex: 0))
        // Shift swaps neighbours; the ends stay put.
        #expect(AgentLayoutTokensEditing.shift(
            3, by: -1, editor: editor, hostID: hostID, rowIndex: 0))
        #expect(
            AgentLayoutTokensEditing.shift(0, by: -1, editor: editor, hostID: hostID, rowIndex: 0)
                == false)
        #expect(
            AgentLayoutTokensEditing.shift(3, by: 1, editor: editor, hostID: hostID, rowIndex: 0)
                == false)
        #expect(
            AgentLayoutTokensEditing.shift(1, by: 2, editor: editor, hostID: hostID, rowIndex: 0)
                == false)

        let saved = try #require(layouts.hostLayouts[hostID])
        let hostRow = saved.rows[0]
        #expect(hostRow.map(\.token) == [.custom("pin_icon"), .terminalTitle, .custom("build_status"), .workspace])
        #expect(hostRow[3].token == .workspace && hostRow[3].fg == colored && hostRow[3].bold == false)
        #expect(hostRow[3].dim == nil)
        #expect(hostRow[1].dim == nil && hostRow[2].dim == nil)
        #expect(layouts.hostLayouts[otherID]?.rows == [[.init(.tab)]])
        #expect(editor.layout(for: hostID) == saved)
        #expect(!editor.isEditing && editor.drafts.isEmpty)
    }

    @Test func firstInlineChangeOnAPluginHostSavesTheWholeLayoutAsItsOwn() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (editor, layouts) = makeEditor(defaults: defaults)
        let hostID = UUID()
        #expect(layouts.hostLayouts[hostID] == nil)
        #expect(editor.underlyingSource(for: hostID) == .unavailable)
        let before = editor.layout(for: hostID)
        #expect(before == .consoleDefault)

        #expect(AgentLayoutTokensEditing.add(.directory, editor: editor, hostID: hostID, rowIndex: 2))
        let saved = try #require(layouts.hostLayouts[hostID])
        #expect(saved.rows == before.rows + [[.init(.directory)]])
        #expect(saved.rowGap == before.rowGap && saved.rowsByAgent == before.rowsByAgent)
        #expect(editor.underlyingSource(for: hostID) == .saved)
    }

    @Test func staleIndexAndCapacityGuardsWriteNothing() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (editor, layouts) = makeEditor(defaults: defaults)
        let hostID = UUID()
        let twoRows: [AgentRow] = [[.init(.workspace), .init(.agent)], [.init(.pane)]]
        let before = AgentRowLayout(rows: twoRows, rowGap: 1)
        try layouts.setLayout(before, for: hostID)

        #expect(
            AgentLayoutTokensEditing.add(.terminalTitle, editor: editor, hostID: hostID, rowIndex: 3)
                == false)
        #expect(
            AgentLayoutTokensEditing.delete(
                IndexSet(integer: 0), editor: editor, hostID: hostID, rowIndex: 5)
                == false)
        #expect(
            AgentLayoutTokensEditing.move(
                IndexSet(integer: 0), to: 1, editor: editor, hostID: hostID, rowIndex: 3)
                == false)
        #expect(
            AgentLayoutTokensEditing.setStyle(
                .secondary, at: 0, editor: editor, hostID: hostID, rowIndex: 3)
                == false)
        #expect(layouts.hostLayouts[hostID] == before)
        #expect(!editor.isEditing && editor.errorMessage == nil)

        let sixteen = (0..<AgentRowLayout.maximumTokensPerRow).map {
            AgentRowStyledToken(.custom("t\($0)"))
        }
        try layouts.setLayout(AgentRowLayout(rows: [sixteen, [.init(.pane)]]), for: hostID)
        #expect(
            AgentLayoutTokensEditing.add(.workspace, editor: editor, hostID: hostID, rowIndex: 0)
                == false)
        #expect(layouts.hostLayouts[hostID]?.rows[0].count == AgentRowLayout.maximumTokensPerRow)
        #expect(layouts.hostLayouts[hostID]?.rows[1] == [.init(.pane)])
    }
}
