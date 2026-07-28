import Testing

@testable import HerdrMobile

@Suite("Settings view")
struct SettingsViewTests {
    @Test func repositoryLinkTargetsTheProject() throws {
        let repositoryURL = try #require(SettingsView.repositoryURL)

        #expect(
            repositoryURL.absoluteString
                == "https://github.com/ZingerLittleBee/herdr-mobile")
    }
}
