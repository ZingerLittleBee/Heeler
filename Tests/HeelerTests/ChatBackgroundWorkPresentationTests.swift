import Foundation
import SwiftUI
import Testing

@testable import Heeler

/// What the strip and the sheet say about each piece of Background Work.
@Suite("Chat background work presentation")
struct ChatBackgroundWorkPresentationTests {
    /// 2026-10-06T15:20:00Z.
    private static let now = Date(timeIntervalSince1970: 1_791_300_000)
    private static let english = Locale(identifier: "en_US")
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private static func row(
        _ id: String, kind: ChatBackgroundWorkItem.Kind = .subagent, state: ChatBackgroundWorkItem.State = .running,
        subtitle: String? = nil, launchedAgo: TimeInterval? = 60, endedAgo: TimeInterval? = nil,
        usage: ChatBackgroundWorkItem.Usage? = nil, progress: ChatWorkflowProgress? = nil, isStale: Bool = false,
        lastActivity: Date? = nil
    ) -> ChatBackgroundWork.Row {
        let item = ChatBackgroundWorkItem(
            id: id, kind: kind, title: id, subtitle: subtitle, state: state, launchOffset: 0,
            launchedAt: launchedAgo.map { now.addingTimeInterval(-$0) },
            endedAt: endedAgo.map { now.addingTimeInterval(-$0) }, usage: usage)
        return ChatBackgroundWork.Row(item: item, progress: progress, isStale: isStale, lastActivity: lastActivity)
    }

    private static func present(
        _ rows: [ChatBackgroundWork.Row], isLive: Bool = true, isHostConnected: Bool = true
    ) -> ChatBackgroundWorkPresentation {
        var work = ChatBackgroundWork()
        work.rows = rows
        work.isLive = isLive
        return ChatBackgroundWorkPresentation(
            work: work, isHostConnected: isHostConnected, now: now, locale: english, calendar: utc)
    }

    private static let auditProgress = ChatWorkflowProgress(agents: [
        .init(id: "k1", label: "audit:setup", phase: "Audit", state: .done),
        .init(id: "k2", label: "audit:index", phase: "Audit", state: .done),
        .init(id: "k3", label: nil, phase: "Verify", state: .running),
    ])

    @Test func aLiveReadShowsRunningWorkWithItsTimeAndAWorkflowsFraction() {
        let presentation = Self.present([
            Self.row("Find old steps", subtitle: "Explore", launchedAgo: 138),
            Self.row("docs-audit", kind: .workflow, subtitle: "Check every page", launchedAgo: 3_900, progress: Self.auditProgress),
            Self.row(
                "Check screenshots", state: .completed, launchedAgo: 200, endedAgo: 60,
                usage: .init(tokens: 41_200, toolUses: 14, durationMilliseconds: 124_000)),
        ])
        #expect(presentation.rows.map(\.status) == [.running, .running, .completed])
        #expect(presentation.rows.map(\.time) == ["2m 18s", "1h 5m", "2m 4s"])
        // A Workflow is in the phase of the agent it started last.
        #expect(presentation.rows.map(\.caption) == ["Explore", "Verify", "Subagent"])
        #expect(presentation.rows.map(\.fraction) == [nil, .init(done: 2, total: 3), nil])
        #expect(presentation.rows[1].detail == "Check every page")
        #expect(presentation.rows[2].usage == "41.2K tokens · 14 tool uses")
        #expect(presentation.ticks)
        #expect(
            presentation.rows[1].accessibilityLabel
                == "docs-audit, Workflow, running, 2 of 3 agents done, 1 hour, 5 minutes")
        #expect(presentation.rows[0].accessibilityLabel == "Find old steps, Explore subagent, running, 2 minutes, 18 seconds")
        #expect(
            presentation.rows[1].agents.map(\.label) == ["audit:setup", "audit:index", "Agent 3"])
        #expect(presentation.rows[1].agents.map(\.status) == [.completed, .completed, .running])
    }

    @Test func aHostAwayOrAFailedReadFreezesWhatRuns() {
        let rows = [
            Self.row("docs-audit", kind: .workflow, progress: Self.auditProgress),
            Self.row("Check screenshots", state: .failed, launchedAgo: 90, endedAgo: 30),
        ]
        for presentation in [Self.present(rows, isLive: false), Self.present(rows, isHostConnected: false)] {
            #expect(presentation.rows.map(\.status) == [.unconfirmed, .failed])
            #expect(presentation.rows[0].time == nil)
            #expect(presentation.rows[0].note == "Not updating")
            #expect(presentation.rows[0].shortNote == "Not updating")
            // The last read's count still stands.
            #expect(presentation.rows[0].fraction == .init(done: 2, total: 3))
            #expect(presentation.rows[0].agents.map(\.status) == [.completed, .completed, .unconfirmed])
            #expect(presentation.rows[1].time == "1m")
            #expect(!presentation.ticks)
            #expect(presentation.summary?.text == "1 not updating · 1 failed")
        }
    }

    @Test func workSilentForTooLongSaysWhenItWasLastSeen() {
        let presentation = Self.present([
            Self.row("today", kind: .workflow, isStale: true, lastActivity: Self.now.addingTimeInterval(-7_400)),
            Self.row("yesterday", isStale: true, lastActivity: Self.now.addingTimeInterval(-86_400)),
            Self.row("unknown", isStale: true),
        ])
        #expect(presentation.rows.map(\.status) == [.quiet, .quiet, .quiet])
        #expect(
            presentation.rows.map(\.note) == [
                "No updates since 1:16\u{202F}PM", "No updates since Oct 5, 2026 at 3:20\u{202F}PM",
                "No recent updates",
            ])
        #expect(presentation.rows.map(\.shortNote) == ["Last seen 1:16\u{202F}PM", "Last seen Oct 5", "No recent updates"])
        #expect(presentation.rows[0].accessibilityLabel == "today, Workflow, no updates since 1:16\u{202F}PM")
        #expect(!presentation.ticks)
    }

    @Test func aWorkflowIsInItsLastRunningAgentsPhase() {
        // A retry keeps the agent's place among those started.
        let retried = ChatWorkflowProgress(agents: [
            .init(id: "k1", label: "audit:setup", phase: "Audit", state: .running),
            .init(id: "k2", label: "verify:setup", phase: "Verify", state: .failed),
        ])
        let ended = ChatWorkflowProgress(agents: [
            .init(id: "k1", label: "audit:setup", phase: "Audit", state: .done),
            .init(id: "k2", label: "verify:setup", phase: "Verify", state: .done),
        ])
        let presentation = Self.present([
            Self.row("retried", kind: .workflow, progress: retried),
            Self.row("ended", kind: .workflow, progress: ended),
        ])
        #expect(presentation.rows.map(\.caption) == ["Audit", "Verify"])
    }

    @Test func aHostClockAheadOfThePhoneReadsZero() {
        let presentation = Self.present([Self.row("ahead", launchedAgo: -45)])
        #expect(presentation.rows.first?.time == "0s")
    }

    @Test func finishedWorkTakesItsCountsFromItsNotification() {
        let journal = ChatWorkflowProgress(agents: [
            .init(id: "k1", label: "audit:setup", phase: "Audit", state: .done),
            .init(id: "k2", label: "audit:index", phase: "Audit", state: .running),
        ])
        let presentation = Self.present([
            Self.row(
                "docs-audit", kind: .workflow, state: .stopped, launchedAgo: 600, endedAgo: 300,
                usage: .init(agents: 4, agentsDone: 3, agentsFailed: 0), progress: journal),
            Self.row("unread", kind: .workflow, state: .completed, launchedAgo: nil, endedAgo: 30),
        ])
        #expect(presentation.rows[0].fraction == .init(done: 3, total: 4))
        // With no duration in the notification, the records' times say.
        #expect(presentation.rows[0].time == "5m")
        // Work that ended took its running agents with it.
        #expect(presentation.rows[0].agents.map(\.status) == [.completed, .stopped])
        #expect(presentation.rows[1].fraction == nil)
        #expect(presentation.rows[1].time == nil)
        #expect(presentation.rows.map(\.caption) == ["Audit", "Workflow"])
    }

    @Test func theSummaryCountsTheRowsByState() {
        let running = Self.present([
            Self.row("Find old steps", subtitle: "Explore"),
            Self.row("docs-audit", kind: .workflow, progress: Self.auditProgress),
            Self.row("Check screenshots", state: .completed, endedAgo: 10),
        ])
        #expect(running.summary?.status == .running)
        #expect(running.summary?.text == "2 running · 1 done")
        #expect(running.summary?.accessibilityValue == "2 running, 1 done")

        // What wants a look comes before what ended well.
        let mixed = Self.present([
            Self.row("Find old steps"), Self.row("quiet", isStale: true),
            Self.row("a", state: .completed), Self.row("b", state: .failed),
        ])
        #expect(mixed.summary?.counts.map(\.status) == [.running, .unconfirmed, .failed, .completed])
        #expect(mixed.summary?.text == "1 running · 1 not updating · 1 failed · 1 done")

        let finished = Self.present([
            Self.row("a", state: .completed), Self.row("b", state: .completed), Self.row("c", state: .stopped),
        ])
        #expect(finished.summary?.status == .completed)
        #expect(finished.summary?.text == "2 done · 1 stopped")
        #expect(finished.summary?.accessibilityValue == "2 done, 1 stopped")
        #expect(Self.present([Self.row("a", state: .completed), Self.row("b", state: .failed)]).summary?.status == .failed)
        #expect(Self.present([]).summary == nil)
    }

    @Test func theStripShowsThreeRowsAndCountsTheRest() {
        let five = Self.present((1...5).map { Self.row("work \($0)") })
        #expect(five.stripRows.map(\.id) == ["work 1", "work 2", "work 3"])
        #expect(five.overflow == 2)
        #expect(Self.present((1...3).map { Self.row("work \($0)") }).overflow == 0)
    }

    @Test func aCommandRowShowsItsKindAndSummary() {
        let presentation = Self.present([
            Self.row("python3 -c '\nimport os'", kind: .command, subtitle: "Run Python tests", launchedAgo: 42),
            Self.row("make lint", kind: .command, state: .stopped, launchedAgo: 90, endedAgo: 30),
        ])
        #expect(presentation.rows.map(\.caption) == ["Command", "Command"])
        #expect(presentation.rows.map(\.kindBadge) == ["Command", "Command"])
        #expect(presentation.rows.map(\.detail) == ["Run Python tests", nil])
        #expect(presentation.rows.map(\.stripHeadline) == ["Run Python tests", "make lint"])
        #expect(presentation.rows.map(\.cardHeadline) == ["Run Python tests", nil])
        #expect(presentation.rows.map(\.terminalPreview) == ["$ python3 -c ' import os'", "$ make lint"])
        #expect(presentation.rows.map(\.fullTerminalText) == ["$ python3 -c '\nimport os'", "$ make lint"])
        #expect(presentation.rows[0].accessibilityLabel == "python3 -c '\nimport os', Command, running, 42 seconds")
        #expect(presentation.rows[1].accessibilityLabel == "make lint, Command, stopped, 1 minute")
        #expect(presentation.summary?.text == "1 running · 1 stopped")
    }

    @Test(arguments: [(0.0, "0s"), (38.9, "38s"), (138, "2m 18s"), (3_900, "1h 5m"), (-5, "0s")])
    func durationsReadAsThoughtForDoes(seconds: TimeInterval, text: String) {
        #expect(ChatBackgroundWorkPresentation.duration(seconds, width: .narrow, locale: Self.english) == text)
    }

    @Test func runningAndNotUpdatingSplitUnfinishedRowsCoherently() {
        let mixed = Self.present([
            Self.row("active-cmd", kind: .command, launchedAgo: 14_100),
            Self.row("quiet-subagent", isStale: true, lastActivity: Self.now.addingTimeInterval(-12_000)),
            Self.row("done-subagent", state: .completed, launchedAgo: 120, endedAgo: 60),
        ])
        #expect(mixed.running.map(\.id) == ["active-cmd"])
        #expect(mixed.running.first?.time == "3h 55m")
        #expect(mixed.notUpdating.map(\.id) == ["quiet-subagent"])
        #expect(mixed.unfinished.map(\.id) == ["active-cmd", "quiet-subagent"])
        #expect(mixed.finished.map(\.id) == ["done-subagent"])

        let offline = Self.present([
            Self.row("active-cmd", kind: .command, launchedAgo: 14_100),
            Self.row("done-subagent", state: .completed, launchedAgo: 120, endedAgo: 60),
        ], isHostConnected: false)
        #expect(offline.running.isEmpty)
        #expect(offline.notUpdating.map(\.id) == ["active-cmd"])
        #expect(offline.notUpdating.first?.status == .unconfirmed)
    }

    @Test func intrinsicExpandableContentRequiresAgentsOrMultiLineCommand() {
        let singleLineCmd = ChatBackgroundWork.Row(
            item: ChatBackgroundWorkItem(
                id: "cmd-1", kind: .command, title: "pytest -q", subtitle: "Run unit tests",
                state: .completed, launchOffset: 1))
        let multiLineCmd = ChatBackgroundWork.Row(
            item: ChatBackgroundWorkItem(
                id: "cmd-2", kind: .command, title: "cd /tmp\npytest -q", subtitle: "Run unit tests",
                state: .completed, launchOffset: 2))
        let emptyWorkflow = ChatBackgroundWork.Row(
            item: ChatBackgroundWorkItem(
                id: "wf-1", kind: .workflow, title: "audit.py", subtitle: "Audit docs",
                state: .running, launchOffset: 3))
        let populatedWorkflow = ChatBackgroundWork.Row(
            item: ChatBackgroundWorkItem(
                id: "wf-2", kind: .workflow, title: "audit.py", subtitle: "Audit docs",
                state: .running, launchOffset: 4),
            progress: ChatWorkflowProgress(agents: [
                .init(id: "a1", label: "reader", phase: "Scan", state: .running)
            ]))
        let subagent = ChatBackgroundWork.Row(
            item: ChatBackgroundWorkItem(
                id: "sub-1", kind: .subagent, title: "Codebase Researcher", subtitle: "research",
                state: .running, launchOffset: 5))
        let timer = ChatBackgroundWork.Row(
            item: ChatBackgroundWorkItem(
                id: "timer-1", kind: .timer, title: "Check build status", subtitle: "4m",
                state: .running, launchOffset: 6))

        let rows = Self.present([singleLineCmd, multiLineCmd, emptyWorkflow, populatedWorkflow, subagent, timer]).rows
        #expect(rows.map(\.hasIntrinsicExpandableContent) == [false, true, false, true, false, false])
    }

    @Test func timerRowShowsPromptTitleAndDurationBadgeWithoutTerminalBox() {
        let timerWithDuration = Self.row(
            "Check DockerManager status", kind: .timer, subtitle: "4m", launchedAgo: 72)
        let bareTimer = Self.row("4m", kind: .timer, subtitle: nil, launchedAgo: 10)
        let cronTimer = Self.row("Poll CI", kind: .timer, subtitle: "*/5 * * * *", launchedAgo: 30)

        let rows = Self.present([timerWithDuration, bareTimer, cronTimer]).rows
        #expect(rows[0].stripHeadline == "Check DockerManager status")
        #expect(rows[0].cardHeadline == "Check DockerManager status")
        #expect(rows[0].stripKind == "Timer · 4m")
        #expect(rows[0].kindBadge == "Timer · 4m")
        #expect(rows[0].terminalPreview == nil)
        #expect(rows[0].fullTerminalText == nil)
        #expect(rows[0].detail == nil)
        #expect(rows[0].accessibilityLabel == "Check DockerManager status, Timer 4m, running, 1 minute, 12 seconds")

        #expect(rows[1].stripKind == "Timer")
        #expect(rows[1].kindBadge == "Timer")
        #expect(rows[1].accessibilityLabel == "4m, Timer, running, 10 seconds")

        #expect(rows[2].stripKind == "Timer · */5 * * * *")
        #expect(rows[2].kindBadge == "Timer · */5 * * * *")
    }
}
