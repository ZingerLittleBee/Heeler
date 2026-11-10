import Foundation
import GhosttyTerminal
import GhosttyTheme
import Observation
import SwiftUI

/// A curated theme choice. Paired options resolve to different catalog themes
/// per appearance; single options render the same theme in both.
enum TerminalThemeOption: String, CaseIterable, Identifiable, Sendable {
    case followSystem = "follow-system"
    case vesper
    case appleSystemColors = "apple-system-colors"
    case dracula
    case solarized
    case catppuccin
    case tokyoNight = "tokyo-night"
    case gruvbox
    case nord
    case monokaiPro = "monokai-pro"
    case rosePine = "rose-pine"
    case ayu
    case oneHalf = "one-half"
    case kanagawa
    case everforest
    case github
    case nightOwl = "night-owl"
    case iceberg
    case flexoki
    case selenized
    case modus
    case tomorrow
    case melange
    case zenbones
    case atomOneDark = "atom-one-dark"
    case snazzy
    case oceanicNext = "oceanic-next"
    case poimandres
    case horizon
    case zenburn

    var id: Self { self }

    var title: String {
        switch self {
        case .followSystem: String(localized: "Default")
        case .vesper: "Vesper"
        case .appleSystemColors: String(localized: "Apple System Colors")
        case .dracula: "Dracula"
        case .solarized: "Solarized"
        case .catppuccin: "Catppuccin"
        case .tokyoNight: String(localized: "Tokyo Night")
        case .gruvbox: "Gruvbox"
        case .nord: "Nord"
        case .monokaiPro: String(localized: "Monokai Pro")
        case .rosePine: String(localized: "Rosé Pine")
        case .ayu: "Ayu"
        case .oneHalf: String(localized: "One Half")
        case .kanagawa: "Kanagawa"
        case .everforest: "Everforest"
        case .github: "GitHub"
        case .nightOwl: String(localized: "Night Owl")
        case .iceberg: "Iceberg"
        case .flexoki: "Flexoki"
        case .selenized: "Selenized"
        case .modus: "Modus"
        case .tomorrow: "Tomorrow"
        case .melange: "Melange"
        case .zenbones: "Zenbones"
        case .atomOneDark: String(localized: "One Dark")
        case .snazzy: "Snazzy"
        case .oceanicNext: String(localized: "Oceanic Next")
        case .poimandres: "Poimandres"
        case .horizon: "Horizon"
        case .zenburn: "Zenburn"
        }
    }

    var detail: String {
        switch self {
        case .followSystem: String(localized: "Alabaster in Light Mode, Afterglow in Dark Mode")
        case .vesper: String(localized: "A warm, low-contrast dark theme")
        case .appleSystemColors: String(localized: "Apple's terminal palette for each appearance")
        case .dracula: String(localized: "The classic high-contrast dark palette")
        case .solarized: String(localized: "Paired iTerm2 Solarized light and dark themes")
        case .catppuccin: String(localized: "Latte in Light Mode, Mocha in Dark Mode")
        case .tokyoNight: String(localized: "Day in Light Mode, Night in Dark Mode")
        case .gruvbox: String(localized: "A warm retro palette for both appearances")
        case .nord: String(localized: "A calm arctic palette for both appearances")
        case .monokaiPro: String(localized: "The popular editor palette for both appearances")
        case .rosePine: String(localized: "Dawn in Light Mode, the classic in Dark Mode")
        case .ayu: String(localized: "Light and dark halves of the Ayu palette")
        case .oneHalf: String(localized: "One Half Light and One Half Dark")
        case .kanagawa: String(localized: "Lotus in Light Mode, Wave in Dark Mode")
        case .everforest: String(localized: "Forest greens for each appearance")
        case .github: String(localized: "GitHub's default palettes for each appearance")
        case .nightOwl: String(localized: "Owlish Light in Light Mode, Night Owl in Dark Mode")
        case .iceberg: String(localized: "Paired Iceberg light and dark themes")
        case .flexoki: String(localized: "Paired inky light and dark themes")
        case .selenized: String(localized: "A Solarized descendant for each appearance")
        case .modus: String(localized: "Operandi in Light Mode, Vivendi in Dark Mode")
        case .tomorrow: String(localized: "Tomorrow in Light Mode, Tomorrow Night in Dark Mode")
        case .melange: String(localized: "Warm paired light and dark themes")
        case .zenbones: String(localized: "Paired low-contrast light and dark themes")
        case .atomOneDark: String(localized: "Atom's One Dark for both appearances")
        case .snazzy: String(localized: "A vivid dark theme for both appearances")
        case .oceanicNext: String(localized: "A deep sea-blue dark theme for both appearances")
        case .poimandres: String(localized: "A cool minimal dark theme for both appearances")
        case .horizon: String(localized: "A warm dusk dark theme for both appearances")
        case .zenburn: String(localized: "The classic low-contrast dark theme for both appearances")
        }
    }

    /// The single source of the option → catalog-theme mapping. Everything
    /// else — rendering configurations, swatches, chrome colours — derives
    /// from this, so an option cannot render one theme and preview another.
    /// The names are catalog keys, never localized; `title` is what shows.
    func catalogName(isDark: Bool) -> String {
        switch self {
        // libghostty's built-in default pair; the catalog carries themes of
        // the same names, matching backgrounds but not every accent — see
        // `configuration(isDark:)`.
        case .followSystem: isDark ? "Afterglow" : "Alabaster"
        case .vesper: "Vesper"
        case .appleSystemColors:
            isDark ? "Apple System Colors" : "Apple System Colors Light"
        case .dracula: "Dracula"
        case .solarized: isDark ? "iTerm2 Solarized Dark" : "iTerm2 Solarized Light"
        case .catppuccin: isDark ? "Catppuccin Mocha" : "Catppuccin Latte"
        case .tokyoNight: isDark ? "TokyoNight Night" : "TokyoNight Day"
        case .gruvbox: isDark ? "Gruvbox Dark" : "Gruvbox Light"
        case .nord: isDark ? "Nord" : "Nord Light"
        case .monokaiPro: isDark ? "Monokai Pro" : "Monokai Pro Light"
        case .rosePine: isDark ? "Rose Pine" : "Rose Pine Dawn"
        case .ayu: isDark ? "Ayu" : "Ayu Light"
        case .oneHalf: isDark ? "One Half Dark" : "One Half Light"
        case .kanagawa: isDark ? "Kanagawa Wave" : "Kanagawa Lotus"
        case .everforest: isDark ? "Everforest Dark Hard" : "Everforest Light Med"
        case .github: isDark ? "GitHub Dark Default" : "GitHub Light Default"
        case .nightOwl: isDark ? "Night Owl" : "Night Owlish Light"
        case .iceberg: isDark ? "Iceberg Dark" : "Iceberg Light"
        case .flexoki: isDark ? "Flexoki Dark" : "Flexoki Light"
        case .selenized: isDark ? "Selenized Dark" : "Selenized Light"
        case .modus: isDark ? "Modus Vivendi" : "Modus Operandi"
        case .tomorrow: isDark ? "Tomorrow Night" : "Tomorrow"
        case .melange: isDark ? "Melange Dark" : "Melange Light"
        case .zenbones: isDark ? "Zenbones Dark" : "Zenbones Light"
        case .atomOneDark: "Atom One Dark"
        case .snazzy: "Snazzy"
        case .oceanicNext: "Oceanic Next"
        case .poimandres: "Poimandres"
        case .horizon: "Horizon"
        case .zenburn: "Zenburn"
        }
    }

    /// The rendering configuration for one appearance. Follow System keeps
    /// libghostty's built-in Alabaster/Afterglow builders: the catalog entries
    /// of the same names share their backgrounds but differ in selection and
    /// bright-palette accents, and the built-ins are the pair every existing
    /// install has been rendering.
    func configuration(isDark: Bool) -> TerminalConfiguration {
        if self == .followSystem {
            return isDark ? .afterglow : .alabaster
        }
        return Self.definitions[catalogName(isDark: isDark)]?
            .toTerminalConfiguration() ?? .default
    }

    func colors(isDark: Bool) -> TerminalThemeColors? {
        Self.definitions[catalogName(isDark: isDark)].map(TerminalThemeColors.init)
    }

    static var requiredCatalogThemeNames: [String] {
        var seen = Set<String>()
        return allCases.flatMap { option in
            [option.catalogName(isDark: false), option.catalogName(isDark: true)]
        }.filter { seen.insert($0).inserted }
    }

    static var missingCatalogThemeNames: [String] {
        requiredCatalogThemeNames.filter { definitions[$0] == nil }
    }

    static let definitions: [String: GhosttyThemeDefinition] =
        GhosttyThemeCatalog.allThemes.reduce(into: [:]) { result, definition in
            result[definition.name] = definition
        }
}

/// A theme's colors in the `#rrggbb` form a herdr-core attach reports.
struct TerminalThemeColors: Sendable, Equatable {
    let foreground: String?
    let background: String?
    let cursor: String?

    init(_ definition: GhosttyThemeDefinition) {
        foreground = Self.normalized(definition.foreground)
        background = Self.normalized(definition.background)
        cursor = definition.cursorColor.flatMap(Self.normalized)
    }

    private static func normalized(_ hex: String) -> String? {
        var digits = hex.trimmingCharacters(in: .whitespaces).lowercased()
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + digits
    }
}

/// Two independent theme slots, one per system appearance. A paired option in
/// a slot contributes the half matching that slot; a single dark option in the
/// light slot is how "dark terminal even in Light Mode" is expressed.
@MainActor
@Observable
final class TerminalThemeSettings {
    /// Pre-slot releases persisted a single selection under this key; it seeds
    /// both slots on first launch so the rendered pair does not change.
    private static let legacyDefaultsKey = "terminal-theme"
    private static let lightDefaultsKey = "terminal-theme-light"
    private static let darkDefaultsKey = "terminal-theme-dark"
    /// A slot nobody chose shows a theme as light or dark as its appearance,
    /// so an untouched app is lit as the system is (ADR 0042).
    static let defaultLightSelection = TerminalThemeOption.followSystem
    static let defaultDarkSelection = TerminalThemeOption.vesper

    private(set) var lightSelection: TerminalThemeOption
    private(set) var darkSelection: TerminalThemeOption
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let legacy =
            defaults.string(forKey: Self.legacyDefaultsKey)
            .flatMap(TerminalThemeOption.init(rawValue:))
        lightSelection =
            defaults.string(forKey: Self.lightDefaultsKey)
            .flatMap(TerminalThemeOption.init(rawValue:)) ?? legacy ?? Self.defaultLightSelection
        darkSelection =
            defaults.string(forKey: Self.darkDefaultsKey)
            .flatMap(TerminalThemeOption.init(rawValue:)) ?? legacy ?? Self.defaultDarkSelection
    }

    /// What a terminal shows: `appearance`'s slot in both halves, so a
    /// terminal drawn in the other appearance (a dark theme for Light Mode
    /// darkens the app) still shows that slot's theme.
    func terminalTheme(for appearance: ColorScheme) -> TerminalTheme {
        let configuration = selection(for: appearance).configuration(isDark: appearance == .dark)
        return TerminalTheme(light: configuration, dark: configuration)
    }

    func selection(for colorScheme: ColorScheme) -> TerminalThemeOption {
        colorScheme == .dark ? darkSelection : lightSelection
    }

    /// The colors the terminal shows in this appearance.
    func colors(for colorScheme: ColorScheme) -> TerminalThemeColors? {
        selection(for: colorScheme).colors(isDark: colorScheme == .dark)
    }

    func select(_ option: TerminalThemeOption, for colorScheme: ColorScheme) {
        if colorScheme == .dark {
            guard option != darkSelection else { return }
            darkSelection = option
            defaults.set(option.rawValue, forKey: Self.darkDefaultsKey)
        } else {
            guard option != lightSelection else { return }
            lightSelection = option
            defaults.set(option.rawValue, forKey: Self.lightDefaultsKey)
        }
    }
}
