import GhosttyTerminal
import SwiftUI
import UIKit

/// The theme picker for one appearance slot: a live preview of the current
/// pick on top, then every option with its swatch. Both the preview and the
/// swatches force this slot's half of each theme, so the Light Mode page shows
/// light halves even while the system is dark (and vice versa).
struct TerminalThemePickerView: View {
    let terminal: TerminalSettings
    let scheme: ColorScheme

    var body: some View {
        Form {
            Section {
                TerminalThemePreview(
                    theme: previewTheme,
                    fontSize: terminal.zoom.fontSize
                )
                .frame(height: 180)
                .clipShape(.rect(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            Color(uiColor: .separator).opacity(0.45),
                            lineWidth: 0.5)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityLabel("Terminal theme preview")
            } footer: {
                Text(
                    "Changes apply instantly to current and future Attach terminals without reconnecting."
                )
            }

            Section {
                ForEach(TerminalThemeOption.allCases) { option in
                    themeRow(option)
                }
            }
        }
        .navigationTitle(scheme == .dark ? "Dark Mode Theme" : "Light Mode Theme")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The preview surface resolves its theme against the system appearance,
    /// so both halves carry this slot's configuration to pin what it renders.
    private var previewTheme: TerminalTheme {
        let configuration = terminal.themes.selection(for: scheme)
            .configuration(isDark: scheme == .dark)
        return TerminalTheme(light: configuration, dark: configuration)
    }

    private func themeRow(_ option: TerminalThemeOption) -> some View {
        let isSelected = terminal.themes.selection(for: scheme) == option
        return Button {
            terminal.themes.select(option, for: scheme)
        } label: {
            HStack(spacing: 12) {
                TerminalThemeSwatchCard(option: option, scheme: scheme, compact: true)
                    .frame(width: 54, height: 38)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .foregroundStyle(.primary)
                    Text(option.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}
