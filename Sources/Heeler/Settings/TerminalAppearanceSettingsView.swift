import SwiftUI

/// Terminal appearance settings: text size, font, and the per-appearance
/// theme slots, each opening a picker with its own live preview. Pushed from
/// the settings root, which owns the NavigationStack.
struct TerminalAppearanceSettingsView: View {
    let terminal: TerminalSettings

    var body: some View {
        Form {
            textSizeSection

            Section {
                ForEach(terminal.fonts.availableOptions) { option in
                    fontButton(option)
                }
            } header: {
                Text("Terminal Font")
            } footer: {
                Text("Bundled faces are registered with the app; no download needed.")
            }

            Section {
                themePickerLink(for: .light)
                themePickerLink(for: .dark)
            } header: {
                Text("Terminal Theme")
            } footer: {
                Text(
                    "Each appearance has its own theme. Picking a dark "
                        + "theme for Light Mode keeps the terminal dark "
                        + "under a light system.")
            }
        }
        .navigationTitle("Terminal Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var textSizeSection: some View {
        Section {
            Stepper(
                value: Binding(
                    get: { terminal.zoom.fontSize },
                    set: { terminal.zoom.setFontSize($0) }),
                in: TerminalZoomSettings.range,
                step: 1
            ) {
                HStack {
                    Text("Text Size")
                    Spacer(minLength: 12)
                    Text("\(Int(terminal.zoom.fontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .accessibilityValue("\(Int(terminal.zoom.fontSize)) points")
        } header: {
            Text("Terminal Text Size")
        } footer: {
            Text("Pinching a terminal to zoom changes this too, and it sticks.")
        }
    }

    private func fontButton(_ option: TerminalFontOption) -> some View {
        selectableRow(
            title: option.title, detail: option.detail,
            isSelected: terminal.fonts.selection == option
        ) {
            terminal.fonts.select(option)
        }
    }

    private func themePickerLink(for scheme: ColorScheme) -> some View {
        NavigationLink {
            TerminalThemePickerView(terminal: terminal, scheme: scheme)
        } label: {
            HStack(spacing: 12) {
                TerminalThemeSwatchCard(
                    option: terminal.themes.selection(for: scheme),
                    scheme: scheme, compact: true
                )
                .frame(width: 54, height: 38)
                .accessibilityHidden(true)
                Text(scheme == .dark ? "Dark Mode" : "Light Mode")
                Spacer(minLength: 12)
                Text(terminal.themes.selection(for: scheme).title)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityValue(terminal.themes.selection(for: scheme).title)
    }

    private func selectableRow(
        title: String,
        detail: String,
        isSelected: Bool,
        select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
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
