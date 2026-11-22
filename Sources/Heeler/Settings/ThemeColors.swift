import SwiftUI
import UIKit

/// The terminal theme of the current appearance as colours for the app's
/// own surfaces, so they look like the terminal: Chat, a file diff opened
/// from Chat (`fileDiffTheme`), and the Console sidebar beside a detail.
struct ThemeColors: Equatable, Sendable {
    /// Light or dark by the theme's background
    /// (`TerminalThemeOption.chromeColorScheme`); every system colour inside
    /// a themed surface resolves against it. Nil keeps the surrounding one.
    let colorScheme: ColorScheme?
    /// Text stays the system's label colours, which follow `colorScheme`
    /// and leave controls their tint.
    let background: Color
    /// Cards, code blocks and table headers: the background with a little
    /// of the foreground in it.
    let raised: Color
    let diffSurface: DiffSurface

    /// Surfaces the theme does not reach.
    static let system = ThemeColors(
        colorScheme: nil,
        background: Color(uiColor: .systemBackground),
        raised: Color(uiColor: .secondarySystemBackground),
        diffSurface: .system)

    private static let raisedShare: CGFloat = 0.06

    init(
        colorScheme: ColorScheme?, background: Color, raised: Color, diffSurface: DiffSurface
    ) {
        self.colorScheme = colorScheme
        self.background = background
        self.raised = raised
        self.diffSurface = diffSurface
    }

    /// `option`'s theme for `appearance`, the system's light or dark.
    init(option: TerminalThemeOption, appearance: ColorScheme) {
        let palette = option.palette(for: appearance)
        let colorScheme = option.chromeColorScheme(for: appearance)
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let background = UIColor(palette.background)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        let raised = background.mixed(with: UIColor(palette.foreground), by: Self.raisedShare, style: style)
        self.init(
            colorScheme: colorScheme,
            background: palette.background,
            raised: Color(uiColor: raised),
            diffSurface: .theme(background: background, hunkBand: raised, style: style))
    }

    /// The terminal theme the user picked for `appearance`.
    @MainActor
    init(themes: TerminalThemeSettings, appearance: ColorScheme) {
        self.init(option: themes.selection(for: appearance), appearance: appearance)
    }
}

/// Neutral veils that shade a theme's background rather than tint it: black
/// in light, white in dark, at a few strengths, so a card, a strip or a
/// selection reads as the theme a step deeper.
enum ThemeVeil {
    /// A card on the page: the Composer, a sidebar card.
    static let card = Color.primary.opacity(0.04)
    /// A strip: the Composer's Agent strip.
    static let strip = Color.primary.opacity(0.06)
    /// A control on a card: a Blocked card's answers and its fields.
    static let control = Color.primary.opacity(0.08)
    /// What is chosen: a selected sidebar row, the chosen Agent's chip.
    static let selection = UIColor { traits in
        UIColor(white: traits.userInterfaceStyle == .dark ? 1 : 0, alpha: 0.08)
    }
}

/// Chrome that floats over Chat's conversation, which scrolls beneath it: the
/// Composer's card and the strip of work over it.
enum ThemeGlass {
    /// How much of the theme's background the glass carries. Enough that the
    /// glass reads as the theme rather than as the system's grey laid over
    /// it, and that a draft stays readable over the rows passing beneath.
    static let tint: Double = 0.55
    /// How much of the glass shows. A card's worth of the system's glass is
    /// close to opaque, so at part strength the rows beneath stay legible
    /// through it, as output does under the detail header's buttons
    /// (`AgentDetailHeader.glassOpacity`).
    static let opacity: Double = 0.9
}

extension EnvironmentValues {
    /// Set at the scene root (`appAppearance(_:themes:)`); the system's
    /// colours outside one.
    @Entry var themeColors: ThemeColors = .system
}

extension View {
    /// Liquid Glass in `theme`'s background where the system has it, a blur
    /// in it before that, behind this view: rows scrolling beneath show
    /// through softened instead of stopping at an opaque edge. Touches on
    /// the glass stay with this view rather than reach those rows.
    func themeGlass(in shape: some Shape, theme: ThemeColors) -> some View {
        let tint = theme.background.opacity(ThemeGlass.tint)
        return background {
            Group {
                if #available(iOS 26, *) {
                    Color.clear.glassEffect(.regular.tint(tint), in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                        .overlay { shape.fill(tint) }
                }
            }
            .opacity(ThemeGlass.opacity)
        }
        .contentShape(shape)
    }
}

extension View {
    /// Dresses this view, and the navigation bar it shows, in `theme`.
    func wearsTheme(_ theme: ThemeColors) -> some View {
        environment(\.themeColors, theme)
            .environment(\.diffSurface, theme.diffSurface)
            .transformEnvironment(\.colorScheme) { scheme in
                if let themed = theme.colorScheme { scheme = themed }
            }
            .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
    }
}
