import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// The timeline in a real window: hosted rows measured by UIKit, the follow
/// pin, and the reader's place across updates.
@MainActor
@Suite("Chat timeline controller", .serialized, .timeLimit(.minutes(1)))
struct ChatTimelineControllerTests {
    private static let frame = CGRect(x: 0, y: 0, width: 390, height: 640)

    @Test func opensAtTheNewestRowWithVisibleRowsMeasured() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: Self.entries(0..<60)))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let view = controller.timeline
            #expect(controller.isFollowing)
            #expect(abs(view.contentOffset.y - view.maxOffsetY) <= 0.5)
            #expect(controller.visibleRowIDs.last == rows.last?.id)
            #expect(!view.visibleCells.isEmpty)
            for cell in view.visibleCells {
                let fitted = cell.contentView.systemLayoutSizeFitting(
                    CGSize(width: cell.bounds.width, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
                #expect(abs(cell.bounds.height - fitted.height) <= 1)
            }
        }
    }

    @Test func aShortConversationSitsAtTheBottom() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: Self.entries(0..<2)))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let view = controller.timeline
            let last = try #require(rows.last.flatMap { controller.cellFrame(of: $0.id) })
            let visibleBottom = view.contentOffset.y + view.bounds.height - view.adjustedContentInset.bottom
            #expect(abs(last.maxY - visibleBottom) <= 0.5)
        }
    }

    @Test func olderRowsArrivingAboveKeepTheReadersRowInPlace() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let builder = ChatRowBuilder()
        let newer = await builder.rows(
            for: ChatTimelineInput(entries: Self.entries(200..<260), older: .available))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(newer))
            await Self.settle(controller)
            let view = controller.timeline
            Self.drag(controller, to: view.maxOffsetY - 1_200)
            await Self.settle(controller)
            #expect(!controller.isFollowing)
            let (anchor, before) = try #require(Self.firstFullyVisibleRow(controller))

            let all = await builder.rows(for: ChatTimelineInput(entries: Self.entries(0..<260)))
            controller.apply(Self.state(all, revision: 2))
            await Self.settle(controller)
            let after = try #require(Self.screenY(of: anchor, in: controller))
            #expect(abs(after - before) <= 0.5)
            #expect(!controller.isFollowing)
        }
    }

    @Test func aFollowingListStaysPinnedWhileRowsArriveAndGrow() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let builder = ChatRowBuilder()
        var entries = Self.entries(0..<30)
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(await builder.rows(for: ChatTimelineInput(entries: entries))))
            await Self.settle(controller)
            for step in 1...6 {
                if step.isMultiple(of: 2) {
                    entries.append(contentsOf: Self.entries(30 + step..<31 + step))
                } else if case .assistant(var message) = entries[entries.count - 1].content {
                    // The newest answer streams in.
                    message.text += String(repeating: " More words arrive as the answer streams.", count: 6)
                    entries[entries.count - 1].content = .assistant(message)
                }
                let rows = await builder.rows(for: ChatTimelineInput(entries: entries))
                controller.apply(Self.state(rows, revision: 1 + step))
                await Self.settle(controller)
                let view = controller.timeline
                #expect(abs(view.contentOffset.y - view.maxOffsetY) <= 0.5, "step \(step)")
                #expect(controller.visibleRowIDs.last == rows.last?.id, "step \(step)")
            }
            #expect(controller.isFollowing)
        }
    }

    @Test func aReaderScrolledUpIsNotMovedByNewRows() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let builder = ChatRowBuilder()
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(await builder.rows(for: ChatTimelineInput(entries: Self.entries(0..<60)))))
            await Self.settle(controller)
            let view = controller.timeline
            Self.drag(controller, to: view.maxOffsetY - 900)
            await Self.settle(controller)
            let (anchor, before) = try #require(Self.firstFullyVisibleRow(controller))
            let rows = await builder.rows(for: ChatTimelineInput(entries: Self.entries(0..<70)))
            controller.apply(Self.state(rows, revision: 2))
            await Self.settle(controller)
            #expect(!controller.isFollowing)
            let after = try #require(Self.screenY(of: anchor, in: controller))
            #expect(abs(after - before) <= 0.5)
        }
    }

    @Test func jumpToLatestFromFarAwayLandsOnTheNewestRow() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: Self.entries(0..<600)))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let view = controller.timeline
            Self.drag(controller, to: view.minOffsetY)
            await Self.settle(controller)
            #expect(!controller.isFollowing)

            controller.jumpToLatest()
            #expect(controller.isFollowing)
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                #expect(!view.visibleCells.isEmpty)
                if abs(view.contentOffset.y - view.maxOffsetY) <= 0.5,
                    controller.visibleRowIDs.last == rows.last?.id
                {
                    break
                }
            }
            await Self.settle(controller)
            #expect(abs(view.contentOffset.y - view.maxOffsetY) <= 0.5)
            #expect(controller.visibleRowIDs.last == rows.last?.id)
            #expect(controller.isFollowing)
        }
    }

    @Test func expandingAToolRowKeepsItsTopWhereItWas() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: Self.entries(0..<60)))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let view = controller.timeline
            Self.drag(controller, to: view.maxOffsetY - 1_000)
            await Self.settle(controller)
            let tool = try #require(
                controller.visibleRowIDs.first { id in
                    guard let frame = controller.cellFrame(of: id),
                        frame.minY >= view.contentOffset.y + view.adjustedContentInset.top
                    else { return false }
                    return rows.first { $0.id == id }?.isExpandable == true
                })
            let before = try #require(Self.screenY(of: tool, in: controller))
            let folded = try #require(controller.cellFrame(of: tool)).height

            controller.toggle(tool)
            await Self.settle(controller)
            #expect(abs(try #require(Self.screenY(of: tool, in: controller)) - before) <= 0.5)
            #expect(try #require(controller.cellFrame(of: tool)).height > folded + 40)
            #expect(!controller.isFollowing)
        }
    }

    @Test func expandingAToolRowAsksForOutputItHasNoneOrOnlyTheStartOf() async throws {
        var requested: [ChatEntryID] = []
        var actions = ChatTimelineActions()
        actions.loadOutput = { requested.append($0) }
        let controller = ChatTimelineController(actions: actions)
        let reference = ChatOutputReference(offset: 0, length: 10)
        let entries = [
            Self.tool("cut", preview: ChatToolPreview(text: "line 1", isTruncated: true), output: reference),
            Self.tool("whole", preview: ChatToolPreview(text: "line 1", isTruncated: false), output: reference),
            Self.tool("saved", preview: nil, output: reference),
            Self.tool("running", preview: nil, output: nil, status: .running),
        ]
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: entries))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)

            for row in rows { controller.toggle(row.id) }

            #expect(requested == [ChatEntryID("cut"), ChatEntryID("saved")])
        }
    }

    @Test func aRowExpandedWhileItRanAsksOnceItHasOutputAndOnlyATapRetries() async throws {
        var requested: [ChatEntryID] = []
        var actions = ChatTimelineActions()
        actions.loadOutput = { requested.append($0) }
        let controller = ChatTimelineController(actions: actions)
        let builder = ChatRowBuilder()
        let id = ChatEntryID("step")
        let reference = ChatOutputReference(offset: 0, length: 10)
        let cut = ChatToolPreview(text: "line 1", isTruncated: true)
        let running = await builder.rows(
            for: ChatTimelineInput(entries: [Self.tool("step", preview: nil, output: nil, status: .running)]))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(running))
            await Self.settle(controller)
            controller.toggle(.entry(id))
            #expect(requested.isEmpty)

            let done = await builder.rows(
                for: ChatTimelineInput(entries: [Self.tool("step", preview: cut, output: reference)]))
            controller.apply(Self.state(done, revision: 2))
            await Self.settle(controller)
            #expect(requested == [id])

            // The read failed: an update leaves it be, and a tap tries again.
            let failed = await builder.rows(
                for: ChatTimelineInput(entries: [
                    Self.tool("step", preview: cut, output: reference, outputRead: .failed("Couldn't load output."))
                ]))
            controller.apply(Self.state(failed, revision: 3))
            await Self.settle(controller)
            #expect(requested == [id])
            controller.toggle(.entry(id))
            controller.toggle(.entry(id))
            #expect(requested == [id, id])
        }
    }

    @Test func openingAChangedFileGrowsTheRowAndReadsOnlyLinesItLacks() async throws {
        var requested: [ChatEntryID] = []
        var actions = ChatTimelineActions()
        actions.loadOutput = { requested.append($0) }
        let controller = ChatTimelineController(actions: actions)
        let reference = ChatOutputReference(offset: 0, length: 10)
        let held = ChatFileChange(
            path: "/p/held.txt", kind: .created,
            recorded: [
                ChatDiffHunk(
                    oldStart: 0, oldLines: 0, newStart: 1, newLines: 20, lines: (1...20).map { "+line \($0)" })
            ])
        // As the device cache keeps a file: its counts without its lines.
        let saved = ChatFileChange(path: "/p/saved.txt", kind: .updated, added: 4, removed: 2, lineCount: 9)
        let command = ChatToolActivity(
            kind: .command, name: "Bash", title: "python3 gen.py", status: .succeeded,
            fileChanges: ChatFileChanges(files: [held, saved], directory: "/p"),
            preview: ChatToolPreview(text: "done", isTruncated: false), output: reference)
        let edit = ChatToolActivity(
            kind: .fileEdit, name: "Edit", title: "/p/saved.txt", status: .succeeded,
            fileChanges: ChatFileChanges(files: [saved]), output: reference)
        let rows = await ChatRowBuilder().rows(
            for: ChatTimelineInput(entries: [
                ChatEntry(id: ChatEntryID("command"), sourceOffset: 0, content: .tool(command)),
                ChatEntry(id: ChatEntryID("edit"), sourceOffset: 1, content: .tool(edit)),
            ]))
        let commandRow = ChatRowID.entry(ChatEntryID("command"))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let folded = try #require(controller.cellFrame(of: commandRow)).height

            controller.toggleFile(commandRow, path: "/p/held.txt")
            await Self.settle(controller)
            #expect(controller.isFileExpanded(commandRow, path: "/p/held.txt"))
            #expect(requested.isEmpty)
            // Twenty numbered lines open in place.
            #expect(try #require(controller.cellFrame(of: commandRow)).height > folded + 150)

            controller.toggleFile(commandRow, path: "/p/saved.txt")
            #expect(requested == [ChatEntryID("command")])
            controller.toggle(.entry(ChatEntryID("edit")))
            #expect(requested == [ChatEntryID("command"), ChatEntryID("edit")])

            controller.toggleFile(commandRow, path: "/p/held.txt")
            await Self.settle(controller)
            #expect(!controller.isFileExpanded(commandRow, path: "/p/held.txt"))
        }
    }

    @Test func aLongOutputScrollsInsideABoxOfItsOwn() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let short = ChatRowID.entry(ChatEntryID("short"))
        let long = ChatRowID.entry(ChatEntryID("long"))
        let rows = await ChatRowBuilder().rows(
            for: ChatTimelineInput(entries: [
                Self.tool("short", preview: ChatToolPreview(text: Self.outputLines(3), isTruncated: false), output: nil),
                Self.tool("long", preview: ChatToolPreview(text: Self.outputLines(200), isTruncated: false), output: nil),
            ]))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let folded = try #require(controller.cellFrame(of: short)).height

            controller.toggle(short)
            controller.toggle(long)
            await Self.settle(controller)

            // Three lines: the box hugs its text.
            #expect(try #require(controller.cellFrame(of: short)).height - folded < 100)
            // Two hundred: the box stops growing and scrolls.
            let grown = try #require(controller.cellFrame(of: long)).height - folded
            #expect(grown > 200)
            #expect(grown < 300)
        }
    }

    @Test func anotherConversationOpensAtItsEnd() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: Self.entries(0..<60)))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let view = controller.timeline
            Self.drag(controller, to: view.minOffsetY)
            await Self.settle(controller)
            #expect(!controller.isFollowing)

            let next = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: Self.entries(500..<540)))
            controller.apply(ChatTimelineState(generation: 2, revision: 1, rows: next, isReady: true))
            await Self.settle(controller)
            #expect(controller.isFollowing)
            #expect(abs(view.contentOffset.y - view.maxOffsetY) <= 0.5)
            #expect(controller.visibleRowIDs.last == next.last?.id)
        }
    }

    @Test func theFirstPositionedLayoutIsReportedOnceContentIsReady() async throws {
        var reports = 0
        var actions = ChatTimelineActions()
        actions.firstPositionedLayout = { reports += 1 }
        let controller = ChatTimelineController(actions: actions)
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: Self.entries(0..<10)))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(ChatTimelineState(generation: 1, revision: 1, rows: [], isReady: false))
            await Self.settle(controller)
            #expect(reports == 0)
            controller.apply(Self.state(rows, revision: 2))
            await Self.settle(controller)
            controller.apply(Self.state(rows, revision: 3))
            await Self.settle(controller)
            #expect(reports == 1)
        }
    }

    @Test func rowsAtRestClearTheChromeOverTheTopEdge() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: Self.entries(0..<40)))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let view = controller.timeline

            controller.setTopObstruction(52)
            await Self.settle(controller)
            #expect(controller.isFollowing)
            #expect(abs(view.contentOffset.y - view.maxOffsetY) <= 0.5)

            Self.drag(controller, to: view.minOffsetY)
            await Self.settle(controller)
            let first = try #require(rows.first.flatMap { Self.screenY(of: $0.id, in: controller) })
            #expect(first >= 52)

            controller.setTopObstruction(96)
            await Self.settle(controller)
            let moved = try #require(rows.first.flatMap { Self.screenY(of: $0.id, in: controller) })
            #expect(abs(moved - first - 44) <= 0.5)
        }
    }

    // MARK: Helpers

    private static func state(_ rows: [ChatRow], revision: Int = 1) -> ChatTimelineState {
        ChatTimelineState(generation: 1, revision: revision, rows: rows, isReady: true)
    }

    /// A conversation of user prompts, tool calls and answers of varied
    /// length; the same index always makes the same entry.
    nonisolated static func entries(_ range: Range<Int>) -> [ChatEntry] {
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

    private static func tool(
        _ id: String, preview: ChatToolPreview?, output: ChatOutputReference?,
        status: ChatToolActivity.Status = .succeeded, outputRead: ChatToolActivity.OutputRead? = nil
    ) -> ChatEntry {
        var tool = ChatToolActivity(
            kind: .command, name: "Bash", title: "make test", status: status, preview: preview, output: output)
        tool.outputRead = outputRead
        return ChatEntry(id: ChatEntryID(id), sourceOffset: 0, content: .tool(tool))
    }

    private static func outputLines(_ count: Int) -> String {
        (1...count).map { "line \($0) of the output" }.joined(separator: "\n")
    }

    /// A user scroll: the delegate sees a drag begin, the offset move, and
    /// the drag end without momentum.
    private static func drag(_ controller: ChatTimelineController, to offset: CGFloat) {
        let view = controller.timeline
        controller.scrollViewWillBeginDragging(view)
        view.contentOffset.y = min(max(offset, view.minOffsetY), view.maxOffsetY)
        controller.scrollViewDidEndDragging(view, willDecelerate: false)
    }

    /// Lays out until the content size and offset hold still: measuring a
    /// row can change the rows shown, which then measure in turn.
    private static func settle(_ controller: ChatTimelineController) async {
        let view = controller.timeline
        var last: (size: CGSize, offset: CGPoint)?
        var stable = 0
        for _ in 0..<200 {
            view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
            let now = (size: view.contentSize, offset: view.contentOffset)
            if let last, last.size == now.size, last.offset == now.offset {
                stable += 1
                if stable >= 3 { return }
            } else {
                stable = 0
            }
            last = now
        }
    }

    private static func screenY(of id: ChatRowID, in controller: ChatTimelineController) -> CGFloat? {
        controller.cellFrame(of: id).map { $0.minY - controller.timeline.contentOffset.y }
    }

    private static func firstFullyVisibleRow(_ controller: ChatTimelineController) -> (ChatRowID, CGFloat)? {
        let view = controller.timeline
        let top = view.contentOffset.y + view.adjustedContentInset.top
        for id in controller.visibleRowIDs {
            guard let frame = controller.cellFrame(of: id), frame.minY >= top else { continue }
            return (id, frame.minY - view.contentOffset.y)
        }
        return nil
    }
}

@MainActor
@Suite("Chat timeline model")
struct ChatTimelineModelTests {
    @Test func publishesTheNewestRequestAndNumbersConversations() async {
        let model = ChatTimelineModel()
        let entries = ChatTimelineControllerTests.entries(0..<5)
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
}

@Suite("Chat row builder")
struct ChatRowBuilderTests {
    @Test func unchangedEntriesKeepTheirRevisionAndChangedOnesMove() async {
        let builder = ChatRowBuilder()
        var entries = ChatTimelineControllerTests.entries(0..<4)
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
        let entries = ChatTimelineControllerTests.entries(0..<4)
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
        let entries = ChatTimelineControllerTests.entries(0..<2)
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
    private static let actions = ChatRowActions(
        toggle: { _ in }, loadOlder: {}, copy: { _ in }, selectText: { _ in }, missingOutputText: "")

    /// A cell is exactly as tall as its row measured and offers that height
    /// as the row's limit. A SwiftUI stack held to a limit shares it out by
    /// flexibility, which once cut the last line of a code block sitting
    /// between paragraphs and a list.
    @Test func aRowHeldToItsMeasuredHeightShowsAllOfIt() async {
        let answer = ChatEntry(
            id: ChatEntryID("answer"), sourceOffset: 0,
            content: .assistant(
                ChatAssistantMessage(
                    text: """
                        The retry keeps the cart. `retryPayment()` submits the same cart with `keepingItems: true`, and the flow tests cover a decline followed by a retry.

                        Two small suggestions:

                        - Clear the retry banner when the payment sheet closes, so it doesn't flash at the next checkout.
                        - Keep the banner state in one place:

                        ```swift
                        func sheetDidClose() {
                            banner = nil
                        }
                        ```

                        Before you commit, I'd like to run the UI test that covers a declined card.
                        """)))
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: [answer]))
        #expect(!rows.isEmpty)
        for row in rows {
            let host = UIHostingController(rootView: ChatRowView(row: row, isExpanded: false, actions: Self.actions))
            for width in stride(from: CGFloat(320), through: 440, by: 2) {
                let measured = host.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
                let laidOut = host.sizeThatFits(in: CGSize(width: width, height: measured.height))
                #expect(abs(laidOut.height - measured.height) <= 0.01, "at width \(width)")
            }
        }
    }
}
