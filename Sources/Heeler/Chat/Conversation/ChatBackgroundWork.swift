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

/// The Background Work Chat lists above its Composer (ADR 0020): the
/// transcript's Subagents and Workflows, each Workflow with its journal's
/// progress, running work first. Built afresh after every read and never
/// saved, so nothing read from the device can claim to be running.
struct ChatBackgroundWork: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        var item: ChatBackgroundWorkItem
        var progress: ChatWorkflowProgress?
        /// Running, with no sign of it for longer than such work runs: the
        /// program may have stopped it without saying.
        var isStale = false
        /// The newest sign of the work, on the Host's clock: its launch, or
        /// a Workflow's latest journal write.
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
        /// A Subagent records nothing until it ends.
        var subagentRun: TimeInterval = 3 * 3_600
    }

    var rows: [Row] = []
    /// The rows come from a live read: the transcript is being followed,
    /// not shown from the device, and the last read worked.
    var isLive = false

    init() {}

    init(
        transcript: ChatTranscript, progress: [String: ChatWorkflowProgress], isLive: Bool, now: Date,
        staleness: Staleness = Staleness()
    ) {
        self.isLive = isLive
        let rows = transcript.listedBackgroundWork.map { item in
            var row = Row(item: item, progress: progress[item.id])
            row.lastActivity = [item.launchedAt, row.progress?.updatedAt].compactMap(\.self).max()
            if item.state == .running, let lastActivity = row.lastActivity {
                let limit = item.kind == .workflow ? staleness.workflowQuiet : staleness.subagentRun
                row.isStale = now.timeIntervalSince(lastActivity) > limit
            }
            return row
        }
        // Running first; each part keeps launch order, so rows never jump.
        self.rows = rows.filter(\.isRunning) + rows.filter { !$0.isRunning }
    }

    /// Whether a live read shows work running, which keeps Chat reading at
    /// its active pace.
    var holdsActivePace: Bool {
        isLive && rows.contains { $0.isRunning && !$0.isStale }
    }
}
