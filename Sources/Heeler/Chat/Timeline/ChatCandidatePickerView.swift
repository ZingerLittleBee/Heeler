import SwiftUI

/// Lists what a core Agent's conversation could be, when nothing on the Host says
/// (ADR 0034). The user reads a candidate's conversation before choosing it, which
/// is what sets this apart from a guess.
struct ChatCandidatePickerView: View {
    static let title = "Choose a Conversation"

    let chat: AgentChatStore
    let corePin: TerminalCorePin

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Self.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .task {
            await chat.listCandidates(keepingTo: corePin)
            // Chat found the conversation by itself before the list opened.
            if chat.candidates == .notAsked { dismiss() }
        }
        // Watched from the root: the write that says confirmed also empties the list,
        // which takes the preview off the screen.
        .onChange(of: chat.pickConfirmation) { _, state in
            if state == .confirmed { dismiss() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch chat.candidates {
        case .notAsked, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let message):
            ContentUnavailableView(
                "Nothing to Choose From", systemImage: "exclamationmark.bubble", description: Text(message))
        case .listed(let list) where list.candidates.isEmpty:
            ContentUnavailableView(
                "No Conversations Found", systemImage: "bubble.left.and.bubble.right",
                description: Text("This Agent's directory has no recent conversations, and its process holds none open."))
        case .listed(let list):
            List {
                Section {
                    ForEach(list.candidates) { candidate in
                        NavigationLink {
                            ChatCandidatePreviewView(chat: chat, candidate: candidate, corePin: corePin) {
                                dismiss()
                            }
                        } label: {
                            CandidateRow(candidate: candidate)
                        }
                    }
                } footer: {
                    Text(
                        "Chat follows the conversation you choose until the program restarts, or until a message you send from Chat doesn't appear in it.")
                }
            }
        }
    }
}

private struct CandidateRow: View {
    let candidate: ChatSessionCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(candidate.displayTitle)
                .lineLimit(2)
            Text(candidate.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

extension ChatSessionCandidate {
    fileprivate var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "Conversation \(sessionID.prefix(8))"
    }

    fileprivate var detail: String {
        var parts: [String] = []
        if origins.contains(.heldOpen) {
            parts.append("Open in the program")
        } else if origins.contains(.programStatus) {
            parts.append("Named by the program's status")
        } else {
            parts.append("In this directory")
        }
        if let modified { parts.append(modified.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: ", ")
    }
}

/// One candidate's conversation, and the only place it can be chosen.
private struct ChatCandidatePreviewView: View {
    let chat: AgentChatStore
    let candidate: ChatSessionCandidate
    let corePin: TerminalCorePin
    let onDone: () -> Void

    @State private var preview: ChatCandidatePreview?

    var body: some View {
        Group {
            switch preview {
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unreadable(let message):
                ContentUnavailableView(
                    "Can't Show This Conversation", systemImage: "exclamationmark.bubble",
                    description: Text(message))
            case .conversation(_, let entries):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(entries) { entry in
                            PreviewRow(entry: entry)
                        }
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)
                .safeAreaInset(edge: .bottom) { confirmation }
            }
        }
        .navigationTitle(previewTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { preview = await chat.previewCandidate(candidate) }
    }

    private var previewTitle: String {
        if case .conversation(let title?, _) = preview, !title.isEmpty { return title }
        return "Conversation \(candidate.sessionID.prefix(8))"
    }

    @ViewBuilder
    private var confirmation: some View {
        VStack(spacing: 8) {
            switch chat.pickConfirmation {
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                useButton
            case .outcomeUnknown:
                Text(
                    "Heeler sent your choice and got no answer, so it may or may not be saved. Chat shows this conversation if it was. To choose again, reopen this list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Done", action: onDone)
                    .buttonStyle(.bordered)
            case .saving:
                ProgressView()
            case .none, .confirmed:
                useButton
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.bar)
    }

    private var useButton: some View {
        Button("Use This Conversation") {
            Task { await chat.confirmCandidate(candidate, keepingTo: corePin) }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("chat.useConversation")
    }
}

private struct PreviewRow: View {
    let entry: ChatEntry

    var body: some View {
        switch entry.content {
        case .user(let message):
            Text(message.displayText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.secondary, in: .rect(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant(let message):
            Text(message.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }
}
