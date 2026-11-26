import SwiftUI

/// How Chat explains a conversation it cannot show (ADR 0024). Each reason
/// leaves the terminal one tap away; none is something Heeler fixes on the
/// Host by itself.
extension ChatUnavailableReason {
    var title: String {
        switch self {
        case .amp(.missing): String(localized: "Connect Amp Chat")
        case .amp(.update): String(localized: "Update Amp Plugin")
        case .amp(.reload): String(localized: "Reload the Amp Plugin")
        case .amp(.noThread): String(localized: "Open an Amp Thread")
        case .amp: String(localized: "Amp Chat Is Unavailable")
        case .noSession(.agy), .noConversationYet, .awaitingFirstMessage: String(localized: "No Messages Yet")
        case .noSession: String(localized: "Waiting for Conversation")
        case .unidentifiedSession: String(localized: "Conversation Not Identified")
        case .notFound, .mismatched, .sessionStore(_, .sessionMissing): String(localized: "Conversation Not Found")
        case .compressed: String(localized: "Conversation Compressed")
        case .unsupportedSession, .unsupportedFormat, .sessionStore: String(localized: "Conversation Not Readable")
        case .startScreen: String(localized: "Not in This Conversation")
        case .cannotTellSession, .multipleSessions, .cannotTellSessionOnWindows, .cannotReadProcessesOnWindows,
            .extensionNotLoaded, .cannotTellSessionOnRex:
            String(localized: "Can't Tell the Conversation")
        case .transcriptOff: String(localized: "Transcript Saving Is Off")
        case .codexSharedDaemon:
            String(localized: "Codex Started Without \(ChatLaunchNotice.unbrokenNoDaemon)")
        }
    }

    var systemImage: String {
        switch self {
        case .noSession, .noConversationYet, .awaitingFirstMessage: "bubble.left.and.bubble.right"
        case .notFound, .mismatched, .sessionStore(_, .sessionMissing): "doc.text.magnifyingglass"
        default: "exclamationmark.bubble"
        }
    }

    var explanation: String {
        switch self {
        case .amp(let problem): problem.explanation
        case .noSession(.amp), .unidentifiedSession(.amp): AmpChatProblem.unidentified.explanation
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
        case .noSession(.agy):
            String(localized: "Antigravity CLI reports its conversation after a message. Send one to show it here.")
        case .unidentifiedSession(.claude), .unidentifiedSession(.codex), .unidentifiedSession(.pi),
            .unidentifiedSession(.omp), .unidentifiedSession(.grok):
            String(localized: "herdr names this Agent's session without an id, which happens after resuming a conversation by name. Chat can't tell which transcript is its own.")
        case .unidentifiedSession(.opencode):
            String(localized: "herdr reports a session name that isn't an OpenCode session id, so Chat can't tell which conversation is this Agent's.")
        case .unidentifiedSession(.agy):
            String(localized: "herdr reports a session name that isn't an Antigravity CLI conversation id, so Chat can't tell which conversation is this Agent's.")
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
            String(localized: "Install the Host Helper from this Host's details, then restart Pi.")
        case .cannotTellSession(.omp):
            String(localized: "Install the Host Helper from this Host's details and restart Oh My Pi, or send a first message in the terminal.")
        case .cannotTellSession(let program):
            program.sessionEvidenceHelp
        case .multipleSessions(.codex, _):
            String(
                localized: "This Codex holds multiple conversations. Exit Codex and run \("codex resume \(ChatLaunchNotice.unbrokenNoDaemon)").",
                comment: "In Chat's place when Codex holds multiple conversations after /new: the resume command")
        case .multipleSessions(let program, _):
            String(
                localized: "This \(program.chatName) holds multiple conversations. Restart it to reconnect Chat.",
                comment: "In Chat's place when an Agent holds multiple conversations after /new: the program's name")
        case .noConversationYet(let program):
            String(
                localized: "\(program.chatName) starts a conversation with its first message. Send one here or in the terminal, and Chat follows it.",
                comment: "In Chat's place before the program started a conversation: the program's name")
        case .extensionNotLoaded(let program, let turnedOff):
            // One whole text per combination, so each language joins its
            // sentences its own way.
            switch (turnedOff, program == .omp) {
            case (true, false):
                String(
                    localized: "Restart \(program.chatName) without \(Self.unbrokenNoExtensions).",
                    comment: "In Chat's place when Pi or Oh My Pi started with --no-extensions: program name, then the flag")
            case (true, true):
                String(
                    localized: "Restart Oh My Pi without \(Self.unbrokenNoExtensions), or send a first message in the terminal.",
                    comment: "In Chat's place when Oh My Pi started with --no-extensions: the flag")
            case (false, false):
                String(
                    localized: "Restart \(program.chatName) with extensions enabled so it loads Heeler's extension.",
                    comment: "In Chat's place when Heeler's extension is installed but not loaded: program name")
            case (false, true):
                String(
                    localized: "Restart Oh My Pi with extensions enabled, or send a first message in the terminal.",
                    comment: "In Chat's place when Heeler's extension is installed for Oh My Pi but not loaded")
            }
        case .cannotTellSessionOnWindows(let program) where program == .pi || program == .omp:
            String(localized: "Add Heeler's extension below, then restart \(program.chatName).")
        case .cannotTellSessionOnWindows(let program):
            program.sessionEvidenceHelp
        case .cannotReadProcessesOnWindows:
            String(localized: "Heeler couldn't read this Agent's process. Run herdr-core and SSH at the same elevation.")
        case .cannotTellSessionOnRex(let program, let extensionInPlace):
            // One whole text per combination, so each language joins its
            // sentences its own way. Oh My Pi also binds without the extension.
            switch (extensionInPlace, program == .omp) {
            case (false, false):
                String(localized: "Add Heeler's extension below, then restart \(program.chatName).")
            case (false, true):
                String(localized: "Add Heeler's extension below and restart Oh My Pi, or send a first message in the terminal.")
            case (true, false):
                String(
                    localized: "Restart \(program.chatName) with extensions enabled so it loads Heeler's extension.",
                    comment: "In Chat's place when Heeler's extension is installed but not loaded: program name")
            case (true, true):
                String(
                    localized: "Restart Oh My Pi with extensions enabled, or send a first message in the terminal.",
                    comment: "In Chat's place when Heeler's extension is installed for Oh My Pi but not loaded")
            }
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
            let command = "codex \(ChatLaunchNotice.unbrokenNoDaemon) resume"
            return String(
                localized: "Exit Codex, then run \(command).",
                comment: "In Chat's place when Codex started without --no-daemon: the resume command")
        case nil: return explanation
        }
    }

    /// Guide link shown below the unavailable view's action capsules.
    func guideURL(
        launchNotice: ChatLaunchNotice?,
        localization: String = Bundle.main.preferredLocalizations.first ?? "en"
    ) -> URL? {
        if let notice = self.launchNotice(launchNotice) { return notice.guideURL(localization: localization) }
        switch self {
        case .codexSharedDaemon:
            return ChatTroubleshootingGuide.url(for: .codexSharedServer, localization: localization)
        case .cannotTellSession, .multipleSessions, .cannotTellSessionOnWindows, .cannotReadProcessesOnWindows,
            .extensionNotLoaded, .cannotTellSessionOnRex:
            return ChatTroubleshootingGuide.url(for: .cannotTellConversation, localization: localization)
        default:
            return nil
        }
    }

    /// `--no-extensions` with non-breaking hyphens for plain text.
    private static let unbrokenNoExtensions = "\u{2011}\u{2011}no\u{2011}extensions"

    /// Uses ASCII hyphens with word joiners so SF Mono glyphs stay uniform
    /// without mid-flag line breaks.
    private static let inlineNoDaemon = "-\u{2060}-\u{2060}no\u{2060}-\u{2060}daemon"
    private static let inlineNoExtensions = "-\u{2060}-\u{2060}no\u{2060}-\u{2060}extensions"

    /// Trimmed placeholder copy with inline monospaced commands where applicable.
    func unavailableDescription(launchNotice: ChatLaunchNotice?) -> Text {
        if self.launchNotice(launchNotice) == .codexSharedServer {
            let command = Self.inlineCode("codex\u{00A0}\(Self.inlineNoDaemon)\u{00A0}resume")
            return Text(
                "Exit Codex, then run \(command).",
                comment: "In Chat's place when Codex started without --no-daemon: the resume command")
        }
        switch self {
        case .codexSharedDaemon:
            let command = Self.inlineCode("codex\u{00A0}resume\u{00A0}\(Self.inlineNoDaemon)")
            return Text(
                "Exit Codex, run \(command), and pick the conversation in Codex's list.",
                comment: "In Chat's place on herdr-core when Codex started without --no-daemon: the resume command")
        case .multipleSessions(.codex, _):
            let resumeCommand = Self.inlineCode("codex\u{00A0}resume\u{00A0}\(Self.inlineNoDaemon)")
            return Text(
                "This Codex holds multiple conversations. Exit Codex and run \(resumeCommand).",
                comment: "In Chat's place when Codex holds multiple conversations after /new: the resume command")
        case .extensionNotLoaded(let program, true):
            let flag = Self.inlineCode(Self.inlineNoExtensions)
            if program == .omp {
                return Text(
                    "Restart Oh My Pi without \(flag), or send a first message in the terminal.",
                    comment: "In Chat's place when Oh My Pi started with --no-extensions: the flag")
            }
            return Text(
                "Restart \(program.chatName) without \(flag).",
                comment: "In Chat's place when Pi or Oh My Pi started with --no-extensions: program name, then the flag")
        default:
            return Text(explanation(launchNotice: launchNotice))
        }
    }

    private static func inlineCode(_ text: String) -> Text {
        Text(verbatim: text)
            .font(.subheadline.monospaced().weight(.medium))
            .foregroundStyle(Color.primary.opacity(0.88))
    }

    /// One line for a banner over the timeline. `showingSavedMessages` is
    /// false when the timeline holds only messages sent from this device,
    /// as with a new conversation whose transcript isn't written yet.
    func bannerText(showingSavedMessages: Bool) -> String {
        // Each line whole, with and without the saved messages, so no
        // language joins a sentence it can't order.
        let saved = showingSavedMessages
        return switch self {
        case .amp(let problem): problem.explanation
        case .noSession:
            String(localized: "Waiting for the Agent to report its conversation.")
        case .noConversationYet(let program):
            saved
                ? String(
                    localized: "Waiting for \(program.chatName) to start the conversation. Showing saved messages.",
                    comment: "Chat's banner over messages saved earlier: the program's name")
                : String(
                    localized: "Waiting for \(program.chatName) to start the conversation.",
                    comment: "Chat's banner: the program's name")
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
        case .cannotTellSession, .multipleSessions, .cannotTellSessionOnWindows, .cannotReadProcessesOnWindows,
            .extensionNotLoaded, .cannotTellSessionOnRex:
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

    /// A Pi or Oh My Pi with no Helper to bring the extension that names its session:
    /// on a native Windows core Host (ADR 0033), and in a Rex terminal whose
    /// extension folder holds none that reports there (ADR 0056).
    var offersHeelersExtension: Bool {
        switch self {
        case .cannotTellSessionOnWindows(let program): program.namesItsSessionThroughHeelersExtension
        case .cannotTellSessionOnRex(_, let extensionInPlace): !extensionInPlace
        default: false
        }
    }

    /// Whether looking again could find something the user may have fixed.
    var offersRetry: Bool {
        switch self {
        case .amp: true
        case .noSession(.agy), .noConversationYet:
            false
        case .noSession, .notFound, .mismatched, .startScreen, .cannotTellSession, .multipleSessions,
            .cannotTellSessionOnWindows, .cannotReadProcessesOnWindows, .extensionNotLoaded, .transcriptOff,
            .codexSharedDaemon, .cannotTellSessionOnRex:
            true
        case .sessionStore(_, let problem): problem.isRetryable
        default: false
        }
    }

    /// Whether Chat shows the empty-conversation placeholder instead of the
    /// unavailable view: the conversation is new and the Composer starts it.
    var isAwaitingFirstMessage: Bool {
        switch self {
        case .awaitingFirstMessage, .noConversationYet, .noSession(.agy): true
        default: false
        }
    }

    /// Whether Chat waits for the program rather than for the user: its
    /// banner shows progress and offers nothing to do.
    var isWaiting: Bool {
        switch self {
        case .noSession, .noConversationYet, .awaitingFirstMessage: true
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
    /// Searching or opening on the Host failed before any message could be read;
    /// the read-failure banner above explains what happened and offers Retry.
    case readFailed
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
        case .locating:
            if !isHostConnected {
                self = .awaitingHost
            } else if conversation.readFailure != nil {
                self = .readFailed
            } else {
                self = .locating
            }
        case .following:
            self = isHostConnected && conversation.readFailure != nil ? .readFailed : .empty
        case .unavailable(let reason):
            let mayBeNotice = reason.launchNotice(.codexSharedServer) != nil
            self =
                checkingLaunch && mayBeNotice && isHostConnected && conversation.readFailure == nil
                ? .locating : .unavailable(reason)
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
        case .amp: "Amp"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .pi: "Pi"
        case .omp: "Oh My Pi"
        case .grok: "Grok Build"
        case .opencode: "OpenCode"
        case .agy: "Antigravity CLI"
        }
    }

    /// What Chat's "can't tell" says about this program on herdr-core, tmux, and Rex,
    /// where the evidence is what the Host shows of its process (ADR 0034).
    fileprivate var sessionEvidenceHelp: String {
        switch self {
        case .amp: return AmpChatProblem.unidentified.explanation
        case .codex, .grok:
            return String(localized: "Send a first message in the terminal.")
        case .opencode:
            return String(localized: "Start OpenCode 2.1 or later from New Agent, or add Heeler's plugin.")
        case .claude, .pi, .omp:
            return String(localized: "Finish signing in or answer any prompt in the terminal.")
        case .agy:
            return String(localized: "Send a first message in the terminal, or close the other terminal holding this conversation.")
        }
    }
}

/// Sections of the Chat troubleshooting guide linked from unavailable screens.
/// The guide is published in English and Simplified Chinese; every other
/// language opens the English page.
enum ChatTroubleshootingGuide {
    enum Section: Equatable, Sendable {
        case codexSharedServer
        case cannotTellConversation
    }

    /// Each fragment is a heading of `docs/guides/chat-troubleshooting.md` or
    /// `docs/guides/zh/chat-troubleshooting.md` as GitHub slugs it, which the
    /// docs site keeps.
    static func url(
        for section: Section,
        localization: String = Bundle.main.preferredLocalizations.first ?? "en"
    ) -> URL? {
        let isChinese = localization == "zh-Hans"
        var url = URLComponents()
        url.scheme = "https"
        url.host = "docs.heeler.bybee.dev"
        url.path = isChinese ? "/zh/chat-troubleshooting" : "/chat-troubleshooting"
        url.fragment =
            switch section {
            case .codexSharedServer: "codex-started-without---no-daemon"
            case .cannotTellConversation: "cant-tell-the-conversation"
            }
        return url.url
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
    var installAmp: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(reason.title(launchNotice: launchNotice), systemImage: reason.systemImage(launchNotice: launchNotice))
        } description: {
            reason.unavailableDescription(launchNotice: launchNotice)
        } actions: {
            VStack(spacing: 12) {
                VStack(spacing: 10) {
                    capsuleActions
                }
                .fixedSize(horizontal: true, vertical: false)

                if let guide = reason.guideURL(launchNotice: launchNotice) {
                    Link(destination: guide) {
                        HStack(spacing: 4) {
                            Text("Learn More")
                                .font(.footnote.weight(.medium))
                            Image(systemName: "arrow.up.right")
                                .font(.caption2.weight(.semibold))
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.unavailable.learnMore")
                }
            }
        }
        .accessibilityIdentifier("chat.unavailable")
    }

    /// Whether a settling action leads the capsule stack as the primary action.
    private var hasSettlingAction: Bool {
        chooseConversation != nil
            || (ampInstallTitle != nil && installAmp != nil)
            || (reviewEdit != nil && reason.offersOpenCodePluginEdit)
            || (addExtension != nil && reason.offersHeelersExtension)
    }

    private var ampInstallTitle: String? {
        switch reason {
        case .amp(.missing): String(localized: "Install Amp Plugin")
        case .amp(.update): String(localized: "Update Amp Plugin")
        default: nil
        }
    }

    @ViewBuilder private var capsuleActions: some View {
        if let ampInstallTitle, let installAmp {
            Button(ampInstallTitle, action: installAmp)
                .buttonStyle(UnavailableCapsuleStyle(prominence: .primary))
                .accessibilityIdentifier("chat.amp.install")
        }
        if let chooseConversation {
            Button(action: chooseConversation) { Text(ChatCandidatePickerView.title) }
                .buttonStyle(UnavailableCapsuleStyle(prominence: .primary))
                .accessibilityIdentifier("chat.chooseConversation")
        }
        if let reviewEdit, reason.offersOpenCodePluginEdit {
            Button(action: reviewEdit) { Text(OpenCodePluginEdit.offerTitle) }
                .buttonStyle(UnavailableCapsuleStyle(prominence: chooseConversation == nil ? .primary : .secondary))
                .accessibilityIdentifier("chat.unavailable.openCodeEdit")
        }
        if let addExtension, reason.offersHeelersExtension {
            Button(action: addExtension) { Text("Add Heeler's Extension…") }
                .buttonStyle(UnavailableCapsuleStyle(prominence: chooseConversation == nil ? .primary : .secondary))
                .accessibilityIdentifier("chat.unavailable.addExtension")
        }
        Button(action: showAgentTerminal) { Text(AgentDetailSurface.terminal.showTitle) }
            .buttonStyle(UnavailableCapsuleStyle(prominence: hasSettlingAction ? .secondary : .primary))
            .accessibilityIdentifier("chat.unavailable.showAgentTerminal")
        if reason.offersRetry {
            Button(action: retry) {
                Text("Check Again")
                    // Hidden rather than gone, so the capsule keeps its width.
                    .opacity(isChecking ? 0 : 1)
                    .overlay {
                        if isChecking { ProgressView() }
                    }
            }
            .buttonStyle(UnavailableCapsuleStyle(prominence: .secondary))
            .allowsHitTesting(!isChecking)
            .accessibilityLabel(isChecking ? Text("Checking") : Text("Check Again"))
            .accessibilityIdentifier("chat.unavailable.checkAgain")
            // A new button rather than new content: draws the active state
            // cleanly when switching between label and spinner.
            .id(isChecking)
        }
    }
}

/// Equal-width primary/secondary capsule stack matching the themed surface,
/// for a screen that stands in for content and stacks its ways out. The
/// stack around the buttons takes `fixedSize(horizontal:vertical:)`, so
/// every capsule is as wide as the widest.
struct UnavailableCapsuleStyle: ButtonStyle {
    enum Prominence {
        case primary
        case secondary
    }

    let prominence: Prominence

    func makeBody(configuration: Configuration) -> some View {
        CapsuleLabel(prominence: prominence, configuration: configuration)
    }

    private struct CapsuleLabel: View {
        let prominence: Prominence
        let configuration: Configuration
        @Environment(\.themeColors) private var themeColors
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var isEnabled
        @ScaledMetric(relativeTo: .callout) private var minimumButtonWidth: CGFloat = 196

        var body: some View {
            configuration.label
                .font(prominence == .primary ? .callout.weight(.semibold) : .callout.weight(.medium))
                .foregroundStyle(
                    prominence == .primary ? themeColors.background : Color.primary.opacity(0.92))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .frame(
                    minWidth: minimumButtonWidth,
                    maxWidth: .infinity,
                    minHeight: prominence == .primary ? 44 : 42)
                .background {
                    if prominence == .primary {
                        Capsule().fill(Color.primary)
                    } else {
                        Capsule()
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06))
                            .overlay {
                                Capsule().strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color.primary.opacity(colorScheme == .dark ? 0.26 : 0.16),
                                            Color.primary.opacity(0.08),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing),
                                    lineWidth: 1)
                            }
                    }
                }
                .contentShape(.capsule)
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
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
    /// Hides the banner when the user acknowledges an informational warning.
    var dismiss: (() -> Void)?

    private var hasSecondaryAction: Bool { secondaryActionTitle != nil && secondaryAction != nil }
    private var hasDismiss: Bool { dismiss != nil }

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
                if let dismiss {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, -4)
                    .padding(.vertical, -4)
                    .accessibilityLabel("Dismiss")
                    .accessibilityIdentifier("chat.banner.dismiss")
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
        .accessibilityElement(children: hasSecondaryAction || hasDismiss ? .contain : .combine)
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
