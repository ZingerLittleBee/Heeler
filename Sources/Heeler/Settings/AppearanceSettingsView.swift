import SwiftUI

/// Settings › Appearance: the app's light or dark theme, the Agents list's
/// row style, then the terminal's and Chat's own font and text size, each
/// surface in its section. Pushed from the settings root, which owns the
/// NavigationStack.
struct AppearanceSettingsView: View {
    let terminal: TerminalSettings
    let appearance: AppAppearanceSettings
    let agentRowStyle: AgentListRowStyleSettings

    var body: some View {
        Form {
            Section {
                themePicker
            }
            Section {
                rowStylePicker
                if agentRowStyle.style == .statusRing {
                    Toggle(
                        "Show Status Field",
                        isOn: Binding(
                            get: { agentRowStyle.ringShowsStatusField },
                            set: { agentRowStyle.setRingShowsStatusField($0) }))
                        .accessibilityIdentifier("settings.agentList.ringStatusField")
                }
            } header: {
                Text("Agent List")
            } footer: {
                if agentRowStyle.style == .statusRing {
                    Text(AgentListRowStyleCopy.ringStatusField)
                }
            }
            TerminalAppearanceSection(terminal: terminal)
            ChatAppearanceSection()
        }
        .readableColumnPage()
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The app's own light/dark override. A menu picker, not a pushed
    /// screen: three options do not earn a navigation level.
    private var themePicker: some View {
        Picker(
            selection: Binding(
                get: { appearance.selection },
                set: { appearance.select($0) })
        ) {
            ForEach(AppAppearanceOption.allCases) { @Sendable option in
                Text(option.title).tag(option)
            }
        } label: {
            Text("Theme")
        }
    }

    private var rowStylePicker: some View {
        Picker(
            "Row Style",
            selection: Binding(
                get: { agentRowStyle.style },
                set: { agentRowStyle.select($0) })
        ) {
            ForEach(AgentListRowStyle.allCases) { @Sendable style in
                Text(style.title).tag(style)
            }
        }
        .accessibilityIdentifier("settings.agentList.rowStyle")
    }
}

enum AgentListRowStyleCopy {
    static let ringStatusField =
        "The ring shows each Agent's status. Turn this on to also show it as text where a Host's "
        + "Agent List Fields include status."
}

/// The terminal's font, text size, and per-appearance theme slots, each
/// slot opening a picker with its own live preview.
private struct TerminalAppearanceSection: View {
    let terminal: TerminalSettings

    var body: some View {
        Section {
            Picker(
                "Font",
                selection: Binding(
                    get: { terminal.fonts.selection },
                    set: { terminal.fonts.select($0) })
            ) {
                ForEach(terminal.fonts.availableOptions) { @Sendable option in
                    Text(option.title).tag(option)
                }
            }
            Stepper(
                value: Binding(
                    get: { terminal.zoom.fontSize },
                    set: { terminal.zoom.setFontSize($0) }),
                in: TerminalZoomSettings.range,
                step: 1
            ) {
                LabeledContent("Text Size") {
                    Text("\(Int(terminal.zoom.fontSize)) pt")
                        .monospacedDigit()
                }
            }
            .accessibilityValue("\(Int(terminal.zoom.fontSize)) points")
            themePickerLink(for: .light)
            themePickerLink(for: .dark)
        } header: {
            Text("Terminal")
        } footer: {
            Text(
                "Pinching a terminal to zoom changes its text size too, and it sticks. "
                    + "Each appearance has its own theme: a dark theme for Light Mode keeps "
                    + "the terminal dark under a light system.")
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
}

/// Where Fold Finished Turns is kept. On by default.
enum ChatFoldSettings {
    static let defaultsKey = "chat.fold-finished-turns"
}

/// The conversation's font and text size with a sample in them, and Fold
/// Finished Turns, which is how a turn reads once it ends.
private struct ChatAppearanceSection: View {
    @AppStorage(ChatTextSettings.sizeOffsetKey) private var textSizeOffset = ChatTextSettings.defaultSizeOffset
    @AppStorage(ChatTextSettings.fontKey) private var font = ChatFontOption.system
    @AppStorage(ChatFoldSettings.defaultsKey) private var foldsFinishedTurns = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Section {
            Picker("Font", selection: $font) {
                ForEach(ChatFontOption.allCases) { @Sendable option in
                    Text(option.title).tag(option)
                }
            }
            .accessibilityIdentifier("settings.chat.font")
            Stepper(value: $textSizeOffset, in: ChatTextSettings.sizeOffsetRange) {
                LabeledContent("Text Size") {
                    Text("\(bodyPoints) pt")
                        .monospacedDigit()
                }
            }
            .accessibilityValue("\(bodyPoints) points")
            .accessibilityIdentifier("settings.chat.textSize")
            Text("Agents reply here as they would in Chat.")
                .dynamicTypeSize(textSize)
                .fontDesign(font.design)
                .padding(.vertical, 4)
                .accessibilityIdentifier("settings.chat.textSample")
            Toggle("Fold Finished Turns", isOn: $foldsFinishedTurns)
                .accessibilityIdentifier("settings.chat.foldFinishedTurns")
        } header: {
            Text("Chat")
        } footer: {
            Text(
                "Code stays monospaced, and the text size follows the system's from there. "
                    + "A finished turn's steps fold behind one line above its answer; a turn stays "
                    + "open while it runs or while its background work does.")
        }
    }

    private var textSize: DynamicTypeSize {
        ChatTextSettings.size(system: dynamicTypeSize, offset: textSizeOffset)
    }

    private var bodyPoints: Int {
        Int(ChatTextSettings.bodyPointSize(at: textSize).rounded())
    }
}
