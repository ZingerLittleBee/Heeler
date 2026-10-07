import SwiftUI
import UIKit

/// How Chat explains a conversation it cannot show (ADR 0021). Each reason
/// leaves the terminal one tap away; none is something Heeler fixes on the
/// Host by itself.
extension ChatUnavailableReason {
    var title: String {
        switch self {
        case .noSession: "No Conversation Yet"
        case .unidentifiedSession: "Conversation Not Identified"
        case .notFound, .mismatched: "Conversation Not Found"
        case .compressed: "Conversation Compressed"
        case .unsupportedSession, .unsupportedFormat: "Conversation Not Readable"
        }
    }

    var systemImage: String {
        switch self {
        case .noSession: "bubble.left.and.bubble.right"
        case .notFound, .mismatched: "doc.text.magnifyingglass"
        default: "exclamationmark.bubble"
        }
    }

    var explanation: String {
        switch self {
        case .noSession(.claude):
            "herdr hasn't reported a Claude Code session for this Agent. herdr's Claude Code integration reports it. To install it, run this on the Host:"
        case .noSession(.codex):
            "Codex reports its conversation to herdr after the first prompt, through herdr's Codex integration. Send a message below, or install the integration by running this on the Host:"
        case .unidentifiedSession:
            "herdr names this Agent's session without an id, which happens after resuming a conversation by name. Chat can't tell which transcript is its own."
        case .unsupportedSession:
            "herdr reports a session Chat doesn't read."
        case .notFound(let searchedAll):
            searchedAll
                ? "Heeler couldn't find this conversation's transcript on the Host. It keeps looking while Chat is open."
                : "Heeler hasn't found this conversation's transcript yet. It keeps looking while Chat is open."
        case .compressed:
            "Codex compressed this conversation's rollout, which Chat can't read."
        case .mismatched:
            "The transcript under this session's name holds another conversation."
        case .unsupportedFormat(let format):
            "Chat can't read \(format)."
        }
    }

    /// One line for a banner over messages this device kept.
    var bannerText: String {
        switch self {
        case .noSession:
            "Waiting for the Agent to report its conversation."
        case .unidentifiedSession, .unsupportedSession:
            "Chat can't follow this conversation now. Showing saved messages."
        case .notFound, .mismatched:
            "The transcript isn't on the Host any more. Showing saved messages."
        case .compressed, .unsupportedFormat:
            "Chat can't read this transcript now. Showing saved messages."
        }
    }

    /// herdr's integration for the program, which reports the session. Shown
    /// to copy; Heeler never runs it.
    var integrationCommand: String? {
        guard case .noSession(let program) = self else { return nil }
        return "herdr integration install \(program.rawValue)"
    }

    /// Whether looking again could find something the user may have fixed.
    var offersRetry: Bool {
        switch self {
        case .noSession, .notFound, .mismatched: true
        default: false
        }
    }
}

/// In the conversation's place while there is nothing to show.
struct ChatUnavailableView: View {
    let reason: ChatUnavailableReason
    let retry: () -> Void
    let showAgentTerminal: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(reason.title, systemImage: reason.systemImage)
        } description: {
            Text(reason.explanation)
        } actions: {
            if let command = reason.integrationCommand {
                ChatCopyableCommand(command: command)
            }
            Button(AgentDetailSurface.terminal.showTitle, action: showAgentTerminal)
                .buttonStyle(.bordered)
            if reason.offersRetry {
                Button("Check Again", action: retry)
            }
        }
        .accessibilityIdentifier("chat.unavailable")
    }
}

/// A command for the user to run on the Host, with a Copy button.
struct ChatCopyableCommand: View {
    let command: String
    @State private var isCopied = false

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Button {
                UIPasteboard.general.string = command
                isCopied = true
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 24, minHeight: 24)
            }
            .accessibilityLabel(isCopied ? "Copied" : "Copy Command")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

/// While Chat looks for the transcript and has nothing saved to show.
struct ChatLocatingView: View {
    var body: some View {
        ProgressView {
            Text("Looking for the conversation…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("chat.locating")
    }
}

/// A conversation with nothing in it yet.
struct ChatEmptyConversationView: View {
    var body: some View {
        ContentUnavailableView(
            "No Messages Yet", systemImage: "bubble.left.and.bubble.right",
            description: Text("Messages you and the Agent send show here."))
        .accessibilityIdentifier("chat.empty")
    }
}

/// One line over the conversation: the Host is unreachable, a read failed,
/// or the transcript went away.
struct ChatBanner: View {
    let systemImage: String
    let text: String
    var showsProgress = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
