import Foundation
import SwiftUI
import Testing
import UIKit

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
        #expect(presentation.rows[0].accessibilityLabel == "today, Workflow, no updates since 1:16\u{202F}PM")
        #expect(!presentation.ticks)
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

    @Test func theSummaryNamesARunningWorkflowFirst() {
        let running = Self.present([
            Self.row("Find old steps", subtitle: "Explore"),
            Self.row("docs-audit", kind: .workflow, progress: Self.auditProgress),
            Self.row("Check screenshots", state: .completed, endedAgo: 10),
        ])
        #expect(
            running.summary
                == .init(
                    status: .running, text: "2 running · docs-audit 2/3",
                    accessibilityValue: "2 running, docs-audit, 2 of 3 agents done"))

        let subagents = Self.present([Self.row("Find old steps"), Self.row("quiet", isStale: true)])
        #expect(subagents.summary?.text == "1 running · Find old steps")

        let finished = Self.present([
            Self.row("a", state: .completed), Self.row("b", state: .completed), Self.row("c", state: .stopped),
        ])
        #expect(finished.summary == .init(status: .completed, text: "2 done · 1 stopped", accessibilityValue: "2 done, 1 stopped"))
        #expect(Self.present([Self.row("a", state: .completed), Self.row("b", state: .failed)]).summary?.status == .failed)
        #expect(Self.present([]).summary == nil)
    }

    @Test func theStripShowsThreeRowsAndCountsTheRest() {
        let five = Self.present((1...5).map { Self.row("work \($0)") })
        #expect(five.stripRows.map(\.id) == ["work 1", "work 2", "work 3"])
        #expect(five.overflow == 2)
        #expect(Self.present((1...3).map { Self.row("work \($0)") }).overflow == 0)
    }

    @Test(arguments: [(0.0, "0s"), (38.9, "38s"), (138, "2m 18s"), (3_900, "1h 5m"), (-5, "0s")])
    func durationsReadAsThoughtForDoes(seconds: TimeInterval, text: String) {
        #expect(ChatBackgroundWorkPresentation.duration(seconds, width: .narrow, locale: Self.english) == text)
    }
}

/// The strip in a window: one line while condensed, nothing at all when
/// there is nothing to list, which the Blocked card's cap relies on.
@MainActor
@Suite("Chat background work strip, hosted", .serialized)
struct ChatBackgroundWorkStripHostedTests {
    private static func work(_ count: Int) -> ChatBackgroundWork {
        var work = ChatBackgroundWork()
        work.isLive = true
        work.rows = (0..<count).map { index in
            ChatBackgroundWork.Row(
                item: ChatBackgroundWorkItem(
                    id: "work-\(index)", kind: index == 0 ? .workflow : .subagent, title: "Work \(index)",
                    state: index == 2 ? .completed : .running, launchOffset: UInt64(index),
                    launchedAt: Date().addingTimeInterval(-90)))
        }
        return work
    }

    private static func height(_ work: ChatBackgroundWork, isCondensed: Bool) async throws -> CGFloat {
        let controller = UIHostingController(
            rootView: ChatBackgroundWorkStrip(work: work, isHostConnected: true, isCondensed: isCondensed, open: { _ in })
                .environment(\.locale, Locale(identifier: "en_US")))
        // The strip's own height, without the window's insets.
        controller.safeAreaRegions = []
        var height: CGFloat = 0
        try await withTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller) { _ in
            controller.view.layoutIfNeeded()
            height = controller.sizeThatFits(in: CGSize(width: 402, height: CGFloat.greatestFiniteMagnitude)).height
        }
        return height
    }

    @Test func theStripCondensesToOneLineAndTakesNoRoomEmpty() async throws {
        let empty = try await Self.height(Self.work(0), isCondensed: false)
        let condensed = try await Self.height(Self.work(5), isCondensed: true)
        let two = try await Self.height(Self.work(2), isCondensed: false)
        let four = try await Self.height(Self.work(4), isCondensed: false)
        let five = try await Self.height(Self.work(5), isCondensed: false)

        #expect(empty == 0)
        #expect(condensed > 20 && condensed < 50, "one line: \(condensed)")
        // Three rows and "+N more" outgrow two rows, and stop there.
        #expect(four > two + 40, "\(two) against \(four)")
        #expect(abs(five - four) < 0.5, "\(four) against \(five)")
    }
}
