import SwiftUI

/// How Chat explains a conversation it cannot show (ADR 0024). Each reason
/// leaves the terminal one tap away; none is something Heeler fixes on the
/// Host by itself.
extension ChatUnavailableReason {
    var title: String {
        switch self {
        case .noSession: String(localized: "Waiting for Conversation")
        case .unidentifiedSession: String(localized: "Conversation Not Identified")
        case .notFound, .mismatched, .sessionStore(_, .sessionMissing): String(localized: "Conversation Not Found")
        case .awaitingFirstMessage: String(localized: "No Messages Yet")
        case .compressed: String(localized: "Conversation Compressed")
        case .unsupportedSession, .unsupportedFormat, .sessionStore: String(localized: "Conversation Not Readable")
        case .startScreen: String(localized: "Not in This Conversation")
        case .cannotTellSession, .cannotTellSessionOnWindows, .cannotReadProcessesOnWindows, .extensionNotLoaded:
            String(localized: "Can't Tell the Conversation")
        case .transcriptOff: String(localized: "Transcript Saving Is Off")
        case .codexSharedDaemon:
            String(localized: "Codex Started Without \(ChatLaunchNotice.unbrokenNoDaemon)")
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
            String(localized: "herdr hasn't reported a Claude Code session ID for this Agent. Chat will keep checking. You can continue in the Agent terminal.")
        case .noSession(.codex):
            String(localized: "Codex reports its conversation after a prompt. Send one to show it here.")
        case .noSession(.pi):
            String(localized: "herdr hasn't reported a Pi conversation for this Agent yet. Pi reports it once it has started, after you answer whether to trust the project folder. If this lasts, check the Pi integration on the Host. Chat will keep checking, and you can continue in the Agent terminal.")
        case .noSession(.omp):
            String(localized: "herdr hasn't reported an Oh My Pi conversation for this Agent yet. Oh My Pi reports it once it has started. If this lasts, check the OMP integration on the Host. Chat will keep checking, and you can continue in the Agent terminal.")
        case .noSession(.grok):
            String(localized: "herdr hasn't reported a Grok Build session ID for this Agent. Grok Build reports one when a session starts, including after /new or /clear. Chat keeps checking; you can continue in the Agent terminal.")
        case .noSession(.opencode):
            String(localized: "herdr hasn't reported an OpenCode conversation for this Agent yet. OpenCode reports one once a conversation is open: send a first message in the terminal, or open a session there. Chat will keep checking, and you can continue in the Agent terminal.")
        case .unidentifiedSession(.claude), .unidentifiedSession(.codex), .unidentifiedSession(.pi),
            .unidentifiedSession(.omp), .unidentifiedSession(.grok):
            String(localized: "herdr names this Agent's session without an id, which happens after resuming a conversation by name. Chat can't tell which transcript is its own.")
        case .unidentifiedSession(.opencode):
            String(localized: "herdr reports a session name that isn't an OpenCode session id, so Chat can't tell which conversation is this Agent's.")
        case .unsupportedSession:
            String(localized: "herdr reports a session Chat doesn't read.")
        case .notFound(let searchedAll):
            searchedAll
                ? String(localized: "Heeler couldn't find this conversation's transcript on the Host. It keeps looking while Chat is open.")
                : String(localized: "Heeler hasn't found this conversation's transcript yet. It keeps looking while Chat is open.")
        case .awaitingFirstMessage(let program):
            // Two whole sentences rather than a joined fragment: word order
            // for "saves … after …" differs by language.
            program.writesNewConversationWithFirstReply
                ? String(localized: "\(program.chatName) saves this conversation after its first reply. Send a message to start it.")
                : String(localized: "\(program.chatName) saves this conversation once it has a first message. Send a message to start it.")
        case .compressed:
            String(localized: "Codex compressed this conversation's rollout, which Chat can't read.")
        case .mismatched:
            String(localized: "The transcript under this session's name holds another conversation.")
        case .unsupportedFormat(let format):
            String(localized: "Chat can't read \(format).")
        case .sessionStore(_, let problem):
            problem.explanation
        case .startScreen(let program):
            String(localized: "\(program.chatName) is on its home screen, so the conversation herdr reported is no longer open there. Open a conversation in the terminal, or send a first message there to start one. Chat follows it once herdr reports it.")
        case .cannotTellSession(.pi):
            String(localized: "Chat can't tell which conversation this Agent is in, and doesn't guess. Pi names it through Heeler's extension, which comes with the Host Helper. Install the Helper from this Host's details, then start the Agent again.")
        case .cannotTellSession(.omp):
            String(localized: "Chat can't tell which conversation this Agent is in, and doesn't guess. Oh My Pi names it through Heeler's extension, which comes with the Host Helper. Install the Helper from this Host's details, then start the Agent again. Without it, Chat follows the conversation after its first message.")
        case .cannotTellSession(let program):
            String(localized: "Chat can't tell which conversation this Agent is in, and doesn't guess. \(program.sessionEvidenceHelp) Chat checks again when the Agent's status changes.")
        case .extensionNotLoaded(let program, let turnedOff):
            // One whole text per combination, so each language joins its
            // sentences its own way.
            switch (turnedOff, program == .omp) {
            case (true, false):
                String(localized: "Chat can't tell which conversation this Agent is in, and doesn't guess. \(program.chatName) started with its extensions turned off (--no-extensions), so Heeler's extension, which names the conversation, isn't running in this session. Start the Agent again without --no-extensions.")
            case (true, true):
                String(localized: "Chat can't tell which conversation this Agent is in, and doesn't guess. \(program.chatName) started with its extensions turned off (--no-extensions), so Heeler's extension, which names the conversation, isn't running in this session. Start the Agent again without --no-extensions. Without it, Chat follows the conversation after its first message.")
            case (false, false):
                String(localized: "Chat can't tell which conversation this Agent is in, and doesn't guess. Heeler's extension, which names the conversation, is installed, but this \(program.chatName) hasn't loaded it: it started before the Helper was installed, or with its extensions turned off (--no-extensions). Start the Agent again with its extensions on.")
            case (false, true):
                String(localized: "Chat can't tell which conversation this Agent is in, and doesn't guess. Heeler's extension, which names the conversation, is installed, but this \(program.chatName) hasn't loaded it: it started before the Helper was installed, or with its extensions turned off (--no-extensions). Start the Agent again with its extensions on. Without it, Chat follows the conversation after its first message.")
            }
        case .cannotTellSessionOnWindows(let program) where program == .pi || program == .omp:
            String(localized: "Chat can't tell which conversation this Agent is in, and doesn't guess. \(program.chatName) names it through Heeler's extension, which goes in its extension folder on this Host. If it isn't there yet, add it here, then start the Agent again.")
        case .cannotTellSessionOnWindows(let program):
            String(localized: "Chat can't tell which conversation this Agent is in, and doesn't guess. \(program.sessionEvidenceHelp) Chat checks again when the Agent's status changes.")
        case .cannotReadProcessesOnWindows:
            String(localized: "Chat can't tell which conversation this Agent is in, and doesn't guess. Heeler couldn't read this Agent's process on the Host, which happens when herdr-core and the SSH session run at different elevation, or when PowerShell runs in constrained language mode.")
        case .transcriptOff(let variable, let coreCarriesIt):
            variable.explanation(coreCarriesIt: coreCarriesIt)
        case .codexSharedDaemon:
            String(localized: "Codex runs on its shared background server here, where one terminal's conversation looks like another's. Exit Codex, run codex resume \(ChatLaunchNotice.unbrokenNoDaemon), and pick the conversation in Codex's list. \(ChatLaunchNotice.stopSharedServer)")
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
        case .codexSharedServer?:
            String(localized: "Codex Started Without \(ChatLaunchNotice.unbrokenNoDaemon)")
        case nil: title
        }
    }

    func systemImage(launchNotice: ChatLaunchNotice?) -> String {
        self.launchNotice(launchNotice) == nil ? systemImage : "exclamationmark.bubble"
    }

    func explanation(launchNotice: ChatLaunchNotice?) -> String {
        switch self.launchNotice(launchNotice) {
        case .codexSharedServer?:
            String(localized: "Exit Codex, then run codex \(ChatLaunchNotice.unbrokenNoDaemon) resume. \(ChatLaunchNotice.stopSharedServer)")
        case nil: explanation
        }
    }

    /// One line for a banner over the timeline. `showingSavedMessages` is
    /// false when the timeline holds only messages sent from this device,
    /// as with a new conversation whose transcript isn't written yet.
    func bannerText(showingSavedMessages: Bool) -> String {
        // Each line whole, with and without the saved messages, so no
        // language joins a sentence it can't order.
        let saved = showingSavedMessages
        return switch self {
        case .noSession:
            String(localized: "Waiting for the Agent to report its conversation.")
        case .awaitingFirstMessage(let program):
            // Whole sentences per timing, as in `explanation`.
            program.writesNewConversationWithFirstReply
                ? String(localized: "\(program.chatName) saves this conversation after its first reply.")
                : String(localized: "\(program.chatName) saves this conversation once it has a first message.")
        case .unidentifiedSession, .unsupportedSession:
            saved
                ? String(localized: "Chat can't follow this conversation now. Showing saved messages.")
                : String(localized: "Chat can't follow this conversation now.")
        case .notFound:
            saved
                ? String(localized: "The transcript isn't on the Host any more. Showing saved messages.")
                : String(localized: "Heeler hasn't found this conversation's transcript yet.")
        case .mismatched:
            saved
                ? String(localized: "The transcript under this session's name holds another conversation. Showing saved messages.")
                : String(localized: "The transcript under this session's name holds another conversation.")
        case .compressed, .unsupportedFormat:
            saved
                ? String(localized: "Chat can't read this transcript now. Showing saved messages.")
                : String(localized: "Chat can't read this transcript now.")
        case .sessionStore(let program, _):
            saved
                ? String(localized: "Chat can't read this conversation from \(program.chatName)'s database now. Showing saved messages.")
                : String(localized: "Chat can't read this conversation from \(program.chatName)'s database now.")
        // Never over the timeline, which this reason hides.
        case .startScreen(let program):
            String(localized: "\(program.chatName) is on its home screen.")
        case .cannotTellSession, .cannotTellSessionOnWindows, .cannotReadProcessesOnWindows, .extensionNotLoaded:
            saved
                ? String(localized: "Chat can't tell which conversation this Agent is in now. Showing saved messages.")
                : String(localized: "Chat can't tell which conversation this Agent is in now.")
        case .transcriptOff:
            saved
                ? String(localized: "This Agent isn't saving a transcript. Showing saved messages.")
                : String(localized: "This Agent isn't saving a transcript.")
        case .codexSharedDaemon:
            saved
                ? String(localized: "Codex runs on its shared background server, so Chat can't tell this conversation. Showing saved messages.")
                : String(localized: "Codex runs on its shared background server, so Chat can't tell this conversation.")
        }
    }

    /// A core's OpenCode with no id of Heeler's: the plugin is what names its session
    /// (ADR 0033). Nothing on Herdr TUI reads this reason, where herdr reports it.
    var offersOpenCodePluginEdit: Bool {
        self == .cannotTellSession(.opencode)
    }

    /// A Pi or Oh My Pi on a native Windows core Host, which has no Helper to bring the
    /// extension that names its session (ADR 0033).
    var offersWindowsExtension: Bool {
        self == .cannotTellSessionOnWindows(.pi) || self == .cannotTellSessionOnWindows(.omp)
    }

    /// Whether looking again could find something the user may have fixed.
    var offersRetry: Bool {
        switch self {
        case .noSession, .notFound, .mismatched, .startScreen, .cannotTellSession, .cannotTellSessionOnWindows,
            .cannotReadProcessesOnWindows, .extensionNotLoaded, .transcriptOff, .codexSharedDaemon:
            true
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

extension ChatTranscriptOffVariable {
    /// Says so instead of waiting for a file. When the core carries the variable
    /// every Agent it starts inherits it, which the Host's notice explains.
    func explanation(coreCarriesIt: Bool) -> String {
        let fix =
            coreCarriesIt
            ? String(localized: "The herdr-core on this Host carries it too. See the notice in the Host's details for how to fix that.")
            : String(localized: "Start the Agent again without that variable to use Chat.")
        // One whole sentence per effect, not a predicate fragment: the
        // clause around "so it …" moves differently across languages. The
        // fix follows as each language joins sentences.
        return switch self {
        case .childSession:
            String(localized: "This Claude Code was started with \(rawValue), so it has kept no session record and saves no transcript for Chat to read. \(fix)")
        case .skipPromptHistory:
            String(localized: "This Claude Code was started with \(rawValue), so it keeps no transcript for Chat to read. \(fix)")
        }
    }
}

extension ChatSessionStoreProblem {
    /// OpenCode's database is the only session store Chat reads (ADR 0025).
    var explanation: String {
        switch self {
        case .noStore(let path):
            String(localized: "Heeler couldn't find OpenCode's database at \(path). Chat reads OpenCode's default database.")
        case .sessionMissing(let otherStores) where otherStores.isEmpty:
            String(localized: "OpenCode's database has no conversation with this id. If this OpenCode uses another database, such as one set with OPENCODE_DB, Chat can't read it.")
        case .sessionMissing(let otherStores):
            String(localized: "OpenCode's default database has no conversation with this id. This Host also has \(otherStores.joined(separator: ", ")), which other OpenCode builds use; Chat reads only the default database.")
        case .noReader:
            String(localized: "Reading OpenCode's conversations needs sqlite3 or python3 on the Host. Install one, then tap Check Again.")
        case .readerTooOld(let version):
            String(localized: "The Host's SQLite \(version) can't read OpenCode's database: Chat needs SQLite 3.25 or newer with JSON support, through sqlite3 or Python 3.6 or newer.")
        case .storeClosed:
            String(localized: "OpenCode's database is closed, which usually means OpenCode isn't running. Chat shows saved messages and checks again.")
        case .olderOpenCode:
            String(localized: "This OpenCode keeps conversations in its 1.x format, which Chat can't list. Heeler's plugin tells Chat which one OpenCode shows.")
        case .unsupportedLayout(let detail):
            String(localized: "OpenCode's database has a layout Chat doesn't read (\(detail)). A newer OpenCode may have changed it.")
        case .subagentSession:
            String(localized: "herdr reports a subagent's session, which Chat doesn't show. Open the main conversation in the terminal.")
        }
    }
}

/// What became of a herdr-core Agent that has left a Terminal while its detail
/// stays open (ADR 0032).
enum ChatAgentDeparture: Equatable, Sendable {
    /// The core is bringing the kept Terminal back as a new shell.
    case restarting
    /// Its program exited, so nothing comes back.
    case ended
    /// A shell runs in its place until an Agent starts there.
    case shell

    var title: String {
        switch self {
        case .restarting: String(localized: "Restarting…")
        case .ended: String(localized: "Agent Ended")
        case .shell: String(localized: "Agent Gone")
        }
    }

    var systemImage: String {
        switch self {
        case .restarting: "arrow.clockwise"
        case .ended: "stop.circle"
        case .shell: "terminal"
        }
    }

    var explanation: String {
        switch self {
        case .restarting:
            String(localized: "The program was lost. A new shell takes its place in a moment.")
        case .ended:
            String(localized: "Its program exited, so it will not come back.")
        case .shell:
            String(localized: "A shell runs in its Terminal now. Chat comes back with the next Agent it can read there.")
        }
    }
}

/// What takes the conversation's place, if anything, under the banners.
enum ChatSurfacePresentation: Equatable {
    case timeline
    /// The Agent left, with nothing saved to show. Evidence and searches are
    /// about a program that no longer runs.
    case departed(ChatAgentDeparture)
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
        checkingLaunch: Bool = false, departure: ChatAgentDeparture? = nil
    ) {
        guard let conversation else {
            self = .disconnected
            return
        }
        if conversation.showsTimeline(hasPendingEchoes: hasPendingEchoes) {
            self = .timeline
            return
        }
        if let departure {
            self = .departed(departure)
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
    case departure(ChatAgentDeparture)

    var id: String {
        switch self {
        case .departure: "departure"
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
        launchNotice: ChatLaunchNotice? = nil, departure: ChatAgentDeparture? = nil
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
        // What it says outranks a reason about a program no longer there. With no
        // conversation showing, it says so in the conversation's place.
        if let departure {
            if conversation.showsTimeline(hasPendingEchoes: hasPendingEchoes) { lines.append(.departure(departure)) }
            return lines
        }
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
            showingSavedMessages
                ? String(localized: "Connecting to the Host… Showing saved messages.")
                : String(localized: "Connecting to the Host…")
        case .notConnected(let showingSavedMessages):
            showingSavedMessages
                ? String(localized: "Not connected. Showing saved messages.")
                : String(localized: "Not connected.")
        case .readFailure(let failure):
            String(localized: "Couldn't read the conversation. \(failure.presentation.explanation)")
        case .unavailable(let reason, let showingSavedMessages):
            reason.bannerText(showingSavedMessages: showingSavedMessages)
        case .launch(.codexSharedServer):
            String(localized: "This may be another terminal's conversation.")
        case .departure(.restarting):
            String(localized: "Restarting… \(ChatAgentDeparture.restarting.explanation)")
        case .departure(.ended):
            String(localized: "The Agent ended. \(ChatAgentDeparture.ended.explanation)")
        case .departure(.shell):
            String(localized: "The Agent is gone. \(ChatAgentDeparture.shell.explanation)")
        }
    }

    var systemImage: String {
        switch self {
        case .connecting: "wifi"
        case .notConnected: "wifi.slash"
        case .readFailure: "exclamationmark.triangle"
        case .unavailable(let reason, _): reason.systemImage
        case .launch: "exclamationmark.bubble"
        case .departure(let departure): departure.systemImage
        }
    }

    var showsProgress: Bool {
        switch self {
        case .connecting: true
        case .unavailable(let reason, _): reason.isWaiting
        case .departure(let departure): departure == .restarting
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
    /// The program's name in what Chat says about its conversation: a
    /// product name, the same in every language.
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

    /// What Chat's "can't tell" says about this program on herdr-core, where the
    /// evidence is what the Host shows of its process (ADR 0034).
    fileprivate var sessionEvidenceHelp: String {
        switch self {
        case .codex:
            String(localized: "Codex shows its conversation with the first message, so send one in the terminal. Once a message follows /new, nothing says which conversation it shows, so exit Codex, run codex resume \(ChatLaunchNotice.unbrokenNoDaemon), and pick one.")
        case .grok:
            String(localized: "Grok Build lists its conversation while it runs. After /new it lists both, so Chat can't tell until you start Grok Build again.")
        case .opencode:
            String(localized: "OpenCode says which conversation it shows when Heeler starts OpenCode 2.1 or later from New Agent, or through Heeler's plugin, which takes one change to its configuration.")
        case .claude, .pi, .omp:
            String(localized: "\(chatName) names it once it reaches its prompt, so finish signing in or answer any question in the terminal.")
        }
    }
}

/// In the conversation's place while there is nothing to show.
struct ChatUnavailableView: View {
    let reason: ChatUnavailableReason
    var launchNotice: ChatLaunchNotice?
    /// Check Again is looking, so its capsule spins instead.
    var isChecking = false
    let retry: () -> Void
    let showAgentTerminal: () -> Void
    var chooseConversation: (() -> Void)?
    /// Opens the one configuration edit that can settle this reason.
    var reviewEdit: (() -> Void)?
    /// Opens what writes Heeler's extension, on a native Windows core Host.
    var addExtension: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(reason.title(launchNotice: launchNotice), systemImage: reason.systemImage(launchNotice: launchNotice))
        } description: {
            Text(reason.explanation(launchNotice: launchNotice))
        } actions: {
            VStack(spacing: 10) {
                primaryActions
                // One row of capsules, stacked when the row cannot fit.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions }
                    VStack(spacing: 10) { actions }
                }
            }
            .modifier(ChatUnavailableActionStyle())
            .buttonBorderShape(.capsule)
        }
        .accessibilityIdentifier("chat.unavailable")
    }

    /// What can settle the reason, above the row: a list to choose from, the one
    /// configuration edit, or Heeler's extension on a native Windows core Host.
    @ViewBuilder private var primaryActions: some View {
        if let chooseConversation {
            Button(action: chooseConversation) { actionTitle(Text(ChatCandidatePickerView.title)) }
                .modifier(ChatUnavailablePrimaryActionStyle())
                .accessibilityIdentifier("chat.chooseConversation")
        }
        if let reviewEdit, reason.offersOpenCodePluginEdit {
            let edit = Button(action: reviewEdit) { actionTitle(Text(OpenCodePluginEdit.offerTitle)) }
                .accessibilityIdentifier("chat.unavailable.openCodeEdit")
            if chooseConversation == nil {
                edit.modifier(ChatUnavailablePrimaryActionStyle())
            } else {
                edit
            }
        }
        if let addExtension, reason.offersWindowsExtension {
            Button(action: addExtension) { actionTitle(Text("Add Heeler's Extension…")) }
                .modifier(ChatUnavailablePrimaryActionStyle())
                .accessibilityIdentifier("chat.unavailable.windowsExtension")
        }
    }

    @ViewBuilder private var actions: some View {
        Button(action: showAgentTerminal) { actionTitle(Text(AgentDetailSurface.terminal.showTitle)) }
        if reason.offersRetry {
            Button(action: retry) {
                actionTitle(Text("Check Again"))
                    // Hidden rather than gone, so the capsule keeps its width.
                    .opacity(isChecking ? 0 : 1)
                    .overlay {
                        if isChecking { ProgressView() }
                    }
            }
            .allowsHitTesting(!isChecking)
            .accessibilityLabel(isChecking ? Text("Checking") : Text("Check Again"))
            // A new button rather than new content: glass keeps drawing
            // the tapped label until its press settles, over the spinner.
            .id(isChecking)
        }
        if let guide = reason.launchNotice(launchNotice)?.guideURL {
            Link(destination: guide) { actionTitle(Text("Read More")) }
        }
    }

    /// A little larger than the system's regular capsule, which looks small
    /// under the placeholder's text, yet narrow enough to share a row.
    private func actionTitle(_ title: Text) -> some View {
        title.padding(.vertical, 4).padding(.horizontal, 4)
    }
}

/// Clear Liquid Glass like the toolbar's buttons, where the system has it.
private struct ChatUnavailableActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// The prominent form of the same style, for the action that settles the reason.
private struct ChatUnavailablePrimaryActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
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
    var description = String(localized: "Messages you and the Agent send show here.")

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
    /// A second way out. The two go on a row of their own, each its own element.
    var secondaryActionTitle: String?
    var secondaryAction: (() -> Void)?

    private var hasSecondaryAction: Bool { secondaryActionTitle != nil && secondaryAction != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                if !hasSecondaryAction {
                    primaryAction
                }
            }
            if hasSecondaryAction {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { actions }
                    VStack(alignment: .leading, spacing: 6) { actions }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: hasSecondaryAction ? .contain : .combine)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let actionTitle, let action {
            Button(actionTitle, action: action)
                .font(.footnote.weight(.semibold))
        }
    }

    @ViewBuilder
    private var actions: some View {
        primaryAction
        if let secondaryActionTitle, let secondaryAction {
            Button(secondaryActionTitle, action: secondaryAction)
                .font(.footnote.weight(.semibold))
        }
    }
}
