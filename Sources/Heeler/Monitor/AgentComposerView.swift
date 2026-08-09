import SwiftUI

/// Monitor's native, local-first input surface. Optimistic delivery echoes
/// render in ``AgentSentMessagesView`` beside the snapshot, while this view
/// keeps the draft and terminal controls reachable in stable bottom chrome.
struct AgentComposerView: View {
    let store: AgentComposerStore
    let isControlKeyEnabled: Bool
    let onControlKey: (MonitorControlKey) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Message")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                MonitorControlKeyStrip(
                    isEnabled: isControlKeyEnabled,
                    onTap: onControlKey)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    "Type a message",
                    text: Binding(
                        get: { store.draft },
                        set: { store.replaceDraft(with: $0) }),
                    axis: .vertical
                )
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.secondary.opacity(0.18), lineWidth: 1)
                }
                .accessibilityLabel("Message the Agent")

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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

struct AgentSentMessagesView: View {
    let store: AgentComposerStore

    @ViewBuilder
    var body: some View {
        if !store.messages.isEmpty {
            VStack(alignment: .trailing, spacing: 12) {
                ForEach(store.messages) { message in
                    messageRow(message)
                        .id(message.id)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Messages sent from this device")
        }
    }

    private func messageRow(_ message: AgentComposerStore.Message) -> some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 5) {
                Text("You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        Color.accentColor.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                statusLabel(for: message.state)
                    .font(.caption)

                if case .failed(let detail) = message.state {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    HStack(spacing: 8) {
                        Button("Retry", systemImage: "arrow.clockwise") {
                            Task { await store.retry(message.id) }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Edit Draft", systemImage: "pencil") {
                            store.withdrawToDraft(message.id)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func statusLabel(for state: AgentComposerStore.DeliveryState) -> some View {
        switch state {
        case .sending:
            Label("Sending…", systemImage: "arrow.up.circle")
                .foregroundStyle(.secondary)
        case .delivered(.acknowledged):
            Label("Delivered", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .delivered(.agentBusy):
            Label("Delivered, Agent busy", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .delivered(.working):
            Label("Agent working", systemImage: "gearshape.2")
                .foregroundStyle(.secondary)
        case .delivered(.done):
            Label("Done", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .failed:
            Label("Couldn't send", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }
}
