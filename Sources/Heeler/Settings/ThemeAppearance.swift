import SwiftUI
import UIKit

extension EnvironmentValues {
    /// Whose terminal theme is in force: Settings › Appearance › Theme, or
    /// the system's light or dark. Theme lookups read this, never
    /// `\.colorScheme`, which follows the theme's own background
    /// (`appAppearance(_:themes:)`).
    @Entry var themeAppearance: ColorScheme = .light
}

extension View {
    /// At a scene root: picks the terminal theme's slot, then draws the
    /// whole window, sheets and UIKit surfaces included, light or dark as
    /// that theme's background is, so a dark theme for Light Mode darkens the
    /// app rather than only its terminals and Chat.
    func appAppearance(_ appearance: AppAppearanceSettings, themes: TerminalThemeSettings) -> some View {
        modifier(AppAppearanceModifier(appearance: appearance, themes: themes))
    }
}

private struct AppAppearanceModifier: ViewModifier {
    let appearance: AppAppearanceSettings
    let themes: TerminalThemeSettings
    @State private var scene = SceneAppearance()

    func body(content: Content) -> some View {
        let themeAppearance = appearance.preferredColorScheme ?? scene.system
        let drawn = themes.selection(for: themeAppearance).chromeColorScheme(for: themeAppearance)
        content
            .environment(\.themeAppearance, themeAppearance)
            .environment(\.themeColors, ThemeColors(themes: themes, appearance: themeAppearance))
            .onChange(of: drawn, initial: true) { _, drawn in scene.draw(drawn) }
            .background {
                WindowReader { scene.attach($0) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

/// One scene's appearance: the system's light or dark, read from the scene,
/// and the light or dark its window is drawn in. The override is the
/// window's own, not SwiftUI's `preferredColorScheme`, which overrides the
/// whole scene and would hide the system's appearance from it.
@MainActor
@Observable
final class SceneAppearance {
    private(set) var system: ColorScheme
    @ObservationIgnored private weak var window: UIWindow?
    @ObservationIgnored private var drawn: ColorScheme?
    @ObservationIgnored private var registration: (any UITraitChangeRegistration)?

    init() {
        system = Self.colorScheme(of: UITraitCollection.current)
    }

    /// Idempotent per window. Runs from `WindowReader`, before the frame
    /// commits, so the scene's first reading lands on the next turn.
    func attach(_ window: UIWindow) {
        guard window !== self.window, let scene = window.windowScene else { return }
        self.window = window
        applyDrawn()
        registration = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            [weak self] (scene: UIWindowScene, _: UITraitCollection) in
            self?.readSystem(scene.traitCollection)
        }
        Task { @MainActor [weak self] in self?.readSystem(scene.traitCollection) }
    }

    func draw(_ scheme: ColorScheme) {
        drawn = scheme
        applyDrawn()
    }

    private func applyDrawn() {
        guard let window, let drawn else { return }
        window.overrideUserInterfaceStyle = drawn == .dark ? .dark : .light
    }

    private func readSystem(_ traits: UITraitCollection) {
        let scheme = Self.colorScheme(of: traits)
        if scheme != system { system = scheme }
    }

    private static func colorScheme(of traits: UITraitCollection) -> ColorScheme {
        traits.userInterfaceStyle == .dark ? .dark : .light
    }
}
