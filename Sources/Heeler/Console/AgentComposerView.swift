import SwiftUI

/// The native, local-first input surface beneath the live terminal. Drafting
/// stays on device; only Send emits one `agent.prompt` request.
struct AgentComposerView: View {
    let store: AgentComposerStore
    let status: AgentStatus
    let switcher: TerminalAgentSwitcher
    let keyboardHandoff: TerminalKeyboardHandoff
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusLabel
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(
                        "Message Agent",
                        text: Binding(
                            get: { store.draft },
                            set: { store.replaceDraft(with: $0) }),
                        axis: .vertical
                    )
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .frame(minHeight: 36, alignment: .topLeading)
                    .focused($isInputFocused)
                    .accessibilityLabel("Message the Agent")

                    if let failure = latestFailure {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(failure.detail, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                            HStack(spacing: 8) {
                                Button("Retry") {
                                    Task { await store.retry(failure.id) }
                                }
                                Button("Edit Draft") {
                                    store.withdrawToDraft(failure.id)
                                    isInputFocused = true
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Button("Send", systemImage: "arrow.up") {
                            Task { await store.send() }
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .labelStyle(.iconOnly)
                        .font(.footnote.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!store.canSend)
                        .accessibilityHint("Delivers the complete draft to the Agent")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

                TerminalAgentSwitcherRow(
                    switcher: focusPreservingSwitcher,
                    isKeyboardUp: isInputFocused,
                    toggleKeyboard: { isInputFocused.toggle() })
            }
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.secondary.opacity(0.16), lineWidth: 1)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .onAppear {
            guard let selectedID = switcher.selectedID,
                  keyboardHandoff.consume(selectedID)
            else { return }
            isInputFocused = true
        }
    }

    private var focusPreservingSwitcher: TerminalAgentSwitcher {
        TerminalAgentSwitcher(
            items: switcher.items,
            selectedID: switcher.selectedID
        ) { id in
            if isInputFocused {
                keyboardHandoff.arm(for: id)
            }
            switcher.onSelect(id)
        }
    }

    private var latestFailure: (id: AgentComposerStore.Message.ID, detail: String)? {
        guard let message = store.messages.last,
              case .failed(let detail) = message.state
        else { return nil }
        return (message.id, detail)
    }

    private var statusLabel: some View {
        HStack(spacing: 4) {
            if status == .working {
                SolvingOrbView(size: 10)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(Color(status.inkUIColor))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Text(status.rawValue.capitalized)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Color(status.inkUIColor))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent status")
        .accessibilityValue(status.rawValue.capitalized)
    }
}
