import SwiftUI
import UIKit

/// The diff's colours. Green additions and red removals follow GitHub. With
/// Differentiate Without Color on, the diff switches to Heeler's blue and
/// mauve, which stay apart under red-green colour blindness. Code keeps the
/// label colour on every row: the sign, the line numbers, the washes, and a
/// changed word's outline carry each change. Opaque washes keep contrast
/// stable on every surface. On a theme's surface every colour is derived
/// from the theme's background (`current(differentiatingWithoutColor:on:)`).
struct DiffPalette: Equatable, Sendable {
    struct Change: Equatable, Sendable {
        /// The sign, the line numbers, and a changed word's outline.
        let ink: UIColor
        /// The line's wash.
        let line: UIColor
        /// The line-number gutter's deeper wash.
        let gutter: UIColor
        /// A changed word's fill.
        let word: UIColor
    }

    let added: Change
    let removed: Change
    /// Context lines and their gutter.
    let background: UIColor
    /// Code on every row.
    let code: UIColor
    /// Context line numbers.
    let contextNumber: UIColor

    static let github = DiffPalette(
        added: Change(
            ink: adaptive(light: 0x116329, dark: 0x3FB950),
            line: adaptive(light: 0xE6FFEC, dark: 0x0B2411),
            gutter: adaptive(light: 0xCCFFD8, dark: 0x10321A),
            word: adaptive(light: 0xABF2BC, dark: 0x1A5427)),
        removed: Change(
            ink: adaptive(light: 0xB42318, dark: 0xFF7B72),
            line: adaptive(light: 0xFFEBE9, dark: 0x2E1111),
            gutter: adaptive(light: 0xFFD7D5, dark: 0x451918),
            word: adaptive(light: 0xFFC5C0, dark: 0x6E2521)),
        background: DiffSurface.system.background,
        code: systemCode,
        contextNumber: DiffSurface.system.secondaryText)

    static let blueMauve = DiffPalette(
        added: Change(
            ink: adaptive(light: 0x0B4F8A, dark: 0x9ECDFB),
            line: adaptive(light: 0xEAF3FC, dark: 0x112B41),
            gutter: adaptive(light: 0xD5E7F9, dark: 0x163852),
            word: adaptive(light: 0xB9D8F5, dark: 0x1F4E73)),
        removed: Change(
            ink: adaptive(light: 0x8A215B, dark: 0xF1B5D8),
            line: adaptive(light: 0xFBEFF6, dark: 0x3B2032),
            gutter: adaptive(light: 0xF5DCEA, dark: 0x4A2940),
            word: adaptive(light: 0xEDC0DA, dark: 0x6B3558)),
        background: DiffSurface.system.background,
        code: systemCode,
        contextNumber: DiffSurface.system.secondaryText)

    /// Code on the system's surface: the label colour at 92% in dark and 88%
    /// in light.
    private static let systemCode = adaptive(light: 0x000000, lightAlpha: 0.88, dark: 0xFFFFFF, darkAlpha: 0.92)
    /// The diagonals across a side-by-side cell that has no line.
    static let hatch = adaptive(light: 0x000000, lightAlpha: 0.07, dark: 0xFFFFFF, darkAlpha: 0.06)

    static func current(differentiatingWithoutColor: Bool, on surface: DiffSurface) -> DiffPalette {
        guard let themed = surface.themedPalettes else {
            return differentiatingWithoutColor ? blueMauve : github
        }
        return differentiatingWithoutColor ? themed.differentiating : themed.standard
    }

    /// `self` on a theme's background: the tuned washes blended into it, then
    /// the inks and the code moved toward black or white only as far as
    /// 4.5:1 on them takes.
    func themed(on background: UIColor, secondaryText: UIColor, style: UIUserInterfaceStyle) -> DiffPalette {
        let added = added.washed(into: background, style: style)
        let removed = removed.washed(into: background, style: style)
        let codeBackgrounds = [background, added.line, added.word, removed.line, removed.word]
        return DiffPalette(
            added: added,
            removed: removed,
            background: background,
            code: Self.systemCode.flattened(over: background, style: style)
                .readable(on: codeBackgrounds, style: style),
            contextNumber: secondaryText)
    }

    func change(_ kind: DiffLine.Kind) -> Change? {
        switch kind {
        case .added: added
        case .removed: removed
        case .context: nil
        }
    }

    /// The sign's and line numbers' colour.
    func ink(for kind: DiffLine.Kind) -> UIColor {
        change(kind)?.ink ?? contextNumber
    }

    func background(for kind: DiffLine.Kind) -> UIColor {
        change(kind)?.line ?? background
    }

    func gutter(for kind: DiffLine.Kind) -> UIColor {
        change(kind)?.gutter ?? background
    }

    static func adaptive(light: UInt32, dark: UInt32) -> UIColor {
        adaptive(light: light, lightAlpha: 1, dark: dark, darkAlpha: 1)
    }

    static func adaptive(
        light: UInt32, lightAlpha: CGFloat, dark: UInt32, darkAlpha: CGFloat
    ) -> UIColor {
        UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let rgb = isDark ? dark : light
            return UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha)
        }
    }
}

extension DiffPalette.Change {
    /// The change on a theme's background. Each wash is the ink on a grey
    /// as light as the background, so a tinted theme cannot cancel the
    /// change's hue, taking about the share of ink the tuned wash holds over
    /// black or white, less where black or white would no longer read on it;
    /// the ink then moves toward black or white until it reads on its washes.
    func washed(into background: UIColor, style: UIUserInterfaceStyle) -> Self {
        let shares: (line: CGFloat, gutter: CGFloat, word: CGFloat) =
            style == .dark ? (0.19, 0.27, 0.45) : (0.10, 0.20, 0.34)
        let pole = UIColor.readablePole(on: [background], style: style)
        let base = background.neutral(style: style)
        func wash(_ share: CGFloat) -> UIColor {
            var share = share
            var color = base.mixed(with: ink, by: share, style: style)
            while share > 0, pole.contrast(with: color, style: style) < 4.6 {
                share = max(share - 0.01, 0)
                color = base.mixed(with: ink, by: share, style: style)
            }
            return color
        }
        let line = wash(shares.line)
        let gutter = wash(shares.gutter)
        return Self(
            ink: ink.flattened(over: background, style: style).readable(on: [line, gutter], style: style),
            line: line,
            gutter: gutter,
            word: wash(shares.word))
    }
}

/// What a diff is drawn on. The Changes screen keeps the system's surface
/// and the tuned colours; Chat draws on its terminal theme (`ThemeColors`).
struct DiffSurface: Equatable, Sendable {
    let background: UIColor
    let hunkBand: UIColor
    /// Context line numbers and the hunk band's text.
    let secondaryText: UIColor
    /// The theme's appearance, which its colours are derived for; nil on the
    /// system's surface, whose colours adapt on their own.
    let themeStyle: UIUserInterfaceStyle?
    /// A theme's palettes, derived once with its surface; nil on the
    /// system's, which uses the tuned ones.
    let themedPalettes: ThemedPalettes?

    struct ThemedPalettes: Equatable, Sendable {
        let standard: DiffPalette
        /// For Differentiate Without Color.
        let differentiating: DiffPalette
    }

    /// The secondary label, raised to 74% in light so the small digits keep
    /// 4.5:1.
    static let system = DiffSurface(
        background: .systemBackground,
        hunkBand: DiffPalette.adaptive(light: 0xF6F8FA, dark: 0x111214),
        secondaryText: DiffPalette.adaptive(light: 0x3C3C43, lightAlpha: 0.74, dark: 0xEBEBF5, darkAlpha: 0.6),
        themeStyle: nil,
        themedPalettes: nil)

    /// A theme's surface: the system's secondary text, moved toward black or
    /// white until it reads on the background and the band.
    static func theme(background: UIColor, hunkBand: UIColor, style: UIUserInterfaceStyle) -> DiffSurface {
        let secondaryText = system.secondaryText.flattened(over: background, style: style)
            .readable(on: [background, hunkBand], style: style)
        return DiffSurface(
            background: background,
            hunkBand: hunkBand,
            secondaryText: secondaryText,
            themeStyle: style,
            themedPalettes: ThemedPalettes(
                standard: DiffPalette.github.themed(on: background, secondaryText: secondaryText, style: style),
                differentiating: DiffPalette.blueMauve.themed(
                    on: background, secondaryText: secondaryText, style: style)))
    }
}

extension EnvironmentValues {
    @Entry var diffSurface: DiffSurface = .system
}
