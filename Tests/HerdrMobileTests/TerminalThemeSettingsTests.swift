import Foundation
import SwiftUI
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

    /// The chrome around the terminal (safe areas, transparent bar region) is
    /// painted with the theme's own background, so the surface colour must
    /// resolve from the catalog — not fall back to systemBackground.
    @Test func surfaceBackgroundResolvesFromTheThemeCatalog() {
        #expect(
            TerminalThemeOption.tokyoNight.surfaceBackground(for: .dark)
                == Color(hex: "1a1b26"))
        #expect(
            TerminalThemeOption.tokyoNight.surfaceBackground(for: .light)
                == Color(hex: "e1e2e7"))
        // Follow System maps to libghostty's default pair, which the catalog
        // carries under its own names (TerminalTheme+Defaults).
        #expect(
            TerminalThemeOption.followSystem.surfaceBackground(for: .light)
                == Color(hex: "f7f7f7"))
        #expect(
            TerminalThemeOption.followSystem.surfaceBackground(for: .dark)
                == Color(hex: "212121"))
    }

    /// Chrome legibility follows the theme's luminance, not the system
    /// appearance: Dracula stays dark in Light Mode, so its bar titles and
    /// status-bar text must stay light there too.
    @Test func chromeSchemeFollowsThemeLuminanceNotSystemAppearance() {
        #expect(TerminalThemeOption.dracula.chromeColorScheme(for: .light) == .dark)
        #expect(TerminalThemeOption.dracula.chromeColorScheme(for: .dark) == .dark)
        #expect(TerminalThemeOption.solarized.chromeColorScheme(for: .light) == .light)
        #expect(TerminalThemeOption.solarized.chromeColorScheme(for: .dark) == .dark)
        #expect(TerminalThemeOption.followSystem.chromeColorScheme(for: .light) == .light)
        #expect(TerminalThemeOption.followSystem.chromeColorScheme(for: .dark) == .dark)
    }

    /// Every option must yield a catalog-backed surface for both appearances;
    /// a silent fallback to systemBackground would reintroduce the black
    /// bands around the terminal for that theme.
    @Test(arguments: TerminalThemeOption.allCases)
    func everyThemeResolvesACatalogSurface(option: TerminalThemeOption) {
        for scheme in [ColorScheme.light, .dark] {
            #expect(option.surfaceBackground(for: scheme) != Color(uiColor: .systemBackground))
        }
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
