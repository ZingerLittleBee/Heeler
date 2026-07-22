import Foundation
import Testing

@testable import HerdrMobile

@MainActor
@Suite("Terminal theme settings")
struct TerminalThemeSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-terminal-theme-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func defaultsToFollowingTheSystem() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        #expect(TerminalThemeSettings(defaults: defaults).selection == .followSystem)
    }

    @Test func selectionPersistsAcrossStoreInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = TerminalThemeSettings(defaults: defaults)

        settings.select(.dracula)

        #expect(TerminalThemeSettings(defaults: defaults).selection == .dracula)
    }

    @Test func unknownPersistedSelectionFallsBackToTheSystem() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set("removed-theme", forKey: "terminal-theme")

        #expect(TerminalThemeSettings(defaults: defaults).selection == .followSystem)
    }

    @Test func curatedCatalogEntriesExistInThePinnedPackage() {
        #expect(TerminalThemeOption.missingCatalogThemeNames.isEmpty)
    }

    @Test func changingThemeKeepsTheExistingTerminalSession() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        let session = terminal.terminalSession
        let theme = TerminalThemeOption.vesper.terminalTheme

        #expect(terminal.applyTheme(theme))
        #expect(terminal.appliedTheme == theme)
        #expect(terminal.terminalSession === session)
    }
}
