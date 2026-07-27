import GhosttyTheme
import SwiftUI

/// The Appearance pane inside the Keys keyboard: font, text size, and theme.
///
/// There is no preview terminal here. The real one is on the top half of the
/// screen, and every control on this pane applies to it instantly — a second,
/// smaller, fake terminal would only be a worse copy of what the user is
/// already looking at.
struct TerminalAppearancePane: View {
    let themes: TerminalThemeSettings
    let zoom: TerminalZoomSettings
    let fonts: TerminalFontSettings

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controlsRow
                themeGrid
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                sizeButton(symbol: "textformat.size.smaller", delta: -1, label: "Smaller")
                Divider().frame(height: 20)
                sizeButton(symbol: "textformat.size.larger", delta: 1, label: "Larger")
            }
            .background(.quaternary, in: .rect(cornerRadius: 10))

            Menu {
                ForEach(fonts.availableOptions) { option in
                    Button {
                        fonts.select(option)
                    } label: {
                        if option == fonts.selection {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(fonts.selection.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: .rect(cornerRadius: 10))
            }
            .accessibilityLabel("Terminal font")
            .accessibilityValue(fonts.selection.title)
        }
    }

    private func sizeButton(symbol: String, delta: Float, label: String) -> some View {
        Button {
            zoom.adjust(by: delta)
        } label: {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 48, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(zoom.fontSize)) points")
    }

    private var themeGrid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(TerminalThemeOption.allCases) { option in
                Button {
                    themes.select(option)
                } label: {
                    TerminalThemeSwatch(
                        option: option,
                        isSelected: themes.selection == option)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityValue(themes.selection == option ? "Selected" : "")
            }
        }
    }
}

/// A miniature of a themed terminal drawn from the theme's own colours: a few
/// bars standing in for lines of output. Cheap enough to put a dozen of them
/// on screen, unlike a real surface.
struct TerminalThemeSwatch: View {
    let option: TerminalThemeOption
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            card
            Text(option.title)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }

    private var palette: TerminalThemeSwatchPalette {
        // A paired theme is drawn as the half that is actually in force. The
        // swatch answers "what will my terminal look like if I pick this",
        // and right now the appearance is half of that answer.
        option.swatchPalette(for: colorScheme)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 5) {
            bar(width: 0.86, color: palette.accent)
            bar(width: 0.62, color: palette.foreground)
            HStack(spacing: 4) {
                bar(width: 0.2, color: palette.success)
                bar(width: 0.28, color: palette.foreground.opacity(0.7))
                bar(width: 0.16, color: palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .frame(height: 62)
        .background(palette.background, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                    lineWidth: isSelected ? 2 : 0.5)
        }
    }

    private func bar(width: CGFloat, color: Color) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(color)
                .frame(width: proxy.size.width * width, height: 5)
        }
        .frame(height: 5)
    }
}

struct TerminalThemeSwatchPalette {
    let background: Color
    let foreground: Color
    let accent: Color
    let success: Color
}

extension TerminalThemeOption {
    func swatchPalette(for colorScheme: ColorScheme) -> TerminalThemeSwatchPalette {
        guard let definition = swatchDefinition(for: colorScheme) else {
            return TerminalThemeSwatchPalette(
                background: Color(uiColor: .systemBackground),
                foreground: Color(uiColor: .label),
                accent: .accentColor,
                success: .green)
        }
        let foreground = Color(hex: definition.foreground) ?? .primary
        return TerminalThemeSwatchPalette(
            background: Color(hex: definition.background) ?? Color(uiColor: .systemBackground),
            foreground: foreground,
            // ANSI 4 (blue) and 2 (green): the two colours a prompt and a
            // status line almost always land on.
            accent: definition.palette[4].flatMap(Color.init(hex:)) ?? foreground,
            success: definition.palette[2].flatMap(Color.init(hex:)) ?? foreground)
    }

    private func swatchDefinition(for colorScheme: ColorScheme) -> GhosttyThemeDefinition? {
        let isDark = colorScheme == .dark
        let name: String? =
            switch self {
            case .followSystem: nil
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
            }
        // Follow System is libghostty's own default pair, which has no catalog
        // entry to read colours from; it falls back to the system palette.
        guard let name else { return nil }
        return GhosttyThemeCatalog.allThemes.first { $0.name == name }
    }
}

extension Color {
    /// Parses the `#rrggbb` strings the theme catalog stores.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
