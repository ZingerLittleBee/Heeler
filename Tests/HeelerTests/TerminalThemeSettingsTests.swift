import Foundation
import GhosttyTerminal
import GhosttyTheme
import SwiftUI
import Testing

@testable import Heeler

@MainActor
@Suite("Terminal theme settings")
struct TerminalThemeSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-terminal-theme-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func defaultsBothAppearancesToVesper() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = TerminalThemeSettings(defaults: defaults)

        #expect(settings.lightSelection == .vesper)
        #expect(settings.darkSelection == .vesper)
        #expect(settings.terminalTheme(for: .light) == Self.showing(.vesper, isDark: false))
        #expect(settings.terminalTheme(for: .dark) == Self.showing(.vesper, isDark: true))
    }

    /// Pre-slot releases persisted one selection; it must seed both slots so
    /// the rendered pair survives the upgrade unchanged.
    @Test func legacySingleSelectionSeedsBothSlots() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set("tokyo-night", forKey: "terminal-theme")
        let settings = TerminalThemeSettings(defaults: defaults)

        #expect(settings.lightSelection == .tokyoNight)
        #expect(settings.darkSelection == .tokyoNight)
        #expect(settings.terminalTheme(for: .light) == Self.showing(.tokyoNight, isDark: false))
    }

    /// A terminal shows its appearance's slot whichever appearance it is
    /// drawn in: a dark theme for Light Mode darkens the app, and the
    /// terminal must still show the Light Mode slot.
    @Test func eachAppearanceShowsItsSlotInBothHalves() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = TerminalThemeSettings(defaults: defaults)

        settings.select(.solarized, for: .light)
        settings.select(.tokyoNight, for: .dark)

        #expect(settings.terminalTheme(for: .light) == Self.showing(.solarized, isDark: false))
        #expect(settings.terminalTheme(for: .dark) == Self.showing(.tokyoNight, isDark: true))
    }

    private static func showing(_ option: TerminalThemeOption, isDark: Bool) -> TerminalTheme {
        let configuration = option.configuration(isDark: isDark)
        return TerminalTheme(light: configuration, dark: configuration)
    }

    /// A herdr-core attach reports `#rrggbb`, and the catalog writes colors
    /// however its source did.
    @Test func reportedColorsAreInTheFormACoreTakes() {
        let written = TerminalThemeColors(
            GhosttyThemeDefinition(
                name: "Written", background: "282A36", foreground: " #F8F8F2 ", cursorColor: "ff0000"))
        #expect(written.background == "#282a36")
        #expect(written.foreground == "#f8f8f2")
        #expect(written.cursor == "#ff0000")

        let unusable = TerminalThemeColors(
            GhosttyThemeDefinition(name: "Unusable", background: "fff", foreground: "zzzzzz"))
        #expect(unusable.background == nil)
        #expect(unusable.foreground == nil)
        #expect(unusable.cursor == nil)
    }

    @Test func everyThemeReportsBothColorsInEitherAppearance() throws {
        let isColor = /#[0-9a-f]{6}/
        for option in TerminalThemeOption.allCases {
            for isDark in [false, true] {
                let colors = try #require(option.colors(isDark: isDark), "\(option)")
                #expect(try isColor.wholeMatch(in: try #require(colors.foreground)) != nil, "\(option)")
                #expect(try isColor.wholeMatch(in: try #require(colors.background)) != nil, "\(option)")
            }
        }
    }

    @Test func reportedColorsComeFromTheSlotOfTheAppearance() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = TerminalThemeSettings(defaults: defaults)

        settings.select(.tokyoNight, for: .light)
        settings.select(.zenburn, for: .dark)

        #expect(settings.colors(for: .light)?.background == "#e1e2e7")
        #expect(settings.colors(for: .dark)?.background == "#3f3f3f")
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

        settings.select(.dracula, for: .dark)

        let reloaded = TerminalThemeSettings(defaults: defaults)
        #expect(reloaded.darkSelection == .dracula)
        #expect(reloaded.lightSelection == .vesper)
    }

    @Test func unknownPersistedSelectionFallsBackToVesper() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set("removed-theme", forKey: "terminal-theme")
        defaults.set("removed-theme", forKey: "terminal-theme-light")
        defaults.set("removed-theme", forKey: "terminal-theme-dark")
        let settings = TerminalThemeSettings(defaults: defaults)

        #expect(settings.lightSelection == .vesper)
        #expect(settings.darkSelection == .vesper)
    }

    @Test func curatedCatalogEntriesExistInThePinnedPackage() {
        #expect(TerminalThemeOption.missingCatalogThemeNames.isEmpty)
    }

    @Test func changingThemeKeepsTheExistingTerminalSession() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        let session = terminal.terminalSession
        let theme = Self.showing(.vesper, isDark: false)

        #expect(terminal.applyTheme(theme))
        #expect(terminal.appliedTheme == theme)
        #expect(terminal.terminalSession === session)
    }
}
