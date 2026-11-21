import Foundation
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("File diff view", .timeLimit(.minutes(1)))
struct FileDiffViewTests {
    /// Signs and line numbers sit on the line's and the gutter's washes;
    /// code in the label colour sits on the line's and a changed word's.
    /// Both palettes, as Differentiate Without Color switches between them.
    @Test func diffInksHaveReadableContrastInLightAndDarkMode() {
        for (name, palette) in [("GitHub", DiffPalette.github), ("blue and mauve", .blueMauve)] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                for kind in [DiffLine.Kind.added, .removed] {
                    guard let change = palette.change(kind) else {
                        Issue.record("\(name) has no \(kind) colours")
                        continue
                    }
                    let pairs: [(String, UIColor, UIColor)] = [
                        ("ink on line", change.ink, change.line),
                        ("ink on gutter", change.ink, change.gutter),
                        ("code on line", palette.code, change.line),
                        ("code on word", palette.code, change.word),
                    ]
                    for (pair, foreground, background) in pairs {
                        let contrast = Self.contrast(foreground, on: background, style: style)
                        #expect(
                            contrast >= 4.5,
                            "\(name) \(kind) \(pair) in \(style) has contrast \(contrast)")
                    }
                }
                for (pair, foreground) in [
                    ("context numbers", palette.contextNumber), ("code", palette.code),
                ] {
                    let contrast = Self.contrast(foreground, on: DiffSurface.system.background, style: style)
                    #expect(contrast >= 4.5, "\(pair) in \(style) has contrast \(contrast)")
                }
                let band = Self.contrast(DiffSurface.system.secondaryText, on: DiffSurface.system.hunkBand, style: style)
                #expect(band >= 4.5, "hunk band in \(style) has contrast \(band)")
            }
        }
    }

    @Test func differentiateWithoutColorSwitchesToBlueAndMauve() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        func hex(_ color: UIColor) -> String {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.resolvedColor(with: dark).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return String(
                format: "%02X%02X%02X", Int(round(red * 255)), Int(round(green * 255)),
                Int(round(blue * 255)))
        }
        #expect(hex(DiffPalette.current(differentiatingWithoutColor: false, on: .system).added.ink) == "3FB950")
        #expect(hex(DiffPalette.current(differentiatingWithoutColor: true, on: .system).added.ink) == "9ECDFB")
        #expect(hex(DiffPalette.current(differentiatingWithoutColor: true, on: .system).removed.ink) == "F1B5D8")
    }

    /// Composites a translucent foreground over its background before
    /// comparing, as the screen does.
    static func contrast(
        _ foreground: UIColor, on background: UIColor, style: UIUserInterfaceStyle
    ) -> CGFloat {
        let traits = UITraitCollection(userInterfaceStyle: style)
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        foreground.resolvedColor(with: traits).getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        background.resolvedColor(with: traits).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let composite = UIColor(
            red: fr * fa + br * (1 - fa), green: fg * fa + bg * (1 - fa),
            blue: fb * fa + bb * (1 - fa), alpha: 1)
        let front = luminance(composite, style: style)
        let back = luminance(background, style: style)
        return (max(front, back) + 0.05) / (min(front, back) + 0.05)
    }

    private static func luminance(_ color: UIColor, style: UIUserInterfaceStyle) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let linear = [red, green, blue].map { value in
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
