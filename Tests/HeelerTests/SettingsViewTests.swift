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

    @Test func settingsCopyStaysReadOnlyOutsideEditAndNamesNoStatusOnlyRow() {
        #expect(!AgentListFieldsCopy.rowSlots.localizedCaseInsensitiveContains("status only"))
        #expect(AgentListFieldsCopy.noHosts == "Add a Host to configure its Agent rows.")
        #expect(!AgentListFieldsCopy.listIntro.localizedCaseInsensitiveContains("edit"))
        #expect(AgentListFieldsCopy.listIntro.contains("Open a Host"))
        #expect(!AgentListFieldsCopy.detailIntro.localizedCaseInsensitiveContains("tap edit"))
        #expect(AgentListFieldsCopy.detailIntro.contains("save right away"))
        #expect(AgentListFieldsCopy.syncConfirmation.contains("saved right away"))
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

    @Test func destinationsAreKeyedByFixedSlotIndexAndHost() {
        let hostA = UUID(), hostB = UUID()
        let hostSlot = AgentListFieldsEditorDestination(hostID: hostA, rowIndex: 1)
        #expect(hostSlot == AgentListFieldsEditorDestination(hostID: hostA, rowIndex: 1))
        #expect(hostSlot != AgentListFieldsEditorDestination(hostID: hostA, rowIndex: 0))
        #expect(hostSlot != AgentListFieldsEditorDestination(hostID: hostB, rowIndex: 1))
        #expect(hostSlot.id != AgentListFieldsEditorDestination(hostID: hostB, rowIndex: 1).id)
    }

    @Test func rowSlotCopyNamesHerdrRowsAndHeelersRow() {
        #expect(AgentListFieldsCopy.rowSlots.contains("Row 1 and Row 2 start from herdr"))
        #expect(AgentListFieldsCopy.rowSlots.contains("Any row can use herdr and Heeler fields"))
        #expect(AgentListFieldsCopy.rowSlots.contains("status badge always ends Row 1"))
        #expect(AgentListFieldsRowLabel.emptyText(slot: .herdr) == "No fields")
        #expect(AgentListFieldsRowLabel.emptyText(slot: .heeler) == "Not configured")
        #expect(AgentListFieldsRowLabel.emptyText(slot: nil) == "No fields")
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
                == "Row 1, herdr row, Field 1 of 2: agent, default style, Field 2 of 2: workspace, secondary style")
        #expect(AgentListFieldsRowLabel.accessibilityLabel(index: 1, row: []) == "Row 2, herdr row, No fields")
        #expect(AgentListFieldsRowLabel.accessibilityLabel(index: 2, row: []) == "Row 3, Heeler row, Not configured")
    }
}
