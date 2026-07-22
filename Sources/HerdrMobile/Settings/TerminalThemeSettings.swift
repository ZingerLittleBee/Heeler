import Foundation
import GhosttyTerminal
import GhosttyTheme
import Observation

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

    var id: Self { self }

    var title: String {
        switch self {
        case .followSystem: "Follow System"
        case .vesper: "Vesper"
        case .appleSystemColors: "Apple System Colors"
        case .dracula: "Dracula"
        case .solarized: "Solarized"
        case .catppuccin: "Catppuccin"
        case .tokyoNight: "Tokyo Night"
        case .gruvbox: "Gruvbox"
        case .nord: "Nord"
        case .monokaiPro: "Monokai Pro"
        }
    }

    var detail: String {
        switch self {
        case .followSystem: "Alabaster in Light Mode, Afterglow in Dark Mode"
        case .vesper: "A warm, low-contrast dark theme"
        case .appleSystemColors: "Apple's terminal palette for each appearance"
        case .dracula: "The classic high-contrast dark palette"
        case .solarized: "Paired iTerm2 Solarized light and dark themes"
        case .catppuccin: "Latte in Light Mode, Mocha in Dark Mode"
        case .tokyoNight: "Day in Light Mode, Night in Dark Mode"
        case .gruvbox: "A warm retro palette for both appearances"
        case .nord: "A calm arctic palette for both appearances"
        case .monokaiPro: "The popular editor palette for both appearances"
        }
    }

    var terminalTheme: TerminalTheme {
        switch self {
        case .followSystem:
            .default
        case .vesper:
            Self.singleTheme(named: "Vesper")
        case .appleSystemColors:
            Self.pairedTheme(
                light: "Apple System Colors Light",
                dark: "Apple System Colors")
        case .dracula:
            Self.singleTheme(named: "Dracula")
        case .solarized:
            Self.pairedTheme(
                light: "iTerm2 Solarized Light",
                dark: "iTerm2 Solarized Dark")
        case .catppuccin:
            Self.pairedTheme(
                light: "Catppuccin Latte",
                dark: "Catppuccin Mocha")
        case .tokyoNight:
            Self.pairedTheme(
                light: "TokyoNight Day",
                dark: "TokyoNight Night")
        case .gruvbox:
            Self.pairedTheme(
                light: "Gruvbox Light",
                dark: "Gruvbox Dark")
        case .nord:
            Self.pairedTheme(
                light: "Nord Light",
                dark: "Nord")
        case .monokaiPro:
            Self.pairedTheme(
                light: "Monokai Pro Light",
                dark: "Monokai Pro")
        }
    }

    static let requiredCatalogThemeNames = [
        "Vesper",
        "Apple System Colors Light",
        "Apple System Colors",
        "Dracula",
        "iTerm2 Solarized Light",
        "iTerm2 Solarized Dark",
        "Catppuccin Latte",
        "Catppuccin Mocha",
        "TokyoNight Day",
        "TokyoNight Night",
        "Gruvbox Light",
        "Gruvbox Dark",
        "Nord Light",
        "Nord",
        "Monokai Pro Light",
        "Monokai Pro",
    ]

    static var missingCatalogThemeNames: [String] {
        requiredCatalogThemeNames.filter { definitions[$0] == nil }
    }

    private static let definitions: [String: GhosttyThemeDefinition] =
        GhosttyThemeCatalog.allThemes.reduce(into: [:]) { result, definition in
            result[definition.name] = definition
        }

    private static func singleTheme(named name: String) -> TerminalTheme {
        let configuration = configuration(named: name)
        return TerminalTheme(light: configuration, dark: configuration)
    }

    private static func pairedTheme(light: String, dark: String) -> TerminalTheme {
        TerminalTheme(
            light: configuration(named: light),
            dark: configuration(named: dark))
    }

    private static func configuration(named name: String) -> TerminalConfiguration {
        definitions[name]?.toTerminalConfiguration() ?? .default
    }
}

@MainActor
@Observable
final class TerminalThemeSettings {
    private static let defaultsKey = "terminal-theme"

    private(set) var selection: TerminalThemeOption
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection =
            defaults.string(forKey: Self.defaultsKey)
            .flatMap(TerminalThemeOption.init(rawValue:)) ?? .followSystem
    }

    var theme: TerminalTheme {
        selection.terminalTheme
    }

    func select(_ selection: TerminalThemeOption) {
        guard selection != self.selection else { return }
        self.selection = selection
        defaults.set(selection.rawValue, forKey: Self.defaultsKey)
    }
}
