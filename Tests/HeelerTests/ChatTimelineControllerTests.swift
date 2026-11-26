import CoreGraphics
import Foundation
import Testing

@testable import Heeler

/// Entries the timeline suites share.
enum ChatTimelineFixture {
    /// A conversation of user prompts, tool calls and answers of varied
    /// length; the same index always makes the same entry.
    static func entries(_ range: Range<Int>) -> [ChatEntry] {
        range.map { index in
            let content: ChatEntry.Content
            switch index % 4 {
            case 0:
                content = .user(ChatUserMessage(text: "Question \(index): what changed in this part?"))
            case 1:
                let output = (1...12).map { "line \($0) of output from step \(index)" }.joined(separator: "\n")
                content = .tool(
                    ChatToolActivity(
                        kind: .command, name: "Bash", title: "ls -la src/\(index)", status: .succeeded,
                        preview: ChatToolPreview(text: output, isTruncated: false)))
            default:
                content = .assistant(
                    ChatAssistantMessage(
                        text: "Answer \(index). "
                            + String(repeating: "This sentence adds a little length. ", count: 1 + index % 9)))
            }
            return ChatEntry(id: ChatEntryID("e\(index)"), sourceOffset: UInt64(index) * 100, content: content)
        }
    }
}

@MainActor
@Suite("Chat timeline model")
struct ChatTimelineModelTests {
    @Test func publishesTheNewestRequestAndNumbersConversations() async {
        let model = ChatTimelineModel()
        let entries = ChatTimelineFixture.entries(0..<5)
        model.update(conversation: 7, input: ChatTimelineInput(entries: Array(entries.prefix(2))), isReady: false)
        model.update(conversation: 7, input: ChatTimelineInput(entries: entries), isReady: true)
        await model.settled()
        #expect(model.state.rows.map(\.id) == entries.map { .entry($0.id) })
        #expect(model.state.isReady)
        let generation = model.state.generation
        let revision = model.state.revision

        model.update(conversation: 7, input: ChatTimelineInput(entries: entries), isReady: false)
        await model.settled()
        #expect(model.state.generation == generation)
        #expect(model.state.revision > revision)
        #expect(model.state.isReady, "readiness holds within one conversation")

        model.update(conversation: 8, input: ChatTimelineInput(), isReady: false)
        await model.settled()
        #expect(model.state.generation == generation + 1)
        #expect(model.state.rows.isEmpty)
        #expect(!model.state.isReady)
    }

    @Test func updateIfNeededSkipsIdenticalRequestAndUpdatesSignalsSynchronously() async {
        let model = ChatTimelineModel()
        let entries = ChatTimelineFixture.entries(0..<3)
        let input = ChatTimelineInput(entries: entries)
        let cachedSignals = ChatTurnSignals(activity: .idle, foldsFinishedTurns: true, isLive: false)
        model.updateIfNeeded(conversation: 1, input: input, signals: cachedSignals, isReady: true)
        await model.settled()

        let revisionAfterBuild = model.state.revision
        let generation = model.state.generation
        let rowID = ChatRowID.entry(entries[0].id)
        let measured = ChatMeasuredHeight(height: 84, width: 390, contentSizeCategory: "L|system", revision: 1)
        model.recordMeasuredHeight(measured, for: rowID, generation: generation)
        #expect(model.measuredHeights[rowID] == measured)

        // Identical feed on surface re-mount is a no-op.
        model.updateIfNeeded(conversation: 1, input: input, signals: cachedSignals, isReady: true)
        #expect(model.state.revision == revisionAfterBuild)

        // Signal-only change (e.g. cache confirmed live) updates synchronously on MainActor
        // without waiting on the async row builder.
        let liveSignals = ChatTurnSignals(activity: .idle, foldsFinishedTurns: true, isLive: true)
        model.updateIfNeeded(conversation: 1, input: input, signals: liveSignals, isReady: true)
        #expect(model.state.revision == revisionAfterBuild + 1)
        #expect(model.state.signals == liveSignals)
        #expect(model.measuredHeights[rowID] == measured)

        model.reset()
        #expect(model.state.rows.isEmpty)
        #expect(model.measuredHeights.isEmpty)
    }
}

@Suite("Chat row builder")
struct ChatRowBuilderTests {
    @Test func unchangedEntriesKeepTheirRevisionAndChangedOnesMove() async {
        let builder = ChatRowBuilder()
        var entries = ChatTimelineFixture.entries(0..<4)
        let first = await builder.rows(for: ChatTimelineInput(entries: entries))
        if case .assistant(var message) = entries[2].content {
            message.text += " Edited."
            entries[2].content = .assistant(message)
        }
        let second = await builder.rows(for: ChatTimelineInput(entries: entries))
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first[0].revision == second[0].revision)
        #expect(first[1].revision == second[1].revision)
        #expect(first[2].revision != second[2].revision)
        #expect(first[3].revision == second[3].revision)
        guard case .assistant(let source, let blocks) = second[2].content else {
            Issue.record("expected an assistant row")
            return
        }
        #expect(source.hasSuffix("Edited."))
        #expect(!blocks.isEmpty)
    }

    @Test func aRowWhoseSpacingChangesIsANewRevision() async {
        let builder = ChatRowBuilder()
        let entries = ChatTimelineFixture.entries(0..<4)
        let first = await builder.rows(for: ChatTimelineInput(entries: Array(entries.dropFirst())))
        let second = await builder.rows(for: ChatTimelineInput(entries: entries))
        // The tool row led the list; now a prompt sits above it.
        #expect(first[0].topSpacing != second[1].topSpacing)
        #expect(first[0].revision != second[1].revision)
        #expect(first[1].revision == second[2].revision)
    }

    @Test func olderHistoryLeadsAndPendingEchoesTrail() async {
        let builder = ChatRowBuilder()
        let echo = ChatPendingEcho(id: UUID(), text: "Ship it", state: .sending)
        let entries = ChatTimelineFixture.entries(0..<2)
        let rows = await builder.rows(
            for: ChatTimelineInput(entries: entries, pending: [echo], older: .available))
        #expect(rows.map(\.id) == [.olderHistory] + entries.map { .entry($0.id) } + [.pending(echo.id)])
        #expect(rows[0].topSpacing == 8)
        #expect(rows[1].topSpacing == 24)

        let atStart = await builder.rows(for: ChatTimelineInput(entries: entries, older: .reachedStart))
        #expect(atStart.first?.id == .entry(entries[0].id))
    }

    @Test func stepsOfOneTurnSitCloserThanTurns() {
        let tool = ChatRow.Content.tool(ChatToolActivity(kind: .command, name: "Bash", title: "ls", status: .succeeded))
        let user = ChatRow.Content.user(ChatUserMessage(text: "Hi"))
        #expect(ChatRowBuilder.spacing(before: tool, after: tool) < ChatRowBuilder.spacing(before: tool, after: user))
        #expect(ChatRowBuilder.spacing(before: user, after: tool) > ChatRowBuilder.spacing(before: tool, after: user))
        #expect(ChatRowBuilder.spacing(before: user, after: nil) == 8)
    }
}

@MainActor
@Suite("Chat row view")
struct ChatRowViewTests {
    /// A notice that shows a readable form of its text copies the text as
    /// recorded.
    @Test func aNoticeCopiesItsRawDetail() async throws {
        let notice = ChatNotice(
            kind: .error, title: "Turn failed", detail: "Not supported.", rawDetail: #"{"message":"Not supported."}"#)
        let plain = ChatNotice(kind: .error, title: "Turn failed", detail: "Disconnected")
        let entries = [notice, plain].enumerated().map { index, notice in
            ChatEntry(id: ChatEntryID("n\(index)"), sourceOffset: UInt64(index), content: .notice(notice))
        }
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: entries))
        let copied = entries.map { entry in rows.first { $0.id == .entry(entry.id) }?.copyText }
        #expect(copied == ["Turn failed\n{\"message\":\"Not supported.\"}", "Turn failed\nDisconnected"])
    }

    @Test func rowBuilderPrecomputesUserLinksImagesAndInlineDiffs() async {
        let user = ChatEntry(
            id: ChatEntryID("u1"),
            sourceOffset: 0,
            content: .user(ChatUserMessage(text: "See [Image #1]", imageCount: 1, imagePaths: ["/tmp/shot.png"])))
        let hunk = ChatDiffHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ["-old", "+new"])
        let change = ChatFileChange(path: "/tmp/a.swift", kind: .updated, added: 1, removed: 1, lineCount: 2, hunks: [hunk])
        let tool = ChatEntry(
            id: ChatEntryID("t1"),
            sourceOffset: 10,
            content: .tool(
                ChatToolActivity(
                    kind: .fileEdit, name: "Edit", title: "a.swift", status: .succeeded,
                    fileChanges: ChatFileChanges(files: [change]))))
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: [user, tool], entriesRevision: 1))
        #expect(rows[0].precomputedMarkedText != nil)
        #expect(rows[0].precomputedMessageImages?.map(\.path) == ["/tmp/shot.png"])
        #expect(rows[1].precomputedInlineDiffs["/tmp/a.swift"] != nil)

        let sameRevA = ChatTimelineInput(entries: [user], entriesRevision: 7)
        let sameRevB = ChatTimelineInput(entries: [user], entriesRevision: 7)
        #expect(sameRevA == sameRevB)
    }
}

@Suite("Chat timeline initial preposition and banner plans")
struct ChatTimelineControllerPlanTests {
    @Test func initialEndPrepositionDefersZeroBoundsAndTargetsBottomBandWithoutTopRows() async throws {
        let entries = ChatTimelineFixture.entries(0..<80)
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: entries))
        let viewport = CGSize(width: 393, height: 852)
        let topInset: CGFloat = 8
        let baseBottomInset: CGFloat = 12
        let bottomObstruction: CGFloat = 96
        let jumpClearance: CGFloat = 44
        let textWidth = viewport.width - 2 * ChatTimelineMetrics.horizontalPadding
        let heights = rows.map { row in
            ChatHeightEstimate(
                cached: nil,
                seed: row.seed,
                extent: row.extent,
                textWidth: textWidth,
                metrics: .standard,
                width: viewport.width,
                contentSizeCategory: "L|system",
                revision: row.revision
            ).height
        }
        let geometry = ChatTimelineGeometry(
            heights: heights,
            visibleHeight: viewport.height - topInset - (baseBottomInset + bottomObstruction + jumpClearance))

        // 1. Zero-bounds-first mount (`makeUIViewController` on `Terminal -> Show Chat`)
        // defers until real bounds arrive rather than laying out at 0x0 or cancelling.
        #expect(
            ChatInitialEndPrepositionPlan.decide(
                needsPreposition: true,
                isFollowing: true,
                isJumpAnimating: false,
                bounds: .zero,
                itemCount: rows.count,
                estimatedContentHeight: geometry.totalHeight,
                minOffsetY: -topInset,
                baseBottomInset: baseBottomInset,
                bottomObstruction: bottomObstruction,
                collapseControlReserve: 0,
                jumpControlClearance: jumpClearance,
                currentJumpControlReserve: 0) == .deferUntilSized)

        // 2. Empty `.locating` snapshot keeps preposition armed until rows arrive.
        #expect(
            ChatInitialEndPrepositionPlan.decide(
                needsPreposition: true,
                isFollowing: true,
                isJumpAnimating: false,
                bounds: viewport,
                itemCount: 0,
                estimatedContentHeight: 0,
                minOffsetY: -topInset,
                baseBottomInset: baseBottomInset,
                bottomObstruction: bottomObstruction,
                collapseControlReserve: 0,
                jumpControlClearance: jumpClearance,
                currentJumpControlReserve: 0) == .deferUntilSized)

        // 3. Once sized and populated, pre-reserves `jumpControlClearance` and lands
        // directly on the bottom viewport band so row 0 is never materialized.
        let decision = ChatInitialEndPrepositionPlan.decide(
            needsPreposition: true,
            isFollowing: true,
            isJumpAnimating: false,
            bounds: viewport,
            itemCount: rows.count,
            estimatedContentHeight: geometry.totalHeight,
            minOffsetY: -topInset,
            baseBottomInset: baseBottomInset,
            bottomObstruction: bottomObstruction,
            collapseControlReserve: 0,
            jumpControlClearance: jumpClearance,
            currentJumpControlReserve: 0)
        guard case .apply(let reservedJump, let bottomInset, let targetOffsetY) = decision else {
            Issue.record("expected initial end preposition plan to apply")
            return
        }
        #expect(reservedJump == jumpClearance)
        #expect(bottomInset == baseBottomInset + bottomObstruction + jumpClearance)
        let visibleIndices = geometry.indices(from: targetOffsetY, to: targetOffsetY + viewport.height)
        #expect(visibleIndices.contains(rows.count - 1))
        #expect(!visibleIndices.contains(0))
        #expect(visibleIndices.count < 25)

        // 4. Short non-overflowing conversations do not reserve jump clearance and stay at `minOffsetY`.
        let shortHeight = viewport.height - topInset - baseBottomInset - bottomObstruction
        #expect(
            ChatInitialEndPrepositionPlan.decide(
                needsPreposition: true,
                isFollowing: true,
                isJumpAnimating: false,
                bounds: viewport,
                itemCount: 2,
                estimatedContentHeight: shortHeight,
                minOffsetY: -topInset,
                baseBottomInset: baseBottomInset,
                bottomObstruction: bottomObstruction,
                collapseControlReserve: 0,
                jumpControlClearance: jumpClearance,
                currentJumpControlReserve: 0)
                == .apply(
                    jumpControlReserve: nil,
                    bottomInset: baseBottomInset + bottomObstruction,
                    targetOffsetY: -topInset))

        // 5. Unfollowed timelines cancel initial end preposition immediately.
        #expect(
            ChatInitialEndPrepositionPlan.decide(
                needsPreposition: true,
                isFollowing: false,
                isJumpAnimating: false,
                bounds: viewport,
                itemCount: rows.count,
                estimatedContentHeight: geometry.totalHeight,
                minOffsetY: -topInset,
                baseBottomInset: baseBottomInset,
                bottomObstruction: bottomObstruction,
                collapseControlReserve: 0,
                jumpControlClearance: jumpClearance,
                currentJumpControlReserve: 0) == .cancel)
    }

    @Test func topObstructionAnimatesOnlyWhenIdleAtTopInWindowWithoutReduceMotion() {
        // Mid-history (`wasAtTop == false`): updates top inset without pinning or animating (`0pt` jump).
        let midHistory = ChatTopObstructionTransition.decide(
            currentTopInset: 52,
            baseTopInset: 8,
            obstructionHeight: 102,
            contentOffsetY: 320,
            minOffsetY: -52,
            isFollowing: false,
            isUserScrolling: false,
            isTracking: false,
            isDecelerating: false,
            hasWindow: true,
            reduceMotion: false)
        #expect(
            midHistory
                == ChatTopObstructionTransition(
                    topInset: 110,
                    indicatorTopInset: 102,
                    pinsToNewMinOffset: false,
                    animates: false))

        // Resting unfollowed at top in a window: pins to new `minOffsetY` and animates over 0.2s.
        let atTopAnimated = ChatTopObstructionTransition.decide(
            currentTopInset: 52,
            baseTopInset: 8,
            obstructionHeight: 109.67,
            contentOffsetY: -52,
            minOffsetY: -52,
            isFollowing: false,
            isUserScrolling: false,
            isTracking: false,
            isDecelerating: false,
            hasWindow: true,
            reduceMotion: false)
        #expect(
            atTopAnimated
                == ChatTopObstructionTransition(
                    topInset: 117.67,
                    indicatorTopInset: 109.67,
                    pinsToNewMinOffset: true,
                    animates: true))
        #expect(ChatTopObstructionTransition.animationDuration == 0.2)

        // Before window mount (`hasWindow == false`) or with Reduce Motion enabled: pins synchronously without animation.
        let offscreen = ChatTopObstructionTransition.decide(
            currentTopInset: 8,
            baseTopInset: 8,
            obstructionHeight: 58,
            contentOffsetY: -8,
            minOffsetY: -8,
            isFollowing: false,
            isUserScrolling: false,
            isTracking: false,
            isDecelerating: false,
            hasWindow: false,
            reduceMotion: false)
        #expect(offscreen?.pinsToNewMinOffset == true)
        #expect(offscreen?.animates == false)

        let reducedMotion = ChatTopObstructionTransition.decide(
            currentTopInset: 52,
            baseTopInset: 8,
            obstructionHeight: 110,
            contentOffsetY: -52,
            minOffsetY: -52,
            isFollowing: false,
            isUserScrolling: false,
            isTracking: false,
            isDecelerating: false,
            hasWindow: true,
            reduceMotion: true)
        #expect(reducedMotion?.pinsToNewMinOffset == true)
        #expect(reducedMotion?.animates == false)
    }
}

