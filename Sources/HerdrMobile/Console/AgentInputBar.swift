import SwiftUI

/// The Agent detail screen's input surface (#10): a quick-key bar plus a
/// message box, sitting below the read-only Observe terminal. Lets a user
/// answer a Blocked agent — type a reply, tap Enter/y/n, interrupt with
/// Ctrl-C — without ever opening Attach (User Story 6).
struct AgentInputBar: View {
    @Bindable var store: AgentInputStore
    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            QuickKeyBar { key in
                Task { await store.send(key) }
            }

            if case .failed(let message) = store.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply to the agent", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($messageFocused)
                    .submitLabel(.send)

                Button {
                    messageFocused = false
                    Task { await store.sendDraft() }
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
