import Foundation
import Observation

/// What one Agent's Chat reads through. ConsoleStore binds the closures
/// late to the Host's live connection, so a reconnect never strands them.
struct AgentChatSource: Sendable {
    let hostID: Host.ID
    /// The herdr session the Host connects to, which keys the cache.
    let socketLocation: HerdrSocketLocation
    let files: ChatHostFiles
    /// Re-reads the Agent's record (`agent.get`). herdr reports a changed
    /// session through no event, so Chat asks after status changes, and
    /// every few seconds while it shows an idle Agent.
    let agentInfo: @Sendable () async throws -> Agent
    let cache: any ChatTranscriptCache
    let adapter: ChatTranscriptAdapter
    /// Looks up only a saved binding for this exact Agent identity, waiting
    /// for the local directory to load. It never confirms a live session.
    var cachedSession: @Sendable (Agent) async -> AgentSessionInfo? = { _ in nil }
    /// The processes in the Agent's foreground job (`pane.process_info`),
    /// which say how its program was launched; nil where nothing can read
    /// them.
    var processInfo: (@Sendable () async throws -> PaneProcessInfo)?
    /// The Agent's pane, which a Blocked card reads and answers.
    var screen: BlockedScreenIO = .unavailable
}

/// One Agent's Chat (ADR 0024): the conversation herdr says the Agent is
/// in, followed while Chat shows.
///
/// A single loop makes every engine call in turn. The view's requests, an
/// older page or a retry, only set a flag and wake the loop, so a poll, a
/// page and a save never interleave on one transcript.
@MainActor
@Observable
final class AgentChatStore {
    struct Timing: Sendable {
        var activeInterval: Duration = .seconds(1)
        var idleInterval: Duration = .seconds(4)
        /// The active pace of a conversation read by query, each read an
        /// exec on the Host (ADR 0025).
        var queryActiveInterval: Duration = .seconds(2)
        /// The longest pause a query that keeps timing out backs off to.
        var queryTimeoutBackoffCap: Duration = .seconds(30)
        /// How long after a change, a send or a status change polling stays
        /// at the active interval.
        var activeLinger: TimeInterval = 15
        /// Waits before looking for a transcript again, one per failed look;
        /// the last repeats.
        var locateBackoff: [TimeInterval] = [2, 4, 8, 16, 30]
        /// How often the Agent's record is re-read while it reports no
        /// session Chat can follow.
        var sessionRecheck: TimeInterval = 5
        /// How often the record of an idle Agent is re-read while Chat
        /// shows it: `/clear`, `/new` or `/resume` typed in the terminal
        /// moves an idle Agent to another session without a status change.
        var idleSessionRecheck: TimeInterval = 5
        /// How long after delivery a sent prompt may stay unrecorded before
        /// its echo says so, counted on the send's echo clock.
        var echoTimeout: TimeInterval = 10
        /// How long after delivery the program's prompt log is first read
        /// for a send delivered while herdr reported the Agent neither
        /// Working nor Blocked (`ChatTranscriptAdapter.sendWitness`). The
        /// last read comes when the send's echo clock reaches `echoTimeout`.
        var witnessFirstRead: TimeInterval = 2
        /// How long the log's size, a send's mark, may take to read. A mark
        /// still on its way when the send goes is dropped.
        var witnessMarkTimeout: Duration = .seconds(1)
        var witnessReadTimeout: Duration = .seconds(3)
        /// How long Pi or Oh My Pi stays idle before Chat looks in its input
        /// box for unrecorded sends, overdue or not, that the turn which
        /// just ended put back.
        var returnCheckDelay: TimeInterval = 1
        var backgroundWorkStaleness = ChatBackgroundWork.Staleness()
    }

    /// A message in Chat's Composer, as the store matches it against the
    /// prompts the transcript records.
    struct SentMessage: Equatable, Sendable {
        let id: UUID
        /// What herdr typed: the draft after Chat's rewrite.
        let text: String
        /// `agent.prompt` took it, so the program may record it.
        let isDelivered: Bool
    }

    /// Where a sent message stands against the transcript.
    enum SendStatus: Equatable, Sendable {
        case awaiting
        /// The transcript recorded it; its entry replaces the echo.
        case recorded
        /// Still unrecorded once its echo clock reaches `Timing.echoTimeout`.
        case overdue
        /// Unrecorded, and its text sits in the idle Agent's input box: Pi
        /// and Oh My Pi put a steer the turn had not taken back there when
        /// Esc stops the turn, and never record it. A recorded copy still
        /// wins, and a later read of the box that no longer finds it makes
        /// it discarded.
        case returned
        /// Returned, then gone from the input box without the transcript
        /// recording it, such as when the user cleared it in the terminal.
        /// The box is not looked at for it again; only a recorded copy,
        /// such as one the terminal sent, still settles it.
        case discarded
        /// Overdue, and the program said on screen that it would not do
        /// it, saying so here: Pi and Oh My Pi print "Compaction failed"
        /// for a `/compact` with nothing to compact and record nothing. A
        /// recorded copy still wins.
        case refused(String)
        /// Unrecorded, and the program's prompt log names one other session
        /// as the one that took it (`ChatTranscriptAdapter.sendWitness`). A
        /// recorded copy, such as one the terminal sent, still wins.
        case misdirected
        /// Unrecorded and no longer worth an echo: it went into an earlier
        /// conversation, was sent before this store was watching, or was
        /// discarded, refused or misdirected and the transcript has recorded
        /// a prompt since.
        case abandoned
    }

    /// Who asked for earlier messages.
    private enum OlderRequest {
        /// The timeline, as the reader neared the top.
        case automatic
        /// The user: Load Earlier Messages or Retry.
        case user
    }

    let agentID: ConsoleAgent.ID
    let program: ChatProgram
    /// The conversation as last read, or why there is none.
    private(set) var conversation: ChatConversationSnapshot
    /// Whether a Chat view is showing this conversation.
    private(set) var isVisible = false
    /// Changes whenever Chat starts following another conversation, which
    /// the timeline opens at its end instead of diffing into.
    private(set) var conversationGeneration = 0
    /// Each message `updateSends(_:)` reported, by Composer message id.
    private(set) var sendStatuses: [UUID: SendStatus] = [:]
    /// The dialog the Agent waits on while herdr reports it Blocked.
    let blocked: BlockedCardStore
    /// Output read again for expanded tool rows in this conversation.
    private(set) var outputs = ChatToolOutputs()
    /// The Subagents and Workflows the conversation's program runs beside
    /// it, as last read.
    private(set) var backgroundWork = ChatBackgroundWork()
    /// A send the program recorded in another session, which holds every
    /// send until the user is back in this conversation. Only the prompt
    /// log sets it; what the screen shows is read afresh at each send.
    private(set) var sessionConcern: ChatSessionConcern?
    /// Why the conversation herdr reports may not be the one in the Agent's
    /// terminal, read from how the program was launched. It describes the
    /// process, so it outlives a change of conversation.
    private(set) var launchNotice: ChatLaunchNotice?
    /// Whether a read of the launch has finished, so a missing notice
    /// means none rather than not known yet.
    private(set) var hasCheckedLaunch = false

    /// Until the first read of the launch, waiting for a session may be
    /// the notice's case, which a prompt won't end: Chat keeps looking
    /// rather than ask for one.
    var isCheckingLaunch: Bool {
        program.mayShareSessionServer && source.processInfo != nil && !hasCheckedLaunch
    }

    @ObservationIgnored private let source: AgentChatSource
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var agent: Agent
    /// Whether this conversation has had a live read. Until then the
    /// Background Work list stays empty: saved work alone could have ended
    /// long ago (ADR 0024).
    @ObservationIgnored private var hasReadLive = false
    /// What herdr last said the Agent's session is.
    @ObservationIgnored private var resolution: ConversationReference.Resolution
    /// A session the transcript says the conversation continued in, until
    /// herdr reports a session of its own.
    @ObservationIgnored private var continuedSession: ConversationReference?
    @ObservationIgnored private var followed: ConversationReference?
    /// The conversation herdr still reports after the program left it for
    /// its home screen, and the terminal title it had there. Reports of it
    /// read as no report until the program shows it again or herdr reports
    /// another (`checkStartScreen`).
    @ObservationIgnored private var staleSession: ConversationReference?
    @ObservationIgnored private var staleTitle: String?
    /// Retry asks the start-screen watch for a look at the screen.
    @ObservationIgnored private var screenCheckRequested = false
    /// Whether the next visible step reads how the program was launched.
    @ObservationIgnored private var needsLaunchCheck = true
    @ObservationIgnored private var lastLaunchCheck: Date?
    /// Whether the last read of the launch failed, which the next session
    /// recheck tries again.
    @ObservationIgnored private var launchCheckFailed = false
    /// The transport reads no processes, so Chat stops asking.
    @ObservationIgnored private var launchCheckUnavailable = false
    @ObservationIgnored private var engine: ChatConversationEngine?
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var appliedRevision: Int?
    @ObservationIgnored private var needsAgentRefresh = true
    /// Rejects an Agent query overtaken by a newer Console session record.
    @ObservationIgnored private var sessionRecordRevision = 0
    @ObservationIgnored private var lastAgentRefresh: Date?
    /// Agent queries and transcript reads recover independently.
    @ObservationIgnored private var agentRefreshFailure: TransportError?
    @ObservationIgnored private var transcriptReadFailure: TransportError?
    /// A page above the oldest message shown that waits for the loop, by
    /// who asked for it.
    @ObservationIgnored private var olderRequest: OlderRequest?
    /// Look for the transcript's file again before the next read: Codex
    /// continues an undone thread in a new file and leaves the old one
    /// unchanged, so following it alone never shows the new turns.
    @ObservationIgnored private var needsRelocate = false
    @ObservationIgnored private var nextOpen: Date?
    @ObservationIgnored private var failedOpens = 0
    /// Reads in a row that timed out, which slow a conversation read by
    /// query.
    @ObservationIgnored private var timedOutReads = 0
    @ObservationIgnored private var lastActivity: Date?
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var loopID: UUID?
    /// The last loop's end, saving included; a new loop waits for it.
    @ObservationIgnored private var finishing: Task<Void, Never>?
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    @ObservationIgnored private var wakeRequested = false
    /// The Chat views on screen; the conversation is followed while any is.
    @ObservationIgnored private var viewers: Set<UUID> = []
    @ObservationIgnored private var sends: [TrackedSend] = []
    /// Sends the input box was last seen holding, which stay `.returned`
    /// until the transcript records them or a later read of the box no
    /// longer finds them.
    @ObservationIgnored private var returnedSends: Set<UUID> = []
    /// Returned sends a later read of the box no longer found, which stay
    /// `.discarded` unless the transcript records them.
    @ObservationIgnored private var discardedSends: Set<UUID> = []
    /// Returned sends the box was seen holding among more text, which the
    /// user added in the terminal: a recorded prompt that contains one
    /// settles it, since what the user sent is that text and more.
    @ObservationIgnored private var extendedSends: Set<UUID> = []
    /// Sends already looked for in the input box since the Agent last
    /// turned idle: each idle spell reads the screen once for them.
    @ObservationIgnored private var returnChecked: Set<UUID> = []
    /// What the program said on screen about each refused send.
    @ObservationIgnored private var refusedSends: [UUID: String] = [:]
    /// Overdue `/compact` sends already looked for on the screen, once each.
    @ObservationIgnored private var compactChecked: Set<UUID> = []
    /// When the screen last showed a `/compact` send's compaction running:
    /// its echo waits `Timing.echoTimeout` from then, not from delivery.
    @ObservationIgnored private var compactingSeen: [UUID: Date] = [:]
    /// Each send's witness, for a program that logs its prompts.
    @ObservationIgnored private var witnesses: [UUID: WitnessState] = [:]
    /// The latest mark taken for each send, kept so tests can wait for them.
    @ObservationIgnored private var witnessMarks: [UUID: Task<Void, Never>] = [:]
    /// Sends the prompt log says another session took.
    @ObservationIgnored private var misdirectedSends: Set<UUID> = []
    /// When the last transcript read applied to this conversation started:
    /// a session check trusts the transcript once one started after herdr
    /// last reported the Agent idle.
    @ObservationIgnored private var lastReadStartedAt: Date?
    /// When herdr last reported the Agent idle, while it still is.
    @ObservationIgnored private var idleSince: Date?
    /// When herdr last reported a turn starting. Esc puts back only the
    /// steers queued in the turn it stops, so sends delivered before this
    /// are never looked for in the box.
    @ObservationIgnored private var turnStartedAt: Date?
    /// When herdr last reported the Agent Working or Blocked, while it
    /// still does, and the earlier spells it did so that ended after the
    /// oldest send still awaiting its echo was delivered: a program whose
    /// echo clock stops while it works leaves them out of that clock.
    @ObservationIgnored private var busySince: Date?
    @ObservationIgnored private var busySpells: [(start: Date, end: Date)] = []
    /// Recorded prompts already taken by a send in the current
    /// conversation: one recorded copy answers one send. Keyed by entry for
    /// a program whose entries outlive a rewrite of its file, otherwise by
    /// offset within one layout of the file. The value is when the send
    /// that took it was delivered.
    @ObservationIgnored private var claimedPrompts: [String: Date] = [:]
    @ObservationIgnored private var claimedGeneration = 0
    @ObservationIgnored private var claimedLayout = 0
    @ObservationIgnored private var skillNames: Set<String> = []
    /// Rows expanded before the transcript was open, or while the Host was
    /// not connected, read once both are.
    @ObservationIgnored private var waitingOutputs: Set<ChatEntryID> = []
    /// What the Console last said of the Host's connection. A saved
    /// conversation keeps following offline, but its outputs cannot be read.
    @ObservationIgnored private var isHostConnected = true
    /// The latest read for each row, kept so tests can wait for them.
    @ObservationIgnored private var outputReads: [ChatEntryID: Task<Void, Never>] = [:]
    /// What each listed Workflow's journal showed, by the Workflow's id.
    @ObservationIgnored private var workflowProgress: [String: ChatWorkflowProgress] = [:]

    private struct TrackedSend {
        let id: UUID
        let key: String
        /// What herdr typed, looked for in the input box.
        let text: String
        /// The conversation it went into, how its file was laid out, and
        /// how far it had been read: while that layout holds, the program
        /// records the prompt at or after this offset.
        let generation: Int
        let layout: Int
        let floor: UInt64
        /// The entries showing when it was sent, none of which can record
        /// it, wherever a rewrite moves them.
        let knownEntries: Set<ChatEntryID>
        /// First seen already delivered, so its floor is unknown.
        let isOrphan: Bool
        var deliveredAt: Date?
    }

    /// Where a send's witness stands: its mark, taken when the send first
    /// shows and kept only if it landed before the check that let the send
    /// go, and which of its reads have run.
    private struct WitnessState {
        enum Mark {
            case taking
            case taken(ChatSendWitnessMark)
            case sealed(ChatSendWitnessMark)
            case unavailable
        }

        var mark: Mark = .taking
        /// herdr reported the Agent neither Working nor Blocked when it went:
        /// the program submitted it at once, so its line is soon there.
        var deliveredWhileIdle = false
        var firstReadDone = false
        var lastReadDone = false
    }

    /// Callers that only ever show one Chat for this Agent.
    static let soleViewer = UUID()

    init(
        agentID: ConsoleAgent.ID,
        agent: Agent,
        program: ChatProgram,
        source: AgentChatSource,
        timing: Timing = Timing(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.agentID = agentID
        self.agent = agent
        self.program = program
        self.source = source
        self.timing = timing
        self.now = now
        let resolution = ConversationReference.resolve(agent.agentSession)
        self.resolution = resolution
        conversation = ChatConversationSnapshot()
        blocked = BlockedCardStore(program: program, io: source.screen)
        blocked.update(activity: ChatAgentActivity(agent.status))
        switch ChatAgentActivity(agent.status) {
        case .idle: idleSince = now()
        case .working: turnStartedAt = now()
        default: break
        }
        noteActivity(ChatAgentActivity(agent.status))
        followReference()
    }

    // MARK: View lifecycle

    /// A Chat view is on screen: follow the conversation. Each view passes
    /// its own token, so one window leaving does not stop another's.
    func show(_ viewer: UUID = AgentChatStore.soleViewer) {
        if viewers.isEmpty {
            // Background prefetches back off looking for a missing
            // transcript; opening Chat looks at once and backs off afresh.
            switch conversation.phase {
            case .locating, .unavailable(.notFound):
                nextOpen = nil
                failedOpens = 0
            default:
                break
            }
        }
        viewers.insert(viewer)
        isVisible = true
        needsAgentRefresh = true
        needsLaunchCheck = true
        startLoop()
        blocked.show()
    }

    /// A Chat view left the screen. The last one out stops reading, saving
    /// what showed.
    func hide(_ viewer: UUID = AgentChatStore.soleViewer) {
        viewers.remove(viewer)
        guard viewers.isEmpty else { return }
        isVisible = false
        stopLoop()
        blocked.hide()
    }

    /// The app went to the background; Chat keeps its place.
    func suspend() {
        isSuspended = true
        stopLoop()
        blocked.suspend()
    }

    func resume() {
        isSuspended = false
        needsAgentRefresh = true
        needsLaunchCheck = true
        startLoop()
        blocked.resume()
    }

    /// The Agent or its Host is gone.
    func end() {
        viewers.removeAll()
        isVisible = false
        stopLoop()
        blocked.end()
    }

    /// Warms the local document once after a fresh Host snapshot, without
    /// opening Chat or starting permanent polling. A view appearing during
    /// this read takes over the same serialized loop when it finishes.
    /// Returns whether an active visible reader handles the refresh, or this
    /// call completed its own pass without cancellation. Callers still check
    /// the snapshot for read failures. Busy hidden readers return false so
    /// reconnect can retry after a cancelled earlier pass finishes.
    @discardableResult
    func prefetch() async -> Bool {
        guard !isSuspended, !Task.isCancelled else { return false }
        if isVisible { return loop.map { !$0.isCancelled } ?? false }
        guard loop == nil else { return false }
        needsAgentRefresh = true
        let previous = finishing
        let id = UUID()
        loopID = id
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if !Task.isCancelled {
                await self.step()
                await self.engine?.save(force: true)
            }
            guard self.loopID == id else { return }
            self.loop = nil
            self.loopID = nil
            self.startLoop()
        }
        loop = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return !Task.isCancelled && !task.isCancelled
    }

    // MARK: Requests

    /// Preview reads use the same Host connection as the transcript.
    func readImage(at path: String) async throws -> Data {
        try await ChatImagePreviewReader.read(path: path, files: source.files)
    }

    /// Reads one page above the oldest message shown, for the user or,
    /// `automatic`, for a timeline whose rows do not fill the screen.
    func loadOlder(automatic: Bool = false) {
        // The timeline asks as the user does, unless the program bounds
        // what it loads by itself: then it never retries a failure, and
        // stops asking once earlier messages wait for the user.
        let canLoad =
            automatic && source.adapter.limits.automaticOlderSearch != nil
            ? conversation.older == .available && !conversation.olderAwaitsUser
            : conversation.older == .available || isFailedOlder
        guard canLoad, case .following = conversation.phase else { return }
        olderRequest = automatic ? .automatic : .user
        conversation.older = .loading
        wake()
    }

    /// Reads a tool's output again for its expanded row, once the
    /// transcript is open and the Host connected. A read that failed is
    /// tried again. Reads run beside the loop: they change nothing it
    /// follows.
    func loadOutput(_ id: ChatEntryID) {
        guard case .tool(let tool)? = conversation.transcript.entries.last(where: { $0.id == id })?.content,
            let reference = tool.output, outputs.needsRead(id, at: reference)
        else { return }
        guard case .following = conversation.phase, isHostConnected, let engine else {
            waitingOutputs.insert(id)
            return
        }
        waitingOutputs.remove(id)
        outputs.begin(id, at: reference)
        let generation = conversationGeneration
        outputReads[id] = Task { [weak self] in
            let result = await engine.output(of: tool)
            guard let self, conversationGeneration == generation else { return }
            outputs.finish(id, at: reference, with: result)
        }
    }

    /// The Console's Host status changed. Rows expanded while it was not
    /// connected are read once it is.
    func hostConnectionChanged(_ isConnected: Bool) {
        guard isConnected != isHostConnected else { return }
        isHostConnected = isConnected
        guard isConnected else { return }
        let waiting = waitingOutputs
        for id in waiting {
            loadOutput(id)
        }
    }

    /// Resolves once every output read so far has finished, for tests.
    func outputReadsSettled() async {
        for read in outputReads.values {
            await read.value
        }
    }

    /// Resolves once every witness mark taken so far has landed or timed
    /// out, for tests.
    func witnessMarksSettled() async {
        for mark in witnessMarks.values {
            await mark.value
        }
    }

    /// Looks for the transcript again now, after a failure or an
    /// unavailable state the user may have fixed, such as a program shown
    /// on its home screen that shows the conversation again.
    func retry() {
        needsAgentRefresh = true
        nextOpen = nil
        failedOpens = 0
        screenCheckRequested = true
        needsLaunchCheck = true
        wake()
    }

    /// A prompt was just sent: the Agent is about to write, and may start a
    /// session Chat has not seen.
    func noteSent() {
        lastActivity = now()
        needsAgentRefresh = true
        nextOpen = nil
        failedOpens = 0
        wake()
    }

    /// The messages Chat's Composer holds, oldest first. Each one's place in
    /// the transcript is taken when it first appears, before it is sent, so
    /// only prompts recorded after that can match it.
    func updateSends(_ messages: [SentMessage]) {
        let ids = Set(messages.map(\.id))
        sends.removeAll { !ids.contains($0.id) }
        returnedSends.formIntersection(ids)
        discardedSends.formIntersection(ids)
        extendedSends.formIntersection(ids)
        returnChecked.formIntersection(ids)
        refusedSends = refusedSends.filter { ids.contains($0.key) }
        compactChecked.formIntersection(ids)
        compactingSeen = compactingSeen.filter { ids.contains($0.key) }
        witnesses = witnesses.filter { ids.contains($0.key) }
        witnessMarks = witnessMarks.filter { ids.contains($0.key) }
        misdirectedSends.formIntersection(ids)
        for message in messages {
            if let index = sends.firstIndex(where: { $0.id == message.id }) {
                guard message.isDelivered != (sends[index].deliveredAt != nil) else { continue }
                sends[index].deliveredAt = message.isDelivered ? now() : nil
                if message.isDelivered {
                    witnessDelivery(of: message.id)
                    noteSent()
                }
            } else {
                let transcript = conversation.transcript
                let knownEntries = Set(transcript.entries.map(\.id) + transcript.recordedPrompts.compactMap(\.entryID))
                sends.append(
                    TrackedSend(
                        id: message.id, key: source.adapter.echoKey(message.text), text: message.text,
                        generation: conversationGeneration, layout: conversation.layoutGeneration,
                        floor: conversation.readOffset, knownEntries: knownEntries,
                        isOrphan: message.isDelivered, deliveredAt: message.isDelivered ? now() : nil))
                if !message.isDelivered { takeWitnessMark(for: message.id) }
            }
        }
        matchSends()
    }

    /// Why a send the input box would take waits all the same, from what
    /// the box doesn't show: a send the program recorded in another session
    /// (`sessionConcern`), or a screen showing another session
    /// (`ChatTranscriptAdapter.sessionCheck`). Nil lets it go, and keeps the
    /// witness mark of the newest unsent send of that text if it landed
    /// before this; one still on its way is dropped, so no mark postdates
    /// the paste. Synchronous: nothing is awaited between the screen read
    /// and the paste.
    func sendConcern(for outgoing: String, after screen: ANSIScreen) -> String? {
        var verdict = ChatScreenSessionVerdict.unknown
        if let check = source.adapter.sessionCheck { verdict = check(screen, sessionCheckInput) }
        switch verdict {
        case .thisSession:
            sessionConcern = nil
        case .otherSession:
            // herdr may have adopted the session already (a `/new` since its
            // last idle recheck): asking now rebinds Chat within one step.
            needsAgentRefresh = true
            wake()
        case .unknown:
            break
        }
        if let sessionConcern { return sessionConcern.reason }
        if case .otherSession(let reason) = verdict { return reason }
        let key = source.adapter.echoKey(outgoing)
        if let send = sends.last(where: { $0.deliveredAt == nil && $0.key == key }), var witness = witnesses[send.id] {
            switch witness.mark {
            case .taken(let mark): witness.mark = .sealed(mark)
            case .taking: witness.mark = .unavailable
            case .sealed, .unavailable: break
            }
            witnesses[send.id] = witness
        }
        return nil
    }

    /// What a session check reads besides the screen, while herdr reports a
    /// session Chat follows.
    private var sessionCheckInput: ChatSessionCheckInput? {
        guard let sessionID = followed?.sessionID, !isAwaitingSession else { return nil }
        let date = now()
        let unrecorded = sends.filter { send in
            send.generation == conversationGeneration && send.deliveredAt != nil && sendStatuses[send.id] != .recorded
        }
        let recent = unrecorded.filter { send in
            send.deliveredAt.map { date.timeIntervalSince($0) < timing.echoTimeout } ?? false
        }
        return ChatSessionCheckInput(
            sessionID: sessionID, transcript: conversation.transcript, activity: ChatAgentActivity(agent.status),
            polledSinceIdle: idleSince.flatMap { idle in lastReadStartedAt.map { $0 >= idle } } ?? false,
            unrecordedSendKeys: Set(recent.map(\.key)),
            misdirectedSendKeys: Set(unrecorded.filter { misdirectedSends.contains($0.id) }.map(\.key)))
    }

    /// The skills the Host offers, so a Codex `$name` prompt shows as the
    /// command it invoked.
    func skillsDidLoad(_ names: Set<String>) {
        guard names != skillNames else { return }
        skillNames = names
        wake()
    }

    /// The Console's latest record of the Agent, from a snapshot or a status
    /// change.
    func agentDidChange(_ next: Agent) {
        let statusChanged = next.status != agent.status
        let sessionChanged = next.agentSession != agent.agentSession
        let identityChanged = !sameIdentity(agent, next)
        if identityChanged { forgetStaleSession() }
        let reported = resolveReported(next.agentSession)
        // While the start screen marks a conversation stale, the same record
        // handed over again is no report: OpenCode changes its conversation
        // without a status change, so the Console's record can be older than
        // the answer herdr gave Chat (`checkStartScreen`).
        let bindingReturned = isAwaitingSession && staleSession == nil && reported != .noSession
        let previous = ChatAgentActivity(agent.status)
        agent = next
        // A program started again in the pane changes its status or
        // session, which is when its launch may have changed.
        if statusChanged || sessionChanged || identityChanged { needsLaunchCheck = true }
        if sessionChanged || identityChanged || bindingReturned {
            sessionRecordRevision += 1
            adopt(reported, replacingAgent: identityChanged)
            wake()
        }
        guard statusChanged else { return }
        let activity = ChatAgentActivity(next.status)
        blocked.update(activity: activity)
        noteActivity(activity)
        idleSince = activity == .idle ? now() : nil
        // Answering a dialog resumes the turn it interrupted.
        if activity == .working, previous != .working, previous != .blocked { turnStartedAt = now() }
        returnChecked = []
        // A turn starting or ending is when a session changes (`/clear`,
        // `/resume`), when a missing transcript appears, and when a turn
        // after an undo writes to the thread's new file.
        lastActivity = now()
        needsAgentRefresh = true
        needsRelocate = true
        nextOpen = nil
        failedOpens = 0
        wake()
    }

    // MARK: Loop

    /// One turn of the loop: restores local entries before asking the Host,
    /// then makes at most one read of the transcript, and after a poll that
    /// worked, a few reads of Workflow journals. Internal for tests, which
    /// drive turns directly.
    func step() async {
        await restoreIfNeeded()
        guard !Task.isCancelled else { return }
        if needsAgentRefresh || sessionRecheckIsDue, let fresh = await refreshAgent() {
            guard !Task.isCancelled else { return }
            await checkStartScreen(fresh)
        }
        guard !Task.isCancelled else { return }
        // The query may select another session. Restore that session's own
        // document before waiting for its transcript, too.
        await restoreIfNeeded()
        guard !Task.isCancelled else { return }
        guard let engine, !isAwaitingSession else {
            matchSends()
            refreshBackgroundWork()
            // The launch may be why no session comes.
            if launchCheckIsDue { await checkLaunch() }
            return
        }
        let context = projectionContext
        let snapshot: ChatConversationSnapshot
        let readStart = now()
        var polled = false
        var opened = false
        var didRead = true
        if let request = olderRequest {
            olderRequest = nil
            snapshot = await engine.loadOlder(context: context, automatic: request == .automatic)
        } else if case .following = conversation.phase {
            if needsRelocate {
                needsRelocate = false
                snapshot = await engine.relocate(context: context)
                // A search that failed is tried again on the next step.
                if snapshot.readFailure != nil, !Task.isCancelled, engine === self.engine { needsRelocate = true }
            } else {
                snapshot = await engine.poll(context: context)
            }
            polled = true
        } else if openIsDue {
            snapshot = await engine.open(directories: directories, context: context, lostAMessage: hasLostAMessage)
            if !Task.isCancelled, engine === self.engine { scheduleNextOpen(after: snapshot) }
            opened = true
        } else {
            snapshot = await engine.reproject(context: context)
            didRead = false
        }
        guard !Task.isCancelled, engine === self.engine, !isAwaitingSession else { return }
        if didRead { countTimeout(snapshot.readFailure) }
        apply(snapshot, from: engine)
        if polled || opened, case .following = snapshot.phase, snapshot.readFailure == nil {
            lastReadStartedAt = readStart
        }
        matchSends()
        // Persist the transcript before optional journal requests can wait
        // on an unavailable connection.
        await engine.save()
        guard !Task.isCancelled, engine === self.engine, !isAwaitingSession else { return }
        await checkReturnedSends()
        guard !Task.isCancelled, engine === self.engine, !isAwaitingSession else { return }
        await checkRefusedCompactions()
        guard !Task.isCancelled, engine === self.engine, !isAwaitingSession else { return }
        await checkSendWitnesses()
        guard !Task.isCancelled, engine === self.engine, !isAwaitingSession else { return }
        // A journal read adds a deadline of its own, so a round whose
        // transcript read failed leaves the journals for later.
        if polled, case .following = snapshot.phase, snapshot.readFailure == nil {
            let progress = await engine.followWorkflows()
            if engine === self.engine { workflowProgress = progress }
        }
        refreshBackgroundWork()
        // After the transcript, which never waits on it.
        guard !Task.isCancelled else { return }
        if launchCheckIsDue { await checkLaunch() }
    }

    private func restoreIfNeeded() async {
        while engine == nil, resolution == .noSession {
            let recordRevision = sessionRecordRevision
            let session = await source.cachedSession(agent)
            guard !Task.isCancelled else { return }
            // Retry the local lookup if inventory replaced this Agent while
            // the directory was loading. Its cache must precede remote work.
            guard recordRevision == sessionRecordRevision else { continue }
            guard engine == nil, resolution == .noSession,
                case .bound(let reference) = ConversationReference.resolve(session), reference.program == program
            else { break }
            // Keep resolution unresolved: a saved binding permits local
            // display, never remote reads of an unconfirmed session.
            followReference(cachedReference: reference)
        }
        while !restored, let engine {
            let snapshot = await engine.restore()
            guard !Task.isCancelled else { return }
            // A Console update can switch sessions during a disk read.
            // Finish restoring the new identity before doing remote work.
            guard engine === self.engine else { continue }
            restored = true
            apply(snapshot, from: engine)
            matchSends()
            refreshBackgroundWork()
        }
    }

    private func startLoop() {
        guard isVisible, !isSuspended, loop == nil else { return }
        let previous = finishing
        loopID = UUID()
        loop = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled {
                guard let self else { return }
                await self.step()
                guard !Task.isCancelled else { return }
                await self.pause(self.interval)
            }
        }
    }

    private func stopLoop() {
        guard let loop else { return }
        loop.cancel()
        sleeper?.cancel()
        self.loop = nil
        loopID = nil
        let engine = engine
        finishing = Task {
            await loop.value
            await engine?.save(force: true)
        }
    }

    private func pause(_ duration: Duration) async {
        if wakeRequested {
            wakeRequested = false
            return
        }
        let sleeper = Task<Void, Never> { try? await Task.sleep(for: duration) }
        self.sleeper = sleeper
        await sleeper.value
        self.sleeper = nil
        wakeRequested = false
    }

    private func wake() {
        if let sleeper {
            sleeper.cancel()
        } else {
            wakeRequested = true
        }
    }

    /// The pause after each turn. Internal for tests.
    ///
    /// A conversation read by query keeps its own active pace, and each read
    /// in a row that timed out doubles the pause, up to a cap: a query past
    /// its deadline holds the Host's query lane until its watchdog ends it
    /// (ADR 0025).
    var interval: Duration {
        if engine == nil { return .seconds(timing.sessionRecheck) }
        guard source.adapter.readsByQuery else { return pace(active: timing.activeInterval) }
        let pace = pace(active: timing.queryActiveInterval)
        let cap = max(pace, timing.queryTimeoutBackoffCap)
        var interval = pace
        var doublings = timedOutReads
        while doublings > 0, interval < cap {
            interval *= 2
            doublings -= 1
        }
        return min(interval, cap)
    }

    private func pace(active: Duration) -> Duration {
        if [.working, .blocked].contains(agent.status) { return active }
        if let lastActivity, now().timeIntervalSince(lastActivity) < timing.activeLinger {
            return active
        }
        // herdr can report the Agent idle while its program still runs
        // work in the background.
        if backgroundWork.holdsActivePace { return active }
        return timing.idleInterval
    }

    /// Counts a read that timed out; a read without a failure starts over,
    /// and another failure leaves the count.
    private func countTimeout(_ failure: TransportError?) {
        switch failure {
        case .hostFileTimedOut?: timedOutReads += 1
        case nil: timedOutReads = 0
        default: break
        }
    }

    // MARK: Session

    private var sessionRecheckIsDue: Bool {
        let interval: TimeInterval
        if engine == nil || isUnavailable || agentRefreshFailure != nil {
            interval = timing.sessionRecheck
        } else if isVisible, ChatAgentActivity(agent.status) == .idle {
            interval = timing.idleSessionRecheck
        } else {
            return false
        }
        guard let lastAgentRefresh else { return true }
        return now().timeIntervalSince(lastAgentRefresh) >= interval
    }

    /// Re-reads the Agent's record and adopts the session it reports.
    /// Returns the record, unless reading it failed or a newer Console
    /// record overtook it.
    private func refreshAgent() async -> Agent? {
        needsAgentRefresh = false
        lastAgentRefresh = now()
        let recordRevision = sessionRecordRevision
        do {
            let fresh = try await source.agentInfo()
            guard !Task.isCancelled, recordRevision == sessionRecordRevision else { return nil }
            agentRefreshFailure = nil
            updateReadFailure()
            adoptRecord(fresh)
            return fresh
        } catch {
            guard !Task.isCancelled, recordRevision == sessionRecordRevision,
                !(error is CancellationError), error as? TransportError != .cancelled
            else { return nil }
            agentRefreshFailure = error as? TransportError
                ?? .channelFailed(detail: String(describing: type(of: error)))
            updateReadFailure()
            return nil
        }
    }

    /// Adopts the session in a record herdr just answered with. The
    /// Console's record keeps whatever its last snapshot said; herdr's
    /// answer here is newer, and only a later change to that record
    /// overrides it.
    private func adoptRecord(_ fresh: Agent) {
        let identityChanged = !sameIdentity(agent, fresh)
        if identityChanged {
            agent = fresh
            blocked.update(activity: ChatAgentActivity(fresh.status))
            noteActivity(ChatAgentActivity(fresh.status))
            forgetStaleSession()
            needsLaunchCheck = true
        }
        adopt(resolveReported(fresh.agentSession), replacingAgent: identityChanged)
    }

    /// Due while Chat shows the conversation, after anything that may mean
    /// the program was started again, and every session recheck while a
    /// notice shows, so it clears once the user restarts the program, or
    /// after a failed read.
    private var launchCheckIsDue: Bool {
        guard program.mayShareSessionServer, isVisible, source.processInfo != nil, !launchCheckUnavailable else {
            return false
        }
        if needsLaunchCheck { return true }
        guard launchNotice != nil || launchCheckFailed, let lastLaunchCheck else { return false }
        return now().timeIntervalSince(lastLaunchCheck) >= timing.sessionRecheck
    }

    /// Reads whether Codex in the Agent's pane runs on its shared server:
    /// launched without an option that keeps it off one, while one runs. A
    /// failed read keeps the last answer; Chat itself never depends on it.
    private func checkLaunch() async {
        guard let processInfo = source.processInfo else { return }
        needsLaunchCheck = false
        lastLaunchCheck = now()
        let info: PaneProcessInfo
        do {
            info = try await processInfo()
        } catch {
            guard !Task.isCancelled else { return }
            if case .hostFeatureUnavailable? = error as? TransportError {
                launchCheckUnavailable = true
                launchNotice = nil
            } else {
                launchCheckFailed = true
            }
            hasCheckedLaunch = true
            return
        }
        var notice: ChatLaunchNotice?
        if CodexLaunch.launchesOnSharedServer(info) == true {
            do {
                let socket = CodexLaunch.controlSocketPath(home: try await source.files.home())
                if try await source.files.status(socket) != nil { notice = .codexSharedServer }
            } catch {
                guard !Task.isCancelled else { return }
                launchCheckFailed = true
                hasCheckedLaunch = true
                return
            }
        }
        guard !Task.isCancelled else { return }
        launchCheckFailed = false
        if launchNotice != notice { launchNotice = notice }
        hasCheckedLaunch = true
    }

    private func sameIdentity(_ lhs: Agent, _ rhs: Agent) -> Bool {
        lhs.terminalID == rhs.terminalID && lhs.workspaceID == rhs.workspaceID
            && lhs.tabID == rhs.tabID && lhs.kind == rhs.kind && lhs.paneID == rhs.paneID
    }

    /// An unreported binding does not prove that this Agent changed its
    /// conversation. Keep its last document readable, but stop remote reads
    /// until the Host supplies an explicit binding again. A report of a
    /// stale conversation counts as none (`resolveReported`).
    private var isAwaitingSession: Bool {
        resolution == .noSession && followed != nil
    }

    /// What herdr's report means here: a report of the conversation the
    /// program left for its home screen reads as none.
    private func resolveReported(_ session: AgentSessionInfo?) -> ConversationReference.Resolution {
        let resolved = ConversationReference.resolve(session)
        if let staleSession, resolved == .bound(staleSession) { return .noSession }
        return resolved
    }

    /// Why Chat shows no conversation while it awaits a session from herdr:
    /// none reported, or only the one the program left for its home screen.
    private var awaitingReason: ChatUnavailableReason {
        staleSession == nil ? .noSession(program) : .startScreen(program)
    }

    /// Whether the conversation shows `awaitingReason`.
    private var showsAwaitingReason: Bool {
        switch conversation.phase {
        case .unavailable(.noSession), .unavailable(.startScreen): true
        default: false
        }
    }

    private func adopt(_ next: ConversationReference.Resolution, replacingAgent: Bool = false) {
        guard next != resolution || replacingAgent else { return }
        if next != .noSession { forgetStaleSession() }
        resolution = next
        if !replacingAgent, isAwaitingSession {
            conversation.phase = .unavailable(awaitingReason)
            conversation.isFromCache = !conversation.transcript.entries.isEmpty
            if conversation.older == .loading { conversation.older = .available }
            olderRequest = nil
            appliedRevision = nil
            refreshBackgroundWork()
            return
        }
        continuedSession = nil
        followReference(force: replacingAgent)
    }

    /// Points the engine at the conversation to follow, starting a new one
    /// when it changed.
    private func followReference(force: Bool = false, cachedReference: ConversationReference? = nil) {
        var target = cachedReference
        if case .bound(let reference) = resolution, reference.program == program {
            target = continuedSession ?? reference
        }
        guard target != followed || force else {
            if target == nil {
                showUnavailable()
            } else if showsAwaitingReason {
                // Resume the same timeline rather than changing its identity
                // or clearing the entries while the Host is being read.
                conversation.phase = .locating
                appliedRevision = nil
                nextOpen = nil
                failedOpens = 0
            }
            return
        }
        if let engine { Task { await engine.save(force: true) } }
        followed = target
        transcriptReadFailure = nil
        conversationGeneration += 1
        // herdr reports another session: whatever went astray, Chat follows
        // the one the Agent is in now.
        sessionConcern = nil
        lastReadStartedAt = nil
        engine = target.map(makeEngine)
        restored = false
        appliedRevision = nil
        olderRequest = nil
        needsRelocate = false
        nextOpen = nil
        failedOpens = 0
        timedOutReads = 0
        // Reads still running for the last conversation drop their results.
        outputs = ChatToolOutputs()
        waitingOutputs = []
        workflowProgress = [:]
        backgroundWork = ChatBackgroundWork()
        hasReadLive = false
        if target == nil {
            showUnavailable()
        } else {
            conversation = ChatConversationSnapshot()
            if isAwaitingSession { conversation.phase = .unavailable(awaitingReason) }
            updateReadFailure()
        }
    }

    private func showUnavailable() {
        let reason: ChatUnavailableReason =
            switch resolution {
            case .noSession: .noSession(program)
            case .unidentified: .unidentifiedSession(program)
            case .unsupported, .bound: .unsupportedSession
            }
        var next = ChatConversationSnapshot()
        next.phase = .unavailable(reason)
        next.readFailure = agentRefreshFailure
        if conversation != next { conversation = next }
    }

    private func makeEngine(_ reference: ConversationReference) -> ChatConversationEngine {
        ChatConversationEngine(
            reference: reference,
            cacheKey: ChatCacheKey(
                hostID: source.hostID, socketLocation: source.socketLocation, reference: reference),
            files: source.files, cache: source.cache, adapter: source.adapter, now: now)
    }

    // MARK: Start screen

    /// The start-screen watch (ADR 0025), for a program that leaves its
    /// conversation without herdr reporting it
    /// (`ChatProgram.leavesSessionWithoutReport`): after OpenCode's `/new`
    /// herdr keeps reporting the conversation OpenCode left for its home
    /// screen. Each record read while Chat shows the idle Agent reads the
    /// screen once, unless the terminal title is the followed
    /// conversation's own, and the home screen marks the conversation
    /// stale: reports of it read as none, and Chat shows no conversation.
    /// The mark clears when herdr reports another conversation (`adopt`),
    /// when the screen shows a conversation under the stale one's title,
    /// unless that is the title the home screen has too, and when it shows
    /// one on the first read after Retry.
    private func checkStartScreen(_ fresh: Agent) async {
        let retried = screenCheckRequested
        screenCheckRequested = false
        guard program.leavesSessionWithoutReport, isVisible, ChatAgentActivity(fresh.status) == .idle else {
            return
        }
        let title = fresh.terminalTitleStripped
        let recordRevision = sessionRecordRevision
        if let staleSession {
            let showsStaleTitle = staleTitle != OpenCodeTerminalTitle.untitled && title == staleTitle
            guard showsStaleTitle || retried else { return }
            let route = await screenRoute()
            guard !Task.isCancelled, recordRevision == sessionRecordRevision, self.staleSession == staleSession,
                route == .session
            else { return }
            clearStaleSession(reporting: fresh.agentSession)
            return
        }
        guard case .bound(let reference) = resolution, reference == followed else { return }
        let sessionTitle = conversation.transcript.title
        guard OpenCodeTerminalTitle.verdict(terminalTitle: title, sessionTitle: sessionTitle) != .matches else {
            return
        }
        let route = await screenRoute()
        guard !Task.isCancelled, recordRevision == sessionRecordRevision, resolution == .bound(reference),
            followed == reference, route == .home
        else { return }
        staleSession = reference
        staleTitle = OpenCodeTerminalTitle.expected(sessionTitle: sessionTitle)
        adopt(.noSession)
    }

    /// The route the Agent's screen shows, or nil when it can't be read.
    private func screenRoute() async -> OpenCodeScreen.Route? {
        guard let screen = try? await source.screen.readScreen() else { return nil }
        return OpenCodeScreenReader.read(screen).route
    }

    /// Drops the stale mark and adopts what herdr reports now. A report of
    /// the same conversation resumes its kept timeline (`followReference`).
    private func clearStaleSession(reporting session: AgentSessionInfo?) {
        forgetStaleSession()
        let next = resolveReported(session)
        guard next != resolution else {
            // herdr reports none: Chat waits for one, as for any program.
            if isAwaitingSession { conversation.phase = .unavailable(awaitingReason) }
            return
        }
        adopt(next)
    }

    private func forgetStaleSession() {
        staleSession = nil
        staleTitle = nil
    }

    /// The check before each send, for a program that can leave its
    /// conversation without herdr reporting it
    /// (`ChatProgram.confirmsSessionBeforeSend`): reads the Agent's record
    /// once and adopts it, so Chat follows a session herdr newly reports,
    /// then compares the terminal title with the conversation's. Returns
    /// why the message would land outside the conversation Chat shows, or
    /// nil to go on.
    func confirmSessionBeforeSend() async -> String? {
        guard program.confirmsSessionBeforeSend else { return nil }
        let shown = followed
        let recordRevision = sessionRecordRevision
        // A newer Console record during the read may have moved Chat too.
        guard let fresh = try? await source.agentInfo(), !Task.isCancelled,
            recordRevision == sessionRecordRevision
        else { return Self.uncheckedSessionReason(program) }
        let before = resolution
        adoptRecord(fresh)
        if resolution != before { wake() }
        let name = program.chatName
        if followed != shown {
            return "herdr now reports another \(name) conversation for this Agent. Chat is switching to it; check it, then send again."
        }
        if staleSession != nil {
            return "\(name) is on its home screen, so this conversation isn't open there. Open it in the terminal first."
        }
        let verdict = OpenCodeTerminalTitle.verdict(
            terminalTitle: fresh.terminalTitleStripped, sessionTitle: conversation.transcript.title)
        if case .differs(let title) = verdict {
            return "\(name)'s terminal shows another conversation (\(title)). Open this one in the terminal, then send again."
        }
        return nil
    }

    /// Why a send that couldn't be checked sent nothing: the Agent's record
    /// couldn't be read, or there is no Chat to check with.
    static func uncheckedSessionReason(_ program: ChatProgram) -> String {
        "Heeler couldn't check which conversation \(program.chatName) shows, so it sent nothing. Try again."
    }

    // MARK: Snapshots

    private func apply(_ snapshot: ChatConversationSnapshot, from origin: ChatConversationEngine) {
        // A session switch may have replaced the engine during the read.
        guard origin === engine, snapshot.revision != appliedRevision,
            !isAwaitingSession || snapshot.isFromCache
        else { return }
        if snapshot.transcript.entries != conversation.transcript.entries { lastActivity = now() }
        appliedRevision = snapshot.revision
        transcriptReadFailure = snapshot.readFailure
        var next = snapshot
        next.readFailure = transcriptReadFailure ?? agentRefreshFailure
        if isAwaitingSession { next.phase = .unavailable(awaitingReason) }
        if olderRequest != nil, next.older == .available { next.older = .loading }
        conversation = next
        // A prompt the transcript recorded since: the terminal is back in
        // this conversation.
        if let concern = sessionConcern, let latest = next.transcript.latestPromptOffset,
            latest >= concern.promptFloor
        {
            sessionConcern = nil
        }
        blocked.update(transcript: next.transcript)
        if case .following = next.phase, !waitingOutputs.isEmpty {
            let waiting = waitingOutputs
            waitingOutputs = []
            for id in waiting {
                loadOutput(id)
            }
        }
        if let linked = snapshot.transcript.links.continuedInSessionID
            .flatMap(program.sessionNaming.sessionID),
            linked != followed?.sessionID
        {
            continuedSession = ConversationReference(program: program, sessionID: linked)
            followReference()
        }
    }

    private func updateReadFailure() {
        conversation.readFailure = transcriptReadFailure ?? agentRefreshFailure
    }

    private var isUnavailable: Bool {
        if case .unavailable = conversation.phase { return true }
        return false
    }

    private func refreshBackgroundWork() {
        var isLive = conversation.readFailure == nil && !conversation.isFromCache
        if case .following = conversation.phase {} else { isLive = false }
        if isLive { hasReadLive = true }
        let next =
            hasReadLive
            ? ChatBackgroundWork(
                transcript: conversation.transcript, progress: workflowProgress, isLive: isLive, now: now(),
                staleness: timing.backgroundWorkStaleness)
            : ChatBackgroundWork()
        if next != backgroundWork { backgroundWork = next }
    }

    private var isFailedOlder: Bool {
        if case .failed = conversation.older { return true }
        return false
    }

    private var openIsDue: Bool {
        nextOpen.map { now() >= $0 } ?? true
    }

    /// A message sent into this conversation went overdue: for Claude Code,
    /// which records one as it takes it, a session with no file then saves
    /// none rather than waiting for its first message.
    private var hasLostAMessage: Bool {
        sends.contains { $0.generation == conversationGeneration && sendStatuses[$0.id] == .overdue }
    }

    private func scheduleNextOpen(after snapshot: ChatConversationSnapshot) {
        switch snapshot.phase {
        case .following, .unavailable(.awaitingFirstMessage):
            // A new conversation's file comes with the first message or
            // reply, during a turn that keeps the active pace: look on
            // every pass. For Claude that stats only the Agent's
            // directories, past one search of every project directory
            // each time herdr reports another status.
            nextOpen = nil
            failedOpens = 0
            return
        case .unavailable(.sessionStore(_, let problem)) where !problem.reopensByItself:
            // Nothing on the Host fixes this unprompted: open again on Retry
            // or a status change.
            nextOpen = .distantFuture
            return
        default:
            break
        }
        let delays = timing.locateBackoff
        let delay = delays.isEmpty ? 0 : delays[min(failedOpens, delays.count - 1)]
        failedOpens += 1
        nextOpen = now().addingTimeInterval(delay)
        // Not found may mean the session moved on: ask herdr again first.
        needsAgentRefresh = true
    }

    private var directories: [String] {
        var directories: [String] = []
        for directory in [agent.foregroundCwd, agent.cwd].compactMap(\.self)
        where !directory.isEmpty && !directories.contains(directory) {
            directories.append(directory)
        }
        return directories
    }

    private var projectionContext: ChatProjectionContext {
        ChatProjectionContext(activity: ChatAgentActivity(agent.status), skillNames: skillNames)
    }

    // MARK: Sent prompts

    /// Matches sends to the prompts the transcript recorded: first in,
    /// first out, one to one, equal keys, and only prompts recorded after
    /// the send. A send that went into an earlier conversation, such as the
    /// first prompt that makes Codex report a session, may match anywhere in
    /// the current one, as may one sent before the file was rewritten; an
    /// entry already showing at the send never matches it. A discarded or
    /// misdirected send takes only a prompt no other send matches, so
    /// sending its text again settles the new send; a returned send the user
    /// added to in the box takes a prompt that contains it. Conservative on
    /// purpose: a wrong match would hide a prompt that never arrived. A
    /// discarded, refused or misdirected send that any prompt recorded after
    /// it overtakes, unmatched or matched by a later send, is abandoned: it
    /// is no longer the conversation's latest message. A send from before it
    /// recorded late does not overtake it.
    private func matchSends() {
        let byEntry = source.adapter.echoesByEntry
        let layout = conversation.layoutGeneration
        if claimedGeneration != conversationGeneration || (!byEntry && claimedLayout != layout) {
            claimedGeneration = conversationGeneration
            claimedLayout = layout
            claimedPrompts = [:]
        }
        struct Candidate {
            let claim: String
            let offset: UInt64
            let entryID: ChatEntryID?
        }
        func candidate(offset: UInt64, entryID: ChatEntryID?) -> Candidate? {
            guard byEntry else { return Candidate(claim: "@\(offset)", offset: offset, entryID: entryID) }
            return entryID.map { Candidate(claim: $0.rawValue, offset: offset, entryID: $0) }
        }
        let transcript = conversation.transcript
        let recorded = transcript.recordedPrompts.compactMap { prompt in
            candidate(offset: prompt.offset, entryID: prompt.entryID).map {
                (
                    candidate: $0, key: source.adapter.echoKey(prompt.text), text: String(Self.squeezed(prompt.text)),
                    imagePaths: prompt.pastedImagePaths
                )
            }
        }
        // Codex records no prompt for `/compact`, only the compaction.
        let compactions = transcript.entries.compactMap { entry -> Candidate? in
            guard case .divider(let divider) = entry.content, divider.kind == .compaction else { return nil }
            return candidate(offset: entry.sourceOffset, entryID: entry.id)
        }
        let date = now()
        // A new Pi or Oh My Pi conversation records nothing until the
        // program writes its file, however long the first reply takes.
        // Claude Code writes it with the message, so its echo times out.
        var isUnwritten = false
        if case .unavailable(.awaitingFirstMessage(let program)) = conversation.phase {
            isUnwritten = program.writesNewConversationWithFirstReply
        }
        var statuses: [UUID: SendStatus] = [:]
        var becameOverdue = false
        let matchedLast = discardedSends.union(misdirectedSends)
        let ordered = sends.filter { !matchedLast.contains($0.id) } + sends.filter { matchedLast.contains($0.id) }
        for send in ordered {
            if sendStatuses[send.id] == .recorded {
                statuses[send.id] = .recorded
                continue
            }
            guard let deliveredAt = send.deliveredAt else {
                statuses[send.id] = .awaiting
                continue
            }
            if send.isOrphan {
                statuses[send.id] = .abandoned
                continue
            }
            let isSameConversation = send.generation == conversationGeneration
            let floor = isSameConversation && send.layout == layout ? send.floor : 0
            func isAfter(_ candidate: Candidate) -> Bool {
                guard candidate.offset >= floor else { return false }
                guard isSameConversation, let entryID = candidate.entryID else { return true }
                return !send.knownEntries.contains(entryID)
            }
            func isOpen(_ candidate: Candidate) -> Bool {
                isAfter(candidate) && claimedPrompts[candidate.claim] == nil
            }
            // A prompt that a send from before this one took is that send's
            // late record, not a message after this one.
            var isOvertaken: Bool {
                recorded.contains { prompt in
                    isAfter(prompt.candidate) && claimedPrompts[prompt.candidate.claim].map { $0 > deliveredAt } ?? true
                }
            }
            var match = recorded.first { $0.key == send.key && isOpen($0.candidate) }?.candidate
            // A compaction recorded after a prompt recorded since the send
            // is a later `/compact`'s, however long this one stays in the
            // Composer.
            if match == nil, send.key == "/compact" {
                match = compactions.first { compaction in
                    isOpen(compaction)
                        && !recorded.contains { isAfter($0.candidate) && $0.candidate.offset < compaction.offset }
                }
            }
            // A path pasted alone becomes `[Image #N]` plus the image, which
            // may name the path only as the program read it, or not at all.
            if match == nil, let path = ChatRecordedPrompt.pastedPath(in: send.text) {
                match = recorded.first { prompt in
                    guard let paths = prompt.imagePaths, isOpen(prompt.candidate) else { return false }
                    return paths.isEmpty || paths.contains(path)
                }?.candidate
            }
            if match == nil, extendedSends.contains(send.id) {
                let text = String(Self.squeezed(send.text))
                match = recorded.first { !text.isEmpty && $0.text.contains(text) && isOpen($0.candidate) }?.candidate
            }
            if let match {
                claimedPrompts[match.claim] = deliveredAt
                statuses[send.id] = .recorded
            } else if misdirectedSends.contains(send.id) {
                statuses[send.id] =
                    send.generation == conversationGeneration && !isOvertaken ? .misdirected : .abandoned
            } else if returnedSends.contains(send.id), send.generation == conversationGeneration {
                statuses[send.id] = .returned
            } else if discardedSends.contains(send.id), send.generation == conversationGeneration {
                statuses[send.id] = isOvertaken ? .abandoned : .discarded
            } else if returnedSends.contains(send.id) || discardedSends.contains(send.id) {
                // Put back or cleared in an earlier conversation: the new
                // one, still unwritten, is not waiting for it.
                statuses[send.id] = .abandoned
            } else if let refusal = refusedSends[send.id] {
                statuses[send.id] =
                    send.generation == conversationGeneration && !isOvertaken ? .refused(refusal) : .abandoned
            } else if send.key == "/compact", program.recordsCompactionBeforeNextPrompt, isOvertaken {
                // The program records a compaction before the next prompt,
                // and a refused one nowhere: with a prompt after it and no
                // compaction, it never ran, whatever the screen read found.
                statuses[send.id] = .abandoned
            } else if isUnwritten || echoClock(for: send, at: date) < timing.echoTimeout
                || awaitsCompaction(send, at: date)
            {
                statuses[send.id] = .awaiting
            } else if send.generation == conversationGeneration {
                statuses[send.id] = .overdue
                becameOverdue = becameOverdue || sendStatuses[send.id] != .overdue
            } else {
                statuses[send.id] = .abandoned
            }
        }
        if statuses != sendStatuses { sendStatuses = statuses }
        // The send that raised the concern was recorded here after all.
        if let concern = sessionConcern, statuses[concern.raisedBy] == .recorded { sessionConcern = nil }
        // Only an awaiting send's clock still decides anything, so spells
        // that ended before the oldest one was delivered go. Dropping
        // spells only moves a clock on, past a timeout it already reached.
        let oldestAwaiting = sends.compactMap { statuses[$0.id] == .awaiting ? $0.deliveredAt : nil }.min()
        busySpells.removeAll { spell in oldestAwaiting.map { spell.end <= $0 } ?? true }
        // The program may have forked into a session herdr has not
        // reported through the snapshot yet.
        if becameOverdue {
            needsAgentRefresh = true
            needsRelocate = true
            wake()
        }
    }

    /// Opens a busy spell when herdr reports the Agent Working or Blocked,
    /// and closes it when herdr reports anything else.
    private func noteActivity(_ activity: ChatAgentActivity) {
        let isBusy = activity == .working || activity == .blocked
        if isBusy, busySince == nil {
            busySince = now()
        } else if !isBusy, let start = busySince {
            busySpells.append((start: start, end: now()))
            busySince = nil
        }
    }

    /// How long `send` has waited for its record by `date`: the time since
    /// delivery or, for a program whose echo clock stops while it works
    /// (`ChatTranscriptAdapter.echoClockStopsWhileWorking`), only the part
    /// of it herdr reported the Agent neither Working nor Blocked.
    private func echoClock(for send: TrackedSend, at date: Date) -> TimeInterval {
        guard let deliveredAt = send.deliveredAt else { return 0 }
        let waited = date.timeIntervalSince(deliveredAt)
        guard source.adapter.echoClockStopsWhileWorking else { return waited }
        let spells = busySpells + (busySince.map { [(start: $0, end: date)] } ?? [])
        return spells.reduce(waited) { clock, spell in
            clock - max(0, min(spell.end, date).timeIntervalSince(max(spell.start, deliveredAt)))
        }
    }

    // MARK: Send witness

    /// Reads the size of the program's prompt log beside the followed
    /// transcript for a send that just showed, alongside the check before
    /// it goes and never awaited by it. The read makes no engine call.
    private func takeWitnessMark(for id: UUID) {
        guard let witness = source.adapter.sendWitness, case .following(let path) = conversation.phase else { return }
        witnesses[id] = WitnessState()
        let files = source.files
        let timeout = timing.witnessMarkTimeout
        witnessMarks[id] = Task { [weak self] in
            let mark = await Self.witnessRead(within: timeout) {
                try await witness.mark(forTranscript: path, files: files)
            } ?? nil
            // The check before the send may have dropped it meanwhile.
            guard let self, var state = self.witnesses[id], case .taking = state.mark else { return }
            state.mark = mark.map { .taken($0) } ?? .unavailable
            self.witnesses[id] = state
        }
    }

    /// Reads the Host for a witness within `timeout`, and never cancels
    /// the read: a cancelled SFTP request can leave its reply for the next
    /// request on the channel, so a read that outlives its deadline or its
    /// step runs on, and its answer is dropped. The transport's own request
    /// timeout still ends it.
    private static func witnessRead<Value: Sendable>(
        within timeout: Duration, _ read: @escaping @Sendable () async throws -> Value
    ) async -> Value? {
        let uncancelled = Task { try await read() }
        return try? await AsyncDeadline.run(for: timeout) { try await uncancelled.value }
    }

    /// A send went: a mark the check before it did not keep is dropped.
    private func witnessDelivery(of id: UUID) {
        guard var state = witnesses[id] else { return }
        state.deliveredWhileIdle = busySince == nil
        if case .sealed = state.mark {} else { state.mark = .unavailable }
        witnesses[id] = state
    }

    /// Reads what the program's prompt log gained since each unrecorded
    /// send's mark: once `Timing.witnessFirstRead` after a send delivered
    /// while the Agent was idle, which the program submitted at once, and
    /// once its echo clock reaches `Timing.echoTimeout`, by when a queued
    /// send's turn has run. A log that names one other session for the send
    /// makes it misdirected, and holds later sends until the terminal is
    /// back in this conversation. The lines are compared and dropped. A
    /// read counts once it returns, timed out or not: one a cancelled step
    /// cut short is the next step's to take.
    private func checkSendWitnesses() async {
        guard let witness = source.adapter.sendWitness, let sessionID = followed?.sessionID else { return }
        let date = now()
        var due: [(send: TrackedSend, mark: ChatSendWitnessMark, isLast: Bool)] = []
        for send in sends where send.generation == conversationGeneration {
            guard let deliveredAt = send.deliveredAt, let state = witnesses[send.id],
                case .sealed(let mark) = state.mark,
                sendStatuses[send.id] == .awaiting || sendStatuses[send.id] == .overdue
            else { continue }
            let isFirst =
                !state.firstReadDone && state.deliveredWhileIdle
                && date.timeIntervalSince(deliveredAt) >= timing.witnessFirstRead
            let isLast =
                !state.lastReadDone
                && (sendStatuses[send.id] == .overdue || echoClock(for: send, at: date) >= timing.echoTimeout)
            guard isFirst || isLast else { continue }
            due.append((send, mark, isLast))
        }
        guard !due.isEmpty else { return }
        let generation = conversationGeneration
        let files = source.files
        for (send, mark, isLast) in due {
            let appended = await Self.witnessRead(within: timing.witnessReadTimeout) {
                try await witness.appended(since: mark, files: files)
            } ?? nil
            guard !Task.isCancelled, generation == conversationGeneration else { return }
            witnesses[send.id]?.firstReadDone = true
            if isLast { witnesses[send.id]?.lastReadDone = true }
            guard let appended else { continue }
            switch witness.verdict(
                lines: appended.lines, key: send.key, sessionID: sessionID, isWholeAppend: appended.isWholeAppend,
                echoKey: source.adapter.echoKey)
            {
            case .here:
                // Later reads would find the same line.
                witnesses[send.id]?.lastReadDone = true
            case .elsewhere:
                misdirectedSends.insert(send.id)
                sessionConcern = ChatSessionConcern(
                    reason:
                        "Your last message went to another \(program.chatName) session. Switch back to this conversation in the terminal, so its newest message shows there, or send from the terminal; then send again here.",
                    raisedBy: send.id, promptFloor: conversation.readOffset, generation: generation)
            case .unknown:
                break
            }
        }
        matchSends()
    }

    /// Esc in Pi or Oh My Pi puts the steers its turn had not taken back
    /// into the input box, and the transcript never records them. Once the
    /// Agent has been idle a moment, the screen is read once for the sends
    /// from the turn that just ended that are still unrecorded, overdue or
    /// not (a Stop right after a steer ends the turn inside the echo
    /// timeout, and the user may add to the box before it runs out), and
    /// for the sends already found there, which the user may have sent or
    /// cleared in the terminal since. Only programs whose Stop is known to
    /// hand steers back opt in (`ChatProgram.stopReturnsUntakenSends`).
    private func checkReturnedSends() async {
        guard program.stopReturnsUntakenSends, let idleSince,
            now().timeIntervalSince(idleSince) >= timing.returnCheckDelay
        else { return }
        let candidates = sends.filter { send in
            guard !returnChecked.contains(send.id) else { return false }
            switch sendStatuses[send.id] {
            case .returned:
                return true
            case .overdue:
                guard let deliveredAt = send.deliveredAt, let turnStartedAt else { return false }
                return deliveredAt >= turnStartedAt
            case .awaiting:
                // A send still in time is read early only when it went in
                // while the turn ran; one made since is the next turn's.
                guard let deliveredAt = send.deliveredAt, let turnStartedAt else { return false }
                return deliveredAt >= turnStartedAt && deliveredAt <= idleSince
            default:
                return false
            }
        }
        guard !candidates.isEmpty else { return }
        let ids = Set(candidates.map(\.id))
        returnChecked.formUnion(ids)
        guard let screen = try? await source.screen.readScreen(), !Task.isCancelled,
            self.idleSince == idleSince
        else { return }
        observeInputBox(InputBoxStateDetector.detect(screen, program: program), for: ids)
    }

    /// Whether a `/compact` past its echo timeout still waits, in a program
    /// that declines one only on screen: until the screen has been read for
    /// it while the Agent is idle, or while the compaction last seen running
    /// there is recent.
    private func awaitsCompaction(_ send: TrackedSend, at date: Date) -> Bool {
        guard program.declinesCompactOnScreen, send.key == "/compact" else { return false }
        if let seen = compactingSeen[send.id] { return date.timeIntervalSince(seen) < timing.echoTimeout }
        return !compactChecked.contains(send.id) && ChatAgentActivity(agent.status) == .idle
    }

    /// Pi and Oh My Pi refuse a `/compact` with nothing to compact on
    /// screen ("Error: Compaction failed: Nothing to compact (session too
    /// small)") and record nothing, so its echo would stay overdue; Grok
    /// Build does the same for one Stop cancelled ("Compaction cancelled.").
    /// The
    /// Agent often never leaves idle for it, so the screen is read once for
    /// each `/compact` past its echo timeout while herdr reports the Agent
    /// idle, whenever it last turned so; the echo awaits that read. herdr
    /// stays idle through a compaction that runs too ("Compacting
    /// context...", 10 to 18 s for a small Pi session): a read that finds
    /// its spinner keeps the echo awaiting and the next step reads again,
    /// and once it is gone the echo waits the echo timeout from the last
    /// read that saw it, for the compaction's record.
    private func checkRefusedCompactions() async {
        guard program.declinesCompactOnScreen, ChatAgentActivity(agent.status) == .idle else { return }
        let date = now()
        let candidates = sends.filter { send in
            guard send.key == "/compact", !compactChecked.contains(send.id), let deliveredAt = send.deliveredAt,
                sendStatuses[send.id] == .awaiting || sendStatuses[send.id] == .overdue
            else { return false }
            return compactingSeen[send.id] != nil || date.timeIntervalSince(deliveredAt) >= timing.echoTimeout
        }
        guard !candidates.isEmpty else { return }
        let ids = Set(candidates.map(\.id))
        let screen = try? await source.screen.readScreen()
        guard !Task.isCancelled else { return }
        compactChecked.formUnion(ids)
        defer { matchSends() }
        guard let screen else { return }
        if screen.rows.contains(where: { Self.showsRunningCompaction($0.text) }) {
            compactChecked.subtract(ids)
            for id in ids { compactingSeen[id] = now() }
            return
        }
        guard let failure = Self.latestCompactionFailure(in: screen, program: program) else { return }
        let refusal =
            if failure.text.contains(Self.grokCompactionCancelled) {
                "The compaction was cancelled."
            } else if failure.text.contains("Nothing to compact") {
                "\(program.chatName) had nothing to compact."
            } else {
                "\(program.chatName) couldn't compact."
            }
        for send in candidates {
            refusedSends[send.id] = refusal
        }
    }

    /// Pi 0.85.1's and Oh My Pi 18.11's row while a compaction runs, Pi's
    /// countdown before it retries a failed summarization call ("Retrying
    /// (1/3) in 2s... (escape to cancel)"), or Grok Build 1.0.62's turn
    /// status row ("⠼ Compacting…  1.0s ⇣26.1k [stop]"). Grok's
    /// "Compacting conversation…" row stays after the compaction ends.
    private static func showsRunningCompaction(_ row: String) -> Bool {
        row.contains(compactingSpinner) || row.contains(grokCompactingStatus)
            || row.contains(/Retrying \(\d+\/\d+\) in \d+s\.\.\./)
    }

    private static let compactingSpinner = "Compacting context..."
    private static let grokCompactingStatus = "Compacting…"
    private static let grokCompactionCancelled = "Compaction cancelled."

    /// The last "Compaction failed:" row (Grok Build's "Compaction
    /// cancelled."), when nothing but blank rows, the message's own wrapped
    /// rows (drawn in its color: at the phone's 62 columns `small)` wraps),
    /// Oh My Pi's dim italic session title and Grok's scrollbar thumb
    /// separate it from the input box (Pi's rule, Oh My Pi's box or status
    /// band, Grok's box). One with conversation below it is an earlier
    /// attempt's.
    private static func latestCompactionFailure(in screen: ANSIScreen, program: ChatProgram) -> ScreenRow? {
        let rows = screen.rows
        let marker = program == .grok ? grokCompactionCancelled : "Compaction failed:"
        guard let index = rows.lastIndex(where: { $0.text.contains(marker) }) else { return nil }
        let color = rows[index].runs.first { $0.text.contains(marker) }?.style.foreground
        func drawn(_ row: ScreenRow, _ matches: (ScreenStyle) -> Bool) -> Bool {
            let runs = row.runs.filter { !$0.text.allSatisfy(\.isWhitespace) }
            return !runs.isEmpty && runs.allSatisfy { matches($0.style) }
        }
        let next = rows[(index + 1)...].first { row in
            !row.isBlank && !(color != nil && drawn(row) { $0.foreground == color })
                && !(program == .omp && drawn(row) { $0.isDim && $0.isItalic })
                && !(program == .grok && row.trimmedText.allSatisfy { $0 == "█" })
        }
        guard let next else { return rows[index] }
        let text = next.trimmedText
        let isInputBox =
            text.allSatisfy { $0 == "─" } || text.hasPrefix("╭")
            || (program == .omp && PiInputBoxDetector.isOMPStatusBand(next))
        return isInputBox ? rows[index] : nil
    }

    /// A read of the Agent's screen made for another reason, such as the
    /// check before a send: a returned send it no longer finds in the input
    /// box is discarded. It never finds new ones.
    func inputBoxWasRead(_ screen: ANSIScreen) {
        guard program.stopReturnsUntakenSends, !returnedSends.isEmpty else { return }
        observeInputBox(InputBoxStateDetector.detect(screen, program: program), for: returnedSends)
    }

    /// Settles which of `ids` the input box holds. Only an empty box or
    /// one showing text says so; any other state leaves them as they were.
    /// A returned send the box no longer holds left it undelivered, but
    /// text that shows one of them among more, such as one the user added
    /// to in the terminal, says nothing about which left.
    private func observeInputBox(_ state: InputBoxState, for ids: Set<UUID>) {
        let box: String
        switch state {
        case .text(let draft): box = draft
        case .empty: box = ""
        default: return
        }
        let held = Self.sends(in: box, among: sends.filter { ids.contains($0.id) })
        let returned = sends.filter { ids.contains($0.id) && returnedSends.contains($0.id) }
        let mentioned = Self.mentioned(in: box, among: returned)
        if held.isEmpty, !mentioned.isEmpty {
            extendedSends.formUnion(mentioned)
            return
        }
        let left = returnedSends.intersection(ids).subtracting(held)
        let next = returnedSends.subtracting(ids).union(held)
        guard next != returnedSends else { return }
        returnedSends = next
        discardedSends.formUnion(left)
        matchSends()
    }

    /// The sends, oldest first, whose texts make up all of `box`. Pi
    /// returns every queued steer at once, joined by blank lines in the
    /// order they were sent; the editor also wraps and trims what it shows,
    /// so spacing says nothing. Text the box holds beyond them, such as a
    /// draft, means none of them can be told apart from it.
    private static func sends(in box: String, among sends: [TrackedSend]) -> Set<UUID> {
        let target = squeezed(box)
        let texts = sends.map { squeezed($0.text) }
        guard !target.isEmpty else { return [] }
        var dead: Set<Int> = []
        // Indices of the sends that spell `target` from `start` on, using
        // only sends from `first` on.
        func spell(from start: Int, first: Int) -> [Int]? {
            if start == target.count { return [] }
            let key = start * (texts.count + 1) + first
            guard !dead.contains(key) else { return nil }
            for index in first..<texts.count where !texts[index].isEmpty {
                let end = start + texts[index].count
                guard end <= target.count, target[start..<end].elementsEqual(texts[index]),
                    let rest = spell(from: end, first: index + 1)
                else { continue }
                return [index] + rest
            }
            dead.insert(key)
            return nil
        }
        guard let indices = spell(from: 0, first: 0) else { return [] }
        return Set(indices.map { sends[$0].id })
    }

    /// Those of `sends` that show anywhere in `box`, spacing aside.
    private static func mentioned(in box: String, among sends: [TrackedSend]) -> Set<UUID> {
        let target = String(squeezed(box))
        return Set(
            sends.filter { send in
                let text = String(squeezed(send.text))
                return !text.isEmpty && target.contains(text)
            }.map(\.id))
    }

    /// `text` without its whitespace, which the editor's wrapping changes.
    private static func squeezed(_ text: String) -> [Character] { Array(text.filter { !$0.isWhitespace }) }
}

extension ChatAgentActivity {
    /// What herdr's Agent Status says about the Agent's turn.
    init(_ status: AgentStatus?) {
        guard let status else {
            self = .unknown
            return
        }
        switch status {
        case .idle, .done: self = .idle
        case .working: self = .working
        case .blocked: self = .blocked
        default: self = .unknown
        }
    }
}

extension ChatProgram {
    /// Whether Stop puts the steers its turn had not taken back into the
    /// input box, unrecorded (Pi's and Oh My Pi's Esc). Opting in reads
    /// the screen once the Agent idles, for the sends delivered while that
    /// turn ran, never the turn's opener.
    var stopReturnsUntakenSends: Bool {
        switch self {
        case .pi, .omp: true
        case .claude, .codex, .grok: false
        // OpenCode 2.0.32's Esc interrupt resumes: a steer still waiting
        // runs after the stop rather than coming back to the box.
        case .opencode: false
        }
    }

    /// Whether an accepted `/compact` is always recorded before the next
    /// prompt, so one a later prompt overtook with no compaction never ran
    /// (Pi 0.85.1, Oh My Pi 18.11, Grok Build 1.0.62, OpenCode 2.0.32, which
    /// records its compaction rows and then the turn's end).
    var recordsCompactionBeforeNextPrompt: Bool {
        switch self {
        case .pi, .omp, .grok, .opencode: true
        case .claude, .codex: false
        }
    }

    /// Whether a declined `/compact` shows only on screen, so an overdue
    /// one is looked for there while the Agent idles (Pi 0.85.1,
    /// Oh My Pi 18.11, and Grok Build 1.0.62 for one Stop cancelled).
    /// Opting in also needs the program's rows in
    /// `showsRunningCompaction` and `latestCompactionFailure`. OpenCode
    /// 2.0.32 records its refusal (`Nothing to compact yet`) as a failed
    /// compaction row, so that refusal does not show only on screen.
    var declinesCompactOnScreen: Bool {
        switch self {
        case .pi, .omp, .grok: true
        case .claude, .codex, .opencode: false
        }
    }

    /// Whether the Blocked card offers its key pad when herdr reports
    /// Blocked and the screen shows no dialog. OpenCode 2.0.32's prompt
    /// would act on those keys: Up recalls the last prompt for Enter to
    /// send again, Shift+Tab switches the agent, Down opens the subagent
    /// panel, and Enter on an empty box sends a queued prompt. Its card
    /// says why it is Blocked instead (`BlockedCardStore.unreadableNote`).
    var offersKeysWhenBlockedWithoutDialog: Bool {
        switch self {
        case .claude, .codex, .pi, .omp, .grok: true
        case .opencode: false
        }
    }

    /// Whether the program can leave its conversation without herdr
    /// reporting it, so Chat watches for its home screen while the Agent
    /// idles (`AgentChatStore.checkStartScreen`). OpenCode 2.0.32's `/new`
    /// opens its home screen, where herdr's integration reports nothing and
    /// herdr keeps the conversation it left (ADR 0025). Opting in needs the
    /// program's screen reader and terminal title in the watch.
    var leavesSessionWithoutReport: Bool {
        switch self {
        case .claude, .codex, .pi, .omp, .grok: false
        case .opencode: true
        }
    }

    /// Whether each send first checks that the program still shows the
    /// conversation Chat shows (`AgentChatStore.confirmSessionBeforeSend`),
    /// which a program that leaves it without a report may not. Opting in
    /// needs the program's terminal title in the check.
    var confirmsSessionBeforeSend: Bool {
        switch self {
        case .claude, .codex, .pi, .omp, .grok: false
        case .opencode: true
        }
    }

    /// Whether the program can run on a shared background server whose
    /// hooks report sessions for the wrong pane, which Chat reads from how
    /// it was launched (`AgentChatStore.checkLaunch`).
    var mayShareSessionServer: Bool {
        switch self {
        case .codex: true
        case .claude, .pi, .omp, .grok, .opencode: false
        }
    }
}
