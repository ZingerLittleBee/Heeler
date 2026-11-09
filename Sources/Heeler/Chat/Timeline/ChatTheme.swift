import SwiftUI
import UIKit

/// Chat's colours: the terminal theme of the current appearance, so an
/// Agent's Chat and its terminal look alike. A file diff opened from Chat
/// wears it too (`fileDiffTheme`).
struct ChatTheme: Equatable, Sendable {
    /// Light or dark by the theme's background
    /// (`TerminalThemeOption.chromeColorScheme`); every system colour inside
    /// Chat resolves against it. Nil keeps the surrounding one.
    let colorScheme: ColorScheme?
    let background: Color
    let foreground: Color
    /// Cards, code blocks and table headers: the background with a little
    /// of the foreground in it.
    let raised: Color
    let diffSurface: DiffSurface

    /// Views outside Chat.
    static let system = ChatTheme(
        colorScheme: nil,
        background: Color(uiColor: .systemBackground),
        foreground: Color(uiColor: .label),
        raised: Color(uiColor: .secondarySystemBackground),
        diffSurface: .system)

    private static let raisedShare: CGFloat = 0.06

    init(
        colorScheme: ColorScheme?, background: Color, foreground: Color, raised: Color,
        diffSurface: DiffSurface
    ) {
        self.colorScheme = colorScheme
        self.background = background
        self.foreground = foreground
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
            foreground: palette.foreground,
            raised: Color(uiColor: raised),
            diffSurface: .theme(background: background, hunkBand: raised, style: style))
    }

    /// The terminal theme the user picked for `appearance`.
    @MainActor
    init(themes: TerminalThemeSettings, appearance: ColorScheme) {
        self.init(option: themes.selection(for: appearance), appearance: appearance)
    }
}

extension EnvironmentValues {
    @Entry var chatTheme: ChatTheme = .system
}

extension View {
    /// Dresses this view, and the navigation bar it shows, in `theme`.
    func wearsChatTheme(_ theme: ChatTheme) -> some View {
        environment(\.chatTheme, theme)
            .environment(\.diffSurface, theme.diffSurface)
            .foregroundStyle(theme.foreground)
            .transformEnvironment(\.colorScheme) { scheme in
                if let themed = theme.colorScheme { scheme = themed }
            }
            .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
    }
}
