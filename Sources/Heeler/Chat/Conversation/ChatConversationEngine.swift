import Foundation

/// Why Chat cannot show a conversation from the Host. Each case has its own
/// explanation; none of them is an error the user caused.
enum ChatUnavailableReason: Equatable, Sendable {
    case amp(AmpChatProblem)
    /// herdr has reported no session ID for the Agent. This does not establish
    /// whether the program's integration is installed.
    case noSession(ChatProgram)
    /// The session record names something other than a session id the
    /// program's naming accepts, such as a Codex thread name after
    /// `resume <name>`. The program words the explanation.
    case unidentifiedSession(ChatProgram)
    /// The session record is not one Chat reads.
    case unsupportedSession
    /// No transcript was found. `searchedAll` is false when the search was
    /// cut short, so the file may still exist.
    case notFound(searchedAll: Bool)
    /// The program started the conversation but writes its file only with
    /// the first message (Claude Code) or the first reply (Pi, Oh My Pi):
    /// the conversation is new, and a message starts it.
    case awaitingFirstMessage(ChatProgram)
    /// Codex compressed the rollout, which Chat does not read.
    case compressed
    /// A file under the session's name holds another conversation.
    case mismatched
    /// The transcript is in a format Chat does not read.
    case unsupportedFormat(String)
    /// The store the program keeps its conversations in, which Chat reads
    /// by query (ADR 0025), cannot give this one.
    case sessionStore(ChatProgram, ChatSessionStoreProblem)
    /// The program shows its home screen, where the conversation herdr
    /// still reports is no longer open: OpenCode keeps reporting one after
    /// `/new` or `/clear` (ADR 0025).
    case startScreen(ChatProgram)
    /// Nothing on the Host shows which conversation a herdr-core Agent is in,
    /// and Chat never guesses (ADR 0034).
    case cannotTellSession(ChatProgram)
    /// The Agent's process holds more than one conversation (for example after
    /// `/new` in Codex or Grok Build), so Chat can't tell which one is on
    /// screen (ADR 0034). `offersPick` is false on Windows, which has no picker.
    case multipleSessions(ChatProgram, offersPick: Bool = true)
    /// The same on a native Windows Host, which has no Host Helper to offer.
    case cannotTellSessionOnWindows(ChatProgram)
    /// The same for a Pi or Oh My Pi that hasn't loaded Heeler's extension, which is
    /// in its extension folder: it runs with its extensions turned off, as
    /// `turnedOff` says its arguments show, or started before the extension was there.
    case extensionNotLoaded(ChatProgram, turnedOff: Bool)
    /// The same because the read of the Agent's process failed on that Host, which
    /// its extension would not change (ADR 0034).
    case cannotReadProcessesOnWindows(ChatProgram)
    /// The same for a Pi or Oh My Pi in a Rex terminal, whose Server has no Host
    /// Helper to bring the extension that names its session, so Chat offers it
    /// (ADR 0056). `extensionInPlace` says the Agent's own extension folder holds
    /// one that reports there, which this process then has not loaded.
    case cannotTellSessionOnRex(ChatProgram, extensionInPlace: Bool)
    /// The Agent's process carries a variable that stops the program keeping
    /// a Transcript, so there is no file to wait for (ADR 0034).
    case transcriptOff(ChatTranscriptOffVariable, coreCarriesIt: Bool)
    /// A herdr-core Codex on the shared daemon, whose windows' sessions look alike
    /// from outside. Only reopening it with `--no-daemon` offers Chat (ADR 0034).
    case codexSharedDaemon
    /// A herdr-core program that shows no conversation yet and makes one with its
    /// first message: Antigravity CLI before its first prompt (ADR 0034). There is
    /// nothing to choose, and a Send starts it.
    case noConversationYet(ChatProgram)

    /// Whether Chat shows the explanation in the conversation's place even
    /// over saved messages, which stay in memory until the program shows
    /// the conversation again.
    var hidesConversation: Bool {
        switch self {
        case .startScreen, .amp: true
        default: false
        }
    }

    /// Nothing exact names the conversation on a POSIX core Host, which is where a
    /// pick can stand in for it (ADR 0034).
    var leavesItToAPick: Bool {
        switch self {
        case .cannotTellSession, .extensionNotLoaded: true
        case .multipleSessions(_, let offersPick): offersPick
        default: false
        }
    }
}

/// Variables that stop Claude Code keeping a Transcript when it inherits them,
/// as from a core started inside a Claude Code session (ADR 0034).
enum ChatTranscriptOffVariable: String, CaseIterable, Equatable, Sendable {
    /// No registry entry and no Transcript, for the values Claude Code honors.
    /// Read only once no registry entry turned up.
    case childSession = "CLAUDE_CODE_CHILD_SESSION"
    /// No Transcript.
    case skipPromptHistory = "CLAUDE_CODE_SKIP_PROMPT_HISTORY"
}

extension ChatProgram {
    /// Whether a new conversation's file comes only with the first reply,
    /// as Pi and Oh My Pi write it, rather than with the first message, as
    /// Claude Code does: a message waits for its record as long as the
    /// reply takes.
    var writesNewConversationWithFirstReply: Bool {
        switch self {
        case .pi, .omp: true
        case .claude, .codex, .grok, .opencode, .agy, .amp: false
        }
    }

    /// Whether what names the running session is Heeler's own extension, which
    /// Pi and Oh My Pi load from their extension folders (ADR 0033).
    var namesItsSessionThroughHeelersExtension: Bool {
        switch self {
        case .pi, .omp: true
        case .claude, .codex, .grok, .opencode, .agy, .amp: false
        }
    }
}

/// Why a program's session store cannot give Chat the conversation herdr
/// reports (ADR 0025). Only OpenCode keeps one.
enum ChatSessionStoreProblem: Equatable, Sendable {
    /// No database where Chat reads it, the path shown with `~` for home.
    case noStore(path: String)
    /// The database has no conversation with the reported id.
    /// `otherStores` names the store files beside it, which Chat never reads.
    case sessionMissing(otherStores: [String])
    /// The Host has neither `sqlite3` nor a `python3` Chat can use.
    case noReader
    /// The reader's SQLite, at this version, is too old or lacks JSON.
    case readerTooOld(String)
    /// The database's side files are gone: OpenCode isn't running.
    case storeClosed
    /// The database holds only OpenCode 1.x tables.
    case olderOpenCode
    /// Tables or columns Chat reads are missing, named in the text.
    case unsupportedLayout(String)
    /// herdr reports a subagent's session; Chat follows the root's.
    case subagentSession

    /// Whether the user can fix it on the Host, so Chat offers Retry.
    var isRetryable: Bool {
        switch self {
        case .noStore, .sessionMissing, .noReader, .readerTooOld, .storeClosed: true
        case .olderOpenCode, .unsupportedLayout, .subagentSession: false
        }
    }

    /// Whether the store may answer later without the user doing anything,
    /// as when OpenCode starts, so Chat looks again by itself. The rest wait
    /// for Retry, a status change or a send.
    var reopensByItself: Bool {
        switch self {
        case .noStore, .sessionMissing, .storeClosed: true
        case .noReader, .readerTooOld, .olderOpenCode, .unsupportedLayout, .subagentSession: false
        }
    }
}

/// Whether earlier messages exist above the ones shown.
enum ChatOlderHistory: Equatable, Sendable {
    case reachedStart
    case available
    case loading
    case failed(String)
}

/// Why an expanded row's output could not be read again.
enum ChatToolOutputFailure: Error, Equatable, Sendable {
    /// No transcript is open to read it from.
    case notFollowing
    /// Its line is longer than `ChatToolPreview.maximumFetchBytes`.
    case tooLong
    /// The line no longer holds the call: the file was rewritten or is
    /// gone.
    case gone
    /// The Host could not be read, for this reason.
    case unreadable(String)

    /// What the row says.
    var message: String {
        switch self {
        case .notFollowing: String(localized: "Output is available when connected.")
        case .tooLong: String(localized: "This output is too long to show here.")
        case .gone: String(localized: "Output is no longer available.")
        case .unreadable(let reason): String(localized: "Couldn't load output: \(reason)")
        }
    }

    /// Whether reading again could succeed: a line too long, or no longer
    /// there, stays so.
    var canRetry: Bool {
        switch self {
        case .notFollowing, .unreadable: true
        case .tooLong, .gone: false
        }
    }
}

/// What one conversation looks like after its engine's last step.
struct ChatConversationSnapshot: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Looking for the transcript; entries the device kept may show.
        case locating
        /// Following the transcript at this path, or the conversation a
        /// source read by query gives as its path.
        case following(path: String)
        case unavailable(ChatUnavailableReason)
    }

    var phase: Phase = .locating
    var transcript = ChatTranscript()
    /// Every entry shown comes from the device: the Host has not confirmed
    /// them on this visit, or the file has since gone.
    var isFromCache = false
    var older: ChatOlderHistory = .reachedStart
    /// Earlier messages load only when the user asks: a request the
    /// timeline made by itself, for a program that bounds such requests
    /// (`TranscriptFollower.Limits.automaticOlderSearch`), read its limit
    /// without reaching the opener of the turn the window starts in. A
    /// request that brings an opener clears it, and so does a fresh tail.
    var olderAwaitsUser = false
    /// The last read failed this way. Whatever was read before still shows.
    var readFailure: TransportError?
    /// How far the transcript has been read. A prompt the program records
    /// after a send lands at or after the offset read when it was sent.
    var readOffset: UInt64 = 0
    /// The last read stopped at its budget, short of what the source holds.
    var hasUnreadRecords = false
    /// The live window starts at the source's first record, so nothing it holds is
    /// before what was read.
    var readsFromStart = false
    /// Bumped when offsets read before may now locate other records: the
    /// file was rewritten, replaced or moved, or is shorter than the saved
    /// document read it to.
    var layoutGeneration = 0
    /// Bumped whenever anything above changes.
    var revision = 0
}

/// What a reducer is built from: the file it reads and, for a program whose
/// records depend on it, the file's first line, which a tail window starts
/// after.
struct ChatReducerSeed: Sendable {
    let path: String
    let firstLine: ChatLine?
}

/// How Chat reads one program's transcript.
struct ChatTranscriptAdapter: Sendable {
    /// Bumped when the program's normalization changes.
    var revision: Int
    /// The framing limits for this program's lines.
    var limits = TranscriptFollower.Limits()
    /// Whether `makeReducer` needs the file's first line.
    var wantsFirstLine = false
    /// Tree transcripts must prove ancestry from live records before
    /// restoring earlier entries: a cached prefix may belong to an old branch.
    var joinsCachedHistory = true
    var makeReducer: @Sendable (ChatReducerSeed) -> any ChatTranscriptReducer
    /// What a sent prompt and a recorded one are compared on: the text as
    /// the program records it, which drops what Heeler adds when it sends.
    var echoKey: @Sendable (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// What the program records for a send it moves pasted image paths
    /// around in, each placeholder back as its path; nil when it moves none.
    var pastedImageEcho: @Sendable (String) -> String? = { _ in nil }
    /// The image files a send gives up as `[Image #N]` placeholders, in
    /// placeholder order; empty when the send gives up none.
    var pastedImagePaths: @Sendable (String) -> [String] = { _ in [] }
    /// Names the conversation from the file's first bytes, for a program
    /// that rewrites them; nil compares the bytes.
    var identity: TranscriptFollower.Identity?
    /// Whether a recorded prompt keeps its entry when the program rewrites
    /// its file, so sends are matched to entries rather than to offsets.
    var echoesByEntry = false
    /// Makes the source for a program whose conversations are read from its
    /// store by query rather than from a transcript file (ADR 0025); it
    /// returns nil for a session id the store cannot be asked about. Nil
    /// for a program whose transcript file the engine finds and follows.
    var makeRecordSource: (@Sendable (_ sessionID: String) -> (any ChatTranscriptSource)?)? = nil

    /// Whether the conversation is read by query, so there is no file to
    /// look for.
    var readsByQuery: Bool { makeRecordSource != nil }
    /// Whether the program can leave a send unrecorded for as long as herdr
    /// reports the Agent Working or Blocked, so its echo times out on the
    /// time herdr reports neither rather than on the time since delivery.
    var echoClockStopsWhileWorking = false
    /// Reads the Agent's screen before a send, for a program whose screen
    /// can move to another session without herdr reporting it. The input
    /// is nil while herdr reports no session Chat follows.
    var sessionCheck: (@Sendable (ANSIScreen, ChatSessionCheckInput?) -> ChatScreenSessionVerdict)? = nil
    /// The program's log of the prompts it submits, which names the
    /// session that took each one.
    var sendWitness: ChatSendWitness? = nil
    /// Converts older entries when the saved document contains all the source
    /// information required by the current revision.
    var migrateCache: (@Sendable (ChatCacheDocument) -> ChatCacheDocument?)? = nil
}

/// One conversation's transcript on its Host: finds the file and follows
/// it, or follows the source the adapter makes for a store read by query
/// (ADR 0025). It feeds the program's reducer and keeps what it showed in
/// the device cache. It also reads the journals of the Workflows the
/// transcript lists.
///
/// The owner makes one call at a time and waits for it. Each call may read
/// the Host several times, and a second call interleaved at one of those
/// awaits would follow the file from a stale offset. `output(of:)` is the
/// exception: it changes nothing, so it may run alongside.
actor ChatConversationEngine {
    /// How Workflow journals are read beside the transcript.
    struct WorkflowLimits: Sendable {
        var follower = WorkflowJournalFollower.Limits()
        /// The most one journal reads in one call.
        var journalBudget = 128 << 10
        /// The most all journals read in one call, and how many are looked
        /// at, least recently looked at first.
        var callBudget = 256 << 10
        var journalsPerCall = 2
        /// How often `<session>/workflows/<runId>.json` is stat'd while a
        /// Workflow still reads running, and how long it settles so a
        /// `<task-notification>` in the main transcript lands first.
        var runEndCheckInterval: TimeInterval = 5
        var runEndSettle: TimeInterval = 5
        /// How many running background commands' output files one call
        /// stats, least recently looked at first, and how long one waits
        /// before it is looked at again: its time only keeps a command
        /// that has run for hours from reading as quiet.
        var commandOutputsPerCall = 4
        var commandOutputCheckInterval: TimeInterval = 30
        /// How often `<session>/subagents/` is listed for teammates, and how
        /// many new meta files one call reads.
        var teammateListInterval: TimeInterval = 60
        var teammateMetasPerCall = 8
        /// How many teammate transcripts one call stats, least recently
        /// looked at first, how long one waits before it is looked at again,
        /// a running one sooner, and how much of a changed one's end is read.
        var teammatesPerCall = 4
        var runningTeammateCheckInterval: TimeInterval = 10
        var idleTeammateCheckInterval: TimeInterval = 30
        var teammateTailBytes = 64 << 10
        /// A teammate whose launch is not loaded joins the list only when
        /// its transcript changed this recently: one whose Claude Code
        /// stopped mid-turn leaves a transcript that never ends.
        var foundTeammateQuiet: TimeInterval = 30 * 60
        /// Waits after a failed look at a journal, one per failure; the
        /// last repeats.
        var backoff: [TimeInterval] = [2, 4, 8, 16, 30]
    }

    /// One Workflow journal and what it showed.
    private struct FollowedJournal {
        var follower: WorkflowJournalFollower
        var journal = ClaudeWorkflowJournal()
        /// What shows: the journal as of the last time it was read to its
        /// end, so counts never climb through a first read.
        var progress: ChatWorkflowProgress?
        /// The call that last looked at it.
        var lastLook = 0
        var failures = 0
        var nextLook: Date?
        /// Read to its end after the Workflow ended: nothing more comes.
        var isSettled = false
        /// Too large, or the Host refuses it: not looked at again.
        var isUnreadable = false
    }

    /// One running Claude Workflow's end-of-run state file
    /// (`<session>/workflows/<runId>.json`), written only when the run ends.
    private struct FollowedWorkflowRunEnd {
        let path: String
        var launchedAt: Date?
        var lastLook = 0
        var failures = 0
        var nextLook: Date?
        var isUnreadable = false
        var firstSeenAt: Date?
        var settledEvidence: ChatBackgroundWorkEvidence?
    }

    /// One running Claude Code background command's output file
    /// (`<tasks>/<task id>.output`), which the command writes as it runs.
    private struct FollowedCommandOutput {
        let path: String
        var lastLook = 0
        var failures = 0
        var nextLook: Date?
        var isUnreadable = false
        /// When the Host last wrote the file, as of the last look.
        var lastSeenAt: Date?
    }

    /// One Claude Code teammate under `<session>/subagents/`, followed in
    /// its own transcript.
    private struct FollowedTeammate {
        let name: String
        let title: String?
        /// When its meta file was written, as it was spawned.
        let spawnedAt: Date?
        let path: String
        var size: UInt64?
        var turn: ClaudeTeammateTurn?
        /// When the Host last wrote its transcript, as of the last look.
        var lastSeenAt: Date?
        var lastLook = 0
        var failures = 0
        var nextLook: Date?
        var isUnreadable = false
    }

    /// One request for older history, across the calls that read its pages.
    private struct OlderSearch {
        var pageLength: Int
        /// What a bounded automatic request may still read.
        var allowance: Int?
    }

    let reference: ConversationReference
    let cacheKey: ChatCacheKey
    private let files: ChatHostFiles
    private let cache: any ChatTranscriptCache
    private let adapter: ChatTranscriptAdapter
    private let now: @Sendable () -> Date
    /// How often entries that keep changing are saved.
    private let saveInterval: TimeInterval

    /// Where the Agent runs and was launched, which Claude files sessions
    /// under, and the newest directory the transcript says it moved to.
    private var directories: [String] = []
    private var relocatedDirectory: String?
    private var source: (any ChatTranscriptSource)?
    private var reducer: (any ChatTranscriptReducer)?
    /// True while `.following` is confirmed against `cached` without having
    /// downloaded and reduced the tail window yet.
    private var isCacheBacked = false
    /// A transcript was followed: one missing now has gone, not yet to come.
    private var hasFollowed = false
    /// What herdr reported the Agent doing when a search of every Claude
    /// project directory last looked for the new conversation's file. It
    /// comes with a prompt, under a directory the Agent reports, so until
    /// the Agent does something else, looking there is enough.
    private var newConversationActivity: ChatAgentActivity?
    /// The last open's word that a delivered message went unrecorded.
    /// Claude Code writes a message as it takes it, so a session that lost
    /// one saves nothing, and is not a new conversation still to start.
    private var lostAMessage = false
    /// Set by `open` when unconfirmed Composer sends require `recordedPrompts`
    /// from a live tail read.
    private var requiresLiveBody = false
    /// The document last restored or saved. Its entries older than the
    /// live window show above it once the window reaches what it covers.
    private var cached: ChatCacheDocument?
    /// The line before the window is too long to page past.
    private var olderUnreadable = false
    /// The request for older history still reading, between its pages.
    private var olderSearch: OlderSearch?
    private var context = ChatProjectionContext()
    private var needsProjection = false
    private var snapshot = ChatConversationSnapshot()
    private var lastSave: (revision: Int, date: Date)?
    private let workflowLimits: WorkflowLimits
    /// Journals by the Workflow's id, for the Workflows the transcript
    /// lists.
    private var journals: [String: FollowedJournal] = [:]
    private var journalCalls = 0
    private var workflowRunEnds: [String: FollowedWorkflowRunEnd] = [:]
    private var workflowRunEndCalls = 0
    private var commandOutputs: [String: FollowedCommandOutput] = [:]
    private var commandOutputCalls = 0
    /// The `subagents/` folder the teammates below are in.
    private var teammateFolder: String?
    /// Teammates by agent id, and the named agents whose meta names none.
    private var teammates: [String: FollowedTeammate] = [:]
    private var notTeammates: Set<String> = []
    private var teammatesListedAt: Date?
    private var teammateCalls = 0
    /// Teammates the Host showed running that no loaded record launched,
    /// by agent id, carried into every projection like saved work.
    private var foundTeammates: [String: ChatBackgroundWorkItem] = [:]
    private let agyBackgroundWorkLimits: AgyBackgroundWorkFollower.Limits
    private var agyBackgroundWork = AgyBackgroundWorkFollower()
    private struct FollowedSwarmWorker {
        let workerID: String
        let path: String
        var follower: TranscriptFollower
        var reducer: AgyTranscriptReducer
        var cachedTranscript: ChatTranscript?
        var cachedIsWorking: Bool?
    }

    private let agySwarmLimits: AgySwarmFollower.Limits
    private var agySwarm = AgySwarmFollower()
    private var agyWorkerPeek: FollowedSwarmWorker?
    /// Where the Agent's own program keeps Transcripts, from a check of its process
    /// (ADR 0034): Claude Code's config dir, or Pi's or Oh My Pi's sessions folder.
    /// Nil looks in the Host's default place.
    private let transcriptRoot: String?
    /// Heeler can name an id before the program has written it (ADR 0034).
    private let sessionMayPrecedeItsStore: Bool
    /// The localization entries are worded in now, which a saved document
    /// must match to join live rows (`ChatCacheDocument.localization`).
    private let localization: String

    init(
        reference: ConversationReference,
        cacheKey: ChatCacheKey,
        files: ChatHostFiles,
        cache: any ChatTranscriptCache,
        adapter: ChatTranscriptAdapter,
        saveInterval: TimeInterval = 10,
        workflowLimits: WorkflowLimits = WorkflowLimits(),
        agyBackgroundWorkLimits: AgyBackgroundWorkFollower.Limits = AgyBackgroundWorkFollower.Limits(),
        agySwarmLimits: AgySwarmFollower.Limits = AgySwarmFollower.Limits(),
        transcriptRoot: String? = nil,
        sessionMayPrecedeItsStore: Bool = false,
        localization: String = ChatCacheDocument.currentLocalization,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transcriptRoot = transcriptRoot
        self.sessionMayPrecedeItsStore = sessionMayPrecedeItsStore
        self.localization = localization
        self.reference = reference
        self.cacheKey = cacheKey
        self.files = files
        self.cache = cache
        self.adapter = adapter
        self.saveInterval = saveInterval
        self.workflowLimits = workflowLimits
        self.agyBackgroundWorkLimits = agyBackgroundWorkLimits
        self.agySwarmLimits = agySwarmLimits
        self.now = now
    }

    /// Shows what the device kept from an earlier visit, before the Host
    /// answers. A document the current adapter cannot read is discarded. One
    /// worded in another language still shows, since a Saved Chat's
    /// messages live only here, but never joins live rows (`joinedCache`),
    /// so the next save words it anew.
    private static func restoredTranscript(from document: ChatCacheDocument) -> ChatTranscript {
        var transcript = ChatTranscript(
            entries: document.entries, title: document.title,
            needsOlderHistory: !document.reachedStart,
            backgroundWork: document.backgroundWork ?? [], latestPromptOffset: document.latestPromptOffset,
            turns: document.turns ?? [], precedingTurnEnd: document.precedingTurnEnd)
        transcript.model = document.model
        transcript.effort = document.effort
        transcript.permissionMode = document.permissionMode
        return transcript
    }

    func restore() async -> ChatConversationSnapshot {
        switch await cache.load(cacheKey) {
        case .hit(let saved):
            guard let document = saved.adapterRevision == adapter.revision ? saved : adapter.migrateCache?(saved),
                  document.adapterRevision == adapter.revision else {
                await cache.remove(cacheKey)
                break
            }
            cached = document
            update {
                $0.transcript = Self.restoredTranscript(from: document)
                $0.readOffset = document.coverageEnd
                $0.isFromCache = !document.entries.isEmpty
                $0.olderAwaitsUser = document.olderAwaitsUser ?? false
                $0.older = document.reachedStart ? .reachedStart : .available
            }
        case .miss, .unavailable:
            break
        }
        return snapshot
    }

    /// Finds the transcript and reads its tail, or, for a store read by
    /// query, opens the adapter's source without looking for a file.
    /// `directories` are where the Agent runs and was launched, most
    /// current first. `lostAMessage` says a message delivered to the
    /// Agent went unrecorded past its echo timeout.
    func open(
        directories: [String], context: ChatProjectionContext, lostAMessage: Bool = false,
        requiresLiveBody: Bool = false
    ) async -> ChatConversationSnapshot {
        self.directories = directories
        self.lostAMessage = lostAMessage
        self.requiresLiveBody = requiresLiveBody
        setContext(context)
        do {
            if let makeRecordSource = adapter.makeRecordSource {
                if let source = makeRecordSource(reference.sessionID) {
                    try await follow(source)
                } else {
                    stop(.unidentifiedSession(reference.program))
                }
            } else if let preloaded = try await fastLocateCachedFile() {
                try await follow(
                    preloaded.path, preloadedStatus: preloaded.status, preloadedHead: preloaded.head)
            } else {
                switch try await locate() {
                case .found(let path):
                    try await follow(path)
                case .unavailable(let reason):
                    stop(reason)
                }
            }
        } catch let unavailable as ChatSourceUnavailable {
            stop(
                isConversationStillToStart(unavailable.reason)
                    ? .awaitingFirstMessage(reference.program) : unavailable.reason)
        } catch {
            recordFailure(error)
        }
        noteReadProgress()
        projectIfNeeded()
        return snapshot
    }

    /// Reads what the program appended since the last look. Without a
    /// source to follow it changes nothing; the owner opens again.
    func poll(context: ChatProjectionContext) async -> ChatConversationSnapshot {
        setContext(context)
        if var source {
            do {
                if isCacheBacked, needsLiveHydrationForCurrentContext {
                    try await hydrateFromCache()
                    update { $0.readFailure = nil }
                    noteReadProgress()
                    projectIfNeeded()
                    return snapshot
                }
                switch try await source.poll(files) {
                case .unchanged:
                    self.source = source
                case .appended(let lines):
                    if isCacheBacked {
                        try await hydrateFromCache()
                    } else {
                        self.source = source
                        reducer?.append(lines)
                        needsProjection = true
                    }
                case .reset(let lines, _):
                    try await start(source, lines: lines)
                case .missing:
                    // Claude moves a session's file on `/cd`, Codex on
                    // archive, and a store can lose the session: look for
                    // it again, keeping what shows.
                    return await open(
                        directories: directories, context: context, lostAMessage: lostAMessage,
                        requiresLiveBody: requiresLiveBody)
                }
                update { $0.readFailure = nil }
            } catch let unavailable as ChatSourceUnavailable {
                stop(unavailable.reason)
            } catch {
                recordFailure(error)
            }
        }
        noteReadProgress()
        projectIfNeeded()
        return snapshot
    }

    private func noteReadProgress() {
        update {
            $0.hasUnreadRecords = source?.hasUnreadRecords ?? false
            $0.readsFromStart = source?.windowStart == 0
        }
    }

    /// Looks for the transcript again, then reads it: a Codex undo
    /// continues the thread in a new `_<rollout>` file and leaves the one
    /// followed unchanged, so a poll alone would never show the turns
    /// written since (ADR 0024). Follows the new file when the live one
    /// moved, else polls. A search that fails is a read failure, so the
    /// owner can look again. Other programs only poll.
    func relocate(context: ChatProjectionContext) async -> ChatConversationSnapshot {
        guard reference.program == .codex, !adapter.readsByQuery, let current = source?.path else {
            return await poll(context: context)
        }
        setContext(context)
        do {
            if case .found(let path) = try await locate(), path != current {
                try await follow(path)
                projectIfNeeded()
                return snapshot
            }
        } catch {
            recordFailure(error)
            projectIfNeeded()
            return snapshot
        }
        return await poll(context: context)
    }

    /// Reads the tail of the transcript at `path` and follows it, or confirms
    /// an unchanged cached document without re-downloading its body.
    private func follow(
        _ path: String, preloadedStatus: RemoteFileStatus? = nil, preloadedHead: Data? = nil
    ) async throws {
        if try await confirmUnchangedCache(
            path: path, preloadedStatus: preloadedStatus, preloadedHead: preloadedHead)
        {
            return
        }
        var follower = TranscriptFollower(path: path, limits: adapter.limits, identity: adapter.identity)
        if let lines = try await follower.open(
            files, preloadedStatus: preloadedStatus, preloadedHead: preloadedHead)
        {
            try await start(follower, lines: lines)
        } else {
            stop(.notFound(searchedAll: true))
        }
    }

    /// Reads the newest records of `source` and follows it.
    private func follow(_ source: any ChatTranscriptSource) async throws {
        var source = source
        if let lines = try await source.open(files) {
            try await start(source, lines: lines)
        } else {
            stop(.notFound(searchedAll: true))
        }
    }

    /// Reads one page of history above the oldest line read. A request goes
    /// on, with `older` staying `.loading`, until it brings the opener of a
    /// turn not shown before, the file's head or the saved entries are
    /// reached, or the source has spent the request's search; the owner calls
    /// again for each page. A long turn can span tens of MiB, so each page
    /// shows as it comes and the owner may poll between pages, as what the
    /// Agent writes meanwhile matters more than what it wrote before.
    ///
    /// A request the timeline makes by itself (`automatic`) reads as the
    /// user's does, unless the source bounds it (`automaticOlderSearch`): then
    /// it reads at most that many bytes, and one that reads them all inside a
    /// turn leaves earlier history to the user's requests (`olderAwaitsUser`).
    /// A cancelled read costs the request nothing: the next call reads the
    /// page again.
    func loadOlder(context: ChatProjectionContext, automatic: Bool = false) async -> ChatConversationSnapshot {
        setContext(context)
        if isCacheBacked {
            do {
                try await hydrateFromCache()
                projectIfNeeded()
            } catch let unavailable as ChatSourceUnavailable {
                stop(unavailable.reason)
                return snapshot
            } catch {
                guard !Self.isCancellation(error) else { return snapshot }
                recordFailure(error)
                let message =
                    (error as? TransportError)?.presentation.summary
                    ?? String(localized: "Earlier messages could not be read")
                olderSearch = nil
                update { $0.older = .failed(message) }
                projectIfNeeded()
                return snapshot
            }
        }
        // So the opener compared below can only come from this page.
        projectIfNeeded()
        if olderSearch == nil {
            guard var first = source, first.hasOlder, !olderUnreadable, !(automatic && snapshot.olderAwaitsUser)
            else { return snapshot }
            first.beginOlderSearch()
            source = first
            // Each page projects everything loaded again, so a long search
            // reads larger pages.
            olderSearch = OlderSearch(
                pageLength: first.olderPageLengths.first, allowance: automatic ? first.automaticOlderSearch : nil)
            update { $0.older = .loading }
        }
        guard var source, var search = olderSearch else { return snapshot }
        let oldestOpener = snapshot.transcript.turns.first?.firstEntryID
        // A bounded request's pages read no more than their length, so this
        // counts every byte, the lines page boundaries cut and read again
        // included.
        let limit = search.allowance.map { min(search.pageLength, $0) }
        search.allowance = search.allowance.map { $0 - (limit ?? 0) }
        do {
            switch try await source.loadOlder(files, length: limit ?? search.pageLength, limit: limit) {
            case .lines(let lines):
                self.source = source
                reducer?.prepend(lines)
            case .headReached:
                self.source = source
            case .unreadable:
                olderUnreadable = true
            case .beyondLimit:
                // A line longer than this page; the next is larger.
                break
            case .missing, .rewritten:
                endOlderSearch()
                return await open(
                    directories: directories, context: context, lostAMessage: lostAMessage,
                    requiresLiveBody: requiresLiveBody)
            }
            needsProjection = true
            update { $0.readFailure = nil }
        } catch let unavailable as ChatSourceUnavailable {
            stop(unavailable.reason)
            return snapshot
        } catch {
            guard !Self.isCancellation(error) else { return snapshot }
            recordFailure(error)
            let message =
                (error as? TransportError)?.presentation.summary
                ?? String(localized: "Earlier messages could not be read")
            olderSearch = nil
            update { $0.older = .failed(message) }
            projectIfNeeded()
            return snapshot
        }
        search.pageLength = min(search.pageLength * 2, source.olderPageLengths.maximum)
        olderSearch = search
        projectIfNeeded()
        // Reopened, the window starts over at the tail below the saved rows
        // it reads again. Those bring nothing new, so they spend no search.
        if let current = self.source, joinedCache(windowStart: current.windowStart ?? current.readOffset) != nil {
            self.source?.beginOlderSearch()
        }
        if snapshot.transcript.turns.first?.firstEntryID != oldestOpener {
            update { $0.olderAwaitsUser = false }
            endOlderSearch()
        } else if snapshot.older == .reachedStart || self.source?.hasOlder != true || olderUnreadable
            || self.source?.olderSearchExhausted != false
        {
            endOlderSearch()
        } else if search.allowance == 0 {
            // Further pages would only grow the turn's run of steps.
            update { $0.olderAwaitsUser = true }
            endOlderSearch()
        }
        return snapshot
    }

    private func endOlderSearch() {
        olderSearch = nil
        update { if $0.older == .loading { $0.older = .available } }
    }

    /// Projects again without reading, for a change only the context
    /// carries: the Agent's activity decides whether a tool is still running.
    func reproject(context: ChatProjectionContext) -> ChatConversationSnapshot {
        setContext(context)
        projectIfNeeded()
        return snapshot
    }

    /// Saves what shows, at most once per save interval unless `force`.
    func save(force: Bool = false) async {
        let entries = snapshot.transcript.recordedEntries
        guard case .following(let path) = snapshot.phase, let source,
            let head = source.head, !entries.isEmpty
        else { return }
        let date = now()
        if let lastSave {
            if lastSave.revision == snapshot.revision { return }
            if !force, date.timeIntervalSince(lastSave.date) < saveInterval { return }
        }
        let windowStart = source.windowStart ?? source.readOffset
        let joined = joinedCache(windowStart: windowStart)
        let coverageStart = joined.map { min($0.coverageStart, windowStart) } ?? windowStart
        let transcript = snapshot.transcript
        let hadTransientState =
            !transcript.unrecordedEntryIDs.isEmpty
            || !transcript.pendingRequests.isEmpty
            || !transcript.openTurnBackgroundCommands.isEmpty
            || transcript.links.continuedInSessionID != nil
            || snapshot.hasUnreadRecords
        let document = ChatCacheDocument(
            key: cacheKey, adapterRevision: adapter.revision, transcriptPath: path, head: head,
            coverageStart: coverageStart, coverageEnd: source.readOffset,
            reachedStart: (joined?.reachedStart ?? (windowStart == 0)) || olderUnreadable,
            title: transcript.title, entries: entries, savedAt: date,
            // A teammate found on the Host is looked for there again.
            backgroundWork: transcript.savedBackgroundWork.filter { item in
                item.taskID.flatMap { foundTeammates[$0] }?.id != item.id
            },
            latestPromptOffset: transcript.latestPromptOffset, turns: transcript.turns,
            precedingTurnEnd: transcript.precedingTurnEnd, model: transcript.model,
            effort: transcript.effort, permissionMode: transcript.permissionMode,
            tailAnchor: source.savedTailAnchor, hadTransientState: hadTransientState,
            olderAwaitsUser: snapshot.olderAwaitsUser ? true : nil,
            localization: localization)
        await cache.save(document)
        // What was just saved fills in above a later window: a moved file's
        // fresh tail, or a rewrite's.
        cached = document
        lastSave = (snapshot.revision, date)
    }

    // MARK: Workflows

    /// Reads the journals of the Workflows the transcript lists, a few per
    /// call and within a budget, and returns what each shows by the
    /// Workflow's id. Only while the transcript itself reads: a journal
    /// adds nothing to work Chat cannot see. Never throws and never changes
    /// the snapshot, so a journal that cannot be read only stops showing
    /// progress.
    func followWorkflows() async -> [String: ChatWorkflowProgress] {
        guard case .following = snapshot.phase, !snapshot.isFromCache, snapshot.readFailure == nil else {
            return workflowProgress
        }
        var listed: [String: String] = [:]
        for item in snapshot.transcript.listedBackgroundWork where item.kind == .workflow {
            if let path = item.journalPath { listed[item.id] = path }
        }
        journals = journals.filter { listed[$0.key] == $0.value.follower.path }
        for (id, path) in listed where journals[id] == nil {
            journals[id] = FollowedJournal(follower: WorkflowJournalFollower(path: path, limits: workflowLimits.follower))
        }
        let running = Set(snapshot.transcript.listedBackgroundWork.filter { $0.state == .running }.map(\.id))
        journalCalls += 1
        let date = now()
        let due = journals
            .filter { !$0.value.isSettled && !$0.value.isUnreadable && $0.value.nextLook.map { date >= $0 } ?? true }
            .sorted { ($0.value.lastLook, $0.key) < ($1.value.lastLook, $1.key) }
            .prefix(workflowLimits.journalsPerCall)
        var budget = workflowLimits.callBudget
        for (id, var followed) in due where budget > 0 {
            followed.lastLook = journalCalls
            var follower = followed.follower
            let before = follower.readOffset
            do {
                let change = try await follower.poll(files, budget: min(budget, workflowLimits.journalBudget))
                budget -= Int(follower.readOffset >= before ? follower.readOffset - before : follower.readOffset)
                followed.follower = follower
                switch change {
                case .unchanged:
                    break
                case .appended(let lines):
                    followed.journal.apply(lines)
                case .restarted(let lines):
                    followed.journal = ClaudeWorkflowJournal()
                    followed.journal.apply(lines)
                case .missing:
                    // Whatever showed stays, and ages toward stale.
                    backOff(&followed, at: date)
                    journals[id] = followed
                    continue
                case .tooLarge:
                    followed.isUnreadable = true
                }
                followed.failures = 0
                followed.nextLook = nil
                if follower.isCaughtUp {
                    followed.progress = followed.journal.progress(
                        updatedAt: follower.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) })
                    // One last read to its end after the Workflow ended.
                    if !running.contains(id) { followed.isSettled = true }
                }
            } catch {
                if Self.isCancellation(error) { return workflowProgress }
                if case .hostFileUnreadable? = error as? TransportError {
                    followed.isUnreadable = true
                } else {
                    backOff(&followed, at: date)
                }
            }
            journals[id] = followed
        }
        return workflowProgress
    }

    private var workflowProgress: [String: ChatWorkflowProgress] {
        journals.compactMapValues(\.progress)
    }

    private func backOff(_ followed: inout FollowedJournal, at date: Date) {
        let delays = workflowLimits.backoff
        let delay = delays.isEmpty ? 0 : delays[min(followed.failures, delays.count - 1)]
        followed.failures += 1
        followed.nextLook = date.addingTimeInterval(delay)
    }

    /// Checks `<session>/workflows/<runId>.json` for running Claude Code
    /// Workflows so a run that ended without a matched `<task-notification>`
    /// retires once its run file settles.
    func followClaudeWorkflowEnds() async -> [String: ChatBackgroundWorkEvidence] {
        guard reference.program == .claude else { return [:] }
        guard case .following = snapshot.phase, !snapshot.isFromCache, snapshot.readFailure == nil else {
            return claudeWorkflowEndEvidence
        }
        var running: [String: (path: String, launchedAt: Date?)] = [:]
        for item in snapshot.transcript.listedBackgroundWork
        where item.kind == .workflow && item.state == .running {
            guard let journalPath = item.journalPath,
                let runFile = ClaudeTranscriptLocation.workflowRunFile(forJournalPath: journalPath)
            else { continue }
            running[item.id] = (runFile, item.launchedAt)
        }
        workflowRunEnds = workflowRunEnds.filter { running[$0.key]?.path == $0.value.path }
        guard !running.isEmpty else { return [:] }
        for (id, entry) in running {
            if var existing = workflowRunEnds[id] {
                existing.launchedAt = entry.launchedAt
                workflowRunEnds[id] = existing
            } else {
                workflowRunEnds[id] = FollowedWorkflowRunEnd(path: entry.path, launchedAt: entry.launchedAt)
            }
        }
        workflowRunEndCalls += 1
        let date = now()
        let due = workflowRunEnds
            .filter {
                $0.value.settledEvidence == nil
                    && !$0.value.isUnreadable
                    && ($0.value.nextLook.map { date >= $0 } ?? true)
            }
            .sorted { ($0.value.lastLook, $0.key) < ($1.value.lastLook, $1.key) }
            .prefix(workflowLimits.journalsPerCall)
        for (id, var followed) in due {
            followed.lastLook = workflowRunEndCalls
            do {
                guard let status = try await files.status(followed.path) else {
                    followed.failures = 0
                    followed.firstSeenAt = nil
                    followed.nextLook = date.addingTimeInterval(workflowLimits.runEndCheckInterval)
                    workflowRunEnds[id] = followed
                    continue
                }
                followed.failures = 0
                let seenAt = followed.firstSeenAt ?? date
                followed.firstSeenAt = seenAt
                if date.timeIntervalSince(seenAt) >= workflowLimits.runEndSettle {
                    let endedState = await resolvedWorkflowRunState(id: id, path: followed.path)
                    let mtimeDate = status.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    let rawEndedAt = mtimeDate ?? seenAt
                    let endedAt = followed.launchedAt.map { max($0, rawEndedAt) } ?? rawEndedAt
                    followed.settledEvidence = ChatBackgroundWorkEvidence(endedState: endedState, endedAt: endedAt)
                    followed.nextLook = nil
                } else {
                    followed.nextLook = seenAt.addingTimeInterval(workflowLimits.runEndSettle)
                }
            } catch {
                if Self.isCancellation(error) { return claudeWorkflowEndEvidence }
                if case .hostFileUnreadable? = error as? TransportError {
                    followed.isUnreadable = true
                } else {
                    let delays = workflowLimits.backoff
                    let delay = delays.isEmpty ? 0 : delays[min(followed.failures, delays.count - 1)]
                    followed.failures += 1
                    followed.nextLook = date.addingTimeInterval(delay)
                }
            }
            workflowRunEnds[id] = followed
        }
        return claudeWorkflowEndEvidence
    }

    private var claudeWorkflowEndEvidence: [String: ChatBackgroundWorkEvidence] {
        workflowRunEnds.compactMapValues(\.settledEvidence)
    }

    private func resolvedWorkflowRunState(id: String, path: String) async -> ChatBackgroundWorkItem.State {
        struct RunStatusPayload: Decodable {
            var status: String?
        }
        if let slice = try? await files.read(RemoteFileRange(path: path, offset: 0, maxBytes: 16 << 10)),
            let payload = try? JSONDecoder().decode(RunStatusPayload.self, from: slice.data),
            let rawStatus = payload.status?.lowercased()
        {
            switch rawStatus {
            case "failed", "error":
                return .failed
            case "stopped", "killed", "cancelled", "canceled":
                return .stopped
            case "completed", "succeeded", "done":
                return .completed
            default:
                break
            }
        }
        if let agents = journals[id]?.journal.agents, !agents.isEmpty {
            if agents.contains(where: { $0.state == .running }) { return .stopped }
            if agents.contains(where: { $0.state == .failed }) { return .failed }
        }
        return .completed
    }

    /// Stats the output files of running Claude Code background commands, a
    /// few a call and each at most once an interval, so one that still
    /// writes shows when it last did. The file says nothing of a command's
    /// end, which only the transcript records; nothing is read from it.
    func followClaudeCommandOutputs() async -> [String: ChatBackgroundWorkEvidence] {
        guard reference.program == .claude else { return [:] }
        guard case .following = snapshot.phase, !snapshot.isFromCache, snapshot.readFailure == nil else {
            return claudeCommandOutputEvidence
        }
        var running: [String: String] = [:]
        for item in snapshot.transcript.listedBackgroundWork
        where item.kind == .command && item.state == .running {
            guard let path = item.outputPath, RemoteFilePath.isAcceptable(path) else { continue }
            running[item.id] = path
        }
        commandOutputs = commandOutputs.filter { running[$0.key] == $0.value.path }
        guard !running.isEmpty else { return [:] }
        for (id, path) in running where commandOutputs[id] == nil {
            commandOutputs[id] = FollowedCommandOutput(path: path)
        }
        commandOutputCalls += 1
        let date = now()
        let due = commandOutputs
            .filter { !$0.value.isUnreadable && ($0.value.nextLook.map { date >= $0 } ?? true) }
            .sorted { ($0.value.lastLook, $0.key) < ($1.value.lastLook, $1.key) }
            .prefix(workflowLimits.commandOutputsPerCall)
        for (id, var followed) in due {
            followed.lastLook = commandOutputCalls
            do {
                if let status = try await files.status(followed.path) {
                    followed.failures = 0
                    followed.nextLook = date.addingTimeInterval(workflowLimits.commandOutputCheckInterval)
                    let writtenAt = status.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    followed.lastSeenAt = [followed.lastSeenAt, writtenAt].compactMap(\.self).max()
                } else {
                    backOff(&followed.failures, &followed.nextLook, at: date)
                }
            } catch {
                if Self.isCancellation(error) { return claudeCommandOutputEvidence }
                if case .hostFileUnreadable? = error as? TransportError {
                    followed.isUnreadable = true
                } else {
                    backOff(&followed.failures, &followed.nextLook, at: date)
                }
            }
            commandOutputs[id] = followed
        }
        return claudeCommandOutputEvidence
    }

    /// Follows the session's teammates in their own transcripts under
    /// `<session>/subagents/`, which say when a turn ends before the lead's
    /// transcript does, and when another teammate's message starts one,
    /// which it never records. Lists the folder now and then, reads a new
    /// teammate's meta once, and stats a few transcripts a call, reading the
    /// end of one that grew. A teammate the Host shows running that no
    /// loaded record launched joins the transcript's Background Work.
    func followClaudeTeammates() async -> [String: ChatBackgroundWorkEvidence] {
        guard reference.program == .claude else { return [:] }
        guard case .following(let path) = snapshot.phase, !snapshot.isFromCache, snapshot.readFailure == nil,
            let folder = ClaudeTranscriptLocation.subagentsDirectory(transcriptPath: path)
        else { return claudeTeammateEvidence }
        if folder != teammateFolder {
            teammateFolder = folder
            teammates = [:]
            notTeammates = []
            teammatesListedAt = nil
            foundTeammates = [:]
        }
        let date = now()
        if teammatesListedAt.map({ date.timeIntervalSince($0) >= workflowLimits.teammateListInterval }) ?? true {
            do {
                try await listTeammates(in: folder, at: date)
            } catch {
                if Self.isCancellation(error) { return claudeTeammateEvidence }
                teammatesListedAt = date
            }
        }
        teammateCalls += 1
        let due = teammates
            .filter { !$0.value.isUnreadable && ($0.value.nextLook.map { date >= $0 } ?? true) }
            .sorted { ($0.value.lastLook, $0.key) < ($1.value.lastLook, $1.key) }
            .prefix(workflowLimits.teammatesPerCall)
        for (id, var followed) in due {
            followed.lastLook = teammateCalls
            do {
                if let status = try await files.status(followed.path), let size = status.size {
                    followed.failures = 0
                    if size != followed.size {
                        let tail = UInt64(workflowLimits.teammateTailBytes)
                        let start = size > tail ? size - tail : 0
                        let slice = try await files.read(
                            RemoteFileRange(path: followed.path, offset: start, maxBytes: Int(size - start)))
                        followed.size = size
                        if let turn = ClaudeTeammateTurn.latest(in: slice.data, startsAtFileStart: start == 0) {
                            // A tail that missed the prompt keeps the start an
                            // earlier look read.
                            let keepsStart =
                                if case .running(nil) = turn, case .running(_?)? = followed.turn { true } else { false }
                            if !keepsStart { followed.turn = turn }
                        }
                    }
                    let writtenAt = status.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    followed.lastSeenAt = [followed.lastSeenAt, writtenAt].compactMap(\.self).max()
                    let isRunning = if case .running? = followed.turn { true } else { false }
                    followed.nextLook = date.addingTimeInterval(
                        isRunning
                            ? workflowLimits.runningTeammateCheckInterval : workflowLimits.idleTeammateCheckInterval)
                } else {
                    backOff(&followed.failures, &followed.nextLook, at: date)
                }
            } catch {
                if Self.isCancellation(error) { return claudeTeammateEvidence }
                if case .hostFileUnreadable? = error as? TransportError {
                    followed.isUnreadable = true
                } else {
                    backOff(&followed.failures, &followed.nextLook, at: date)
                }
            }
            teammates[id] = followed
        }
        addFoundTeammates(at: date)
        return claudeTeammateEvidence
    }

    /// Lists `folder` for named agents' meta files and reads a few new ones
    /// a call, keeping the teammates. The folder is listed again once every
    /// meta it names has been read and the interval has passed.
    private func listTeammates(in folder: String, at date: Date) async throws {
        guard
            let listing = try await files.list(
                RemoteFileListingRequest(directory: folder, kinds: [.regular], nameSuffixes: [".meta.json"]))
        else {
            teammatesListedAt = date
            return
        }
        var unread = 0
        for entry in listing.entries {
            guard let agentID = ClaudeTeammateFiles.agentID(metaFileName: entry.name),
                teammates[agentID] == nil, !notTeammates.contains(agentID)
            else { continue }
            guard unread < workflowLimits.teammateMetasPerCall else {
                unread += 1
                continue
            }
            unread += 1
            let slice = try await files.read(
                RemoteFileRange(path: RemoteFilePath.join(folder, entry.name), offset: 0, maxBytes: 16 << 10))
            guard let meta = ClaudeTeammateFiles.teammate(meta: slice.data) else {
                notTeammates.insert(agentID)
                continue
            }
            teammates[agentID] = FollowedTeammate(
                name: meta.name, title: meta.description,
                spawnedAt: entry.status.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                path: RemoteFilePath.join(folder, "agent-\(agentID).jsonl"))
        }
        if unread <= workflowLimits.teammateMetasPerCall { teammatesListedAt = date }
    }

    /// Adds each teammate the Host shows running that the transcript has no
    /// row for: its launch is above the window, and no saved conversation
    /// carried it. A conversation read from its start launched all of its.
    private func addFoundTeammates(at date: Date) {
        guard let source, (source.windowStart ?? source.readOffset) > 0 else { return }
        let known = Set(snapshot.transcript.backgroundWork.compactMap { $0.kind == .teammate ? $0.taskID : nil })
        var found: [ChatBackgroundWorkItem] = []
        for (agentID, followed) in teammates.sorted(by: { $0.key < $1.key })
        where foundTeammates[agentID] == nil && !known.contains(agentID) {
            guard case .running(let since)? = followed.turn, let seenAt = followed.lastSeenAt,
                date.timeIntervalSince(seenAt) <= workflowLimits.foundTeammateQuiet
            else { continue }
            var item = ChatBackgroundWorkItem(
                id: "teammate:\(agentID)", kind: .teammate,
                title: followed.title ?? String(localized: "Teammate @\(followed.name)"), subtitle: followed.name,
                launchOffset: 0, launchedAt: since ?? followed.spawnedAt)
            item.taskID = agentID
            foundTeammates[agentID] = item
            found.append(item)
        }
        guard !found.isEmpty else { return }
        let windowStart = source.windowStart ?? source.readOffset
        update { $0.transcript.carryBackgroundWork(found, launchedBefore: windowStart, latestPromptOffset: nil) }
    }

    /// What each teammate's own transcript shows, for its row: when it
    /// last wrote, and that its latest turn ended or that one runs.
    private var claudeTeammateEvidence: [String: ChatBackgroundWorkEvidence] {
        var rows: [String: String] = [:]
        for item in snapshot.transcript.backgroundWork where item.kind == .teammate {
            if let agentID = item.taskID { rows[agentID] = item.id }
        }
        var evidence: [String: ChatBackgroundWorkEvidence] = [:]
        for (agentID, followed) in teammates {
            guard let id = rows[agentID], let turn = followed.turn else { continue }
            var entry = ChatBackgroundWorkEvidence(lastSeenAt: followed.lastSeenAt)
            switch turn {
            case .running(let since):
                entry.resumedAt = since
            case .ended(let at, let state):
                entry.endedState = state
                entry.endedAt = at
            }
            evidence[id] = entry
        }
        return evidence
    }

    private var claudeCommandOutputEvidence: [String: ChatBackgroundWorkEvidence] {
        commandOutputs.compactMapValues { followed in
            followed.lastSeenAt.map { ChatBackgroundWorkEvidence(lastSeenAt: $0) }
        }
    }

    private func backOff(_ failures: inout Int, _ nextLook: inout Date?, at date: Date) {
        let delays = workflowLimits.backoff
        let delay = delays.isEmpty ? 0 : delays[min(failures, delays.count - 1)]
        failures += 1
        nextLook = date.addingTimeInterval(delay)
    }

    /// Reads SFTP side files of an Antigravity CLI conversation's running
    /// Background Work (`tasks/task-<N>.log` and subagent transcripts) within
    /// a bounded budget, never throwing and never changing the snapshot.
    func followAgyBackgroundWork() async -> [String: ChatBackgroundWorkEvidence] {
        guard reference.program == .agy else { return [:] }
        let date = now()
        guard case .following(let path) = snapshot.phase,
            !snapshot.isFromCache,
            snapshot.readFailure == nil,
            AgyTranscriptLocator.sessionID(ofTranscript: path) != nil
        else {
            return agyBackgroundWork.snapshotEvidence(at: date, limits: agyBackgroundWorkLimits)
        }
        var follower = agyBackgroundWork
        let evidence = await follower.poll(
            root: AgyTranscriptLocator.root(ofTranscript: path),
            items: snapshot.transcript.listedBackgroundWork,
            files: files,
            limits: agyBackgroundWorkLimits,
            at: date,
            isCancellation: Self.isCancellation)
        if case .following(let currentPath) = snapshot.phase, currentPath == path {
            agyBackgroundWork = follower
            return evidence
        }
        return agyBackgroundWork.snapshotEvidence(at: date, limits: agyBackgroundWorkLimits)
    }

    /// Reads SFTP side files of an Antigravity CLI conversation's native Swarm
    /// (`members.json`, `board.jsonl`, `view.json`, and member compact
    /// transcripts) within bounded per-call budgets, never throwing and never
    /// changing the snapshot.
    func followAgySwarm() async -> AgySwarmSnapshot? {
        guard reference.program == .agy else { return nil }
        let date = now()
        guard case .following(let path) = snapshot.phase,
            !snapshot.isFromCache,
            snapshot.readFailure == nil,
            let coordinatorID = AgyTranscriptLocator.sessionID(ofTranscript: path)
        else {
            return agySwarm.snapshot(isLive: false, at: date)
        }
        var follower = agySwarm
        let result = await follower.poll(
            root: AgyTranscriptLocator.root(ofTranscript: path),
            coordinatorID: coordinatorID,
            hasSwarmHint: snapshot.transcript.hasSwarmActivity,
            files: files,
            limits: agySwarmLimits,
            at: date,
            isCancellation: Self.isCancellation)
        if case .following(let currentPath) = snapshot.phase, currentPath == path {
            agySwarm = follower
            return result
        }
        return agySwarm.snapshot(isLive: false, at: date)
    }

    /// Reads and incrementally follows the tail window of one Swarm member's
    /// `transcript_full.jsonl` on demand for the Swarm sheet's read-only worker
    /// conversation peek.
    func agySwarmTranscript(
        of conversationID: String, isWorking: Bool
    ) async -> Result<ChatTranscript, ChatToolOutputFailure> {
        guard reference.program == .agy,
            case .following(let path) = snapshot.phase
        else {
            return .failure(.notFollowing)
        }
        guard let workerID = ConversationReference.canonicalUUID(conversationID) else {
            return .failure(.gone)
        }
        let root = AgyTranscriptLocator.root(ofTranscript: path)
        let workerPath = AgyTranscriptLocator.transcriptPath(
            inFolder: AgyTranscriptLocator.folder(in: root, id: workerID))
        guard RemoteFilePath.isAcceptable(workerPath) else { return .failure(.gone) }
        do {
            if var peek = agyWorkerPeek, peek.workerID == workerID, peek.path == workerPath {
                switch try await peek.follower.poll(files) {
                case .unchanged:
                    if let cached = peek.cachedTranscript, peek.cachedIsWorking == isWorking {
                        agyWorkerPeek = peek
                        return .success(cached)
                    }
                case .appended(let lines):
                    peek.reducer.append(lines)
                    peek.cachedTranscript = nil
                case .reset(let lines, _):
                    peek.reducer = AgyTranscriptReducer()
                    peek.reducer.append(lines)
                    peek.cachedTranscript = nil
                case .missing:
                    agyWorkerPeek = nil
                    return .failure(.gone)
                }
                var projectionContext = ChatProjectionContext(activity: isWorking ? .working : .idle)
                projectionContext.windowStart = peek.follower.windowStart ?? 0
                let built = peek.reducer.transcript(projectionContext)
                peek.cachedTranscript = built
                peek.cachedIsWorking = isWorking
                agyWorkerPeek = peek
                return .success(built)
            }

            var follower = TranscriptFollower(
                path: workerPath, limits: adapter.limits, identity: adapter.identity)
            guard let lines = try await follower.open(files) else {
                agyWorkerPeek = nil
                return .failure(.gone)
            }
            var workerReducer = AgyTranscriptReducer()
            workerReducer.append(lines)
            var projectionContext = ChatProjectionContext(activity: isWorking ? .working : .idle)
            projectionContext.windowStart = follower.windowStart ?? 0
            let built = workerReducer.transcript(projectionContext)
            agyWorkerPeek = FollowedSwarmWorker(
                workerID: workerID,
                path: workerPath,
                follower: follower,
                reducer: workerReducer,
                cachedTranscript: built,
                cachedIsWorking: isWorking)
            return .success(built)
        } catch {
            return .failure(
                .unreadable(
                    (error as? TransportError)?.presentation.summary
                        ?? String(localized: "The Host could not be read.")))
        }
    }

    // MARK: Output

    /// A tool's output read again for an expanded row: the line its row
    /// references, read through the source and decoded up to
    /// `ChatToolPreview.expandedLimits` and `ChatFileChanges.expandedLimits`,
    /// or the start of the file the program moved a long output to.
    func output(of tool: ChatToolActivity) async -> Result<ChatExpandedOutput, ChatToolOutputFailure> {
        guard let reference = tool.output, source != nil else {
            return .failure(.notFollowing)
        }
        guard reference.length <= ChatToolPreview.maximumFetchBytes else { return .failure(.tooLong) }
        do {
            if isCacheBacked, self.reference.program == .claude, tool.fileChanges != nil {
                try await hydrateFromCache()
                projectIfNeeded()
            }
            guard let source else { return .failure(.notFollowing) }
            let activeReducer: any ChatTranscriptReducer
            if let reducer {
                activeReducer = reducer
            } else {
                activeReducer = adapter.makeReducer(
                    ChatReducerSeed(path: source.path, firstLine: try await firstLine(for: source)))
            }
            guard let line = try await source.line(at: reference, files: files) else { return .failure(.gone) }
            let output = ChatToolPreview.$limits.withValue(ChatToolPreview.expandedLimits) {
                ChatFileChanges.$limits.withValue(ChatFileChanges.expandedLimits) {
                    activeReducer.output(of: line, for: tool)
                }
            }
            switch output {
            case .preview(let preview, let fileChanges)?:
                return .success(ChatExpandedOutput(preview: preview, fileChanges: fileChanges))
            case .file(let file, let fallback, let fileChanges)?:
                return .success(
                    ChatExpandedOutput(preview: try await spilledOutput(file) ?? fallback, fileChanges: fileChanges))
            case nil:
                return .failure(.gone)
            }
        } catch let failure as ChatToolOutputFailure {
            return .failure(failure)
        } catch {
            return .failure(
                .unreadable((error as? TransportError)?.presentation.summary ?? String(localized: "The Host could not be read.")))
        }
    }

    /// The start of a file a long output was moved to, capped like a line's
    /// output; nil when the file is gone. A few bytes past the cap say
    /// whether there is more, and keep a character cut at the end of the
    /// read out of what shows.
    private func spilledOutput(_ path: String) async throws -> ChatToolPreview? {
        let limits = ChatToolPreview.expandedLimits
        guard let data = try await files.read(path: path, from: 0, to: UInt64(limits.bytes + 4), chunk: 256 << 10)
        else { return nil }
        return ChatToolPreview.$limits.withValue(limits) {
            ChatToolPreview(capping: String(decoding: data, as: UTF8.self))
        }
    }

    /// On herdr-core Heeler can know an OpenCode session's id before its first
    /// prompt makes the row, so a store without it has a conversation to start, not
    /// one that went missing (ADR 0034). Herdr TUI reports only ids that exist.
    private func isConversationStillToStart(_ reason: ChatUnavailableReason) -> Bool {
        mayStillBeToStart && reason == .sessionStore(.opencode, .sessionMissing(otherStores: []))
    }

    /// Whether nothing found under an id Host evidence named can mean its first message
    /// is still to come. Once Chat has shown it, or the device kept it, it went missing.
    /// A message that went in and never showed says Chat looks in the wrong place.
    private var mayStillBeToStart: Bool {
        sessionMayPrecedeItsStore && !hasFollowed && cached == nil && !lostAMessage
    }

    // MARK: Locating

    private enum Location {
        case found(String)
        case unavailable(ChatUnavailableReason)
    }

    private func locate() async throws -> Location {
        switch reference.program {
        case .claude:
            var candidates = directories
            if let relocatedDirectory {
                candidates.removeAll { $0 == relocatedDirectory }
                candidates.insert(relocatedDirectory, at: 0)
            }
            let isNew = !lostAMessage && snapshot.phase == .unavailable(.awaitingFirstMessage(.claude))
            let searchesEveryProject = !isNew || context.activity != newConversationActivity
            // Once per activity, so a search that fails is not repeated
            // every pass.
            if isNew, searchesEveryProject { newConversationActivity = context.activity }
            switch try await ClaudeTranscriptLocator(files: files).locate(
                sessionID: reference.sessionID, directories: candidates, searchesEveryProject: searchesEveryProject,
                configRoot: transcriptRoot)
            {
            case .success(let location): return .found(location.transcriptPath)
            case .failure(.notFound) where !searchesEveryProject:
                return .unavailable(.awaitingFirstMessage(.claude))
            case .failure(.notFound(let searchedAll)):
                return .unavailable(.notFound(searchedAll: searchedAll))
            case .failure(.notWritten):
                // A file shown before, or saved on the device, that is gone
                // now is not a conversation still to start.
                guard !hasFollowed, cached == nil, !lostAMessage else {
                    return .unavailable(.notFound(searchedAll: true))
                }
                newConversationActivity = context.activity
                return .unavailable(.awaitingFirstMessage(.claude))
            case .failure(.mismatched): return .unavailable(.mismatched)
            }
        case .codex:
            switch try await CodexTranscriptLocator(files: files, now: now).locate(
                threadID: reference.sessionID, configRoot: transcriptRoot)
            {
            case .success(let location):
                guard let live = location.live else { return .unavailable(.notFound(searchedAll: true)) }
                return .found(live.path)
            case .failure(.notFound): return .unavailable(.notFound(searchedAll: true))
            case .failure(.compressed): return .unavailable(.compressed)
            case .failure(.mismatched): return .unavailable(.mismatched)
            }
        case .pi, .omp:
            let isNew = !lostAMessage && snapshot.phase == .unavailable(.awaitingFirstMessage(reference.program))
            // Once per activity, as for Claude Code: a wait looks on every pass.
            switch try await PiTranscriptLocator(files: files).locate(
                reference: reference, directories: directories, sessionsRoot: transcriptRoot,
                searchesEveryProject: !isNew || context.activity != newConversationActivity)
            {
            case .success(let path): return .found(path)
            case .failure(.notFound) where mayStillBeToStart:
                // The Agent's own evidence names this id, and nothing is saved
                // under it yet: a conversation still to start, as with a path.
                newConversationActivity = context.activity
                return .unavailable(.awaitingFirstMessage(reference.program))
            case .failure(.notFound(let searchedAll)): return .unavailable(.notFound(searchedAll: searchedAll))
            case .failure(.notWritten):
                // A file shown before, or saved on the device, that is gone
                // now is not a conversation still to start.
                return .unavailable(
                    hasFollowed || cached != nil
                        ? .notFound(searchedAll: true) : .awaitingFirstMessage(reference.program))
            case .failure(.mismatched): return .unavailable(.mismatched)
            case .failure(.unsupportedVersion(let version)):
                let name = reference.program == .omp ? "Oh My Pi" : "Pi"
                return .unavailable(.unsupportedFormat(String(localized: "\(name) session version \(version)")))
            }
        case .grok:
            switch try await GrokTranscriptLocator(files: files).locate(
                sessionID: reference.sessionID, directories: directories, configRoot: transcriptRoot)
            {
            case .success(let path): return .found(path)
            case .failure(.notFound(searchedAll: false)) where mayStillBeToStart:
                // Its row and folder come as it starts, and `updates.jsonl` with
                // the first message.
                return .unavailable(.awaitingFirstMessage(reference.program))
            case .failure(.notFound(let searchedAll)):
                return .unavailable(.notFound(searchedAll: searchedAll))
            case .failure(.mismatched): return .unavailable(.mismatched)
            }
        case .agy:
            switch try await AgyTranscriptLocator(files: files).locate(
                sessionID: reference.sessionID, configRoot: transcriptRoot)
            {
            case .success(let path): return .found(path)
            case .failure(.notWritten):
                // A file shown before, or saved on the device, that is gone
                // now is not a conversation still to start.
                guard !hasFollowed, cached == nil, !lostAMessage else {
                    return .unavailable(.notFound(searchedAll: true))
                }
                return .unavailable(.awaitingFirstMessage(.agy))
            case .failure(.notFound) where mayStillBeToStart:
                return .unavailable(.awaitingFirstMessage(.agy))
            case .failure(.notFound):
                return .unavailable(.notFound(searchedAll: true))
            }
        case .opencode, .amp:
            // Its store is read by query, so `open` never looks for a file.
            return .unavailable(.unsupportedSession)
        }
    }

    // MARK: Following

    private var needsLiveHydrationForCurrentContext: Bool {
        if context.activity == .blocked { return true }
        if !context.skillNames.isEmpty, reference.program == .codex { return true }
        return false
    }

    private static func pathIsUnderRoot(_ path: String, root: String) -> Bool {
        var cleanRoot = root
        while cleanRoot.count > 1, cleanRoot.hasSuffix("/") || cleanRoot.hasSuffix("\\") {
            cleanRoot.removeLast()
        }
        guard path.hasPrefix(cleanRoot), path.count > cleanRoot.count else { return false }
        let separator = path[path.index(path.startIndex, offsetBy: cleanRoot.count)]
        return separator == "/" || separator == "\\"
    }

    /// Checks whether `cached.transcriptPath` still holds the same conversation
    /// before running a full directory/config-root search. Codex is excluded
    /// because an undo writes a new sibling `_<rollout>` file while leaving the
    /// earlier segment untouched.
    private func fastLocateCachedFile() async throws -> (
        path: String, status: RemoteFileStatus, head: Data
    )? {
        guard reference.program != .codex, !adapter.readsByQuery,
            let cached, !cached.transcriptPath.isEmpty
        else { return nil }
        if let transcriptRoot, !Self.pathIsUnderRoot(cached.transcriptPath, root: transcriptRoot) {
            return nil
        }
        let status: RemoteFileStatus?
        do {
            status = try await files.status(cached.transcriptPath)
        } catch TransportError.hostFileUnreadable {
            return nil
        }
        guard let status, ClaudeTranscriptLocator.isUsable(status) else { return nil }
        let head: Data?
        do {
            head = try await files.read(
                path: cached.transcriptPath, from: 0, to: UInt64(adapter.limits.headLength),
                chunk: adapter.limits.readChunk)
        } catch TransportError.hostFileUnreadable {
            return nil
        }
        guard let head,
            TranscriptFollower.sameConversation(cached.head, head, identity: adapter.identity)
        else { return nil }
        if reference.program == .claude,
            ClaudeTranscriptLocator.headVerdict(head, sessionID: reference.sessionID) == false
        {
            return nil
        }
        return (cached.transcriptPath, status, head)
    }

    /// Confirms an unchanged cached transcript by checking its size, `head`,
    /// and `tailAnchor` (4 KiB + 64 B at most) instead of re-downloading and
    /// re-decoding up to `tailWindow` (1 MiB) of JSONL records.
    private func confirmUnchangedCache(
        path: String, preloadedStatus: RemoteFileStatus?, preloadedHead: Data?
    ) async throws -> Bool {
        guard !adapter.readsByQuery,
            !requiresLiveBody,
            let cached,
            cached.transcriptPath == path,
            cached.isWorded(in: localization),
            let savedAnchor = cached.tailAnchor,
            !savedAnchor.isEmpty,
            cached.coverageEnd >= UInt64(savedAnchor.count),
            cached.hadTransientState != true,
            !cached.entries.isEmpty,
            context.activity != .blocked,
            context.skillNames.isEmpty || reference.program != .codex,
            (cached.reachedStart
                || adapter.joinsCachedHistory
                || cached.coverageEnd - cached.coverageStart <= UInt64(adapter.limits.tailWindow)),
            !cached.entries.contains(where: { entry in
                if case .tool(let tool) = entry.content { return tool.status == .running }
                return false
            })
        else { return false }

        let status: RemoteFileStatus?
        if let preloadedStatus {
            status = preloadedStatus
        } else {
            status = try await files.status(path)
        }
        guard let status, let size = status.size, size == cached.coverageEnd else { return false }

        let head: Data?
        if let preloadedHead {
            head = preloadedHead
        } else {
            head = try await files.read(
                path: path, from: 0, to: UInt64(adapter.limits.headLength), chunk: adapter.limits.readChunk)
        }
        guard let head,
            TranscriptFollower.sameConversation(cached.head, head, identity: adapter.identity)
        else { return false }

        let anchor: Data?
        if UInt64(head.count) == size {
            anchor = Data(head.suffix(savedAnchor.count))
        } else {
            anchor = try await files.read(
                path: path, from: size - UInt64(savedAnchor.count), to: size,
                chunk: adapter.limits.readChunk)
        }
        guard anchor == savedAnchor else { return false }

        let follower = TranscriptFollower.confirmedFromCache(
            path: path, limits: adapter.limits, identity: adapter.identity, status: status, head: head,
            windowStart: cached.coverageStart, readOffset: cached.coverageEnd, tailAnchor: savedAnchor)
        let movedLayout = hasFollowed && snapshot.phase != .following(path: path)
        source = follower
        reducer = nil
        isCacheBacked = true
        hasFollowed = true
        olderUnreadable = false
        olderSearch = nil
        needsProjection = false
        let restored = Self.restoredTranscript(from: cached)
        update {
            $0.transcript = restored
            $0.phase = .following(path: path)
            $0.readFailure = nil
            $0.isFromCache = false
            $0.olderAwaitsUser = cached.olderAwaitsUser ?? false
            $0.older = cached.reachedStart ? .reachedStart : .available
            $0.readOffset = cached.coverageEnd
            if movedLayout { $0.layoutGeneration += 1 }
        }
        lastSave = (snapshot.revision, now())
        return true
    }

    /// Loads the live tail window and reducer when an operation (`poll` after
    /// new writes, `loadOlder`, or context re-projection) needs live records
    /// after a cache-backed open.
    private func hydrateFromCache() async throws {
        guard isCacheBacked, let currentPath = source?.path else { return }
        var follower = TranscriptFollower(path: currentPath, limits: adapter.limits, identity: adapter.identity)
        guard let lines = try await follower.open(files) else {
            stop(.notFound(searchedAll: true))
            return
        }
        try await start(follower, lines: lines, hydratingFromCache: true)
    }

    /// Starts over on a freshly opened source: a new reducer over its tail
    /// window. Nothing changes if building it fails.
    private func start(
        _ source: any ChatTranscriptSource, lines: [ChatLine], hydratingFromCache: Bool = false
    ) async throws {
        var reducer = adapter.makeReducer(
            ChatReducerSeed(path: source.path, firstLine: try await firstLine(for: source)))
        reducer.append(lines)
        if let format = reducer.unsupportedFormat {
            stop(.unsupportedFormat(format))
            return
        }
        var movedLayout = (hasFollowed && !hydratingFromCache) || snapshot.readOffset > source.readOffset
        if let cached,
            !TranscriptFollower.sameConversation(cached.head, source.head, identity: adapter.identity)
        {
            // Another conversation now has this name.
            self.cached = nil
            lastSave = nil
            movedLayout = true
            await cache.remove(cacheKey)
        }
        self.source = source
        self.reducer = reducer
        isCacheBacked = false
        hasFollowed = true
        olderUnreadable = false
        olderSearch = nil
        needsProjection = true
        update {
            $0.phase = .following(path: source.path)
            $0.readFailure = nil
            $0.isFromCache = false
            // A fresh tail loads earlier messages by itself again.
            $0.olderAwaitsUser = false
            if movedLayout { $0.layoutGeneration += 1 }
        }
    }

    /// A tail window that starts past the file's first line still needs it
    /// when the program's records depend on it. Only a file has one.
    private func firstLine(for source: any ChatTranscriptSource) async throws -> ChatLine? {
        guard adapter.wantsFirstLine, let follower = source as? TranscriptFollower, follower.windowStart != 0 else {
            return nil
        }
        if let head = follower.head {
            if let newline = head.firstIndex(of: 0x0A) {
                return ChatLine(offset: 0, data: Data(head[head.startIndex..<newline]))
            }
            if let size = follower.knownSize, UInt64(head.count) == size {
                return nil
            }
        }
        guard case .line(let data)? = try await files.firstLine(
            of: follower.path, initialBytes: 64 << 10, limit: 1 << 20)
        else { return nil }
        return ChatLine(offset: 0, data: Data(data))
    }

    /// Stops following, keeping whatever shows.
    private func stop(_ reason: ChatUnavailableReason) {
        endOlderSearch()
        source = nil
        reducer = nil
        isCacheBacked = false
        update {
            $0.phase = .unavailable(reason)
            $0.readFailure = nil
            $0.isFromCache = !$0.transcript.entries.isEmpty
        }
    }

    // MARK: Projecting

    private func setContext(_ context: ChatProjectionContext) {
        guard context.activity != self.context.activity || context.skillNames != self.context.skillNames
        else { return }
        self.context = context
        needsProjection = true
    }

    /// The saved document when its entries continue the live window without
    /// a gap, in the words the live rows use.
    private func joinedCache(windowStart: UInt64) -> ChatCacheDocument? {
        guard adapter.joinsCachedHistory, let cached, cached.isWorded(in: localization), windowStart > 0,
            cached.coverageEnd >= windowStart, cached.coverageStart < windowStart
        else { return nil }
        return cached
    }

    /// Rebuilds the transcript from the reducer, after the saved entries the
    /// live window has not reached yet.
    private func projectIfNeeded() {
        guard needsProjection, let reducer, let source else { return }
        needsProjection = false
        let windowStart = source.windowStart ?? source.readOffset
        var context = context
        context.windowStart = windowStart
        var transcript = reducer.transcript(context)
        var reachedStart = windowStart == 0
        if let joined = joinedCache(windowStart: windowStart) {
            let live = Set(transcript.entries.map(\.id))
            let earlier = joined.entries.filter { $0.sourceOffset < windowStart && !live.contains($0.id) }
            transcript.entries = earlier + transcript.entries
            // Turns opened above the window, ahead of the ones it opens.
            let earlierIDs = Set(earlier.map(\.id))
            var earlierTurns = (joined.turns ?? []).filter { earlierIDs.contains($0.firstEntryID) }
            // The saved record of the turn the window opens inside may
            // predate its end.
            if let end = transcript.precedingTurnEnd, let last = earlierTurns.indices.last,
                earlierTurns[last].ending != .interrupted
            {
                earlierTurns[last].ending = end.ending
                earlierTurns[last].endedAt = end.endedAt ?? earlierTurns[last].endedAt
            }
            // The window's end belongs to the rows above the first turn
            // only when the saved rows above the window open none.
            if joined.turns == nil || !earlierTurns.isEmpty { transcript.precedingTurnEnd = nil }
            transcript.turns = earlierTurns + transcript.turns
            if transcript.title == nil { transcript.title = joined.title }
            // Work launched above the window still runs, or ends in it.
            transcript.carryBackgroundWork(
                joined.backgroundWork ?? [], launchedBefore: windowStart,
                latestPromptOffset: joined.latestPromptOffset)
            reachedStart = joined.reachedStart
        } else if olderUnreadable {
            transcript.entries.insert(
                ChatEntry(
                    id: ChatEntryID("history-unavailable"), sourceOffset: windowStart,
                    content: .divider(ChatDivider(kind: .historyUnavailable))),
                at: 0)
            reachedStart = true
        }
        if !foundTeammates.isEmpty {
            transcript.carryBackgroundWork(
                foundTeammates.values.sorted { $0.id < $1.id }, launchedBefore: windowStart, latestPromptOffset: nil)
        }
        if let directory = transcript.links.relocatedCwd { relocatedDirectory = directory }
        let older: ChatOlderHistory =
            switch (reachedStart, snapshot.older) {
            case (true, _): .reachedStart
            case (false, .failed(let message)): .failed(message)
            case (false, .loading) where olderSearch != nil: .loading
            case (false, _): .available
            }
        update {
            $0.transcript = transcript
            $0.older = older
            $0.readOffset = source.readOffset
        }
    }

    private func recordFailure(_ error: any Error) {
        if Self.isCancellation(error) { return }
        let failure =
            error as? TransportError
            ?? .channelFailed(detail: String(describing: type(of: error)))
        update { $0.readFailure = failure }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || error as? TransportError == .cancelled
    }

    private func update(_ change: (inout ChatConversationSnapshot) -> Void) {
        var next = snapshot
        change(&next)
        guard next != snapshot else { return }
        next.revision = snapshot.revision + 1
        snapshot = next
    }
}
