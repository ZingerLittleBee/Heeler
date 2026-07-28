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
    @Environment(\.colorScheme) private var colorScheme

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

    /// The grid edits the slot for the appearance in force: the pane's whole
    /// premise is that every control applies instantly to the terminal above,
    /// and that terminal is rendering the current appearance's slot.
    private var themeGrid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(TerminalThemeOption.allCases) { option in
                Button {
                    themes.select(option, for: colorScheme)
                } label: {
                    TerminalThemeSwatch(
                        option: option,
                        isSelected: themes.selection(for: colorScheme) == option)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityValue(
                    themes.selection(for: colorScheme) == option ? "Selected" : "")
            }
        }
    }
}

/// A themed swatch card with the option's title underneath, for the keyboard
/// pane's grid. Draws the half of the theme matching the current appearance:
/// the pane edits the slot that is in force.
struct TerminalThemeSwatch: View {
    let option: TerminalThemeOption
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            TerminalThemeSwatchCard(
                option: option, scheme: colorScheme, isSelected: isSelected
            )
            .frame(height: 62)
            Text(option.title)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }
}

/// A miniature of a themed terminal drawn from the theme's own colours: a few
/// bars standing in for lines of output. Cheap enough to put a dozen of them
/// on screen, unlike a real surface. The caller picks which appearance's half
/// of the theme to draw and the frame; `compact` shrinks the bars for list
/// rows.
struct TerminalThemeSwatchCard: View {
    let option: TerminalThemeOption
    let scheme: ColorScheme
    var isSelected = false
    var compact = false

    private var palette: TerminalThemeSwatchPalette {
        option.swatchPalette(for: scheme)
    }

    private var cornerRadius: CGFloat { compact ? 6 : 8 }
    private var barHeight: CGFloat { compact ? 3.5 : 5 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3.5 : 5) {
            bar(width: 0.86, color: palette.accent)
            bar(width: 0.62, color: palette.foreground)
            HStack(spacing: compact ? 3 : 4) {
                bar(width: 0.2, color: palette.success)
                bar(width: 0.28, color: palette.foreground.opacity(0.7))
                bar(width: 0.16, color: palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 7 : 10)
        .frame(maxHeight: .infinity)
        .background(palette.background, in: .rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                    lineWidth: isSelected ? 2 : 0.5)
        }
    }

    private func bar(width: CGFloat, color: Color) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(color)
                .frame(width: proxy.size.width * width, height: barHeight)
        }
        .frame(height: barHeight)
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
        Self.definitions[catalogName(isDark: colorScheme == .dark)]
    }

    /// The active theme's terminal background, for painting the chrome around
    /// the terminal surface (the safe areas and the transparent bar region) so
    /// the theme owns the whole screen instead of stopping at the grid.
    func surfaceBackground(for colorScheme: ColorScheme) -> Color {
        swatchPalette(for: colorScheme).background
    }

    /// Chrome legibility follows the theme's luminance rather than the system
    /// appearance: a dark theme under a light system still needs light bar
    /// titles and status-bar text (Ghostty's `window-theme = auto` semantics).
    func chromeColorScheme(for colorScheme: ColorScheme) -> ColorScheme {
        guard let definition = swatchDefinition(for: colorScheme) else {
            return colorScheme
        }
        return Self.isDarkBackground(hex: definition.background) ? .dark : .light
    }

    private static func isDarkBackground(hex: String) -> Bool {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return true }
        let red = Double((value >> 16) & 0xFF)
        let green = Double((value >> 8) & 0xFF)
        let blue = Double(value & 0xFF)
        return 0.299 * red + 0.587 * green + 0.114 * blue < 128
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
