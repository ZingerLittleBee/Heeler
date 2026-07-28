import SwiftUI
import UIKit

/// Terminal appearance settings: live preview, text size, font, and the
/// per-appearance theme slots. Pushed from the settings root, which owns the
/// NavigationStack.
struct TerminalAppearanceSettingsView: View {
    let terminal: TerminalSettings

    var body: some View {
        Form {
            Section {
                TerminalThemePreview(
                    theme: terminal.themes.theme,
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
            } header: {
                Text("Preview")
            } footer: {
                Text(
                    "Changes apply instantly to current and future Attach terminals without reconnecting."
                )
            }

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
            List {
                ForEach(TerminalThemeOption.allCases) { option in
                    themeButton(option, for: scheme)
                }
            }
            .navigationTitle(scheme == .dark ? "Dark Mode Theme" : "Light Mode Theme")
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            LabeledContent(
                scheme == .dark ? "Dark Mode" : "Light Mode",
                value: terminal.themes.selection(for: scheme).title)
        }
    }

    private func themeButton(_ option: TerminalThemeOption, for scheme: ColorScheme) -> some View {
        selectableRow(
            title: option.title, detail: option.detail,
            isSelected: terminal.themes.selection(for: scheme) == option
        ) {
            terminal.themes.select(option, for: scheme)
        }
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
