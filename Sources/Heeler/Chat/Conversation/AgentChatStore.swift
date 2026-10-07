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
    /// session through no event, so Chat asks after status changes.
    let agentInfo: @Sendable () async throws -> Agent
    let cache: any ChatTranscriptCache
    let adapter: ChatTranscriptAdapter
    /// The Agent's pane, which a Blocked card reads and answers.
    var screen: BlockedScreenIO = .unavailable
}

/// One Agent's Chat (ADR 0020): the conversation herdr says the Agent is
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
        /// How long after a change, a send or a status change polling stays
        /// at the active interval.
        var activeLinger: TimeInterval = 15
        /// Waits before looking for a transcript again, one per failed look;
        /// the last repeats.
        var locateBackoff: [TimeInterval] = [2, 4, 8, 16, 30]
        /// How often the Agent's record is re-read while it reports no
        /// session Chat can follow.
        var sessionRecheck: TimeInterval = 5
        /// How long after delivery a sent prompt may stay unrecorded before
        /// its echo says so.
        var echoTimeout: TimeInterval = 10
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
        /// Still unrecorded `Timing.echoTimeout` after delivery.
        case overdue
        /// Unrecorded and no longer worth an echo: it went into an earlier
        /// conversation, or was sent before this store was watching.
        case abandoned
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

    @ObservationIgnored private let source: AgentChatSource
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var agent: Agent
    /// What herdr last said the Agent's session is.
    @ObservationIgnored private var resolution: ConversationReference.Resolution
    /// A session the transcript says the conversation continued in, until
    /// herdr reports a session of its own.
    @ObservationIgnored private var continuedSession: ConversationReference?
    @ObservationIgnored private var followed: ConversationReference?
    @ObservationIgnored private var engine: ChatConversationEngine?
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var appliedRevision: Int?
    @ObservationIgnored private var needsAgentRefresh = true
    @ObservationIgnored private var lastAgentRefresh: Date?
    @ObservationIgnored private var olderRequested = false
    @ObservationIgnored private var nextOpen: Date?
    @ObservationIgnored private var failedOpens = 0
    @ObservationIgnored private var lastActivity: Date?
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The last loop's end, saving included; a new loop waits for it.
    @ObservationIgnored private var finishing: Task<Void, Never>?
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    @ObservationIgnored private var wakeRequested = false
    /// The Chat views on screen; the conversation is followed while any is.
    @ObservationIgnored private var viewers: Set<UUID> = []
    @ObservationIgnored private var sends: [TrackedSend] = []
    /// Recorded prompts already taken by a send in the current
    /// conversation: one recorded copy answers one send.
    @ObservationIgnored private var claimedOffsets: Set<UInt64> = []
    @ObservationIgnored private var claimedGeneration = 0
    @ObservationIgnored private var skillNames: Set<String> = []
    /// Rows expanded before the transcript was open, read once it is.
    @ObservationIgnored private var waitingOutputs: Set<ChatEntryID> = []
    /// The latest read for each row, kept so tests can wait for them.
    @ObservationIgnored private var outputReads: [ChatEntryID: Task<Void, Never>] = [:]
    /// What each listed Workflow's journal showed, by the Workflow's id.
    @ObservationIgnored private var workflowProgress: [String: ChatWorkflowProgress] = [:]

    private struct TrackedSend {
        let id: UUID
        let key: String
        /// The conversation it went into, and how far that had been read:
        /// the program records the prompt at or after this offset.
        let generation: Int
        let floor: UInt64
        /// First seen already delivered, so its floor is unknown.
        let isOrphan: Bool
        var deliveredAt: Date?
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
        followReference()
    }

    // MARK: View lifecycle

    /// A Chat view is on screen: follow the conversation. Each view passes
    /// its own token, so one window leaving does not stop another's.
    func show(_ viewer: UUID = AgentChatStore.soleViewer) {
        viewers.insert(viewer)
        isVisible = true
        needsAgentRefresh = true
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

    // MARK: Requests

    /// Reads one page above the oldest message shown.
    func loadOlder() {
        guard conversation.older == .available || isFailedOlder,
            case .following = conversation.phase
        else { return }
        olderRequested = true
        conversation.older = .loading
        wake()
    }

    /// Reads a tool's output again for its expanded row, once the
    /// transcript is open. A read that failed is tried again. Reads run
    /// beside the loop: they change nothing it follows.
    func loadOutput(_ id: ChatEntryID) {
        guard case .tool(let tool)? = conversation.transcript.entries.last(where: { $0.id == id })?.content,
            let reference = tool.output, outputs.needsRead(id, at: reference)
        else { return }
        guard case .following = conversation.phase, let engine else {
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

    /// Resolves once every output read so far has finished, for tests.
    func outputReadsSettled() async {
        for read in outputReads.values {
            await read.value
        }
    }

    /// Looks for the transcript again now, after a failure or an
    /// unavailable state the user may have fixed.
    func retry() {
        needsAgentRefresh = true
        nextOpen = nil
        failedOpens = 0
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
        for message in messages {
            if let index = sends.firstIndex(where: { $0.id == message.id }) {
                guard message.isDelivered != (sends[index].deliveredAt != nil) else { continue }
                sends[index].deliveredAt = message.isDelivered ? now() : nil
                if message.isDelivered { noteSent() }
            } else {
                sends.append(
                    TrackedSend(
                        id: message.id, key: source.adapter.echoKey(message.text),
                        generation: conversationGeneration, floor: conversation.readOffset,
                        isOrphan: message.isDelivered, deliveredAt: message.isDelivered ? now() : nil))
            }
        }
        matchSends()
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
        agent = next
        if sessionChanged { adopt(ConversationReference.resolve(next.agentSession)) }
        guard statusChanged else { return }
        blocked.update(activity: ChatAgentActivity(next.status))
        // A turn starting or ending is when a session changes (`/clear`,
        // `/resume`) and when a missing transcript appears.
        lastActivity = now()
        needsAgentRefresh = true
        nextOpen = nil
        failedOpens = 0
        wake()
    }

    // MARK: Loop

    /// One turn of the loop: re-reads the Agent's record when due, then
    /// makes at most one read of the transcript, and after a poll that
    /// worked, a few reads of Workflow journals. Internal for tests, which
    /// drive turns directly.
    func step() async {
        if needsAgentRefresh || sessionRecheckIsDue { await refreshAgent() }
        guard let engine else {
            matchSends()
            refreshBackgroundWork()
            return
        }
        let context = projectionContext
        if !restored {
            restored = true
            apply(await engine.restore(), from: engine)
        }
        let snapshot: ChatConversationSnapshot
        var polled = false
        if olderRequested {
            olderRequested = false
            snapshot = await engine.loadOlder(context: context)
        } else if case .following = conversation.phase {
            snapshot = await engine.poll(context: context)
            polled = true
        } else if openIsDue {
            snapshot = await engine.open(directories: directories, context: context)
            scheduleNextOpen(after: snapshot)
        } else {
            snapshot = await engine.reproject(context: context)
        }
        apply(snapshot, from: engine)
        matchSends()
        // A journal read adds a deadline of its own, so a round whose
        // transcript read failed leaves the journals for later.
        if polled, case .following = snapshot.phase, snapshot.readFailure == nil {
            let progress = await engine.followWorkflows()
            if engine === self.engine { workflowProgress = progress }
        }
        refreshBackgroundWork()
        await engine.save()
    }

    private func startLoop() {
        guard isVisible, !isSuspended, loop == nil else { return }
        let previous = finishing
        loop = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled {
                guard let self else { return }
                await self.step()
                await self.pause(self.interval)
            }
        }
    }

    private func stopLoop() {
        guard let loop else { return }
        loop.cancel()
        sleeper?.cancel()
        self.loop = nil
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
    var interval: Duration {
        if engine == nil { return .seconds(timing.sessionRecheck) }
        if [.working, .blocked].contains(agent.status) { return timing.activeInterval }
        if let lastActivity, now().timeIntervalSince(lastActivity) < timing.activeLinger {
            return timing.activeInterval
        }
        // herdr can report the Agent idle while its program still runs
        // work in the background.
        if backgroundWork.holdsActivePace { return timing.activeInterval }
        return timing.idleInterval
    }

    // MARK: Session

    private var sessionRecheckIsDue: Bool {
        guard engine == nil || isUnavailable else { return false }
        guard let lastAgentRefresh else { return true }
        return now().timeIntervalSince(lastAgentRefresh) >= timing.sessionRecheck
    }

    private func refreshAgent() async {
        needsAgentRefresh = false
        lastAgentRefresh = now()
        // The Console's record keeps whatever its last snapshot said; herdr's
        // answer here is newer, and only a later change to that record
        // overrides it.
        guard let fresh = try? await source.agentInfo() else { return }
        adopt(ConversationReference.resolve(fresh.agentSession))
    }

    private func adopt(_ next: ConversationReference.Resolution) {
        guard next != resolution else { return }
        resolution = next
        continuedSession = nil
        followReference()
    }

    /// Points the engine at the conversation to follow, starting a new one
    /// when it changed.
    private func followReference() {
        var target: ConversationReference?
        if case .bound(let reference) = resolution, reference.program == program {
            target = continuedSession ?? reference
        }
        guard target != followed else {
            if target == nil { showUnavailable() }
            return
        }
        if let engine { Task { await engine.save(force: true) } }
        followed = target
        conversationGeneration += 1
        engine = target.map(makeEngine)
        restored = false
        appliedRevision = nil
        olderRequested = false
        nextOpen = nil
        failedOpens = 0
        // Reads still running for the last conversation drop their results.
        outputs = ChatToolOutputs()
        waitingOutputs = []
        workflowProgress = [:]
        backgroundWork = ChatBackgroundWork()
        if target == nil {
            showUnavailable()
        } else {
            conversation = ChatConversationSnapshot()
        }
    }

    private func showUnavailable() {
        let reason: ChatUnavailableReason =
            switch resolution {
            case .noSession: .noSession(program)
            case .unidentified: .unidentifiedSession
            case .unsupported, .bound: .unsupportedSession
            }
        var next = ChatConversationSnapshot()
        next.phase = .unavailable(reason)
        if conversation != next { conversation = next }
    }

    private func makeEngine(_ reference: ConversationReference) -> ChatConversationEngine {
        ChatConversationEngine(
            reference: reference,
            cacheKey: ChatCacheKey(
                hostID: source.hostID, socketLocation: source.socketLocation, reference: reference),
            files: source.files, cache: source.cache, adapter: source.adapter, now: now)
    }

    // MARK: Snapshots

    private func apply(_ snapshot: ChatConversationSnapshot, from origin: ChatConversationEngine) {
        // A session switch may have replaced the engine during the read.
        guard origin === engine, snapshot.revision != appliedRevision else { return }
        if snapshot.transcript.entries != conversation.transcript.entries { lastActivity = now() }
        appliedRevision = snapshot.revision
        var next = snapshot
        if olderRequested, next.older == .available { next.older = .loading }
        conversation = next
        blocked.update(transcript: next.transcript)
        if case .following = next.phase, !waitingOutputs.isEmpty {
            let waiting = waitingOutputs
            waitingOutputs = []
            for id in waiting {
                loadOutput(id)
            }
        }
        if let linked = snapshot.transcript.links.continuedInSessionID
            .flatMap(ConversationReference.canonicalUUID),
            linked != followed?.sessionID
        {
            continuedSession = ConversationReference(program: program, sessionID: linked)
            followReference()
        }
    }

    private var isUnavailable: Bool {
        if case .unavailable = conversation.phase { return true }
        return false
    }

    private func refreshBackgroundWork() {
        var isLive = conversation.readFailure == nil && !conversation.isFromCache
        if case .following = conversation.phase {} else { isLive = false }
        let next = ChatBackgroundWork(
            transcript: conversation.transcript, progress: workflowProgress, isLive: isLive, now: now(),
            staleness: timing.backgroundWorkStaleness)
        if next != backgroundWork { backgroundWork = next }
    }

    private var isFailedOlder: Bool {
        if case .failed = conversation.older { return true }
        return false
    }

    private var openIsDue: Bool {
        nextOpen.map { now() >= $0 } ?? true
    }

    private func scheduleNextOpen(after snapshot: ChatConversationSnapshot) {
        if case .following = snapshot.phase {
            nextOpen = nil
            failedOpens = 0
            return
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
    /// the current one. Conservative on purpose: a wrong match would hide a
    /// prompt that never arrived.
    private func matchSends() {
        if claimedGeneration != conversationGeneration {
            claimedGeneration = conversationGeneration
            claimedOffsets = []
        }
        let transcript = conversation.transcript
        let recorded = transcript.recordedPrompts.map { (offset: $0.offset, key: source.adapter.echoKey($0.text)) }
        // Codex records no prompt for `/compact`, only the compaction.
        let compactions = transcript.entries.compactMap { entry -> UInt64? in
            guard case .divider(let divider) = entry.content, divider.kind == .compaction else { return nil }
            return entry.sourceOffset
        }
        let date = now()
        var statuses: [UUID: SendStatus] = [:]
        var becameOverdue = false
        for send in sends {
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
            let floor = send.generation == conversationGeneration ? send.floor : 0
            var match = recorded.first {
                $0.offset >= floor && $0.key == send.key && !claimedOffsets.contains($0.offset)
            }?.offset
            if match == nil, send.key == "/compact" {
                match = compactions.first { $0 >= floor && !claimedOffsets.contains($0) }
            }
            if let match {
                claimedOffsets.insert(match)
                statuses[send.id] = .recorded
            } else if date.timeIntervalSince(deliveredAt) < timing.echoTimeout {
                statuses[send.id] = .awaiting
            } else if send.generation == conversationGeneration {
                statuses[send.id] = .overdue
                becameOverdue = becameOverdue || sendStatuses[send.id] != .overdue
            } else {
                statuses[send.id] = .abandoned
            }
        }
        if statuses != sendStatuses { sendStatuses = statuses }
        // The program may have forked into a session herdr has not
        // reported through the snapshot yet.
        if becameOverdue {
            needsAgentRefresh = true
            wake()
        }
    }
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
