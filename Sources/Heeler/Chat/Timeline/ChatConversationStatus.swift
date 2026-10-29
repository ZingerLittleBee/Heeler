import SwiftUI

/// How Chat explains a conversation it cannot show (ADR 0024). Each reason
/// leaves the terminal one tap away; none is something Heeler fixes on the
/// Host by itself.
extension ChatUnavailableReason {
    var title: String {
        switch self {
        case .noSession: "Waiting for Conversation"
        case .unidentifiedSession: "Conversation Not Identified"
        case .notFound, .mismatched, .sessionStore(_, .sessionMissing): "Conversation Not Found"
        case .awaitingFirstMessage: "No Messages Yet"
        case .compressed: "Conversation Compressed"
        case .unsupportedSession, .unsupportedFormat, .sessionStore: "Conversation Not Readable"
        case .startScreen: "Not in This Conversation"
        }
    }

    var systemImage: String {
        switch self {
        case .noSession, .awaitingFirstMessage: "bubble.left.and.bubble.right"
        case .notFound, .mismatched, .sessionStore(_, .sessionMissing): "doc.text.magnifyingglass"
        default: "exclamationmark.bubble"
        }
    }

    var explanation: String {
        switch self {
        case .noSession(.claude):
            "herdr hasn't reported a Claude Code session ID for this Agent. Chat will keep checking. You can continue in the Agent terminal."
        case .noSession(.codex):
            "Codex reports its conversation after a prompt. Send one to show it here."
        case .noSession(.pi):
            "herdr hasn't reported a Pi conversation for this Agent yet. Pi reports it once it has started, after you answer whether to trust the project folder. If this lasts, check the Pi integration on the Host. Chat will keep checking, and you can continue in the Agent terminal."
        case .noSession(.omp):
            "herdr hasn't reported an Oh My Pi conversation for this Agent yet. Oh My Pi reports it once it has started. If this lasts, check the OMP integration on the Host. Chat will keep checking, and you can continue in the Agent terminal."
        case .noSession(.grok):
            "herdr hasn't reported a Grok Build session ID for this Agent. Grok Build reports one when a session starts, including after /new or /clear. Chat keeps checking; you can continue in the Agent terminal."
        case .noSession(.opencode):
            "herdr hasn't reported an OpenCode conversation for this Agent yet. OpenCode reports one once a conversation is open: send a first message in the terminal, or open a session there. Chat will keep checking, and you can continue in the Agent terminal."
        case .unidentifiedSession(.claude), .unidentifiedSession(.codex), .unidentifiedSession(.pi),
            .unidentifiedSession(.omp), .unidentifiedSession(.grok):
            "herdr names this Agent's session without an id, which happens after resuming a conversation by name. Chat can't tell which transcript is its own."
        case .unidentifiedSession(.opencode):
            "herdr reports a session name that isn't an OpenCode session id, so Chat can't tell which conversation is this Agent's."
        case .unsupportedSession:
            "herdr reports a session Chat doesn't read."
        case .notFound(let searchedAll):
            searchedAll
                ? "Heeler couldn't find this conversation's transcript on the Host. It keeps looking while Chat is open."
                : "Heeler hasn't found this conversation's transcript yet. It keeps looking while Chat is open."
        case .awaitingFirstMessage(let program):
            "\(program.chatName) saves this conversation \(program.firstSave). Send a message to start it."
        case .compressed:
            "Codex compressed this conversation's rollout, which Chat can't read."
        case .mismatched:
            "The transcript under this session's name holds another conversation."
        case .unsupportedFormat(let format):
            "Chat can't read \(format)."
        case .sessionStore(_, let problem):
            problem.explanation
        case .startScreen(let program):
            "\(program.chatName) is on its home screen, so the conversation herdr reported is no longer open there. Open a conversation in the terminal, or send a first message there to start one. Chat follows it once herdr reports it."
        }
    }

    /// The notice that replaces this reason's wait: a Codex Agent launched
    /// on its shared server and waiting for a session, which a prompt won't
    /// end.
    func launchNotice(_ notice: ChatLaunchNotice?) -> ChatLaunchNotice? {
        notice == .codexSharedServer && self == .noSession(.codex) ? notice : nil
    }

    func title(launchNotice: ChatLaunchNotice?) -> String {
        switch self.launchNotice(launchNotice) {
        case .codexSharedServer?: "Codex Started Without \(ChatLaunchNotice.unbrokenNoDaemon)"
        case nil: title
        }
    }

    func systemImage(launchNotice: ChatLaunchNotice?) -> String {
        self.launchNotice(launchNotice) == nil ? systemImage : "exclamationmark.bubble"
    }

    func explanation(launchNotice: ChatLaunchNotice?) -> String {
        switch self.launchNotice(launchNotice) {
        case .codexSharedServer?:
            "Exit Codex, then run codex \(ChatLaunchNotice.unbrokenNoDaemon) resume."
        case nil: explanation
        }
    }

    /// One line for a banner over the timeline. `showingSavedMessages` is
    /// false when the timeline holds only messages sent from this device,
    /// as with a new conversation whose transcript isn't written yet.
    func bannerText(showingSavedMessages: Bool) -> String {
        let saved = showingSavedMessages ? " Showing saved messages." : ""
        return switch self {
        case .noSession:
            "Waiting for the Agent to report its conversation."
        case .awaitingFirstMessage(let program):
            "\(program.chatName) saves this conversation \(program.firstSave)."
        case .unidentifiedSession, .unsupportedSession:
            "Chat can't follow this conversation now.\(saved)"
        case .notFound:
            showingSavedMessages
                ? "The transcript isn't on the Host any more.\(saved)"
                : "Heeler hasn't found this conversation's transcript yet."
        case .mismatched:
            "The transcript under this session's name holds another conversation.\(saved)"
        case .compressed, .unsupportedFormat:
            "Chat can't read this transcript now.\(saved)"
        case .sessionStore(let program, _):
            "Chat can't read this conversation from \(program.chatName)'s database now.\(saved)"
        // Never over the timeline, which this reason hides.
        case .startScreen(let program):
            "\(program.chatName) is on its home screen."
        }
    }

    /// Whether looking again could find something the user may have fixed.
    var offersRetry: Bool {
        switch self {
        case .noSession, .notFound, .mismatched, .startScreen: true
        case .sessionStore(_, let problem): problem.isRetryable
        default: false
        }
    }

    var isAwaitingFirstMessage: Bool {
        if case .awaitingFirstMessage = self { true } else { false }
    }

    /// Whether Chat waits for the program rather than for the user: its
    /// banner shows progress and offers nothing to do.
    var isWaiting: Bool {
        switch self {
        case .noSession, .awaitingFirstMessage: true
        default: false
        }
    }
}

extension ChatSessionStoreProblem {
    /// OpenCode's database is the only session store Chat reads (ADR 0025).
    var explanation: String {
        switch self {
        case .noStore(let path):
            "Heeler couldn't find OpenCode's database at \(path). Chat reads OpenCode's default database."
        case .sessionMissing(let otherStores) where otherStores.isEmpty:
            "OpenCode's database has no conversation with this id. If this OpenCode uses another database, such as one set with OPENCODE_DB, Chat can't read it."
        case .sessionMissing(let otherStores):
            "OpenCode's default database has no conversation with this id. This Host also has \(otherStores.joined(separator: ", ")), which other OpenCode builds use; Chat reads only the default database."
        case .noReader:
            "Reading OpenCode's conversations needs sqlite3 or python3 on the Host. Install one, then tap Check Again."
        case .readerTooOld(let version):
            "The Host's SQLite \(version) can't read OpenCode's database: Chat needs SQLite 3.25 or newer with JSON support, through sqlite3 or Python 3.6 or newer."
        case .storeClosed:
            "OpenCode's database is closed, which usually means OpenCode isn't running. Chat shows saved messages and checks again."
        case .olderOpenCode:
            "This OpenCode keeps conversations in its 1.x format, which Chat doesn't read. Chat reads OpenCode 2.x."
        case .unsupportedLayout(let detail):
            "OpenCode's database has a layout Chat doesn't read (\(detail)). A newer OpenCode may have changed it."
        case .subagentSession:
            "herdr reports a subagent's session, which Chat doesn't show. Open the main conversation in the terminal."
        }
    }
}

/// What takes the conversation's place, if anything, under the banners.
enum ChatSurfacePresentation: Equatable {
    case timeline
    /// Searching the Host for the transcript, with nothing saved to show.
    case locating
    /// Nothing saved to show, and the Host to search isn't connected:
    /// nothing is being looked for until it is.
    case awaitingHost
    case empty
    case unavailable(ChatUnavailableReason)
    /// The Host is not in the catalog, so there is no Chat to read.
    case disconnected

    /// `conversation` is nil while there is no Chat to read.
    /// `checkingLaunch` keeps a wait the launch may explain looking until
    /// the launch is read (`AgentChatStore.isCheckingLaunch`).
    init(
        conversation: ChatConversationSnapshot?, hasPendingEchoes: Bool, isHostConnected: Bool,
        checkingLaunch: Bool = false
    ) {
        guard let conversation else {
            self = .disconnected
            return
        }
        if conversation.showsTimeline(hasPendingEchoes: hasPendingEchoes) {
            self = .timeline
            return
        }
        switch conversation.phase {
        case .locating: self = isHostConnected ? .locating : .awaitingHost
        case .following: self = .empty
        case .unavailable(let reason):
            let mayBeNotice = reason.launchNotice(.codexSharedServer) != nil
            self = checkingLaunch && mayBeNotice && isHostConnected ? .locating : .unavailable(reason)
        }
    }
}

/// One line over Chat's conversation, before the view adds its action.
enum ChatBannerLine: Equatable, Identifiable {
    case connecting(showingSavedMessages: Bool)
    case notConnected(showingSavedMessages: Bool)
    case readFailure(TransportError)
    case unavailable(ChatUnavailableReason, showingSavedMessages: Bool)
    case launch(ChatLaunchNotice)

    var id: String {
        switch self {
        case .connecting, .notConnected: "host"
        case .readFailure: "read"
        case .unavailable: "unavailable"
        case .launch: "launch"
        }
    }

    /// The lines over the conversation, top to bottom. `conversation` is nil
    /// while there is no Chat to read. Saved messages are transcript entries
    /// this device kept; messages sent from it and not yet recorded are not.
    static func lines(
        hostStatus: EventsSessionStatus?, conversation: ChatConversationSnapshot?, hasPendingEchoes: Bool,
        launchNotice: ChatLaunchNotice? = nil
    ) -> [ChatBannerLine] {
        let showingSaved = conversation?.transcript.entries.isEmpty == false
        switch hostStatus {
        case .connected?: break
        case .connecting?, .reconnecting?: return [.connecting(showingSavedMessages: showingSaved)]
        default: return [.notConnected(showingSavedMessages: showingSaved)]
        }
        guard let conversation else { return [] }
        var lines: [ChatBannerLine] = []
        if let failure = conversation.readFailure { lines.append(.readFailure(failure)) }
        if case .unavailable(let reason) = conversation.phase,
            conversation.showsTimeline(hasPendingEchoes: hasPendingEchoes)
        {
            lines.append(
                .unavailable(reason, showingSavedMessages: !conversation.transcript.entries.isEmpty))
        }
        // Over a conversation, or the search for one. A placeholder saying
        // why there is none shows no conversation to warn about, and
        // Waiting for Conversation explains the notice itself.
        if let launchNotice {
            switch conversation.phase {
            case .following, .locating: lines.append(.launch(launchNotice))
            case .unavailable:
                if conversation.showsTimeline(hasPendingEchoes: hasPendingEchoes) {
                    lines.append(.launch(launchNotice))
                }
            }
        }
        return lines
    }

    var text: String {
        switch self {
        // A Host that accepts the connection and never answers keeps this
        // line up, so it says the rows below are the saved ones.
        case .connecting(let showingSavedMessages):
            showingSavedMessages ? "Connecting to the Host… Showing saved messages." : "Connecting to the Host…"
        case .notConnected(let showingSavedMessages):
            showingSavedMessages ? "Not connected. Showing saved messages." : "Not connected."
        case .readFailure(let failure): "Couldn't read the conversation. \(failure.presentation.explanation)"
        case .unavailable(let reason, let showingSavedMessages):
            reason.bannerText(showingSavedMessages: showingSavedMessages)
        case .launch(.codexSharedServer):
            "This may be another terminal's conversation."
        }
    }

    var systemImage: String {
        switch self {
        case .connecting: "wifi"
        case .notConnected: "wifi.slash"
        case .readFailure: "exclamationmark.triangle"
        case .unavailable(let reason, _): reason.systemImage
        case .launch: "exclamationmark.bubble"
        }
    }

    var showsProgress: Bool {
        switch self {
        case .connecting: true
        case .unavailable(let reason, _): reason.isWaiting
        case .notConnected, .readFailure, .launch: false
        }
    }
}

extension ChatConversationSnapshot {
    /// Whether the timeline is up rather than a placeholder: it has entries,
    /// or messages sent from this device the program hasn't recorded yet,
    /// and no reason hides them.
    func showsTimeline(hasPendingEchoes: Bool) -> Bool {
        if case .unavailable(let reason) = phase, reason.hidesConversation { return false }
        return !transcript.entries.isEmpty || hasPendingEchoes
    }
}

extension ChatProgram {
    /// The program's name in what Chat says about its conversation.
    var chatName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .pi: "Pi"
        case .omp: "Oh My Pi"
        case .grok: "Grok Build"
        case .opencode: "OpenCode"
        }
    }

    /// When the program first saves a new conversation, after "saves this
    /// conversation".
    fileprivate var firstSave: String {
        writesNewConversationWithFirstReply ? "after its first reply" : "once it has a first message"
    }
}

/// In the conversation's place while there is nothing to show.
struct ChatUnavailableView: View {
    let reason: ChatUnavailableReason
    var launchNotice: ChatLaunchNotice?
    let retry: () -> Void
    let showAgentTerminal: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(reason.title(launchNotice: launchNotice), systemImage: reason.systemImage(launchNotice: launchNotice))
        } description: {
            Text(reason.explanation(launchNotice: launchNotice))
        } actions: {
            Button(AgentDetailSurface.terminal.showTitle, action: showAgentTerminal)
                .buttonStyle(.bordered)
            if reason.offersRetry {
                Button("Check Again", action: retry)
            }
            if let guide = reason.launchNotice(launchNotice)?.guideURL {
                Link("Read More", destination: guide)
            }
        }
        .accessibilityIdentifier("chat.unavailable")
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
    var description = "Messages you and the Agent send show here."

    var body: some View {
        ContentUnavailableView(
            "No Messages Yet", systemImage: "bubble.left.and.bubble.right",
            description: Text(description))
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
