import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// Chat and the sidebar wear the terminal theme, so every theme in both
/// appearances must keep their cards and diffs readable.
@MainActor
@Suite("Theme colors")
struct ThemeColorsTests {
    private static let appearances: [ColorScheme] = [.light, .dark]

    /// Text is the system's label, so it must read on every theme's page and
    /// cards in the light or dark that theme is drawn in.
    @Test func labelTextReadsOnEveryThemesSurfaces() {
        for option in TerminalThemeOption.allCases {
            for appearance in Self.appearances {
                let theme = ThemeColors(option: option, appearance: appearance)
                let style = theme.diffSurface.themeStyle ?? .light
                for (surface, color) in [("page", theme.background), ("card", theme.raised)] {
                    let contrast = FileDiffViewTests.contrast(.label, on: UIColor(color), style: style)
                    #expect(
                        contrast >= 4.5,
                        "\(option) \(appearance) text on the \(surface) has contrast \(contrast)")
                }
            }
        }
    }

    /// The pairs the tuned colours are held to, on every theme's surface.
    @Test func diffColoursAreReadableOnEveryTerminalTheme() {
        for option in TerminalThemeOption.allCases {
            for appearance in Self.appearances {
                let surface = ThemeColors(option: option, appearance: appearance).diffSurface
                guard let style = surface.themeStyle else {
                    Issue.record("\(option) \(appearance) has no theme style")
                    continue
                }
                for differentiating in [false, true] {
                    let palette = DiffPalette.current(
                        differentiatingWithoutColor: differentiating, on: surface)
                    var pairs: [(String, UIColor, UIColor)] = [
                        ("context numbers", palette.contextNumber, palette.background),
                        ("code", palette.code, palette.background),
                        ("hunk band", surface.secondaryText, surface.hunkBand),
                    ]
                    for kind in [DiffLine.Kind.added, .removed] {
                        guard let change = palette.change(kind) else { continue }
                        pairs += [
                            ("\(kind) ink on line", change.ink, change.line),
                            ("\(kind) ink on gutter", change.ink, change.gutter),
                            ("\(kind) code on line", palette.code, change.line),
                            ("\(kind) code on word", palette.code, change.word),
                        ]
                    }
                    let name = differentiating ? "blue and mauve" : "GitHub"
                    for (pair, foreground, background) in pairs {
                        let contrast = FileDiffViewTests.contrast(foreground, on: background, style: style)
                        #expect(
                            contrast >= 4.5,
                            "\(option) \(appearance) \(name) \(pair) has contrast \(contrast)")
                    }
                }
            }
        }
    }

    @Test func diffOutsideChatKeepsTheTunedColours() {
        let palette = DiffPalette.current(differentiatingWithoutColor: false, on: .system)
        #expect(palette.added.line == DiffPalette.github.added.line)
        #expect(palette.background == DiffSurface.system.background)
    }
}
