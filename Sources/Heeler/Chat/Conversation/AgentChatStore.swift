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
        followReference()
    }

    // MARK: View lifecycle

    /// Chat is on screen: follow the conversation.
    func show() {
        isVisible = true
        needsAgentRefresh = true
        startLoop()
    }

    /// Chat left the screen: stop reading, saving what showed.
    func hide() {
        isVisible = false
        stopLoop()
    }

    /// The app went to the background; Chat keeps its place.
    func suspend() {
        isSuspended = true
        stopLoop()
    }

    func resume() {
        isSuspended = false
        needsAgentRefresh = true
        startLoop()
    }

    /// The Agent or its Host is gone.
    func end() {
        isVisible = false
        stopLoop()
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

    /// The Console's latest record of the Agent, from a snapshot or a status
    /// change.
    func agentDidChange(_ next: Agent) {
        let statusChanged = next.status != agent.status
        let sessionChanged = next.agentSession != agent.agentSession
        agent = next
        if sessionChanged { adopt(ConversationReference.resolve(next.agentSession)) }
        guard statusChanged else { return }
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
    /// makes at most one read of the transcript. Internal for tests, which
    /// drive turns directly.
    func step() async {
        if needsAgentRefresh || sessionRecheckIsDue { await refreshAgent() }
        guard let engine else { return }
        let context = projectionContext
        if !restored {
            restored = true
            apply(await engine.restore(), from: engine)
        }
        let snapshot: ChatConversationSnapshot
        if olderRequested {
            olderRequested = false
            snapshot = await engine.loadOlder(context: context)
        } else if case .following = conversation.phase {
            snapshot = await engine.poll(context: context)
        } else if openIsDue {
            snapshot = await engine.open(directories: directories, context: context)
            scheduleNextOpen(after: snapshot)
        } else {
            snapshot = await engine.reproject(context: context)
        }
        apply(snapshot, from: engine)
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

    private var interval: Duration {
        if engine == nil { return .seconds(timing.sessionRecheck) }
        if [.working, .blocked].contains(agent.status) { return timing.activeInterval }
        if let lastActivity, now().timeIntervalSince(lastActivity) < timing.activeLinger {
            return timing.activeInterval
        }
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
        let activity: ChatAgentActivity =
            switch agent.status {
            case .idle, .done: .idle
            case .working: .working
            case .blocked: .blocked
            default: .unknown
            }
        return ChatProjectionContext(activity: activity)
    }
}
