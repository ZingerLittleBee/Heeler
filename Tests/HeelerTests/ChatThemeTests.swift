import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// Chat wears the terminal theme, so every theme in both appearances must
/// keep Chat's cards and diffs readable.
@MainActor
@Suite("Chat theme")
struct ChatThemeTests {
    private static let appearances: [ColorScheme] = [.light, .dark]

    /// A card may cost a little of the theme's own text contrast, never more
    /// than a tenth, and never below 4.5:1 where the theme starts above it.
    @Test func textOnCardsKeepsTheThemesContrast() {
        for option in TerminalThemeOption.allCases {
            for appearance in Self.appearances {
                let theme = ChatTheme(option: option, appearance: appearance)
                let style = theme.diffSurface.themeStyle ?? .light
                let text = UIColor(theme.foreground)
                let page = FileDiffViewTests.contrast(text, on: UIColor(theme.background), style: style)
                let card = FileDiffViewTests.contrast(text, on: UIColor(theme.raised), style: style)
                #expect(
                    card >= min(4.5, page * 0.9),
                    "\(option) \(appearance) text on a card has contrast \(card), on the page \(page)")
            }
        }
    }

    /// The pairs the tuned colours are held to, on every theme's surface.
    @Test func diffColoursAreReadableOnEveryTerminalTheme() {
        for option in TerminalThemeOption.allCases {
            for appearance in Self.appearances {
                let surface = ChatTheme(option: option, appearance: appearance).diffSurface
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
