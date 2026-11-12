import SwiftUI
import UIKit

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
    @State private var isRevealed = false
    /// Just tall enough for the field and its notes, so the terminal's
    /// prompt stays in sight above the sheet and the keyboard. Larger text
    /// scrolls the form.
    @ScaledMetric(relativeTo: .body) private var sheetHeight: CGFloat = 230

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        ShellTerminalPasswordField(
                            text: $password, isRevealed: isRevealed, onSubmit: insert)
                        revealButton
                    }
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
    }

    private var revealButton: some View {
        Button {
            isRevealed.toggle()
        } label: {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
                .foregroundStyle(Color.secondary)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        // Borderless, or the whole row would be the button.
        .buttonStyle(.borderless)
        .accessibilityLabel(
            isRevealed ? String(localized: "Hide Password") : String(localized: "Show Password"))
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

/// The sheet's password field. One UIKit text field rather than SwiftUI's
/// `SecureField` and `TextField`, so showing the password keeps the same
/// field, keyboard and AutoFill bar, and nothing rewrites what is typed
/// while it shows: SwiftUI's `TextField` turned `"`, `--` and `'` into
/// smart quotes and a dash, which changes the password.
struct ShellTerminalPasswordField: UIViewRepresentable {
    @Binding var text: String
    let isRevealed: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ShellTerminalPasswordTextField {
        let field = ShellTerminalPasswordTextField()
        field.placeholder = String(localized: "Password")
        field.textContentType = .password
        field.isSecureTextEntry = !isRevealed
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .done
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.delegate = context.coordinator
        field.addTarget(
            context.coordinator, action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: ShellTerminalPasswordTextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        if field.isSecureTextEntry == isRevealed { field.setSecure(!isRevealed) }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: ShellTerminalPasswordTextField, context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? uiView.intrinsicContentSize.width,
            height: uiView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ShellTerminalPasswordField

        init(_ parent: ShellTerminalPasswordField) {
            self.parent = parent
        }

        @objc func textDidChange(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

final class ShellTerminalPasswordTextField: UITextField {
    private var hasTakenFocus = false

    /// Takes the keyboard as the sheet presents, once.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !hasTakenFocus else { return }
        hasTakenFocus = true
        becomeFirstResponder()
    }

    /// Hiding the text again while editing would make the next keystroke
    /// replace all of it, as a secure field does when editing begins. Typing
    /// the text back in counts as that keystroke, so the next one appends.
    func setSecure(_ secure: Bool) {
        isSecureTextEntry = secure
        guard secure, isFirstResponder, let text, !text.isEmpty else { return }
        self.text = ""
        insertText(text)
    }
}
