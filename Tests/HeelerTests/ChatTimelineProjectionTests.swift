import Foundation
import Testing

@testable import Heeler

@Suite("Chat timeline projection")
struct ChatTimelineProjectionTests {
    private static let start = Date(timeIntervalSince1970: 1_791_266_142)
    private static let idle = ChatTurnSignals(activity: .idle)
    private static let working = ChatTurnSignals(activity: .working)

    // MARK: Builders

    private static func row(_ id: String, _ content: ChatRow.Content, revision: Int = 1) -> ChatRow {
        ChatRow(id: .entry(ChatEntryID(id)), content: content, revision: revision, topSpacing: 0)
    }

    private static func user(_ id: String, queued: Bool = false) -> ChatRow {
        row(id, .user(ChatUserMessage(text: id, wasQueued: queued)))
    }

    private static func text(_ id: String) -> ChatRow {
        row(id, .assistant(source: id, blocks: []))
    }

    private static func thought(_ id: String, _ text: String = "Considering") -> ChatRow {
        row(id, .reasoning(ChatReasoning(text: text)))
    }

    private static func tool(
        _ id: String, _ kind: ChatToolActivity.Kind = .command, name: String = "Bash", title: String? = nil,
        status: ChatToolActivity.Status = .succeeded, diff: ChatDiffStats? = nil, changes: ChatFileChanges? = nil
    ) -> ChatRow {
        var tool = ChatToolActivity(kind: kind, name: name, title: title ?? id, status: status, diff: diff)
        tool.fileChanges = changes
        return row(id, .tool(tool))
    }

    private static func notice(_ id: String, _ kind: ChatNotice.Kind) -> ChatRow {
        row(id, .notice(ChatNotice(kind: kind, title: id)))
    }

    private static func turn(
        _ first: String, ended: Bool = true, ending: ChatTurn.Ending = .completed, seconds: TimeInterval = 35
    ) -> ChatTurn {
        ChatTurn(
            firstEntryID: ChatEntryID(first), startedAt: start, endedAt: ended ? start + seconds : nil,
            ending: ended ? ending : nil)
    }

    private static func project(
        _ rows: [ChatRow], turns: [ChatTurn], precedingTurnEnd: ChatTurnEnd? = nil, signals: ChatTurnSignals = idle,
        open: Set<ChatRowID> = []
    ) -> ChatTimelineProjection.Output {
        ChatTimelineProjection.project(
            rows, turns: turns, precedingTurnEnd: precedingTurnEnd, signals: signals, open: open)
    }

    private static func ids(_ output: ChatTimelineProjection.Output) -> [String] {
        output.rows.map { row in
            switch row.id {
            case .entry(let id): row.isNested ? "  \(id.rawValue)" : id.rawValue
            case .pending: "pending"
            case .olderHistory: "older"
            case .liveTurn: "[working]"
            case .turn(let id): "[turn \(id.rawValue)]"
            case .group(let id): "[group \(id.rawValue)]"
            case .liveGroup(let id): "[live group \(id.rawValue)]"
            }
        }
    }

    private static func turnHeader(_ output: ChatTimelineProjection.Output, _ id: ChatRowID) -> ChatTurnHeader? {
        guard case .turnHeader(let header)? = output.rows.first(where: { $0.id == id })?.content else { return nil }
        return header
    }

    private static func group(_ output: ChatTimelineProjection.Output, _ id: ChatRowID) -> ChatToolGroup? {
        guard case .toolGroup(let group)? = output.rows.first(where: { $0.id == id })?.content else { return nil }
        return group
    }

    private static func entry(_ id: String) -> ChatRowID { .entry(ChatEntryID(id)) }

    /// A finished turn: prompt, narration, two commands, a plan, an edit,
    /// and a two-part answer.
    private static let finished: [ChatRow] = [
        user("u1"), text("n1"), tool("c1"), thought("r1"), tool("c2"),
        row("p1", .plan(ChatPlan(text: "Plan", status: .succeeded), blocks: [])),
        tool("e1", .fileEdit, name: "Edit"), text("a1"), text("a2"),
    ]

    // MARK: Turn folds

    @Test func aFinishedTurnFoldsItsStepsAboveItsAnswer() {
        let output = Self.project(Self.finished, turns: [Self.turn("u1")])

        #expect(Self.ids(output) == ["u1", "p1", "[turn a1]", "a1", "a2"])
        let header = Self.turnHeader(output, .turn(ChatEntryID("a1")))
        #expect(header == ChatTurnHeader(state: .worked(35), isOpen: false, stepCount: 5))
        for id in ["n1", "c1", "r1", "c2", "e1"] {
            #expect(output.owners[Self.entry(id)] == .turn(ChatEntryID("a1")))
        }
    }

    @Test func anOpenTurnShowsItsStepsWithTheirGroupsClosed() {
        let output = Self.project(Self.finished, turns: [Self.turn("u1")], open: [.turn(ChatEntryID("a1"))])

        #expect(Self.ids(output) == ["u1", "p1", "[turn a1]", "n1", "[group c2]", "e1", "a1", "a2"])
        #expect(Self.turnHeader(output, .turn(ChatEntryID("a1")))?.isOpen == true)
        #expect(output.rows.first { $0.id == Self.entry("n1") }?.isMuted == true)
        #expect(output.rows.first { $0.id == Self.entry("a1") }?.isMuted == false)
        #expect(output.owners[Self.entry("r1")] == .group(ChatEntryID("c2")))
        #expect(output.owners[Self.entry("n1")] == nil)
    }

    @Test func anOpenGroupInAnOpenTurnShowsItsCallsNested() {
        let output = Self.project(
            Self.finished, turns: [Self.turn("u1")], open: [.turn(ChatEntryID("a1")), .group(ChatEntryID("c2"))])

        #expect(Self.ids(output) == ["u1", "p1", "[turn a1]", "n1", "[group c2]", "  c1", "  r1", "  c2", "e1", "a1", "a2"])
        #expect(output.owners.isEmpty)
    }

    @Test func aTurnWithoutADurationReadsDetails() {
        let output = Self.project(Self.finished, turns: [ChatTurn(firstEntryID: ChatEntryID("u1"))])
        #expect(Self.turnHeader(output, .turn(ChatEntryID("a1")))?.state == .worked(nil))
    }

    @Test func turnsWithNothingToFoldOrNoAnswerStayOpen() {
        // Only an answer.
        #expect(Self.ids(Self.project([Self.user("u1"), Self.text("a1")], turns: [Self.turn("u1")])) == ["u1", "a1"])
        // No answer at the end.
        let toolLast = [Self.user("u1"), Self.text("n1"), Self.tool("c1")]
        #expect(Self.ids(Self.project(toolLast, turns: [Self.turn("u1")])) == ["u1", "n1", "c1"])
        // Only pinned rows before the answer.
        let pinned = [Self.user("u1"), Self.notice("t1", .taskNotification), Self.text("a1")]
        #expect(Self.ids(Self.project(pinned, turns: [Self.turn("u1")])) == ["u1", "t1", "a1"])
    }

    @Test(arguments: [ChatTurn.Ending.interrupted, .failed])
    func anInterruptedOrFailedTurnDoesNotFold(_ ending: ChatTurn.Ending) {
        let rows = [Self.user("u1"), Self.tool("c1"), Self.text("a1")]
        #expect(Self.ids(Self.project(rows, turns: [Self.turn("u1", ending: ending)])) == ["u1", "c1", "a1"])
    }

    @Test func pinnedRowsAfterTheAnswerStayAfterIt() {
        let rows = [
            Self.user("u1"), Self.tool("c1"), Self.text("a1"), Self.notice("x1", .interrupted),
            Self.tool("s1", .agent, name: "Agent"),
        ]
        #expect(
            Self.ids(Self.project(rows, turns: [Self.turn("u1")])) == ["u1", "[turn a1]", "a1", "x1", "s1"])
    }

    @Test func foldingCanBeTurnedOff() {
        var signals = Self.idle
        signals.foldsFinishedTurns = false
        let output = Self.project(Self.finished, turns: [Self.turn("u1")], signals: signals)
        // Groups still form.
        #expect(Self.ids(output) == ["u1", "n1", "[group c2]", "p1", "e1", "a1", "a2"])
    }

    @Test func everyEarlierTurnIsFinished() {
        let rows = [Self.user("u1"), Self.tool("c1"), Self.text("a1"), Self.user("u2"), Self.tool("c2")]
        let output = Self.project(rows, turns: [Self.turn("u1", ended: false), Self.turn("u2", ended: false)], signals: Self.working)
        #expect(Self.ids(output) == ["u1", "[turn a1]", "a1", "u2", "[working]", "c2"])
    }

    // MARK: The newest turn

    @Test func aRunningTurnShowsHowLongItHasWorked() {
        let rows = [Self.user("u1"), Self.text("n1"), Self.tool("c1"), Self.text("a1")]
        let output = Self.project(rows, turns: [Self.turn("u1", ended: false)], signals: Self.working)
        #expect(Self.ids(output) == ["u1", "[working]", "n1", "c1", "a1"])
        #expect(Self.turnHeader(output, .liveTurn)?.state == .working(since: Self.start))
        #expect(output.rows.first { $0.id == .liveTurn }?.isExpandable == false)
    }

    @Test func aRunningTurnWithNoKnownStartHasNoHeader() {
        let rows = [Self.user("u1"), Self.tool("c1"), Self.text("a1")]
        let output = Self.project(rows, turns: [ChatTurn(firstEntryID: ChatEntryID("u1"))], signals: Self.working)
        #expect(Self.ids(output) == ["u1", "c1", "a1"])
    }

    @Test(arguments: [ChatAgentActivity.working, .blocked, .unknown])
    func aTurnNoRecordClosedRunsUnlessTheAgentIsIdle(_ activity: ChatAgentActivity) {
        let rows = [Self.user("u1"), Self.tool("c1"), Self.text("a1")]
        let open = Self.project(rows, turns: [Self.turn("u1", ended: false)], signals: ChatTurnSignals(activity: activity))
        #expect(Self.ids(open) == ["u1", "[working]", "c1", "a1"])
        let idle = Self.project(rows, turns: [Self.turn("u1", ended: false)], signals: Self.idle)
        #expect(Self.ids(idle) == ["u1", "[turn a1]", "a1"])
    }

    /// A new Claude Code conversation opens with the `/clear` that made it,
    /// a turn no `turn_duration` closes. With no status from the Agent it
    /// doesn't count as work; a reported status still decides.
    @Test func aCommandOnlyTurnDoesNotRunWhileTheAgentReportsNoState() {
        let rows = [Self.notice("clear", .command)]
        let turns = [Self.turn("clear", ended: false)]
        let unknown = Self.project(rows, turns: turns, signals: ChatTurnSignals(activity: .unknown))
        #expect(Self.ids(unknown) == ["clear"])
        let working = Self.project(rows, turns: turns, signals: ChatTurnSignals(activity: .working))
        #expect(Self.ids(working) == ["clear", "[working]"])
        let prompted = Self.project(
            rows + [Self.user("u1")], turns: turns + [Self.turn("u1", ended: false)],
            signals: ChatTurnSignals(activity: .unknown))
        #expect(Self.ids(prompted) == ["clear", "u1", "[working]"])
    }

    /// Saved rows read as last seen while nothing live backs them: an open
    /// turn the Agent's unknown state can't close settles instead of
    /// counting minutes from stale rows (SND-12).
    @Test(arguments: [ChatAgentActivity.working, .blocked, .unknown])
    func anOpenTurnDoesNotRunWithoutALiveHost(_ activity: ChatAgentActivity) {
        let rows = [Self.user("u1"), Self.tool("c1"), Self.text("a1")]
        let signals = ChatTurnSignals(activity: activity, isLive: false)
        #expect(ChatTimelineProjection.newestPhase(ending: nil, signals: signals) == .settled)
        let output = Self.project(rows, turns: [Self.turn("u1", ended: false)], signals: signals)
        #expect(Self.ids(output) == ["u1", "[turn a1]", "a1"])
        var held = signals
        held.isBackgroundWorkRunning = true
        #expect(ChatTimelineProjection.newestPhase(ending: nil, signals: held) == .held)
    }

    /// Rows are live only from a connected Host and a conversation read on
    /// this visit; a failed read alone keeps them live.
    @Test(arguments: [
        (EventsSessionStatus?.some(.connected), false, false, true),
        (.connected, false, true, true),
        (.connected, true, false, false),
        (.connecting, false, false, false),
        (.reconnecting(attempt: 1, delay: .seconds(1), failure: .channelFailed(detail: "x")), false, false, false),
        (.suspended, false, false, false),
        (nil, false, false, false),
    ])
    func rowsAreLiveOnlyFromAConnectedHostAndAFreshRead(
        status: EventsSessionStatus?, isFromCache: Bool, readFailed: Bool, isLive: Bool
    ) {
        var conversation = ChatConversationSnapshot()
        conversation.isFromCache = isFromCache
        conversation.readFailure = readFailed ? .channelFailed(detail: "read") : nil
        #expect(ChatTurnSignals.isLive(hostStatus: status, conversation: conversation) == isLive)
    }

    /// A running call as last seen stops claiming to run, in its own row
    /// and in its group's header, and draws again as it changes.
    @Test func runningCallsAreLastSeenWithoutALiveHost() throws {
        let rows = [
            Self.user("u1"), Self.tool("c1"), Self.tool("c2", status: .running),
            Self.tool("t1", .agent, name: "Agent", status: .running),
        ]
        let open: Set<ChatRowID> = [.group(ChatEntryID("c2"))]
        let live = Self.project(rows, turns: [Self.turn("u1", ended: false)], signals: Self.working, open: open)
        #expect(Self.activityTool(live, "t1")?.isNotUpdating == false)
        let saved = Self.project(
            rows, turns: [Self.turn("u1", ended: false)], signals: ChatTurnSignals(activity: .working, isLive: false),
            open: open)
        #expect(Self.ids(saved) == ["u1", "[group c2]", "  c1", "  c2", "t1"])
        #expect(Self.activityTool(saved, "c1")?.isNotUpdating == false)
        #expect(Self.activityTool(saved, "c2")?.isNotUpdating == true)
        #expect(Self.activityTool(saved, "t1")?.isNotUpdating == true)
        #expect(Self.group(saved, .group(ChatEntryID("c2")))?.isRunning == false)
        let revision = { (output: ChatTimelineProjection.Output, id: String) in
            output.rows.first { $0.id == Self.entry(id) }?.revision
        }
        #expect(revision(saved, "c1") == 1)
        #expect(revision(saved, "c2") != 1)
    }

    @Test func aClosedTurnStaysFinishedWhileTheNextOneIsNotRecordedYet() {
        let rows = [Self.user("u1"), Self.tool("c1"), Self.text("a1")]
        #expect(Self.ids(Self.project(rows, turns: [Self.turn("u1")], signals: Self.working)) == ["u1", "[turn a1]", "a1"])
    }

    @Test func runningBackgroundWorkKeepsTheNewestTurnOpen() {
        let rows = [Self.user("u1"), Self.tool("c1"), Self.tool("c2"), Self.text("a1")]
        let signals = ChatTurnSignals(activity: .idle, isBackgroundWorkRunning: true)
        let output = Self.project(rows, turns: [Self.turn("u1")], signals: signals)
        // No timer: the turn itself is done.
        #expect(Self.ids(output) == ["u1", "[group c2]", "a1"])
    }

    @Test func aPendingMessageLeavesTheRunningTurnRunning() {
        let pending = ChatRow(
            id: .pending(UUID()), content: .pending(ChatPendingEcho(id: UUID(), text: "next", state: .sending)),
            revision: 1, topSpacing: 0)
        let rows = [Self.user("u1"), Self.tool("c1"), Self.tool("c2"), Self.tool("c3", status: .running), pending]
        let output = Self.project(rows, turns: [Self.turn("u1", ended: false)], signals: Self.working)
        // The program may hold the message until the turn ends: the turn's
        // timer and its live group stay as they were.
        #expect(Self.ids(output) == ["u1", "[working]", "[live group c1]", "c3", "pending"])

        let finished = [Self.user("u1"), Self.tool("c1"), Self.text("a1"), pending]
        #expect(Self.ids(Self.project(finished, turns: [Self.turn("u1")], signals: Self.working)) == ["u1", "[turn a1]", "a1", "pending"])
    }

    @Test func aQuestionStaysAboveTheFoldOfItsTurn() {
        let rows = [
            Self.user("u1"), Self.tool("c1"), Self.tool("q1", .question, name: "AskUserQuestion"), Self.tool("c2"), Self.text("a1"),
        ]
        #expect(Self.ids(Self.project(rows, turns: [Self.turn("u1")])) == ["u1", "q1", "[turn a1]", "a1"])
    }

    @Test func withoutRecordedTurnsAPromptOpensOne() {
        let rows = [
            Self.user("u1"), Self.tool("c1"), Self.text("a1"), Self.user("q1", queued: true), Self.text("a2"),
            Self.user("u2"), Self.tool("c2"), Self.text("a3"),
        ]
        let output = Self.project(rows, turns: [], signals: Self.working)
        #expect(Self.ids(output) == ["u1", "q1", "[turn a2]", "a2", "u2", "c2", "a3"])
    }

    @Test func rowsAboveTheFirstLoadedTurnFoldOnceNothingOlderRemains() {
        func rows(_ older: ChatOlderHistory) -> [ChatRow] {
            let row = ChatRow(id: .olderHistory, content: .olderHistory(older), revision: 1, topSpacing: 0)
            return [row, Self.tool("c0"), Self.tool("c1"), Self.text("a0"), Self.user("u1"), Self.text("a1")]
        }
        let ended = Self.project(rows(.reachedStart), turns: [Self.turn("u1")])
        #expect(Self.ids(ended) == ["older", "[turn a0]", "a0", "u1", "a1"])
        #expect(Self.turnHeader(ended, .turn(ChatEntryID("a0")))?.state == .worked(nil))

        // While its start is still to load, what loads shows.
        for older in [ChatOlderHistory.available, .loading, .failed("x")] {
            let partial = Self.project(rows(older), turns: [Self.turn("u1")])
            #expect(Self.ids(partial) == ["older", "[group c1]", "a0", "u1", "a1"])
        }
    }

    /// Once earlier messages wait for the user, the rows above the first
    /// loaded turn read as a finished turn while the user's own requests
    /// load or fail: folded behind a header with the time the record that
    /// ends the turn gives, or Details without one. An interrupted one
    /// stays open, as a loaded one does.
    @Test func rowsAboveTheFirstLoadedTurnFoldOnceEarlierMessagesWaitForTheUser() {
        func rows(_ older: ChatOlderHistory) -> [ChatRow] {
            let row = ChatRow(id: .olderHistory, content: .olderHistory(older), revision: 1, topSpacing: 0)
            return [row, Self.tool("c0"), Self.tool("c1"), Self.text("a0"), Self.user("u1"), Self.text("a1")]
        }
        let waiting = ChatTurnSignals(activity: .idle, olderAwaitsUser: true)
        let end = ChatTurnEnd(ending: .completed, endedAt: Self.start, duration: 136.363)
        let header = ChatRowID.turn(ChatEntryID("a0"))
        for older in [ChatOlderHistory.available, .loading, .failed("x")] {
            let timed = Self.project(rows(older), turns: [Self.turn("u1")], precedingTurnEnd: end, signals: waiting)
            #expect(Self.ids(timed) == ["older", "[turn a0]", "a0", "u1", "a1"])
            #expect(Self.turnHeader(timed, header)?.state == .worked(136.363))
        }
        let untimed = Self.project(rows(.available), turns: [Self.turn("u1")], signals: waiting)
        #expect(Self.ids(untimed) == ["older", "[turn a0]", "a0", "u1", "a1"])
        #expect(Self.turnHeader(untimed, header)?.state == .worked(nil))

        let interrupted = ChatTurnEnd(ending: .interrupted, endedAt: Self.start)
        let stopped = Self.project(
            rows(.available), turns: [Self.turn("u1")], precedingTurnEnd: interrupted, signals: waiting)
        #expect(Self.ids(stopped) == ["older", "[group c1]", "a0", "u1", "a1"])
    }

    /// The record that ends the turn above the loaded rows closes it as a
    /// turn's own record does: while the Agent works on a turn the rows do
    /// not show yet, it stays finished. Without one, it runs.
    @Test func theRecordThatEndsTheTurnAboveTheLoadedRowsClosesIt() {
        let older = ChatRow(id: .olderHistory, content: .olderHistory(.available), revision: 1, topSpacing: 0)
        let rows = [older, Self.tool("c0"), Self.tool("c1"), Self.text("a0")]
        let waiting = ChatTurnSignals(activity: .working, olderAwaitsUser: true)

        let ended = Self.project(rows, turns: [], precedingTurnEnd: ChatTurnEnd(ending: .completed), signals: waiting)
        #expect(Self.ids(ended) == ["older", "[turn a0]", "a0"])
        let running = Self.project(rows, turns: [], signals: waiting)
        #expect(Self.ids(running) == ["older", "[group c1]", "a0"])
    }

    /// Until earlier messages wait for the user, which only Grok Build's
    /// can, the record that ends the turn above the loaded rows changes
    /// nothing: they show as they load, and with the file's start loaded
    /// they fold as before.
    @Test func rowsAboveTheFirstLoadedTurnIgnoreTheirEndUntilEarlierMessagesWait() {
        let older = ChatRow(id: .olderHistory, content: .olderHistory(.available), revision: 1, topSpacing: 0)
        let loading = [older, Self.tool("c0"), Self.tool("c1")]
        let ended = Self.project(
            loading, turns: [], precedingTurnEnd: ChatTurnEnd(ending: .completed), signals: Self.working)
        #expect(Self.ids(ended) == Self.ids(Self.project(loading, turns: [], signals: Self.working)))

        let loaded = [Self.tool("c0"), Self.tool("c1"), Self.text("a0")]
        let interrupted = Self.project(loaded, turns: [], precedingTurnEnd: ChatTurnEnd(ending: .interrupted))
        #expect(Self.ids(interrupted) == Self.ids(Self.project(loaded, turns: [])))
    }

    @Test func aTurnOpenedByARowThatIsNotAPromptStillFolds() {
        let rows = [Self.text("n1"), Self.tool("c1"), Self.text("a1")]
        #expect(Self.ids(Self.project(rows, turns: [Self.turn("n1")])) == ["[turn a1]", "a1"])
    }

    // MARK: Groups

    @Test func oneCallIsNoGroupEvenWithManyFiles() {
        let changes = ChatFileChanges(
            files: ["a.swift", "b.swift", "c.swift"].map { ChatFileChange(path: $0, kind: .updated, added: 1, removed: 0, lineCount: 1) })
        let rows = [Self.user("u1"), Self.tool("e1", .fileEdit, name: "Edit", changes: changes), Self.text("n1")]
        #expect(Self.ids(Self.project(rows, turns: [Self.turn("u1", ended: false)], signals: Self.working)) == ["u1", "[working]", "e1", "n1"])
    }

    @Test func reasoningJoinsARunAndBlankReasoningShowsNowhere() {
        let rows = [
            Self.user("u1"), Self.thought("r0"), Self.tool("c1"), Self.thought("r1"), Self.thought("b1", ""),
            Self.tool("c2"), Self.thought("r2"), Self.thought("b2", ""), Self.text("n1"),
        ]
        let output = Self.project(rows, turns: [Self.turn("u1", ended: false)], signals: Self.working, open: [.group(ChatEntryID("c2"))])
        #expect(Self.ids(output) == ["u1", "[working]", "r0", "[group c2]", "  c1", "  r1", "  c2", "r2", "n1"])
        #expect(Self.group(output, .group(ChatEntryID("c2")))?.calls == 2)
    }

    @Test func runsBreakAtEverythingButReasoning() {
        var image = ChatToolActivity(kind: .fileRead, name: "Read", title: "shot.png", status: .succeeded)
        image.imagePath = "/tmp/shot.png"
        let breakers: [ChatRow] = [
            Self.text("x"), Self.notice("x", .system), Self.row("x", .divider(ChatDivider(kind: .compaction))),
            Self.user("x", queued: true), Self.tool("x", .agent, name: "Agent"), Self.tool("x", .question, name: "AskUserQuestion"),
            Self.tool("x", status: .awaitingApproval), Self.tool("x", name: "user_shell"),
            // Its image shows on the row, never folded into a group.
            Self.row("x", .tool(image)),
        ]
        for breaker in breakers {
            let rows = [Self.user("u1"), Self.tool("c1"), breaker, Self.tool("c2"), Self.text("n1")]
            let output = Self.project(rows, turns: [Self.turn("u1", ended: false)], signals: Self.working)
            #expect(!output.rows.contains { $0.id.isHeader && $0.id != .liveTurn }, "\(breaker.content)")
        }
    }

    @Test func aRunningRunKeepsItsNewestCallAsItsOwnRow() {
        let rows = [Self.user("u1"), Self.tool("c1"), Self.tool("c2"), Self.tool("c3", status: .running), Self.thought("r1")]
        let output = Self.project(rows, turns: [Self.turn("u1", ended: false)], signals: Self.working)
        #expect(Self.ids(output) == ["u1", "[working]", "[live group c1]", "c3", "r1"])
        #expect(Self.group(output, .liveGroup(ChatEntryID("c1")))?.summary == "Ran 2 commands")

        // Settled once something follows it, under another id.
        let later = rows + [Self.text("n1")]
        let settled = Self.project(later, turns: [Self.turn("u1", ended: false)], signals: Self.working)
        #expect(Self.ids(settled) == ["u1", "[working]", "[group c3]", "r1", "n1"])
        #expect(Self.group(settled, .group(ChatEntryID("c3")))?.isRunning == true)
    }

    @Test func aRunKeepsItsLiveGroupWhileItsNewestCallWaitsForApproval() {
        let rows = [Self.user("u1"), Self.tool("c1"), Self.tool("c2"), Self.tool("c3", status: .running)]
        let running = Self.project(rows, turns: [Self.turn("u1", ended: false)], signals: Self.working)
        #expect(Self.ids(running) == ["u1", "[working]", "[live group c1]", "c3"])

        let asking = rows.dropLast() + [Self.tool("c3"), Self.thought("r1"), Self.tool("c4", status: .awaitingApproval)]
        let waiting = Self.project(Array(asking), turns: [Self.turn("u1", ended: false)], signals: Self.working)
        #expect(Self.ids(waiting) == ["u1", "[working]", "[live group c1]", "r1", "c4"])
        #expect(Self.group(waiting, .liveGroup(ChatEntryID("c1")))?.summary == "Ran 3 commands")
    }

    @Test func aGroupHeaderSumsItsDiffsAndCountsFailures() {
        let rows = [
            Self.user("u1"), Self.tool("e1", .fileEdit, name: "Edit", diff: ChatDiffStats(added: 3, removed: 1)),
            Self.tool("e2", .fileEdit, name: "Edit", status: .failed, diff: ChatDiffStats(added: 2, removed: 4)),
            Self.tool("c1", status: .declined), Self.text("n1"),
        ]
        let group = Self.group(
            Self.project(rows, turns: [Self.turn("u1", ended: false)], signals: Self.working), .group(ChatEntryID("c1")))
        #expect(group?.added == 5)
        #expect(group?.removed == 5)
        #expect(group?.failed == 2)
        #expect(group?.kind == .fileEdit)
        #expect(group?.summary == "Ran 1 command, Edited 2 files")
    }

    @Test func summariesNameWhatTheCallsDid() {
        func tool(_ kind: ChatToolActivity.Kind, _ name: String = "T", title: String = "t") -> ChatToolActivity {
            ChatToolActivity(kind: kind, name: name, title: title, status: .succeeded)
        }
        let summary = ChatTimelineProjection.summary(of:)
        #expect(summary([tool(.command), tool(.command)]) == "Ran 2 commands")
        #expect(summary([tool(.fileRead, title: "a"), tool(.fileRead, title: "a"), tool(.fileRead, title: "b")]) == "Read 2 files")
        #expect(summary([tool(.fileWrite, title: "a")]) == "Created 1 file")
        #expect(summary([tool(.search), tool(.search)]) == "Ran 2 searches")
        #expect(summary([tool(.command), tool(.listing)]) == "Ran 1 command, Listed 1 folder")
        #expect(summary([tool(.search), tool(.listing), tool(.listing)]) == "Ran 1 search, Listed 2 folders")
        #expect(summary([tool(.web, "WebSearch"), tool(.web, "WebFetch"), tool(.web, "WebFetch")]) == "Searched the web once, Fetched 2 pages")
        #expect(summary([tool(.web, "browse"), tool(.web, "browse")]) == "Used the web 2 times")
        #expect(summary([tool(.mcp), tool(.image), tool(.todo), tool(.todo)]) == "Called 1 tool, 1 image, Updated the to-do list")
        #expect(summary([tool(.command), tool(.image), tool(.image)]) == "Ran 1 command, 2 images")
        #expect(summary([tool(.other), tool(.other)]) == "Used 2 tools")
        #expect(summary([tool(.command), tool(.other)]) == "Ran 1 command, 1 other tool")

        var edit = tool(.fileEdit)
        edit.fileChanges = ChatFileChanges(
            files: ["a", "b"].map { ChatFileChange(path: $0, kind: .updated, added: 1, removed: 0, lineCount: 1) }, moreFiles: 3)
        var again = tool(.fileEdit)
        again.fileChanges = ChatFileChanges(files: [ChatFileChange(path: "a", kind: .updated, added: 1, removed: 0, lineCount: 1)])
        #expect(summary([edit, again]) == "Edited 5 files")

        var created = tool(.fileWrite)
        created.fileChanges = ChatFileChanges(files: [ChatFileChange(path: "new", kind: .created, added: 1, removed: 0, lineCount: 1)])
        var overwritten = tool(.fileWrite)
        overwritten.fileChanges = ChatFileChanges(files: [ChatFileChange(path: "old", kind: .updated, added: 1, removed: 1, lineCount: 1)])
        #expect(summary([created, overwritten]) == "Edited 1 file, Created 1 file")

        // A write that can't tell a new file from an old one wrote it.
        var written = tool(.fileWrite)
        written.fileChanges = ChatFileChanges(files: [ChatFileChange(path: "todo.txt", kind: .written, added: 1, removed: 0, lineCount: 1)])
        #expect(summary([written]) == "Wrote 1 file")
        #expect(summary([overwritten, created, written]) == "Edited 1 file, Created 1 file, Wrote 1 file")

        // A failed edit has only its title, relative to where it ran; the
        // retry that worked records the full path. They are one file.
        let failed = tool(.fileEdit, title: "c.txt")
        var retried = tool(.fileEdit, title: "c.txt")
        retried.fileChanges = ChatFileChanges(
            files: [ChatFileChange(path: "/private/tmp/p/c.txt", kind: .updated, added: 1, removed: 1, lineCount: 1)],
            directory: "/tmp/p")
        #expect(summary([failed, retried]) == "Edited 1 file")

        // A Codex patch row has no per-file list: its title names every
        // file it touched, and its line counts say how many there were.
        var patch = tool(.fileEdit, title: "new.txt, notes.txt")
        patch.diff = ChatDiffStats(added: 2, removed: 1, files: 2)
        #expect(summary([patch]) == "Edited 2 files")
        #expect(summary([patch, patch]) == "Edited 2 files")
        var adds = tool(.fileWrite, title: "a.txt, b.txt")
        adds.diff = ChatDiffStats(added: 2, removed: 0, files: 2)
        #expect(summary([adds, patch]) == "Edited 2 files, Created 2 files")
    }

    /// A file a turn changes more than once is one changed file, under
    /// what the first change did; reading it stays a read of its own.
    @Test func aFileChangedTwiceCountsOnceUnderItsFirstChange() {
        func change(_ kind: ChatToolActivity.Kind, _ path: String, _ change: ChatFileChange.Kind) -> ChatToolActivity {
            var tool = ChatToolActivity(kind: kind, name: "T", title: path, status: .succeeded)
            tool.fileChanges = ChatFileChanges(
                files: [ChatFileChange(path: path, kind: change, added: 1, removed: 0, lineCount: 1)])
            return tool
        }
        let summary = ChatTimelineProjection.summary(of:)
        let create = change(.fileWrite, "v4.txt", .created)
        let edit = change(.fileEdit, "v4.txt", .updated)
        let other = change(.fileEdit, "w.txt", .updated)
        #expect(summary([create, edit]) == "Created 1 file")
        #expect(summary([edit, create]) == "Edited 1 file")
        #expect(summary([create, edit, other]) == "Edited 1 file, Created 1 file")
        #expect(summary([change(.fileWrite, "v4.txt", .written), edit]) == "Wrote 1 file")
        let read = ChatToolActivity(kind: .fileRead, name: "Read", title: "v4.txt", status: .succeeded)
        #expect(summary([read, edit]) == "Edited 1 file, Read 1 file")

        // Codex patch rows count by their titles the same way.
        var adds = ChatToolActivity(kind: .fileWrite, name: "T", title: "a.txt, b.txt", status: .succeeded)
        adds.diff = ChatDiffStats(added: 2, removed: 0, files: 2)
        var patch = ChatToolActivity(kind: .fileEdit, name: "T", title: "a.txt, b.txt", status: .succeeded)
        patch.diff = ChatDiffStats(added: 1, removed: 1, files: 2)
        #expect(summary([adds, patch]) == "Created 2 files")
    }

    // MARK: Subagents

    private static func subagent(_ id: String, path: String?, event: String) -> ChatRow {
        let status: ChatToolActivity.Status = event == "completed" ? .succeeded : .noResult
        return row(id, .tool(ChatToolActivity(
            kind: .agent, name: "SubAgentActivity", title: "Subagent: task", status: status,
            subagentActivity: ChatSubagentActivity(agentPath: path, events: [event]))))
    }

    private static func activityTool(_ output: ChatTimelineProjection.Output, _ id: String) -> ChatToolActivity? {
        guard case .tool(let tool)? = output.rows.first(where: { $0.id == entry(id) })?.content else { return nil }
        return tool
    }

    /// A Codex wait is plumbing: it folds while the subagent cards stay
    /// pinned above the fold.
    @Test func aWaitFoldsWhileTheSubagentCardsStayPinned() {
        let rows = [
            Self.user("u1"), Self.subagent("s1", path: "/root/probe_a", event: "started"),
            Self.subagent("s2", path: "/root/probe_b", event: "started"),
            Self.tool("w1", .other, name: "wait", title: "Waited for subagents"),
            Self.tool("w2", .other, name: "wait", title: "Waited for subagents"), Self.text("a1"),
        ]
        let output = Self.project(rows, turns: [Self.turn("u1")])
        #expect(Self.ids(output) == ["u1", "s1", "s2", "[turn a1]", "a1"])
        #expect(output.owners[Self.entry("w1")] == .turn(ChatEntryID("a1")))
        #expect(output.owners[Self.entry("w2")] == .turn(ChatEntryID("a1")))
    }

    @Test func interleavedSubagentEventsMergeByFullPathAndKeepTheLatestStatus() {
        let rows = [
            Self.user("u1"), Self.subagent("a1", path: "/root/a/task", event: "started"),
            Self.subagent("b1", path: "/root/b/task", event: "started"),
            Self.tool("call", .agent, name: "Agent", title: "Subagent: task"),
            Self.subagent("a2", path: "/root/a/task", event: "completed"),
            Self.subagent("b2", path: "/root/b/task", event: "completed"),
            Self.subagent("a3", path: "/root/a/task", event: "interacted"),
        ]
        let output = Self.project(rows, turns: [Self.turn("u1")])
        #expect(Self.ids(output) == ["u1", "a1", "b1", "call"])
        #expect(Self.activityTool(output, "a1")?.subagentActivity?.events == ["started", "completed", "interacted"])
        #expect(Self.activityTool(output, "a1")?.status == .noResult)
        #expect(Self.activityTool(output, "b1")?.status == .succeeded)
        #expect(Self.activityTool(output, "a1")?.output == nil)
        #expect(output.owners[Self.entry("a2")] == Self.entry("a1"))
        #expect(output.owners[Self.entry("a3")] == Self.entry("a1"))
        #expect(output.owners[Self.entry("b2")] == Self.entry("b1"))
    }

    @Test func unknownSubagentIdentityDoesNotMerge() {
        let rows = [
            Self.subagent("a", path: nil, event: "started"), Self.subagent("b", path: nil, event: "completed"),
            Self.subagent("c", path: "", event: "started"), Self.subagent("d", path: "", event: "interacted"),
        ]
        let output = Self.project(rows, turns: [])
        #expect(Self.ids(output) == ["a", "b", "c", "d"])
        #expect(output.owners.isEmpty)
    }

    @Test func subagentCardsKeepIdentityAndChangeRevisionWhenAnEventArrives() {
        let rows = [Self.user("u1"), Self.subagent("a1", path: "/root/task", event: "started")]
        let before = Self.project(rows, turns: [Self.turn("u1")])
        let appended = Self.project(
            rows + [Self.subagent("a2", path: "/root/task", event: "interacted")], turns: [Self.turn("u1")])
        let repeated = Self.project(
            rows + [Self.subagent("a2", path: "/root/task", event: "interacted")], turns: [Self.turn("u1")])
        #expect(Self.ids(before) == Self.ids(appended))
        #expect(before.rows.last?.revision != appended.rows.last?.revision)
        #expect(appended.rows.last?.revision == repeated.rows.last?.revision)
    }

    @Test func subagentMergingStopsAtTurnsAndUserMessages() {
        let rows = [
            Self.user("u1"), Self.subagent("a1", path: "/root/task", event: "started"),
            Self.user("queued", queued: true), Self.subagent("a2", path: "/root/task", event: "interacted"),
            Self.user("u2"), Self.subagent("a3", path: "/root/task", event: "completed"),
        ]
        let output = Self.project(rows, turns: [Self.turn("u1"), Self.turn("u2")])
        #expect(Self.ids(output) == ["u1", "a1", "queued", "a2", "u2", "a3"])
        #expect(output.owners.isEmpty)
    }

    @Test func mergedSubagentStaysPinnedAndKeepsAnchorsWhenToolsAndTurnsFold() {
        let rows = [
            Self.user("u1"), Self.subagent("a1", path: "/root/task", event: "started"),
            Self.tool("c1"), Self.tool("c2"), Self.subagent("a2", path: "/root/task", event: "completed"),
            Self.text("answer"),
        ]
        let closed = Self.project(rows, turns: [Self.turn("u1")])
        #expect(Self.ids(closed) == ["u1", "a1", "[turn answer]", "answer"])
        #expect(closed.owners[Self.entry("a2")] == Self.entry("a1"))
        let open = Self.project(rows, turns: [Self.turn("u1")], open: [.turn(ChatEntryID("answer"))])
        #expect(Self.ids(open) == ["u1", "a1", "[turn answer]", "[group c2]", "answer"])
        #expect(open.owners[Self.entry("a2")] == Self.entry("a1"))
    }

    // MARK: Layout

    @Test func shownRowsAreSpacedForTheirShownNeighbors() {
        let output = Self.project(Self.finished, turns: [Self.turn("u1")])
        let spacing = output.rows.map(\.topSpacing)
        // Prompt, plan, header, answer, answer.
        #expect(spacing == [8, 12, 10, 12, 12])
    }

    @Test func idsSurviveEarlierHistoryArrivingAbove() {
        let newer = [Self.user("u1"), Self.tool("c1"), Self.tool("c2"), Self.text("a1")]
        let older = [Self.user("u0"), Self.text("a0")]
        let open: Set<ChatRowID> = [.turn(ChatEntryID("a1"))]
        let before = Self.project(newer, turns: [Self.turn("u1")], open: open)
        let after = Self.project(older + newer, turns: [Self.turn("u0"), Self.turn("u1")], open: open)
        #expect(Self.ids(before) == ["u1", "[turn a1]", "[group c2]", "a1"])
        #expect(Self.ids(after) == ["u0", "a0", "u1", "[turn a1]", "[group c2]", "a1"])
        #expect(before.rows.first { $0.id == .group(ChatEntryID("c2")) }?.revision
            == after.rows.first { $0.id == .group(ChatEntryID("c2")) }?.revision)
    }
}
