import Foundation
import Testing

@testable import Heeler

@Suite("Settings view")
struct SettingsViewTests {
    @Test func agentListRouteConstructsTheFieldsEditor() {
        let destination = SettingsView.agentListDestination
        #expect(destination.rawValue == "settings.agentList.fields")
        #expect(destination.destinationTypeName == String(reflecting: AgentListFieldsSettingsView.self))
        #expect(ConsoleListPresentationMode.flat.title == "All Agents")
    }

    @Test func repositoryLinkTargetsTheProject() throws {
        let repositoryURL = try #require(SettingsView.repositoryURL)

        #expect(
            repositoryURL.absoluteString
                == "https://github.com/ZingerLittleBee/Heeler")
    }

    @Test func acknowledgementsRouteIsOfferedUnderAboutByIdentity() throws {
        // Identity alone is not enough (#161 review finding 1): the row must
        // also map to AcknowledgementsView through the shared destination seam.
        #expect(SettingsView.aboutRows.contains(.acknowledgements))
        #expect(
            SettingsView.AboutRow.acknowledgements.id
                == SettingsView.acknowledgementsRouteID)
        let destination = try #require(
            SettingsView.aboutDestination(for: .acknowledgements))
        #expect(destination.rawValue == SettingsView.acknowledgementsRouteID)
        #expect(
            destination.destinationTypeName
                == String(reflecting: AcknowledgementsView.self))
    }
}

@MainActor
@Suite("Agent list fields settings")
struct AgentListFieldsSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suite = "agent-list-fields-settings-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func sourceCaptionsCoverTheSixUnderlyingSourcesAndIgnoreDraft() throws {
        #expect(AgentListFieldsSourceCaption.text(.saved) == "Your fields")
        #expect(AgentListFieldsSourceCaption.text(.plugin) == "Following herdr plugin")
        #expect(
            AgentListFieldsSourceCaption.text(.pluginDefaults)
                == "herdr default fields (plugin reported a problem)")
        #expect(AgentListFieldsSourceCaption.text(.loading) == "Reading herdr fields…")
        #expect(AgentListFieldsSourceCaption.text(.missing) == "No herdr fields snapshot")
        #expect(AgentListFieldsSourceCaption.text(.unavailable) == "herdr fields unavailable")

        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()
        let editor = AgentListFieldsEditor(
            layouts: AgentRowLayoutStore(defaults: defaults),
            snapshots: HerdrSidebarSnapshotStore(), fetch: { _ in nil })
        #expect(editor.underlyingSource(for: hostID) == .unavailable)
        editor.beginEditing()
        editor.setRows([[.init(.pane)]], kind: nil, for: hostID)
        #expect(editor.source(for: hostID) == .draft)
        #expect(
            AgentListFieldsSourceCaption.text(editor.underlyingSource(for: hostID))
                == "herdr fields unavailable")
        editor.save()
        #expect(editor.underlyingSource(for: hostID) == .saved)
        #expect(AgentListFieldsSourceCaption.text(editor.underlyingSource(for: hostID)) == "Your fields")
    }

    @Test func savedBannerAppearsOnlyAfterASuccessfulDirtySave() {
        #expect(
            AgentListFieldsSessionStatus.current(
                isEditing: true, isDirty: true, didSucceedSave: false) == .unsaved)
        #expect(
            AgentListFieldsSessionStatus.current(
                isEditing: true, isDirty: false, didSucceedSave: false) == nil)
        #expect(
            AgentListFieldsSessionStatus.current(
                isEditing: false, isDirty: false, didSucceedSave: true) == .saved)
        #expect(
            AgentListFieldsSessionStatus.current(
                isEditing: false, isDirty: false, didSucceedSave: false) == nil)
        #expect(
            AgentListFieldsSessionStatus.current(
                isEditing: true, isDirty: true, didSucceedSave: true) == .unsaved)
    }

    @Test func emptyRowCopyMatchesTheConsoleNameFallbackNotStatusOnly() {
        #expect(AgentListFieldsCopy.emptyRows == "No rows. Console shows the Agent name.")
        #expect(!AgentListFieldsCopy.emptyRows.localizedCaseInsensitiveContains("status only"))
        #expect(AgentListFieldsCopy.noHosts == "Add a Host to configure its Agent rows.")
        #expect(
            AgentListFieldsCopy.noOverrides
                == "No overrides. Every Agent uses the rows above.")
        #expect(!AgentListFieldsCopy.listIntro.localizedCaseInsensitiveContains("edit"))
        #expect(AgentListFieldsCopy.listIntro.contains("Open a Host"))
        #expect(AgentListFieldsCopy.detailIntro == "Tap Edit to change this Host's rows.")
        #expect(AgentListFieldsCopy.editingIntro.contains("this Host's draft"))
    }

    @Test func hostHeaderLabelOmitsUnsavedLanguage() {
        let label = AgentListFieldsHostHeader.accessibilityLabel(
            name: "Studio Mac", caption: "Following herdr plugin")
        #expect(label == "Studio Mac, Following herdr plugin")
        #expect(!label.localizedCaseInsensitiveContains("unsaved"))
        #expect(!label.localizedCaseInsensitiveContains("collapsed"))
        #expect(!label.localizedCaseInsensitiveContains("expanded"))
        #expect(
            AgentListFieldsHostHeader.accessibilityLabel(
                name: "Build Server", caption: "Your fields")
                == "Build Server, Your fields")
    }

    @Test func otherValidationTrimsAndRejectsEmptyAndCaseInsensitiveDuplicates() {
        #expect(AgentListFieldsOverrideProposal.validate("", existing: ["claude"]) == .empty)
        #expect(AgentListFieldsOverrideProposal.validate("   ", existing: []) == .empty)
        #expect(AgentListFieldsOverrideProposal.validate("", existing: []).message == "Enter an Agent kind.")
        #expect(
            AgentListFieldsOverrideProposal.validate("CLAUDE", existing: ["claude"])
                == .duplicate("claude"))
        #expect(
            AgentListFieldsOverrideProposal.validate("claude", existing: ["Claude"])
                == .duplicate("Claude"))
        #expect(
            AgentListFieldsOverrideProposal.validate("CLAUDE", existing: ["claude"]).message
                == "This Host already has a CLAUDE override.")
        #expect(AgentListFieldsOverrideProposal.validate("  Grok ", existing: ["claude"]) == .valid("Grok"))
        #expect(AgentListFieldsOverrideProposal.validate("codex", existing: ["claude"]) == .valid("codex"))
    }

    @Test func addOverrideMenuUsesSeenKindsAndOmitsExistingCaseInsensitively() {
        let seen = ["claude", "codex", "grok", "claude", " Codex "]
        #expect(
            AgentListFieldsOverrideProposal.menuKinds(seen: seen, existing: ["Claude"])
                == ["codex", "grok"])
        #expect(
            AgentListFieldsOverrideProposal.menuKinds(seen: ["codex", "claude"], existing: [])
                == ["claude", "codex"])
        #expect(AgentListFieldsOverrideProposal.menuKinds(seen: ["", "  "], existing: []) == [])
    }

    @Test func deletingARowDoesNotRetargetALaterDestination() {
        let presentation = AgentListFieldsPresentation()
        let hostID = UUID()
        presentation.replace(
            hostID,
            layout: AgentRowLayout(rows: [[.init(.workspace)], [.init(.agent)], [.init(.pane)]]))
        let ids = presentation.hostRowIDs(hostID)
        let second = AgentListFieldsEditorDestination(rowID: ids[1], hostID: hostID, kind: nil)
        #expect(presentation.rowIndex(for: second) == 1)

        presentation.deleteHostRows(hostID, at: IndexSet(integer: 0))
        #expect(presentation.rowIndex(for: second) == 0)

        presentation.deleteHostRows(hostID, at: IndexSet(integer: 0))
        #expect(presentation.rowIndex(for: second) == nil)
        #expect(presentation.hostRowIDs(hostID).count == 1)
    }

    @Test func movingARowKeepsTheDestinationBoundToTheSameToken() {
        let presentation = AgentListFieldsPresentation()
        let hostID = UUID()
        presentation.replace(
            hostID, layout: AgentRowLayout(rows: [[.init(.workspace)], [.init(.agent)]]))
        let ids = presentation.hostRowIDs(hostID)
        let first = AgentListFieldsEditorDestination(rowID: ids[0], hostID: hostID, kind: nil)
        let second = AgentListFieldsEditorDestination(rowID: ids[1], hostID: hostID, kind: nil)
        presentation.moveHostRows(hostID, from: IndexSet(integer: 1), to: 0)
        #expect(presentation.rowIndex(for: second) == 0)
        #expect(presentation.rowIndex(for: first) == 1)
    }

    @Test func syncReplacementInvalidatesOnlyThatHost() {
        let presentation = AgentListFieldsPresentation()
        let hostA = UUID()
        let hostB = UUID()
        let layout = AgentRowLayout(rows: [[.init(.workspace)]])
        presentation.replace(hostA, layout: layout)
        presentation.replace(hostB, layout: layout)
        let destA = AgentListFieldsEditorDestination(
            rowID: presentation.hostRowIDs(hostA)[0], hostID: hostA, kind: nil)
        let destB = AgentListFieldsEditorDestination(
            rowID: presentation.hostRowIDs(hostB)[0], hostID: hostB, kind: nil)

        presentation.replace(hostA, layout: AgentRowLayout(rows: [[.init(.agent)]]))
        #expect(presentation.rowIndex(for: destA) == nil)
        #expect(presentation.rowIndex(for: destB) == 0)
    }

    @Test func overrideRowsDoNotShareIdentityWithHostRowsOrAnotherHost() {
        let presentation = AgentListFieldsPresentation()
        let hostA = UUID()
        let hostB = UUID()
        let layout = AgentRowLayout(
            rows: [[.init(.workspace)], [.init(.agent)]],
            rowsByAgent: ["claude": [[.init(.pane)], [.init(.tab)]]])
        presentation.replace(hostA, layout: layout)
        presentation.replace(hostB, layout: layout)

        let aOverride = presentation.overrides(for: hostA)[0]
        let dest = AgentListFieldsEditorDestination(
            rowID: aOverride.rowIDs[0], hostID: hostA, kind: "claude")
        #expect(presentation.rowIndex(for: dest) == 0)
        #expect(
            presentation.rowIndex(
                for: AgentListFieldsEditorDestination(
                    rowID: aOverride.rowIDs[0], hostID: hostA, kind: nil)) == nil)
        #expect(
            presentation.rowIndex(
                for: AgentListFieldsEditorDestination(
                    rowID: aOverride.rowIDs[0], hostID: hostB, kind: "claude")) == nil)

        presentation.deleteOverrideRows(hostID: hostA, kind: "claude", at: IndexSet(integer: 0))
        #expect(presentation.rowIndex(for: dest) == nil)
        #expect(presentation.overrides(for: hostA)[0].rowIDs.count == 1)
        #expect(presentation.overrides(for: hostB)[0].rowIDs.count == 2)
        #expect(presentation.hostRowIDs(hostA).count == 2)
    }

    @Test func ensureKeepsTokensWhenOnlyRowContentChanges() {
        let presentation = AgentListFieldsPresentation()
        let hostID = UUID()
        presentation.replace(hostID, layout: AgentRowLayout(rows: [[.init(.workspace)]]))
        let id = presentation.hostRowIDs(hostID)[0]
        presentation.ensure(hostID, layout: AgentRowLayout(rows: [[.init(.agent)]]))
        #expect(presentation.hostRowIDs(hostID) == [id])
        presentation.ensure(
            hostID, layout: AgentRowLayout(rows: [[.init(.agent)], [.init(.pane)]]))
        #expect(presentation.hostRowIDs(hostID) != [id])
        #expect(presentation.hostRowIDs(hostID).count == 2)
    }

    @Test func overrideSeedCreatesDistinctRowTokens() {
        let presentation = AgentListFieldsPresentation()
        let hostID = UUID()
        presentation.replace(
            hostID, layout: AgentRowLayout(rows: [[.init(.workspace)], [.init(.agent)]]))
        let hostIDs = Set(presentation.hostRowIDs(hostID))
        let overrideID = presentation.addOverride(hostID: hostID, kind: "claude", rowCount: 2)
        let override = presentation.overrides(for: hostID)[0]
        #expect(override.id == overrideID)
        #expect(override.kind == "claude")
        #expect(override.rowIDs.count == 2)
        #expect(Set(override.rowIDs).isDisjoint(with: hostIDs))
    }

    @Test func chipLabelsUseDimAsSecondaryAndIgnoreForegroundAndBold() throws {
        let dim = AgentRowStyledToken(.workspace, fg: HexColor("#abc"), bold: true, dim: true)
        let plain = AgentRowStyledToken(.agent, fg: HexColor("#abc"), bold: true, dim: false)
        let unset = AgentRowStyledToken(.pane)
        #expect(
            AgentListFieldsChipLabel.text(index: 0, count: 2, token: dim)
                == "Field 1 of 2: workspace, secondary style")
        #expect(
            AgentListFieldsChipLabel.text(index: 1, count: 2, token: plain)
                == "Field 2 of 2: agent, default style")
        #expect(
            AgentListFieldsChipLabel.text(index: 0, count: 1, token: unset)
                == "Field 1 of 1: pane, default style")
        #expect(
            AgentListFieldsRowLabel.accessibilityLabel(index: 0, row: [plain, dim])
                == "Row 1, Field 1 of 2: agent, default style, Field 2 of 2: workspace, secondary style")
        #expect(AgentListFieldsRowLabel.accessibilityLabel(index: 2, row: []) == "Row 3, No fields yet")
    }

    @Test func pendingSyncBlocksFieldEditorNavigation() {
        #expect(AgentListFieldsRowNavigation.canOpenFieldEditor(isSyncing: false))
        #expect(!AgentListFieldsRowNavigation.canOpenFieldEditor(isSyncing: true))
    }

    @Test func accessibilityMoveDestinationsMatchListMoveOffsets() throws {
        #expect(AgentListFieldsRowOrder.moveUpDestination(index: 0) == nil)
        #expect(AgentListFieldsRowOrder.moveUpDestination(index: 2) == 1)
        #expect(AgentListFieldsRowOrder.moveDownDestination(index: 2, count: 3) == nil)
        #expect(AgentListFieldsRowOrder.moveDownDestination(index: 0, count: 3) == 2)
        var rows = ["a", "b", "c"]
        rows.move(
            fromOffsets: IndexSet(integer: 0),
            toOffset: try #require(AgentListFieldsRowOrder.moveDownDestination(index: 0, count: 3)))
        #expect(rows == ["b", "a", "c"])
    }
}
