import Foundation

/// Why Chat cannot show a conversation from the Host. Each case has its own
/// explanation; none of them is an error the user caused.
enum ChatUnavailableReason: Equatable, Sendable {
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

    /// Whether Chat shows the explanation in the conversation's place even
    /// over saved messages, which stay in memory until the program shows
    /// the conversation again.
    var hidesConversation: Bool {
        if case .startScreen = self { true } else { false }
    }
}

extension ChatProgram {
    /// Whether a new conversation's file comes only with the first reply,
    /// as Pi and Oh My Pi write it, rather than with the first message, as
    /// Claude Code does: a message waits for its record as long as the
    /// reply takes.
    var writesNewConversationWithFirstReply: Bool {
        switch self {
        case .pi, .omp: true
        case .claude, .codex, .grok, .opencode: false
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
        case .notFollowing: "Output is available when connected."
        case .tooLong: "This output is too long to show here."
        case .gone: "Output is no longer available."
        case .unreadable(let reason): "Couldn't load output: \(reason)"
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
    /// Bumped when the program's normalization changes, so entries cached
    /// by an older build are dropped instead of mixed with new ones.
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
    /// The document last restored or saved. Its entries older than the
    /// live window show above it once the window reaches what it covers.
    private var cached: ChatCacheDocument?
    /// The line before the window is too long to page past.
    private var olderUnreadable = false
    private var context = ChatProjectionContext()
    private var needsProjection = false
    private var snapshot = ChatConversationSnapshot()
    private var lastSave: (revision: Int, date: Date)?
    private let workflowLimits: WorkflowLimits
    /// Journals by the Workflow's id, for the Workflows the transcript
    /// lists.
    private var journals: [String: FollowedJournal] = [:]
    private var journalCalls = 0

    init(
        reference: ConversationReference,
        cacheKey: ChatCacheKey,
        files: ChatHostFiles,
        cache: any ChatTranscriptCache,
        adapter: ChatTranscriptAdapter,
        saveInterval: TimeInterval = 10,
        workflowLimits: WorkflowLimits = WorkflowLimits(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reference = reference
        self.cacheKey = cacheKey
        self.files = files
        self.cache = cache
        self.adapter = adapter
        self.saveInterval = saveInterval
        self.workflowLimits = workflowLimits
        self.now = now
    }

    /// Shows what the device kept from an earlier visit, before the Host
    /// answers.
    func restore() async -> ChatConversationSnapshot {
        switch await cache.load(cacheKey) {
        case .hit(let document) where document.adapterRevision == adapter.revision:
            cached = document
            update {
                $0.transcript = ChatTranscript(
                    entries: document.entries, title: document.title,
                    needsOlderHistory: !document.reachedStart,
                    backgroundWork: document.backgroundWork ?? [], latestPromptOffset: document.latestPromptOffset,
                    turns: document.turns ?? [])
                $0.readOffset = document.coverageEnd
                $0.isFromCache = !document.entries.isEmpty
                $0.older = document.reachedStart ? .reachedStart : .available
            }
        case .hit:
            await cache.remove(cacheKey)
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
        directories: [String], context: ChatProjectionContext, lostAMessage: Bool = false
    ) async -> ChatConversationSnapshot {
        self.directories = directories
        self.lostAMessage = lostAMessage
        setContext(context)
        do {
            if let makeRecordSource = adapter.makeRecordSource {
                if let source = makeRecordSource(reference.sessionID) {
                    try await follow(source)
                } else {
                    stop(.unidentifiedSession(reference.program))
                }
            } else {
                switch try await locate() {
                case .found(let path):
                    try await follow(path)
                case .unavailable(let reason):
                    stop(reason)
                }
            }
        } catch let unavailable as ChatSourceUnavailable {
            stop(unavailable.reason)
        } catch {
            recordFailure(error)
        }
        projectIfNeeded()
        return snapshot
    }

    /// Reads what the program appended since the last look. Without a
    /// source to follow it changes nothing; the owner opens again.
    func poll(context: ChatProjectionContext) async -> ChatConversationSnapshot {
        setContext(context)
        if var source {
            do {
                switch try await source.poll(files) {
                case .unchanged:
                    self.source = source
                case .appended(let lines):
                    self.source = source
                    reducer?.append(lines)
                    needsProjection = true
                case .reset(let lines, _):
                    try await start(source, lines: lines)
                case .missing:
                    // Claude moves a session's file on `/cd`, Codex on
                    // archive, and a store can lose the session: look for
                    // it again, keeping what shows.
                    return await open(directories: directories, context: context)
                }
                update { $0.readFailure = nil }
            } catch let unavailable as ChatSourceUnavailable {
                stop(unavailable.reason)
            } catch {
                recordFailure(error)
            }
        }
        projectIfNeeded()
        return snapshot
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

    /// Reads the tail of the transcript at `path` and follows it.
    private func follow(_ path: String) async throws {
        try await follow(TranscriptFollower(path: path, limits: adapter.limits, identity: adapter.identity))
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

    /// Reads history above the oldest line read, a page at a time, until
    /// it brings the opener of a turn not shown before, the file's head or
    /// the saved entries are reached, or the source has spent the request's
    /// search. A turn's steps fold under its header, so pages that end
    /// inside a turn would add nothing to see. A request the timeline makes
    /// by itself (`automatic`) reads as the user's does, unless the source
    /// bounds it (`automaticOlderSearch`): then it reads at most that many
    /// bytes, and one that reads them all inside a turn leaves earlier
    /// history to the user's requests (`olderAwaitsUser`).
    func loadOlder(context: ChatProjectionContext, automatic: Bool = false) async -> ChatConversationSnapshot {
        setContext(context)
        guard var first = source, first.hasOlder, !olderUnreadable, !(automatic && snapshot.olderAwaitsUser)
        else { return snapshot }
        update { $0.older = .loading }
        let oldestOpener = snapshot.transcript.turns.first?.firstEntryID
        first.beginOlderSearch()
        source = first
        // Each page projects everything loaded again, so a long search
        // reads larger pages.
        let pageLengths = first.olderPageLengths
        var pageLength = pageLengths.first
        // What a bounded automatic request may still read. Its pages read
        // no more than their length, so this counts every byte, the lines
        // page boundaries cut and read again included.
        var allowance = automatic ? first.automaticOlderSearch : nil
        while var source {
            let limit = allowance.map { min(pageLength, $0) }
            allowance = allowance.map { $0 - (limit ?? 0) }
            do {
                switch try await source.loadOlder(files, length: limit ?? pageLength, limit: limit) {
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
                    return await open(directories: directories, context: context)
                }
                needsProjection = true
                update { $0.readFailure = nil }
            } catch let unavailable as ChatSourceUnavailable {
                stop(unavailable.reason)
                update { if $0.older == .loading { $0.older = .available } }
                break
            } catch {
                recordFailure(error)
                let message =
                    (error as? TransportError)?.presentation.summary
                    ?? "Earlier messages could not be read"
                update { $0.older = .failed(message) }
                break
            }
            projectIfNeeded()
            pageLength = min(pageLength * 2, pageLengths.maximum)
            guard snapshot.transcript.turns.first?.firstEntryID == oldestOpener, snapshot.older != .reachedStart,
                self.source?.hasOlder == true, !olderUnreadable, self.source?.olderSearchExhausted == false
            else { break }
            if allowance == 0 {
                // Further pages would only grow the turn's run of steps.
                update { $0.olderAwaitsUser = true }
                break
            }
        }
        if snapshot.transcript.turns.first?.firstEntryID != oldestOpener {
            update { $0.olderAwaitsUser = false }
        }
        projectIfNeeded()
        return snapshot
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
        let document = ChatCacheDocument(
            key: cacheKey, adapterRevision: adapter.revision, transcriptPath: path, head: head,
            coverageStart: coverageStart, coverageEnd: source.readOffset,
            reachedStart: (joined?.reachedStart ?? (windowStart == 0)) || olderUnreadable,
            title: snapshot.transcript.title, entries: entries, savedAt: date,
            backgroundWork: snapshot.transcript.listedBackgroundWork,
            latestPromptOffset: snapshot.transcript.latestPromptOffset, turns: snapshot.transcript.turns)
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
                if error is CancellationError || error as? TransportError == .cancelled { return workflowProgress }
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

    // MARK: Output

    /// A tool's output read again for an expanded row: the line its row
    /// references, read through the source and decoded up to
    /// `ChatToolPreview.expandedLimits` and `ChatFileChanges.expandedLimits`,
    /// or the start of the file the program moved a long output to.
    func output(of tool: ChatToolActivity) async -> Result<ChatExpandedOutput, ChatToolOutputFailure> {
        guard let reference = tool.output, let reducer, let source else {
            return .failure(.notFollowing)
        }
        guard reference.length <= ChatToolPreview.maximumFetchBytes else { return .failure(.tooLong) }
        do {
            guard let line = try await source.line(at: reference, files: files) else { return .failure(.gone) }
            let output = ChatToolPreview.$limits.withValue(ChatToolPreview.expandedLimits) {
                ChatFileChanges.$limits.withValue(ChatFileChanges.expandedLimits) {
                    reducer.output(of: line, for: tool)
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
                .unreadable((error as? TransportError)?.presentation.summary ?? "The Host could not be read."))
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
                sessionID: reference.sessionID, directories: candidates, searchesEveryProject: searchesEveryProject)
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
                threadID: reference.sessionID)
            {
            case .success(let location):
                guard let live = location.live else { return .unavailable(.notFound(searchedAll: true)) }
                return .found(live.path)
            case .failure(.notFound): return .unavailable(.notFound(searchedAll: true))
            case .failure(.compressed): return .unavailable(.compressed)
            case .failure(.mismatched): return .unavailable(.mismatched)
            }
        case .pi, .omp:
            switch try await PiTranscriptLocator(files: files).locate(
                reference: reference, directories: directories)
            {
            case .success(let path): return .found(path)
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
                return .unavailable(.unsupportedFormat("\(name) session version \(version)"))
            }
        case .grok:
            switch try await GrokTranscriptLocator(files: files).locate(
                sessionID: reference.sessionID, directories: directories)
            {
            case .success(let path): return .found(path)
            case .failure(.notFound(let searchedAll)):
                return .unavailable(.notFound(searchedAll: searchedAll))
            case .failure(.mismatched): return .unavailable(.mismatched)
            }
        case .opencode:
            // Its store is read by query, so `open` never looks for a file.
            return .unavailable(.unsupportedSession)
        }
    }

    // MARK: Following

    /// Starts over on a freshly opened source: a new reducer over its tail
    /// window. Nothing changes if building it fails.
    private func start(_ source: any ChatTranscriptSource, lines: [ChatLine]) async throws {
        var reducer = adapter.makeReducer(
            ChatReducerSeed(path: source.path, firstLine: try await firstLine(for: source)))
        reducer.append(lines)
        if let format = reducer.unsupportedFormat {
            stop(.unsupportedFormat(format))
            return
        }
        var movedLayout = hasFollowed || snapshot.readOffset > source.readOffset
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
        hasFollowed = true
        olderUnreadable = false
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
        guard adapter.wantsFirstLine, let follower = source as? TranscriptFollower, follower.windowStart != 0,
            case .line(let data)? = try await files.firstLine(
                of: follower.path, initialBytes: 64 << 10, limit: 1 << 20)
        else { return nil }
        return ChatLine(offset: 0, data: Data(data))
    }

    /// Stops following, keeping whatever shows.
    private func stop(_ reason: ChatUnavailableReason) {
        source = nil
        reducer = nil
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
    /// a gap.
    private func joinedCache(windowStart: UInt64) -> ChatCacheDocument? {
        guard adapter.joinsCachedHistory, let cached, windowStart > 0, cached.coverageEnd >= windowStart,
            cached.coverageStart < windowStart
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
        if let directory = transcript.links.relocatedCwd { relocatedDirectory = directory }
        let older: ChatOlderHistory =
            switch (reachedStart, snapshot.older) {
            case (true, _): .reachedStart
            case (false, .failed(let message)): .failed(message)
            case (false, _): .available
            }
        update {
            $0.transcript = transcript
            $0.older = older
            $0.readOffset = source.readOffset
        }
    }

    private func recordFailure(_ error: any Error) {
        if error is CancellationError || error as? TransportError == .cancelled { return }
        let failure =
            error as? TransportError
            ?? .channelFailed(detail: String(describing: type(of: error)))
        update {
            $0.readFailure = failure
            if $0.older == .loading { $0.older = .available }
        }
    }

    private func update(_ change: (inout ChatConversationSnapshot) -> Void) {
        var next = snapshot
        change(&next)
        guard next != snapshot else { return }
        next.revision = snapshot.revision + 1
        snapshot = next
    }
}
