import SwiftUI

/// The Agent detail screen's input surface (#10): a quick-key bar plus a
/// message box, sitting below the read-only Observe terminal. Lets a user
/// answer a Blocked agent — type a reply, tap Enter/y/n, interrupt with
/// Ctrl-C — without ever opening Attach (User Story 6).
struct AgentInputBar: View {
    @Bindable var store: AgentInputStore
    let dictation: DictationStore
    /// Presents the app's Settings sheet, so a model-not-ready hint in the error
    /// row can route the user to download the model (User Story 15). Injected by
    /// the owner, which holds the sheet state (no duplicate state here).
    let onOpenSettings: () -> Void
    @FocusState private var messageFocused: Bool
    /// The message box's text selection, mirrored into `store.cursorOffset` so
    /// Dictation inserts at the caret, and updated back so the caret follows
    /// the streaming transcript (#37).
    @State private var selection: TextSelection?

    var body: some View {
        VStack(spacing: 8) {
            QuickKeyBar { key in
                _ = store.queue(key)
            }

            errorRow

            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    "Reply to the agent", text: $store.draft, selection: $selection,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($messageFocused)
                .submitLabel(.send)
                .onSubmit {
                    messageFocused = false
                    submit()
                }
                .onChange(of: selection) { store.cursorOffset = cursorOffset(of: selection) }
                .onChange(of: store.cursorOffset) { moveCaret(to: store.cursorOffset) }

                DictationMicButton(store: dictation)

                Button {
                    messageFocused = false
                    submit()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title2)
                }
                .disabled(!store.canSendDraft || store.state == .sending)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Sends the draft, first clearing any lingering dictation error so it
    /// can't mask this send's own failure in the shared error row (#38).
    private func submit() {
        dictation.clearErrorRow()
        store.submitDraft()
    }

    /// The error row shared by the send path and Dictation (#37): the message
    /// plus, when the holding failure offers one, a tappable remedy. A missing
    /// model routes to Settings so the hint is actionable, not a dead end
    /// (User Story 15).
    @ViewBuilder
    private var errorRow: some View {
        if let message = errorRowMessage {
            HStack(spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                if showsOpenSettings {
                    Button("Open Settings", action: onOpenSettings)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The single error row shared by the send path and Dictation (#37). A live
    /// dictation failure wins when present — it is the gesture the user just
    /// made; otherwise a send failure holds the row.
    private var errorRowMessage: String? {
        if let dictationMessage = dictation.errorRowMessage { return dictationMessage }
        if case .failed(let message) = store.state { return message }
        return nil
    }

    /// Whether the holding failure is a dictation one offering the Settings
    /// remedy. Only a dictation failure carries a remedy, and it wins the row
    /// whenever present, so this is enough to gate the affordance.
    private var showsOpenSettings: Bool {
        dictation.errorRowMessage != nil && dictation.errorRowRemedy == .openSettings
    }

    /// The caret offset of an insertion-point selection, or `nil` for no /
    /// ranged selection (Dictation then composes at the end).
    private func cursorOffset(of selection: TextSelection?) -> Int? {
        guard let selection else { return nil }
        let text = store.draft
        switch selection.indices {
        case .selection(let range) where range.isEmpty:
            return text.distance(from: text.startIndex, to: range.lowerBound)
        case .selection, .multiSelection:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Places the caret at `offset` characters into the draft, so it follows
    /// the transcript the store streams in. A no-op when already there, which
    /// stops the two `onChange`s from ping-ponging.
    private func moveCaret(to offset: Int?) {
        guard let offset else { return }
        let text = store.draft
        let clamped = min(max(offset, 0), text.count)
        let caret = text.index(text.startIndex, offsetBy: clamped)
        let next = TextSelection(insertionPoint: caret)
        if cursorOffset(of: selection) != clamped {
            selection = next
        }
    }
}

/// The horizontal quick-key row. Buttons are fixed to herdr's key spellings
/// through `QuickKey`; tapping one fires `onTap` for the store to send.
struct QuickKeyBar: View {
    let onTap: (QuickKey) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(QuickKey.allCases) { key in
                    Button {
                        onTap(key)
                    } label: {
                        keyLabel(key)
                            .font(.callout.weight(.medium))
                            .frame(minWidth: 44, minHeight: 32)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(accessibilityLabel(key))
                }
            }
            .padding(.horizontal, 1)
        }
    }

    @ViewBuilder
    private func keyLabel(_ key: QuickKey) -> some View {
        if let systemImage = key.systemImage {
            Image(systemName: systemImage)
        } else if let label = key.label {
            Text(label)
        }
    }

    private func accessibilityLabel(_ key: QuickKey) -> String {
        key.label ?? key.rawValue.capitalized
    }
}
