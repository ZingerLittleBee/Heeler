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
        _ rows: [ChatRow], turns: [ChatTurn], signals: ChatTurnSignals = idle, open: Set<ChatRowID> = []
    ) -> ChatTimelineProjection.Output {
        ChatTimelineProjection.project(rows, turns: turns, signals: signals, open: open)
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
        let breakers: [ChatRow] = [
            Self.text("x"), Self.notice("x", .system), Self.row("x", .divider(ChatDivider(kind: .compaction))),
            Self.user("x", queued: true), Self.tool("x", .agent, name: "Agent"), Self.tool("x", .question, name: "AskUserQuestion"),
            Self.tool("x", status: .awaitingApproval), Self.tool("x", name: "user_shell"),
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
        #expect(summary([tool(.web, "WebSearch"), tool(.web, "WebFetch"), tool(.web, "WebFetch")]) == "Searched the web once, Fetched 2 pages")
        #expect(summary([tool(.web, "browse"), tool(.web, "browse")]) == "Used the web 2 times")
        #expect(summary([tool(.mcp), tool(.image), tool(.todo), tool(.todo)]) == "Called 1 tool, Viewed 1 image, Updated the to-do list")
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
