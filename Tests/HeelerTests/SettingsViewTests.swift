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
