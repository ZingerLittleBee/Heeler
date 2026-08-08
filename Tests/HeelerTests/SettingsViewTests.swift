import Testing

@testable import Heeler

@Suite("Settings view")
struct SettingsViewTests {
    @Test func repositoryLinkTargetsTheProject() throws {
        let repositoryURL = try #require(SettingsView.repositoryURL)

        #expect(
            repositoryURL.absoluteString
                == "https://github.com/ZingerLittleBee/Heeler")
    }

    @Test func acknowledgementsRouteIsOfferedUnderAboutByIdentity() {
        // Deleting the Acknowledgements NavigationLink means removing
        // `.acknowledgements` from `aboutRows`; a decoy row cannot keep this
        // green because only that case carries the route id (#161).
        #expect(SettingsView.aboutRows.contains(.acknowledgements))
        #expect(
            SettingsView.AboutRow.acknowledgements.id
                == SettingsView.acknowledgementsRouteID)
    }
}
