import SwiftUI

/// Monitor's native, local-first message surface. It renders optimistic
/// echoes but never infers structured conversation history from terminal
/// output (ADR 0012).
struct AgentComposerView: View {
    let store: AgentComposerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.messages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.messages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }
                        }
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: store.messages.count) {
                        guard let latest = store.messages.last else { return }
                        proxy.scrollTo(latest.id, anchor: .bottom)
                    }
                }
                .frame(maxHeight: 176)
                .accessibilityLabel("Sent messages")
            }

            Text("Message")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    "Message",
                    text: Binding(
                        get: { store.draft },
                        set: { store.replaceDraft(with: $0) }),
                    axis: .vertical
                )
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Message")

                Button("Send", systemImage: "arrow.up.circle.fill") {
                    Task { await store.send() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canSend)
                .accessibilityHint("Delivers the complete draft to the Agent")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func messageRow(_ message: AgentComposerStore.Message) -> some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .leading, spacing: 8) {
                Text("You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(message.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                statusLabel(for: message.state)
                    .font(.footnote)

                if case .failed(let detail) = message.state {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            .padding(12)
            .background(
                Color.accentColor.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 14))
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
