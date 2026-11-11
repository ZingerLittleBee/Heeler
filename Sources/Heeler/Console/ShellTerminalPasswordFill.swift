import SwiftUI

/// Which password prompt a Shell Terminal offers to fill, from what its
/// viewport shows.
///
/// A filled prompt stays on screen, since nothing echoes, until the user
/// presses Return. Offering it again would invite a second fill, so the offer
/// stays down until new output changes the screen.
///
/// The keyboard coming back after a fill resizes the pane, and the redraw
/// shows the same screen with blank rows, or rows at the top, added or taken
/// away. So screens compare by their lines with text, the shorter being the
/// tail of the longer. A retry prompt is new output: it adds lines at the
/// bottom even when they repeat the ones before.
@MainActor
@Observable
final class ShellTerminalPasswordPrompts {
    /// The prompt the Fill Password button offers; nil hides the button.
    private(set) var offered: TerminalPasswordPrompt?

    @ObservationIgnored private var viewport = ""
    /// The screen's lines with text at the last fill, while it is still up.
    @ObservationIgnored private var filledLines: [String]?

    /// The prompt on screen now, offered or not, for the sheet to quote.
    var onScreen: TerminalPasswordPrompt? { TerminalPasswordPrompt(viewport: viewport) }

    func viewportDidChange(_ text: String) {
        viewport = text
        if let filledLines {
            let lines = TerminalPasswordPrompt.textLines(of: text)
            guard !Self.isSameScreen(filledLines, lines) else { return }
            self.filledLines = nil
        }
        let prompt = TerminalPasswordPrompt(viewport: text)
        if prompt != offered { offered = prompt }
    }

    func didFill() {
        // With no prompt on screen there is no offer to hold down.
        filledLines = onScreen == nil ? nil : TerminalPasswordPrompt.textLines(of: viewport)
        if offered != nil { offered = nil }
    }

    /// A replacement surface starts from its own output.
    func reset() {
        viewport = ""
        filledLines = nil
        if offered != nil { offered = nil }
    }

    private static func isSameScreen(_ a: [String], _ b: [String]) -> Bool {
        let (longer, shorter) = a.count >= b.count ? (a, b) : (b, a)
        return longer.suffix(shorter.count).elementsEqual(shorter)
    }
}

/// One opening of the password sheet.
struct ShellTerminalPasswordRequest: Identifiable {
    let id = UUID()
    /// The prompt on screen when the sheet opened; nil when there was none.
    let prompt: TerminalPasswordPrompt?
}

/// Floats over the terminal's bottom trailing corner while a password prompt
/// is on screen, in the terminal's own colours like the other floating
/// controls.
struct ShellTerminalPasswordButton: View {
    let palette: TerminalThemePalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Fill Password", systemImage: "key.fill")
                .font(.subheadline.weight(.semibold))
                .labelStyle(ShellTerminalPasswordButtonLabelStyle())
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background { TerminalFloatingControlBackground(palette: palette) }
                // The capsule is 36 points tall; the touch area is not.
                .padding(.vertical, 4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.foreground)
        .hoverEffect(.highlight)
        .accessibilityHint("Opens a secure field for the password prompt on screen")
    }
}

private struct ShellTerminalPasswordButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.foregroundStyle(.tint)
            configuration.title
        }
    }
}

/// A secure field that iOS Password AutoFill can fill, whose text goes into
/// the terminal without Return (`TerminalInputController.insertSecret`).
/// The text lives only in this view's state and leaves with it.
struct ShellTerminalPasswordSheet: View {
    let prompt: TerminalPasswordPrompt?
    let canInsert: Bool
    /// Returns whether the password reached the terminal.
    let onInsert: (String) -> Bool
    let onCancel: () -> Void

    @State private var password = ""
    @FocusState private var isFieldFocused: Bool
    /// Just tall enough for the field and its notes, so the terminal's
    /// prompt stays in sight above the sheet and the keyboard. Larger text
    /// scrolls the form.
    @ScaledMetric(relativeTo: .body) private var sheetHeight: CGFloat = 230

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.done)
                        .focused($isFieldFocused)
                        .onSubmit(insert)
                } header: {
                    if let prompt {
                        Text(verbatim: prompt.line)
                            .font(.system(.footnote, design: .monospaced))
                            .textCase(nil)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert", action: insert)
                        .disabled(password.isEmpty || !canInsert)
                }
            }
        }
        .presentationDetents([.height(sheetHeight)])
        .onAppear { isFieldFocused = true }
    }

    private var footer: String {
        if prompt == nil {
            String(localized: "No password prompt is on screen. If nothing is asking for one, the password will show in the terminal. It’s typed in without Return.")
        } else {
            String(localized: "The password is typed in without Return. Press Return in the terminal to submit it.")
        }
    }

    private func insert() {
        guard !password.isEmpty, canInsert else { return }
        if onInsert(password) { password = "" }
    }
}
