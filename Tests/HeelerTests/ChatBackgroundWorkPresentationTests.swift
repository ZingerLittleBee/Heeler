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
        #expect(presentation.summary?.text == "1 running · python3 -c '\nimport os'")
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

        let rows = Self.present([singleLineCmd, multiLineCmd, emptyWorkflow, populatedWorkflow, subagent]).rows
        #expect(rows.map(\.hasIntrinsicExpandableContent) == [false, true, false, true, false])
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
        // Typed locals keep Xcode 26's type checker within its time limit.
        let launchedAt = Date().addingTimeInterval(-90)
        work.rows = (0..<count).map { (index: Int) -> ChatBackgroundWork.Row in
            let kind: ChatBackgroundWorkItem.Kind = index == 0 ? .workflow : .subagent
            let state: ChatBackgroundWorkItem.State = index == 2 ? .completed : .running
            let item = ChatBackgroundWorkItem(
                id: "work-\(index)", kind: kind, title: "Work \(index)",
                state: state, launchOffset: UInt64(index), launchedAt: launchedAt)
            return ChatBackgroundWork.Row(item: item)
        }
        return work
    }

    private static func size(
        _ work: ChatBackgroundWork, isCondensed: Bool, showsFinishedWork: Bool = true, width: CGFloat = 402
    ) async throws -> CGSize {
        let controller = UIHostingController(
            rootView: ChatBackgroundWorkStrip(
                work: work, isHostConnected: true, isCondensed: isCondensed,
                showsFinishedWork: showsFinishedWork, open: { _ in }
            )
            .environment(\.locale, Locale(identifier: "en_US")))
        // The strip's own size, without the window's insets.
        controller.safeAreaRegions = []
        var size = CGSize.zero
        try await withTestWindow(frame: CGRect(x: 0, y: 0, width: width, height: 874), rootViewController: controller) { _ in
            controller.view.layoutIfNeeded()
            size = controller.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        }
        return size
    }

    private static func height(
        _ work: ChatBackgroundWork, isCondensed: Bool, showsFinishedWork: Bool = true
    ) async throws -> CGFloat {
        try await size(work, isCondensed: isCondensed, showsFinishedWork: showsFinishedWork).height
    }

    @Test func aRowQuietSinceAnotherDayFitsANarrowPhone() async throws {
        var work = ChatBackgroundWork()
        work.isLive = true
        let progress = ChatWorkflowProgress(agents: [
            .init(id: "k1", label: "audit:setup", phase: "Audit", state: .done),
            .init(id: "k2", label: "audit:index", phase: "Audit", state: .running),
        ])
        work.rows = [
            ChatBackgroundWork.Row(
                item: ChatBackgroundWorkItem(
                    id: "quiet", kind: .workflow, title: "docs-audit", launchOffset: 0,
                    launchedAt: Date().addingTimeInterval(-2 * 86_400)),
                progress: progress, isStale: true, lastActivity: Date().addingTimeInterval(-2 * 86_400))
        ]
        let size = try await Self.size(work, isCondensed: false, width: 375)
        #expect(size.width <= 375, "\(size.width)")
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

        var onlyFinished = ChatBackgroundWork()
        onlyFinished.isLive = true
        onlyFinished.rows = [
            ChatBackgroundWork.Row(
                item: ChatBackgroundWorkItem(
                    id: "done-1", kind: .workflow, title: "rex-size-wrap", state: .completed, launchOffset: 1))
        ]
        #expect(try await Self.height(onlyFinished, isCondensed: false, showsFinishedWork: false) == 0)
        #expect(try await Self.height(onlyFinished, isCondensed: true, showsFinishedWork: false) == 0)
        #expect(try await Self.height(Self.work(2), isCondensed: false, showsFinishedWork: false) > 20)
    }

    @Test func activityCardHidesDisclosureChevronUntilContentActuallyExpands() async throws {
        // Use rows without a duration (`launchedAt == nil`, `endedAt == nil`) so
        // the top-right header region only contains ink when `chevron.right` is drawn.
        let shortCommand = ChatBackgroundWork.Row(
            item: ChatBackgroundWorkItem(
                id: "short-cmd", kind: .command, title: "pytest -q", subtitle: "Run unit tests",
                state: .completed, launchOffset: 1))
        let multiLineCommand = ChatBackgroundWork.Row(
            item: ChatBackgroundWorkItem(
                id: "multi-cmd", kind: .command, title: "cd /tmp\npytest -q", subtitle: "Run unit tests",
                state: .completed, launchOffset: 2))
        let truncatedSingleLineCommand = ChatBackgroundWork.Row(
            item: ChatBackgroundWorkItem(
                id: "long-cmd", kind: .command,
                title: "python3 scripts/verify-everything.py --workspace /Users/example/Documents/worktree/Heeler/worktree-rapid-field-9516 --configuration Debug --strict-checks --report-output /tmp/report.json",
                subtitle: "Run full verification command",
                state: .completed, launchOffset: 3))
        let shortSubagent = ChatBackgroundWork.Row(
            item: ChatBackgroundWorkItem(
                id: "short-sub", kind: .subagent, title: "Codebase Researcher", subtitle: "research",
                state: .completed, launchOffset: 4))
        let emptyWorkflow = ChatBackgroundWork.Row(
            item: ChatBackgroundWorkItem(
                id: "empty-wf", kind: .workflow, title: "audit.py", subtitle: "Audit docs",
                state: .completed, launchOffset: 5))
        let agentWorkflow = ChatBackgroundWork.Row(
            item: ChatBackgroundWorkItem(
                id: "agent-wf", kind: .workflow, title: "audit.py", subtitle: "Audit docs",
                state: .completed, launchOffset: 6),
            progress: ChatWorkflowProgress(agents: [
                .init(id: "a1", label: "audit:links", phase: "Audit", state: .done)
            ]))

        var work = ChatBackgroundWork()
        work.isLive = true
        work.rows = [
            shortCommand, multiLineCommand, truncatedSingleLineCommand,
            shortSubagent, emptyWorkflow, agentWorkflow,
        ]
        let presented = ChatBackgroundWorkPresentation(
            work: work, isHostConnected: true, now: Date(), locale: Locale(identifier: "en_US")
        ).rows

        var hasChevron: [Bool] = []
        for row in presented {
            hasChevron.append(try await Self.cardTopRightHasChevronInk(row: row, width: 358))
        }
        #expect(hasChevron == [false, true, true, false, false, true], "chevron visibility per row: \(hasChevron)")
    }

    private static func cardTopRightHasChevronInk(
        row: ChatBackgroundWorkPresentation.Row, width: CGFloat
    ) async throws -> Bool {
        let controller = UIHostingController(
            rootView: ChatBackgroundWorkActivityCard(row: row, expandedCards: .constant([]))
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.locale, Locale(identifier: "en_US")))
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        var hasInk = false
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: width, height: 320), rootViewController: controller
        ) { window in
            window.overrideUserInterfaceStyle = .dark
            // Let SwiftUI's `onGeometryChange` truncation probe settle across layout passes.
            for _ in 0..<4 {
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            controller.view.frame = CGRect(origin: .zero, size: size)
            controller.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            format.opaque = true
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image { ctx in
                UIColor.black.setFill()
                ctx.fill(controller.view.bounds)
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            guard let cgImage = image.cgImage,
                let data = cgImage.dataProvider?.data,
                let bytes = CFDataGetBytePtr(data)
            else { return }
            let scale: CGFloat = 2
            let bytesPerRow = cgImage.bytesPerRow
            let bytesPerPixel = cgImage.bitsPerPixel / 8
            // Card inset is 13pt; top row sits around y = 13...37pt, trailing chevron around width - 28 ... width - 12pt.
            let minX = Int(((width - 30) * scale).rounded(.down))
            let maxX = Int(((width - 11) * scale).rounded(.up))
            let minY = Int((14 * scale).rounded(.down))
            let maxY = Int((36 * scale).rounded(.up))
            // Sample card background inside the header row to the left of the chevron slot (`width - 48`).
            let sampleX = Int(((width - 48) * scale).rounded())
            let sampleY = Int((25 * scale).rounded())
            let bgOffset = sampleY * bytesPerRow + sampleX * bytesPerPixel
            let bgR = Int(bytes[bgOffset])
            let bgG = Int(bytes[bgOffset + 1])
            let bgB = Int(bytes[bgOffset + 2])
            for py in minY..<min(maxY, cgImage.height) {
                for px in minX..<min(maxX, cgImage.width) {
                    let offset = py * bytesPerRow + px * bytesPerPixel
                    let dr = abs(Int(bytes[offset]) - bgR)
                    let dg = abs(Int(bytes[offset + 1]) - bgG)
                    let db = abs(Int(bytes[offset + 2]) - bgB)
                    if max(dr, max(dg, db)) > 18 {
                        hasInk = true
                        return
                    }
                }
            }
        }
        return hasInk
    }
}
