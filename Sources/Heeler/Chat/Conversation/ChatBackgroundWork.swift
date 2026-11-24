import Foundation

/// What a Workflow's journal says about the agents it ran.
struct ChatWorkflowProgress: Equatable, Sendable {
    struct Agent: Identifiable, Equatable, Sendable {
        enum State: Equatable, Sendable {
            case running
            case done
            case failed
        }

        /// The program's key for the agent, kept when it runs again.
        let id: String
        var label: String?
        var phase: String?
        var state: State
    }

    var agents: [Agent] = []
    /// When the Host last wrote the journal, as of the last look, on its
    /// own clock.
    var updatedAt: Date?

    var done: Int { agents.count { $0.state == .done } }
    var failed: Int { agents.count { $0.state == .failed } }
    /// The agents started so far. A running Workflow may start more.
    var started: Int { agents.count }
}

/// Live Host signs of one Background Work item outside the main
/// transcript, such as Antigravity CLI's background-task strip, `/tasks`
/// panel, task log, subagent transcript, or Claude Code's workflow run file
/// and teammate transcripts.
struct ChatBackgroundWorkEvidence: Equatable, Sendable {
    /// When the Host last showed the work still running or writing.
    var lastSeenAt: Date?
    /// A terminal state observed on the Host before the main transcript
    /// recorded its end.
    var endedState: ChatBackgroundWorkItem.State?
    /// When the Host observed `endedState`.
    var endedAt: Date?
    /// `latestPromptOffset` when `endedState` was observed, so a subsequent
    /// user prompt clears evidence-retired work just like `endOffset`.
    var endPromptOffset: UInt64?
    /// When work that can run again, a teammate, started the turn it runs,
    /// as the Host shows: after the start or end the transcript records,
    /// it runs since then.
    var resumedAt: Date?

    /// Combines another live source's evidence with this one, keeping the
    /// newest activity timestamp and preserving an already-known terminal
    /// state unless only `other` has one.
    func merging(_ other: ChatBackgroundWorkEvidence) -> ChatBackgroundWorkEvidence {
        var merged = self
        merged.lastSeenAt = [lastSeenAt, other.lastSeenAt].compactMap(\.self).max()
        merged.resumedAt = [resumedAt, other.resumedAt].compactMap(\.self).max()
        if merged.endedState == nil, let otherEnded = other.endedState {
            merged.endedState = otherEnded
            merged.endedAt = other.endedAt
            merged.endPromptOffset = other.endPromptOffset
        }
        return merged
    }
}

/// The Background Work Chat lists above its Composer (ADR 0024): the
/// transcript's Subagents, teammates, Workflows and background commands, each Workflow
/// with its journal's progress, running work first. Built afresh after every
/// read and never saved, so nothing read from the device can claim to be
/// running.
struct ChatBackgroundWork: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        var item: ChatBackgroundWorkItem
        var progress: ChatWorkflowProgress?
        /// Running, with no sign of it for longer than such work runs: the
        /// program may have stopped it without saying.
        var isStale = false
        /// The newest sign of the work, on the Host's clock: its launch, a
        /// status check in the transcript, a Workflow's latest journal
        /// write, or live Host task/subagent evidence.
        var lastActivity: Date?

        var id: String { item.id }
        var isRunning: Bool { item.state == .running }
    }

    /// How long running work may show no sign of itself before its row
    /// stops claiming it runs.
    struct Staleness: Equatable, Sendable {
        /// A Workflow's journal gains a line as each of its agents starts
        /// or ends.
        var workflowQuiet: TimeInterval = 2 * 3_600
        /// A Subagent or background command records nothing until it ends
        /// unless a status tool checks on it.
        var subagentRun: TimeInterval = 3 * 3_600
        /// A teammate's own transcript gains a line with each step it
        /// takes. When the Host shows when it last did, a turn that wrote
        /// nothing for this long has stopped.
        var teammateQuiet: TimeInterval = 30 * 60
    }

    var rows: [Row] = []
    /// The rows come from a live read: the transcript is being followed,
    /// not shown from the device, and the last read worked.
    var isLive = false

    init() {}

    init(
        transcript: ChatTranscript, progress: [String: ChatWorkflowProgress],
        evidence: [String: ChatBackgroundWorkEvidence] = [:], isLive: Bool, now: Date,
        staleness: Staleness = Staleness()
    ) {
        self.isLive = isLive
        let prompt = transcript.latestPromptOffset ?? 0
        let listed = Set(transcript.listedBackgroundWork.map(\.id))
        let rows = transcript.backgroundWork.compactMap { rawItem -> Row? in
            var item = rawItem
            let itemEvidence = evidence[item.id]
            // The Host shows a turn that started after the latest one the
            // transcript records.
            if let resumedAt = itemEvidence?.resumedAt,
                resumedAt > (item.state == .running ? item.launchedAt : item.endedAt) ?? .distantPast
            {
                if item.state != .running {
                    item.state = .running
                    item.endOffset = nil
                    item.endedAt = nil
                    item.usage = nil
                }
                item.launchedAt = resumedAt
                if let last = item.lastActivityAt, last < resumedAt { item.lastActivityAt = nil }
            } else if !listed.contains(item.id) {
                return nil
            }
            if item.state == .running, let itemEvidence, let endedState = itemEvidence.endedState {
                // What a teammate wrote can reach the transcript after it
                // went idle.
                let latestStart =
                    item.kind == .teammate
                    ? item.launchedAt : [item.launchedAt, item.lastActivityAt].compactMap(\.self).max()
                let postdatesStart: Bool =
                    switch (latestStart, itemEvidence.endedAt) {
                    case (let start?, let endedAt?): endedAt >= start
                    default: true
                    }
                if postdatesStart {
                    if let endPrompt = itemEvidence.endPromptOffset,
                        prompt > endPrompt,
                        prompt > rawItem.launchOffset
                    {
                        return nil
                    }
                    item.state = endedState
                    item.endedAt = item.endedAt ?? itemEvidence.endedAt
                }
            }
            var row = Row(item: item, progress: progress[item.id])
            row.lastActivity = [
                item.launchedAt, item.lastActivityAt, row.progress?.updatedAt, itemEvidence?.lastSeenAt,
            ].compactMap(\.self).max()
            if item.state == .running, let lastActivity = row.lastActivity {
                let limit =
                    switch item.kind {
                    case .workflow: staleness.workflowQuiet
                    case .teammate where itemEvidence?.lastSeenAt != nil: staleness.teammateQuiet
                    default: staleness.subagentRun
                    }
                row.isStale = now.timeIntervalSince(lastActivity) > limit
            }
            return row
        }
        // Running first; each part keeps launch order, so rows never jump.
        self.rows = rows.filter(\.isRunning) + rows.filter { !$0.isRunning }
    }

    /// Whether any listed item has not reached a terminal state yet.
    var hasUnfinished: Bool {
        rows.contains(where: \.isRunning)
    }

    /// Whether finished Background Work stays visible in the floating strip
    /// over the Composer: while a live connected foreground turn is still
    /// running, so items finishing mid-turn stay visible until the turn
    /// concludes, then hiding once both the foreground turn and all
    /// Background Work have ended.
    func showsFinishedInStrip(
        agentStatus: AgentStatus, isHostConnected: Bool, turns: [ChatTurn]
    ) -> Bool {
        guard isHostConnected, isLive else { return false }
        switch agentStatus {
        case .working, .blocked:
            return true
        case .idle, .done, .error:
            return false
        default:
            return turns.last.map { $0.ending == nil } ?? false
        }
    }

    /// Whether a live read shows work running, which keeps Chat reading at
    /// its active pace.
    var holdsActivePace: Bool {
        isLive && rows.contains { $0.isRunning && !$0.isStale }
    }
}
