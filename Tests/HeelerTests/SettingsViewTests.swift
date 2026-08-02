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
}
