import SwiftUI

/// Chat's `/` menu above the Composer's text: the commands and skills a
/// leading `/` matches. Tapping one completes it in the draft and sends
/// nothing; an unavailable one stays visible but cannot be picked.
struct ChatCommandSuggestions: View {
    let commands: [ChatCommand]
    let onSelect: (ChatCommand) -> Void
    let onDismiss: () -> Void
    /// Sized to the rows so one match does not reserve the whole cap.
    @State private var listHeight: CGFloat = Self.maximumListHeight

    private static let maximumListHeight: CGFloat = 176

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Commands")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss Commands")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(commands) { command in
                        row(for: command)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    listHeight = height
                }
            }
            .frame(height: min(listHeight, Self.maximumListHeight))
            .scrollBounceBehavior(.basedOnSize)
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
        .accessibilityIdentifier("chat.command-menu")
    }

    private func row(for command: ChatCommand) -> some View {
        Button {
            onSelect(command)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("/\(command.name)")
                    .font(.subheadline.weight(.medium))
                    .fontDesign(.monospaced)
                    .foregroundStyle(command.isEnabled ? .primary : .secondary)
                    .lineLimit(1)
                if let summary = command.isEnabled ? command.summary : "Available once the Agent is idle" {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!command.isEnabled)
        .accessibilityLabel("/\(command.name)")
        .accessibilityHint("Completes the command without sending it")
    }
}
