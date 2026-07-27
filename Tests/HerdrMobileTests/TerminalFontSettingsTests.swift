import Foundation
import SwiftUI
import Testing

@testable import HerdrMobile

@MainActor
@Suite("Terminal font settings")
struct TerminalFontSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-fonts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func bundledFacesRegisterUnderTheNamesGhosttyLooksUp() {
        // ghostty resolves `font-family` through CoreText by family name, so a
        // face that registers under a different name than the option claims
        // would silently render as something else.
        let families = TerminalFontCatalog.registerBundledFonts()

        #expect(families.contains("JetBrains Mono"))
        #expect(families.contains("IBM Plex Mono"))
    }

    @Test func everyOfferedOptionResolves() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let settings = TerminalFontSettings(defaults: defaults)

        #expect(settings.availableOptions.contains(.system))
        #expect(settings.availableOptions == TerminalFontOption.allCases)
        #expect(settings.selection == .system)
        #expect(settings.familyName == nil)
    }

    @Test func selectionPersists() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let settings = TerminalFontSettings(defaults: defaults)
        settings.select(.jetBrainsMono)

        #expect(settings.familyName == "JetBrains Mono")
        #expect(TerminalFontSettings(defaults: defaults).selection == .jetBrainsMono)
    }

    @Test func aStoredFontThatCannotBeResolvedFallsBackToTheSystem() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set("jetbrains-mono", forKey: "terminal-font-family")

        // An empty bundle registers nothing, standing in for a face that
        // failed to load. The stored choice must not be honoured blind.
        let settings = TerminalFontSettings(defaults: defaults, bundle: Bundle(for: EmptyMarker.self))

        #expect(settings.availableOptions == [.system])
        #expect(settings.selection == .system)
    }
}

private final class EmptyMarker {}

@Suite("Terminal theme swatch")
struct TerminalThemeSwatchTests {
    @Test func hexParsingHandlesBothCatalogSpellings() throws {
        #expect(Color(hex: "#1e1e2e") != nil)
        #expect(Color(hex: "1e1e2e") != nil)
        #expect(Color(hex: "nope") == nil)
        #expect(Color(hex: "#12345") == nil)
    }

    @Test func pairedThemesDrawTheHalfThatIsInForce() {
        // The swatch answers "what will my terminal look like if I pick this",
        // and the current appearance is half of that answer.
        let dark = TerminalThemeOption.solarized.swatchPalette(for: .dark)
        let light = TerminalThemeOption.solarized.swatchPalette(for: .light)

        #expect(dark.background != light.background)
    }

    @Test func everyThemeYieldsADrawablePalette() {
        for option in TerminalThemeOption.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let palette = option.swatchPalette(for: scheme)
                // No crash and no default-constructed nonsense: the accent and
                // success bars must come out as real colours.
                #expect(palette.accent != palette.background)
            }
        }
    }
}
