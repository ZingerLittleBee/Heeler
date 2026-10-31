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

    @Test func imageContextMenuUsesRecordedPathAndCommitsToPreviewSheet() async throws {
        let path = "/tmp/actual.png"
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let entry = ChatEntry(id: ChatEntryID("image"), sourceOffset: 0, content: .tool(ChatToolActivity(
            kind: .image, name: "ImageView", title: "display-only.png", status: .succeeded, imagePath: path)))
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: [entry]))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let menu = try #require(controller.collectionView(controller.timeline,
                contextMenuConfigurationForItemsAt: [IndexPath(item: 0, section: 0)], point: .zero))
            #expect(menu.identifier as? String == path)
            let preview = ChatImagePreviewController(path: path) { _ in throw ChatImagePreviewError.missing }
            let animator = ImagePreviewCommitAnimator(preview: preview)
            controller.collectionView(controller.timeline, willPerformPreviewActionForMenuWith: menu, animator: animator)
            #expect(controller.presentedViewController == nil)
            animator.complete()
            let navigation = try #require(controller.presentedViewController as? UINavigationController)
            #expect(navigation.topViewController === preview)
            #expect(preview.path == path)
            // Let UIKit finish presenting before the window is retired.
            try await Task.sleep(for: .milliseconds(500))
            await withCheckedContinuation { continuation in
                controller.dismiss(animated: false) { continuation.resume() }
            }
        }
    }

    @Test func subagentHistoryStaysOpenWhenMoreEventsArrive() async throws {
        var outputRequests: [ChatEntryID] = []
        let controller = ChatTimelineController(actions: ChatTimelineActions(loadOutput: { outputRequests.append($0) }))
        let builder = ChatRowBuilder()
        func event(_ id: String, _ kind: String) -> ChatEntry {
            ChatEntry(id: ChatEntryID(id), sourceOffset: 0, content: .tool(ChatToolActivity(
                kind: .agent, name: "SubAgentActivity", title: "Subagent: worker", status: .noResult,
                subagentActivity: .init(agentPath: "/root/worker", events: [kind]))))
        }
        let first = event("start", "started")
        let id = ChatRowID.entry(first.id)
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(await builder.rows(for: ChatTimelineInput(entries: [first]))))
            await Self.settle(controller)
            let collapsed = try #require(controller.cellFrame(of: id)).height
            controller.toggle(id)
            await Self.settle(controller)
            let expanded = try #require(controller.cellFrame(of: id)).height
            #expect(expanded > collapsed)

            let rows = await builder.rows(for: ChatTimelineInput(entries: [first, event("message", "interacted")]))
            controller.apply(Self.state(rows, revision: 2))
            await Self.settle(controller)
            #expect(controller.visibleRowIDs == [id])
            #expect(try #require(controller.cellFrame(of: id)).height > expanded)
            #expect(outputRequests.isEmpty)

            controller.toggle(id)
            await Self.settle(controller)
            #expect(try #require(controller.cellFrame(of: id)).height < expanded)
        }
    }

    /// The app applies from inside a SwiftUI update. A pending message whose
    /// status line appears there once grew to its new height but kept
    /// drawing only its bubble, so the line stayed blank until something
    /// else laid the row out.
    @Test func aRowThatGrowsInsideASwiftUIUpdateDrawsWhatItGrewBy() async throws {
        let builder = ChatRowBuilder()
        let entries = Self.entries(0..<6)
        var echo = ChatPendingEcho(id: UUID(), text: "say KIWI", state: .sent)
        func timeline(revision: Int) async -> ChatTimelineView {
            let rows = await builder.rows(for: ChatTimelineInput(entries: entries, pending: [echo]))
            return ChatTimelineView(
                state: Self.state(rows, revision: revision), jumpRequest: 0, followRequest: 0,
                actions: ChatTimelineActions())
        }
        let host = UIHostingController(rootView: await timeline(revision: 1))
        try await withTestWindow(frame: Self.frame, rootViewController: host) { _ in
            // Waits without laying anything out, which would draw the row.
            @MainActor func newestCell() async throws -> UICollectionViewCell {
                for _ in 0..<100 {
                    if let view = Self.collectionView(in: host.view),
                        let cell = view.visibleCells.max(by: { $0.frame.maxY < $1.frame.maxY })
                    {
                        return cell
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                throw CancellationError()
            }
            let before = try await newestCell().bounds.height
            echo.state = .unconfirmed
            host.rootView = await timeline(revision: 2)
            for _ in 0..<100 {
                if try await newestCell().bounds.height > before { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(200))
            let cell = try await newestCell()
            #expect(cell.bounds.height > before)
            // The status line is the row's bottom; the bubble ends above it.
            #expect(Self.drawsAnything(in: cell.contentView, bottom: 12))
        }
    }

    /// Chat's own text size and font reach the hosted rows through the
    /// controller's traits and re-measure them.
    @Test func chatTextSizeAndFontRemeasureTheRows() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let entries = Self.entries(2..<3)
        let id = ChatRowID.entry(try #require(entries.first).id)
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: entries))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            controller.setTypography(size: .large, font: .system)
            await Self.settle(controller)
            let large = try #require(controller.cellFrame(of: id)).height

            controller.setTypography(size: .xSmall, font: .system)
            await Self.settle(controller)
            let small = try #require(controller.cellFrame(of: id)).height
            #expect(small < large)

            // Monospaced letters are wider, so the paragraph takes more lines.
            controller.setTypography(size: .xSmall, font: .monospaced)
            await Self.settle(controller)
            #expect(try #require(controller.cellFrame(of: id)).height > small)

            controller.setTypography(size: nil, font: .system)
            await Self.settle(controller)
            #expect(controller.timeline.traitCollection.preferredContentSizeCategory
                == controller.view.window?.traitCollection.preferredContentSizeCategory)
        }
    }

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

    /// A row above the screen measured while a drag or its bounce holds
    /// the list past its end keeps its old height: the offset adjustment
    /// for it would be clamped to the new end under UIKit's own tracking,
    /// which throws the rows out. Hosted tests cannot hold an overscroll
    /// (nothing tracks, so UIKit clamps it at the next layout), so the
    /// layout is told directly; it takes the height once the list is back.
    @Test func aRowMeasuredAboveWaitsWhileTheListIsPastItsEnd() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: Self.entries(0..<60)))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let view = controller.timeline
            let layout = try #require(view.collectionViewLayout as? ChatTimelineLayout)
            Self.drag(controller, to: view.maxOffsetY - 400)
            await Self.settle(controller)
            let (anchor, before) = try #require(Self.firstFullyVisibleRow(controller))
            let above = IndexPath(item: try #require(layout.index(of: anchor)) - 3, section: 0)
            let original = try #require(layout.layoutAttributesForItem(at: above))
            let measured = try #require(original.copy() as? UICollectionViewLayoutAttributes)
            measured.size.height += 40
            let offset = view.contentOffset.y

            var pastEnd = true
            layout.isPastEnd = { pastEnd }
            #expect(!layout.shouldInvalidateLayout(forPreferredLayoutAttributes: measured, withOriginalAttributes: original))
            view.layoutIfNeeded()
            #expect(abs((layout.layoutAttributesForItem(at: above)?.size.height ?? 0) - original.size.height) <= 0.5)
            #expect(abs(view.contentOffset.y - offset) <= 0.5)

            pastEnd = false
            layout.applyHeldHeights()
            view.layoutIfNeeded()
            #expect(abs((layout.layoutAttributesForItem(at: above)?.size.height ?? 0) - measured.size.height) <= 0.5)
            #expect(abs(view.contentOffset.y - (offset + 40)) <= 0.5)
            #expect(abs(try #require(Self.screenY(of: anchor, in: controller)) - before) <= 0.5)
        }
    }

    /// Rows arriving while a drag holds the list past its end wait until it
    /// is back: applying them clamps the offset to the new end, and the drag
    /// pulls it back on its next frame, so the rows flash by the overscroll.
    @Test func rowsArrivingWhileTheListIsPastItsEndWaitUntilItIsBack() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let builder = ChatRowBuilder()
        let rows = await builder.rows(for: ChatTimelineInput(entries: Self.entries(0..<60)))
        let more = await builder.rows(for: ChatTimelineInput(entries: Self.entries(0..<61)))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let view = controller.timeline
            let count = view.numberOfItems(inSection: 0)

            controller.scrollViewWillBeginDragging(view)
            let pulled = view.maxOffsetY + 100
            view.contentOffset.y = pulled
            controller.apply(Self.state(more, revision: 2))
            #expect(abs(view.contentOffset.y - pulled) <= 0.5)
            #expect(view.numberOfItems(inSection: 0) == count)

            // The bounce brings the list back to its end.
            view.contentOffset.y = view.maxOffsetY
            #expect(view.numberOfItems(inSection: 0) == count + 1)
        }
    }

    @Test func olderRowsLoadedUnderTheLoadEarlierRowKeepTheReadersRowInPlace() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let builder = ChatRowBuilder()
        let newer = await builder.rows(
            for: ChatTimelineInput(entries: Self.entries(200..<260), older: .available))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(newer))
            await Self.settle(controller)
            let view = controller.timeline
            Self.drag(controller, to: view.minOffsetY)
            await Self.settle(controller)
            try #require(controller.visibleRowIDs.contains(.olderHistory))
            let (anchor, before) = try #require(Self.firstFullyVisibleRow(controller) { $0 != .olderHistory })

            let more = await builder.rows(
                for: ChatTimelineInput(entries: Self.entries(100..<260), older: .available))
            controller.apply(Self.state(more, revision: 2))
            await Self.settle(controller)
            let after = try #require(Self.screenY(of: anchor, in: controller))
            #expect(abs(after - before) <= 0.5)
            #expect(!controller.visibleRowIDs.contains(.olderHistory))
        }
    }

    /// Scrolling to the top loads nothing by itself; a pull past it loads
    /// earlier history for the user once the finger lifts.
    @Test func pullingPastTheTopLoadsEarlierHistoryWhenReleased() async throws {
        var automatic = 0
        var user = 0
        let controller = ChatTimelineController(
            actions: ChatTimelineActions(loadOlder: { user += 1 }, loadOlderAutomatically: { automatic += 1 }))
        let rows = await ChatRowBuilder().rows(
            for: ChatTimelineInput(entries: Self.entries(200..<260), older: .available))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let view = controller.timeline
            Self.drag(controller, to: view.minOffsetY)
            await Self.settle(controller)
            #expect(automatic == 0)
            #expect(user == 0)

            Self.pull(controller, by: ChatTimelineController.pullToLoadDistance - 20)
            #expect(user == 0)

            // Pushed back inside the distance before letting go: no request.
            controller.scrollViewWillBeginDragging(view)
            view.contentOffset.y = view.minOffsetY - ChatTimelineController.pullToLoadDistance - 10
            view.contentOffset.y = view.minOffsetY - 30
            controller.scrollViewDidEndDragging(view, willDecelerate: true)
            #expect(user == 0)

            controller.scrollViewWillBeginDragging(view)
            view.contentOffset.y = view.minOffsetY - ChatTimelineController.pullToLoadDistance - 10
            #expect(user == 0)
            controller.scrollViewDidEndDragging(view, willDecelerate: true)
            #expect(user == 1)
            #expect(automatic == 0)
        }
    }

    /// The Load Earlier row follows a pull: a hint while pulling, Release
    /// while letting go would load, then loading until the row shows it. A
    /// pull let go short of that keeps its hint until it bounces back.
    @Test func theLoadEarlierRowFollowsAPull() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let builder = ChatRowBuilder()
        let available = await builder.rows(
            for: ChatTimelineInput(entries: Self.entries(200..<260), older: .available))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(available))
            await Self.settle(controller)
            let view = controller.timeline
            Self.drag(controller, to: view.minOffsetY)
            await Self.settle(controller)
            let distance = ChatTimelineController.pullToLoadDistance

            controller.scrollViewWillBeginDragging(view)
            view.contentOffset.y = view.minOffsetY - 30
            #expect(controller.olderPullPhase == .pulling)
            controller.scrollViewDidEndDragging(view, willDecelerate: true)
            #expect(controller.olderPullPhase == .pulling)
            view.contentOffset.y = view.minOffsetY
            #expect(controller.olderPullPhase == .idle)

            controller.scrollViewWillBeginDragging(view)
            view.contentOffset.y = view.minOffsetY - distance - 10
            #expect(controller.olderPullPhase == .armed)
            view.contentOffset.y = view.minOffsetY - 30
            #expect(controller.olderPullPhase == .pulling)
            view.contentOffset.y = view.minOffsetY - distance - 10
            #expect(controller.olderPullPhase == .armed)
            controller.scrollViewDidEndDragging(view, willDecelerate: true)
            #expect(controller.olderPullPhase == .requested)

            let loading = await builder.rows(
                for: ChatTimelineInput(entries: Self.entries(200..<260), older: .loading))
            controller.apply(Self.state(loading, revision: 2))
            #expect(controller.olderPullPhase == .idle)
        }
    }

    /// Rows that don't fill the screen ask for earlier history by
    /// themselves, which Chat bounds for Grok Build.
    @Test func aShortListAsksForEarlierHistoryByItself() async throws {
        var automatic = 0
        var user = 0
        let controller = ChatTimelineController(
            actions: ChatTimelineActions(loadOlder: { user += 1 }, loadOlderAutomatically: { automatic += 1 }))
        let rows = await ChatRowBuilder().rows(
            for: ChatTimelineInput(entries: Self.entries(200..<202), older: .available))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            #expect(automatic == 1)
            #expect(user == 0)
        }
    }

    @Test func aLoadEarlierRowThatGrowsAtTheTopStaysInView() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let builder = ChatRowBuilder()
        let available = await builder.rows(
            for: ChatTimelineInput(entries: Self.entries(200..<260), older: .available))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(available))
            await Self.settle(controller)
            let view = controller.timeline
            Self.drag(controller, to: view.minOffsetY)
            await Self.settle(controller)
            let before = try #require(Self.screenY(of: .olderHistory, in: controller))

            let message = String(repeating: "Heeler couldn't read earlier messages from the Host. ", count: 4)
            let failed = await builder.rows(
                for: ChatTimelineInput(entries: Self.entries(200..<260), older: .failed(message)))
            controller.apply(Self.state(failed, revision: 2))
            await Self.settle(controller)
            let after = try #require(Self.screenY(of: .olderHistory, in: controller))
            #expect(abs(after - before) <= 0.5)
            #expect(abs(view.contentOffset.y - view.minOffsetY) <= 0.5)
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

    @Test("Opening at latest keeps the chosen top and pushes later rows down",
          arguments: ["tool", "subagent", "group"], [false, true])
    func expandingAtLatestPreservesTheDisclosureTop(kind: String, shortConversation: Bool) async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        var entries = shortConversation ? [] : Self.entries(0..<40)
        let target: ChatRowID
        if kind == "subagent" {
            let id = ChatEntryID("worker")
            entries.append(ChatEntry(id: id, sourceOffset: 4_000, content: .tool(ChatToolActivity(
                kind: .agent, name: "SubAgentActivity", title: "Subagent: worker", status: .noResult,
                subagentActivity: .init(agentPath: "/root/worker", events: [
                    "started", "interacted", "completed", "started", "interacted", "completed",
                ])))))
            target = .entry(id)
        } else {
            let count = kind == "group" ? 5 : 1
            for index in 0..<count {
                var entry = Self.tool("preview-\(index)",
                    preview: ChatToolPreview(text: Self.outputLines(20), isTruncated: false), output: nil)
                if kind == "tool", !shortConversation, case .tool(var tool) = entry.content {
                    tool.title = (1...20).map { "sed -n '\($0),\($0 + 20)p' Sources/Heeler/Chat/Timeline/ChatRowView.swift" }
                        .joined(separator: "\n")
                    entry.content = .tool(tool)
                }
                entries.append(entry)
            }
            target = kind == "group" ? .group(ChatEntryID("preview-4")) : .entry(ChatEntryID("preview-0"))
        }
        entries.append(ChatEntry(id: ChatEntryID("after"), sourceOffset: 5_000,
            content: .assistant(ChatAssistantMessage(text: "The next row stays below the expanded content."))))
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: entries))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            #expect(controller.isFollowing)
            let before = try #require(Self.screenY(of: target, in: controller))
            let afterRowBefore = controller.geometry.minY(at: controller.geometry.count - 1)
            @MainActor func capture(_ state: String) {
                guard kind == "tool", !shortConversation else { return }
                let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
                let image = renderer.image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                Attachment.record(image, named: "chat-long-command-\(state)", as: .png)
            }
            capture("collapsed")

            controller.toggle(target)
            await Self.settle(controller)
            capture("expanded")
            #expect(abs(try #require(Self.screenY(of: target, in: controller)) - before) <= 0.5)
            #expect(controller.geometry.minY(at: controller.geometry.count - 1) > afterRowBefore + 40)
            #expect(!controller.isFollowing)

            // A later layout must not quietly re-arm bottom following.
            controller.timeline.setNeedsLayout()
            await Self.settle(controller)
            #expect(abs(try #require(Self.screenY(of: target, in: controller)) - before) <= 0.5)

            controller.toggle(target)
            await Self.settle(controller)
            #expect(controller.isFollowing)
            #expect(abs(try #require(Self.screenY(of: target, in: controller)) - before) <= 0.5)
            controller.toggle(target)
            await Self.settle(controller)
            controller.followLatest()
            await Self.settle(controller)
            #expect(controller.isFollowing)
            #expect(abs(controller.timeline.contentOffset.y - controller.timeline.maxOffsetY) <= 0.5)
        }
    }

    @Test func outputArrivingAfterExpansionKeepsTheChosenTop() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let builder = ChatRowBuilder()
        let id = ChatRowID.entry(ChatEntryID("loading"))
        let reference = ChatOutputReference(offset: 0, length: 10)
        func entries(_ preview: ChatToolPreview?) -> [ChatEntry] {
            Self.entries(0..<40) + Self.apart([Self.tool("loading", preview: preview, output: reference)])
        }
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(await builder.rows(for: ChatTimelineInput(entries: entries(nil)))))
            await Self.settle(controller)
            let before = try #require(Self.screenY(of: id, in: controller))
            controller.toggle(id)
            await Self.settle(controller)
            #expect(abs(try #require(Self.screenY(of: id, in: controller)) - before) <= 0.5)
            #expect(!controller.isFollowing)

            let loaded = ChatToolPreview(text: Self.outputLines(40), isTruncated: false)
            controller.apply(Self.state(await builder.rows(for: ChatTimelineInput(entries: entries(loaded))), revision: 2))
            await Self.settle(controller)
            #expect(abs(try #require(Self.screenY(of: id, in: controller)) - before) <= 0.5)
            #expect(!controller.isFollowing)
        }
    }

    @Test func aPartiallyClippedDisclosureGrowsDownwardWhenOutputArrives() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let builder = ChatRowBuilder()
        let id = ChatRowID.entry(ChatEntryID("e21"))
        var entries = Self.entries(0..<60)
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(await builder.rows(for: ChatTimelineInput(entries: entries))))
            await Self.settle(controller)
            // Leave the top few points of the tool outside the viewport.
            Self.drag(controller, to: controller.geometry.minY(at: 21) + 8)
            await Self.settle(controller)
            let before = try #require(Self.screenY(of: id, in: controller))
            #expect(before < controller.timeline.adjustedContentInset.top)
            controller.toggle(id)
            await Self.settle(controller)
            #expect(abs(try #require(Self.screenY(of: id, in: controller)) - before) <= 0.5)

            guard case .tool(var tool) = entries[21].content else { return }
            tool.preview = ChatToolPreview(text: Self.outputLines(60), isTruncated: false)
            entries[21].content = .tool(tool)
            controller.apply(Self.state(await builder.rows(for: ChatTimelineInput(entries: entries)), revision: 2))
            await Self.settle(controller)
            #expect(abs(try #require(Self.screenY(of: id, in: controller)) - before) <= 0.5)

            // A real drag releases the disclosure anchor and can resume follow.
            Self.drag(controller, to: controller.timeline.maxOffsetY)
            await Self.settle(controller)
            #expect(controller.isFollowing)
        }
    }

    @Test func expandingAToolRowAsksForOutputItHasNoneOrOnlyTheStartOf() async throws {
        var requested: [ChatEntryID] = []
        var actions = ChatTimelineActions()
        actions.loadOutput = { requested.append($0) }
        let controller = ChatTimelineController(actions: actions)
        let reference = ChatOutputReference(offset: 0, length: 10)
        let entries = Self.apart([
            Self.tool("cut", preview: ChatToolPreview(text: "line 1", isTruncated: true), output: reference),
            Self.tool("whole", preview: ChatToolPreview(text: "line 1", isTruncated: false), output: reference),
            Self.tool("saved", preview: nil, output: reference),
            Self.tool("running", preview: nil, output: nil, status: .running),
            // A call that never ran has no output to read (CLB-02/03/04).
            Self.tool("declined", preview: nil, output: reference, status: .declined),
            Self.tool("interrupted", preview: nil, output: reference, status: .interrupted),
        ])
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
            for: ChatTimelineInput(
                entries: Self.apart([
                    ChatEntry(id: ChatEntryID("command"), sourceOffset: 0, content: .tool(command)),
                    ChatEntry(id: ChatEntryID("edit"), sourceOffset: 1, content: .tool(edit)),
                ])))
        let commandRow = ChatRowID.entry(ChatEntryID("command"))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let folded = try #require(controller.cellFrame(of: commandRow)).height
            let before = try #require(Self.screenY(of: commandRow, in: controller))

            controller.toggleFile(commandRow, path: "/p/held.txt")
            await Self.settle(controller)
            #expect(controller.isFileExpanded(commandRow, path: "/p/held.txt"))
            #expect(abs(try #require(Self.screenY(of: commandRow, in: controller)) - before) <= 0.5)
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
            for: ChatTimelineInput(
                entries: Self.apart([
                    Self.tool("short", preview: ChatToolPreview(text: Self.outputLines(3), isTruncated: false), output: nil),
                    Self.tool("long", preview: ChatToolPreview(text: Self.outputLines(200), isTruncated: false), output: nil),
                ])))
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

    @Test func rowsAtRestClearTheChromeOverTheBottomEdge() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: Self.entries(0..<40)))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let view = controller.timeline
            let newest = try #require(rows.last?.id)

            controller.setBottomEdge(Self.frame.maxY - 120)
            await Self.settle(controller)
            #expect(controller.isFollowing)
            // The list still runs under the chrome; only its rows stop short.
            #expect(view.bounds.height == Self.frame.height)
            let resting = try #require(Self.screenMaxY(of: newest, in: controller))
            #expect(resting <= Self.frame.height - 120)
            #expect(resting >= Self.frame.height - 120 - 24)

            controller.setBottomEdge(Self.frame.maxY - 200)
            await Self.settle(controller)
            let lifted = try #require(Self.screenMaxY(of: newest, in: controller))
            #expect(abs(lifted - resting + 80) <= 0.5)

            // Chrome that begins below the list's own bottom edge, as
            // under a list SwiftUI stops short of the screen's, covers
            // none of it.
            controller.setBottomEdge(Self.frame.maxY + 40)
            await Self.settle(controller)
            let unobstructed = try #require(Self.screenMaxY(of: newest, in: controller))
            #expect(abs(unobstructed - resting - 120) <= 0.5)

            // Room given back leaves no blank space past the end.
            controller.setBottomEdge(nil)
            await Self.settle(controller)
            #expect(abs(view.contentOffset.y - view.maxOffsetY) <= 0.5)
            let lowered = try #require(Self.screenMaxY(of: newest, in: controller))
            #expect(abs(lowered - resting - 120) <= 0.5)
        }
    }

    @Test func theFoldIsSpreadOverTheKeyboardsFallSoRowsNeverReverse() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: Self.entries(0..<40)))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let view = controller.timeline
            let bottom = Self.frame.maxY
            controller.setBottomEdge(bottom - 500, keyboardLift: 300)
            await Self.settle(controller)
            let raised = view.contentInset.bottom

            // The chrome grows by 80 at the start of the fall: nothing moves yet.
            controller.setBottomEdge(bottom - 580, keyboardLift: 300, keyboardIsFalling: true)
            #expect(view.contentInset.bottom == raised)

            var previous = raised
            for lift: CGFloat in [240, 150, 60, 10, 0] {
                let chrome: CGFloat = 280
                controller.setBottomEdge(
                    bottom - (chrome + lift), keyboardLift: lift, keyboardIsFalling: true)
                #expect(view.contentInset.bottom < previous)
                previous = view.contentInset.bottom
            }
            // At the end it is the grown chrome's, without the keyboard.
            #expect(abs(raised - previous - (300 - 80)) <= 0.5)
        }
    }

    @Test func aChromeChangeOverARestingKeyboardAppliesAtOnce() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: Self.entries(0..<40)))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.state(rows))
            await Self.settle(controller)
            let view = controller.timeline
            let bottom = Self.frame.maxY
            controller.setBottomEdge(bottom - 500, keyboardLift: 300)
            await Self.settle(controller)
            let before = view.contentInset.bottom

            // A longer draft, with no fall to spread it over.
            controller.setBottomEdge(bottom - 540, keyboardLift: 300)
            #expect(abs(view.contentInset.bottom - before - 40) <= 0.5)
        }
    }

    // MARK: Folds

    @Test func openingAFinishedTurnKeepsItsHeaderWhereItWas() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let (rows, turns) = await Self.turns(0..<12)
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.foldState(rows, turns: turns))
            await Self.settle(controller)
            let view = controller.timeline
            Self.drag(controller, to: view.maxOffsetY - 900)
            await Self.settle(controller)
            let header = try #require(Self.firstFullyVisibleRow(controller, where: { if case .turn = $0 { true } else { false } }))
            guard case .turn(let answer) = header.0 else { return }
            let index = try #require(Int(answer.rawValue.dropFirst()))

            controller.toggle(header.0)
            await Self.settle(controller)
            #expect(controller.isOpen(header.0))
            #expect(abs(try #require(Self.screenY(of: header.0, in: controller)) - header.1) <= 0.5)
            // Its group shows below it, closed.
            #expect(controller.visibleRowIDs.contains(.group(ChatEntryID("c\(index)b"))))
            #expect(!controller.visibleRowIDs.contains(.entry(ChatEntryID("c\(index)a"))))

            controller.toggle(header.0)
            await Self.settle(controller)
            #expect(!controller.isOpen(header.0))
            #expect(abs(try #require(Self.screenY(of: header.0, in: controller)) - header.1) <= 0.5)
            #expect(!controller.visibleRowIDs.contains(.group(ChatEntryID("c\(index)b"))))
        }
    }

    @Test func openingTheLastTurnWhileFollowingShowsWhatItHeld() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let (rows, turns) = await Self.turns(0..<6)
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.foldState(rows, turns: turns))
            await Self.settle(controller)
            #expect(controller.isFollowing)
            let header = ChatRowID.turn(ChatEntryID("a5"))
            let before = try #require(Self.screenY(of: header, in: controller))

            controller.toggle(header)
            await Self.settle(controller)
            #expect(abs(try #require(Self.screenY(of: header, in: controller)) - before) <= 0.5)
            #expect(!controller.isFollowing)
        }
    }

    /// Once earlier messages wait for the user, the rows above the first
    /// loaded turn fold when the state's record of their turn's end closes
    /// it, though the Agent works on a turn the rows do not show yet.
    @Test func rowsAboveTheFirstLoadedTurnFoldOnTheEndTheStateRecords() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        func command(_ id: String, at offset: UInt64) -> ChatEntry {
            ChatEntry(
                id: ChatEntryID(id), sourceOffset: offset,
                content: .tool(ChatToolActivity(kind: .command, name: "Bash", title: id, status: .succeeded)))
        }
        let answer = ChatEntry(
            id: ChatEntryID("a0"), sourceOffset: 2, content: .assistant(ChatAssistantMessage(text: "Done.")))
        let rows = await ChatRowBuilder().rows(
            for: ChatTimelineInput(entries: [command("c0", at: 0), command("c1", at: 1), answer], older: .available))
        let signals = ChatTurnSignals(activity: .working, olderAwaitsUser: true)
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(ChatTimelineState(generation: 1, revision: 1, rows: rows, isReady: true, signals: signals))
            await Self.settle(controller)
            #expect(controller.visibleRowIDs.contains(.group(ChatEntryID("c1"))))
            #expect(!controller.visibleRowIDs.contains(.turn(ChatEntryID("a0"))))

            controller.apply(
                ChatTimelineState(
                    generation: 1, revision: 2, rows: rows, isReady: true,
                    precedingTurnEnd: ChatTurnEnd(ending: .completed), signals: signals))
            await Self.settle(controller)
            #expect(controller.visibleRowIDs.contains(.turn(ChatEntryID("a0"))))
            #expect(!controller.visibleRowIDs.contains(.group(ChatEntryID("c1"))))
        }
    }

    @Test func aTurnThatFinishesUnderTheReaderPutsItsHeaderWhereTheyWere() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let (rows, turns) = await Self.turns(0..<3, steps: 16, answerLength: 120)
        var running = turns
        running[running.count - 1].endedAt = nil
        running[running.count - 1].ending = nil
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.foldState(rows, turns: running, activity: .working))
            await Self.settle(controller)
            let view = controller.timeline
            // Among the last turn's steps, its answer out of sight. Steps
            // measure shorter than their estimates as they come on screen and
            // can pull the answer back up, so drag again from where it lands.
            for _ in 0..<3 {
                guard let answer = controller.cellFrame(of: .entry(ChatEntryID("a2"))) else { break }
                Self.drag(controller, to: answer.minY - view.bounds.height - 600)
                await Self.settle(controller)
            }
            #expect(!controller.visibleRowIDs.contains(.entry(ChatEntryID("a2"))))
            let top = view.contentOffset.y + view.adjustedContentInset.top
            let first = try #require(controller.visibleRowIDs.first)
            let offset = try #require(controller.cellFrame(of: first)).minY - top

            controller.apply(Self.foldState(rows, turns: turns, activity: .idle, revision: 2))
            await Self.settle(controller)
            let header = try #require(controller.cellFrame(of: .turn(ChatEntryID("a2"))))
            // Where the first row was, or at the top when it started above it.
            #expect(abs(header.minY - (view.contentOffset.y + view.adjustedContentInset.top) - max(offset, 0)) <= 0.5)
            #expect(!controller.isFollowing)
        }
    }

    @Test func aFoldKeepsWhatItsRowsHadOpenAndTheirHeights() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        // Steps enough to run past the screen, where nothing measures again.
        let (rows, turns) = await Self.turns(0..<4, steps: 12)
        let header = ChatRowID.turn(ChatEntryID("a1"))
        let group = ChatRowID.group(ChatEntryID("c1b"))
        let member = ChatRowID.entry(ChatEntryID("c1a"))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.foldState(rows, turns: turns))
            await Self.settle(controller)
            Self.drag(controller, to: controller.timeline.minOffsetY)
            await Self.settle(controller)
            controller.toggle(header)
            controller.toggle(group)
            await Self.settle(controller)
            let closed = try #require(controller.cellFrame(of: member)).height
            controller.toggle(member)
            await Self.settle(controller)
            let open = try #require(controller.cellFrame(of: member)).height
            #expect(open > closed + 40)
            let height = controller.timeline.contentSize.height

            controller.toggle(header)
            await Self.settle(controller)
            #expect(controller.cellFrame(of: member) == nil)
            // The transcript moves on while the turn is folded.
            controller.apply(Self.foldState(rows, turns: turns, revision: 2))
            await Self.settle(controller)

            controller.toggle(header)
            // Laid out from what was measured, before any cell measures again.
            #expect(abs(controller.timeline.contentSize.height - height) <= 0.5)
            await Self.settle(controller)
            #expect(controller.isOpen(group))
            #expect(abs(try #require(controller.cellFrame(of: member)).height - open) <= 0.5)
        }
    }

    @Test func aRowExpandedBeforeItsTurnFoldedReadsItsOutputWhenShownAgain() async throws {
        var requested: [ChatEntryID] = []
        var actions = ChatTimelineActions()
        actions.loadOutput = { requested.append($0) }
        let controller = ChatTimelineController(actions: actions)
        let builder = ChatRowBuilder()
        let id = ChatEntryID("step")
        let start = Date(timeIntervalSince1970: 1_791_266_142)
        let prompt = ChatEntry(id: ChatEntryID("u0"), sourceOffset: 0, content: .user(ChatUserMessage(text: "Go")))
        let answer = ChatEntry(id: ChatEntryID("a0"), sourceOffset: 2, content: .assistant(ChatAssistantMessage(text: "Done")))
        var running = ChatTurn(firstEntryID: ChatEntryID("u0"), startedAt: start)
        let before = await builder.rows(
            for: ChatTimelineInput(entries: [prompt, Self.tool("step", preview: nil, output: nil, status: .running)]))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.foldState(before, turns: [running], activity: .working))
            await Self.settle(controller)
            controller.toggle(.entry(id))

            // The turn ends and folds the row away as its output arrives.
            running.endedAt = start + 35
            running.ending = .completed
            let after = await builder.rows(
                for: ChatTimelineInput(entries: [
                    prompt,
                    Self.tool(
                        "step", preview: ChatToolPreview(text: "line 1", isTruncated: true),
                        output: ChatOutputReference(offset: 0, length: 10)),
                    answer,
                ]))
            controller.apply(Self.foldState(after, turns: [running], revision: 2))
            await Self.settle(controller)
            #expect(controller.cellFrame(of: .entry(id)) == nil)
            #expect(requested.isEmpty)

            controller.toggle(.turn(ChatEntryID("a0")))
            await Self.settle(controller)
            #expect(requested == [id])
        }
    }

    @Test func floatingCollapseFoldsOnlyTheReadTurnAndBringsItsOffscreenHeaderBack() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let (rows, turns) = await Self.turns(0..<3, steps: 8, answerLength: 10)
        let header = ChatRowID.turn(ChatEntryID("a0"))
        let other = ChatRowID.turn(ChatEntryID("a1"))
        let group = ChatRowID.group(ChatEntryID("c0b"))
        let member = ChatRowID.entry(ChatEntryID("c0a"))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.foldState(rows, turns: turns))
            await Self.settle(controller)
            Self.drag(controller, to: controller.timeline.minOffsetY)
            controller.toggle(other)
            controller.toggle(header)
            controller.toggle(group)
            controller.toggle(member)
            await Self.settle(controller)
            let expandedHeight = try #require(controller.cellFrame(of: member)).height
            Self.drag(controller, to: try #require(controller.cellFrame(of: member)).minY + 160)
            await Self.settle(controller)
            #expect(!controller.visibleRowIDs.contains(header))
            #expect(controller.canCollapseTrajectory)

            controller.collapseCurrentTrajectory()
            await Self.settle(controller)
            #expect(!controller.isOpen(header))
            #expect(controller.isOpen(other))
            // The other turn, still open, comes into view under the fold.
            #expect(controller.visibleRowIDs.contains(other))
            #expect(controller.canCollapseTrajectory)
            #expect(abs(try #require(Self.screenY(of: header, in: controller))
                - controller.timeline.adjustedContentInset.top) <= 1)

            controller.toggle(header)
            await Self.settle(controller)
            #expect(!controller.isOpen(group))
            controller.toggle(group)
            await Self.settle(controller)
            #expect(try #require(controller.cellFrame(of: member)).height < expandedHeight - 40)
        }
    }

    @Test(arguments: ["running", "interrupted"])
    func floatingCollapseRevealsTheEndOfAShortTurnWithoutTrailingBlankSpace(mode: String) async throws {
        var availability: [Bool] = []
        let controller = ChatTimelineController(actions: ChatTimelineActions(
            collapseAvailabilityChanged: { availability.append($0) }))
        let question = ChatEntry(id: ChatEntryID("q"), sourceOffset: 0, content: .user(.init(text: "Question")))
        let reasoning = ChatEntry(id: ChatEntryID("r"), sourceOffset: 1,
            content: .reasoning(.init(text: String(repeating: "A long reasoning line.\n", count: 150))))
        let answer = ChatEntry(id: ChatEntryID("a"), sourceOffset: 4, content: .assistant(.init(text: "Continuing.")))
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: [
            question, reasoning,
            Self.tool("t1", preview: ChatToolPreview(text: "one", isTruncated: false), output: nil),
            Self.tool("t2", preview: ChatToolPreview(text: "two", isTruncated: false), output: nil), answer,
        ]))
        let turn = ChatTurn(firstEntryID: question.id, startedAt: .now,
            endedAt: mode == "running" ? nil : .now, ending: mode == "running" ? nil : .interrupted)
        let activity: ChatAgentActivity = mode == "running" ? .working : .idle
        let id = ChatRowID.entry(reasoning.id)
        let group = ChatRowID.group(ChatEntryID("t2"))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.foldState(rows, turns: [turn], activity: activity))
            await Self.settle(controller)
            #expect(!controller.canCollapseTrajectory)
            controller.toggle(id)
            controller.toggle(group)
            await Self.settle(controller)
            Self.drag(controller, to: try #require(controller.cellFrame(of: id)).minY + 300)
            await Self.settle(controller)
            #expect(controller.canCollapseTrajectory)
            #expect(availability.last == true)

            controller.collapseCurrentTrajectory()
            await Self.settle(controller)
            #expect(!controller.canCollapseTrajectory)
            #expect(availability.last == false)
            #expect(!controller.isOpen(group))
            #expect(!controller.isFollowing)
            // A short last turn must rest against the composer, rather than
            // manufacturing a viewport of trailing space to pin its header.
            let end = try #require(controller.cellFrame(of: .entry(answer.id))).maxY
            #expect(abs(controller.timeline.contentSize.height - end) <= 1)
            #expect(controller.visibleRowIDs.contains(.entry(answer.id)))
            #expect(controller.visibleRowIDs.contains(id))
            let heldHeight = controller.timeline.contentSize.height
            controller.followLatest()
            await Self.settle(controller)
            #expect(controller.isFollowing)
            #expect(abs(controller.timeline.contentSize.height - heldHeight) <= 1)
        }
    }

    @Test func floatingCollapseKeepsTheNewestRowClearOfItsButton() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let (rows, turns) = await Self.turns(0..<2, steps: 8)
        let newest = ChatRowID.entry(ChatEntryID("a1"))
        let clearance: CGFloat = 56
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.setCollapseControlClearance(clearance)
            controller.apply(Self.foldState(rows, turns: turns))
            await Self.settle(controller)
            Self.drag(controller, to: controller.timeline.minOffsetY)
            controller.toggle(.turn(ChatEntryID("a0")))
            controller.toggle(.group(ChatEntryID("c0b")))
            controller.followLatest()
            await Self.settle(controller)
            try #require(controller.canCollapseTrajectory)
            let view = controller.timeline
            let bottom = try #require(controller.cellFrame(of: newest)).maxY - view.contentOffset.y
            #expect(bottom <= view.bounds.height - 12 - clearance + 1)

            controller.collapseCurrentTrajectory()
            await Self.settle(controller)
            #expect(!controller.canCollapseTrajectory)
            // The room goes with the button, leaving no blank space past the end.
            #expect(abs(view.contentOffset.y - view.maxOffsetY) <= 1)
            #expect(abs(view.contentSize.height + 12 - view.contentOffset.y - view.bounds.height) <= 1)
        }
    }

    /// Opening a short last turn at rest grows the list past its bottom
    /// edge by less than Collapse Steps' room: the list settles at its end,
    /// with the opened header still in view and every row clear of the
    /// button, rather than leaving the newest rows under it.
    @Test func openingAShortLastTurnRestsItsRowsClearOfFloatingCollapse() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let (rows, turns) = await Self.turns(0..<1, steps: 0, answerLength: 0)
        let header = ChatRowID.turn(ChatEntryID("n0"))
        let clearance: CGFloat = 120
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.setCollapseControlClearance(clearance)
            controller.apply(Self.foldState(rows, turns: turns))
            await Self.settle(controller)
            try #require(!controller.canCollapseTrajectory)
            let view = controller.timeline
            let restingHeight = view.contentSize.height
            controller.toggle(header)
            await Self.settle(controller)
            try #require(controller.canCollapseTrajectory)
            // Opening grew the rows past the bottom edge, by less than the room.
            let grown = view.contentSize.height - restingHeight
            try #require(grown > 1 && grown <= clearance)

            let end = view.contentSize.height - view.contentOffset.y
            #expect(end <= view.bounds.height - 12 - clearance + 1)
            let top = try #require(controller.cellFrame(of: header)).minY - view.contentOffset.y
            #expect(top >= view.adjustedContentInset.top - 1)
        }
    }

    @Test func makingRoomForFloatingCollapseNeverTakesTheButtonAway() async throws {
        var availability: [Bool] = []
        let controller = ChatTimelineController(actions: ChatTimelineActions(
            collapseAvailabilityChanged: { availability.append($0) }))
        let (rows, turns) = await Self.turns(0..<2, steps: 8)
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.foldState(rows, turns: turns))
            await Self.settle(controller)
            Self.drag(controller, to: controller.timeline.minOffsetY)
            controller.toggle(.turn(ChatEntryID("a0")))
            controller.toggle(.group(ChatEntryID("c0b")))
            controller.followLatest()
            await Self.settle(controller)
            try #require(controller.canCollapseTrajectory)
            await Self.settle(controller)
            availability = []

            // Room deep enough to push every row but the newest answer
            // above the top edge once the list follows its end into it.
            let view = controller.timeline
            let answer = try #require(controller.cellFrame(of: .entry(ChatEntryID("a1"))))
            controller.setCollapseControlClearance(view.bounds.height - view.adjustedContentInset.top - answer.height)
            await Self.settle(controller)
            #expect(controller.canCollapseTrajectory)
            #expect(controller.isFollowing)
            #expect(availability.isEmpty)
        }
    }

    /// Away from the end the room moves no rows, so the probe never reaches
    /// above the top edge: the button holds still, and Collapse Steps folds
    /// the open turn on screen rather than one hidden above it.
    @Test(arguments: [false, true])
    func floatingCollapseAwayFromTheEndProbesOnlyWhatIsOnScreen(earlierOpen: Bool) async throws {
        var availability: [Bool] = []
        let controller = ChatTimelineController(actions: ChatTimelineActions(
            collapseAvailabilityChanged: { availability.append($0) }))
        let (rows, turns) = await Self.turns(0..<2, steps: 8)
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.setCollapseControlClearance(56)
            controller.apply(Self.foldState(rows, turns: turns))
            await Self.settle(controller)
            Self.drag(controller, to: controller.timeline.minOffsetY)
            if earlierOpen {
                controller.toggle(.turn(ChatEntryID("a0")))
                controller.toggle(.group(ChatEntryID("c0b")))
                await Self.settle(controller)
            }
            controller.toggle(.turn(ChatEntryID("a1")))
            controller.toggle(.group(ChatEntryID("c1b")))
            await Self.settle(controller)

            // The later prompt crosses the top edge, with the earlier turn's
            // last row inside the button's room above it. Rows measured on
            // the way move the prompt, so line it up again once there.
            let view = controller.timeline
            let prompt = ChatRowID.entry(ChatEntryID("u1"))
            for _ in 0..<20 where !controller.visibleRowIDs.contains(prompt) {
                Self.drag(controller, to: view.contentOffset.y + view.bounds.height / 2)
                await Self.settle(controller)
            }
            for _ in 0..<2 {
                let frame = try #require(controller.cellFrame(of: prompt))
                Self.drag(controller, to: frame.minY - view.adjustedContentInset.top + 8)
                await Self.settle(controller)
            }
            try #require(controller.visibleRowIDs.first == prompt)
            try #require(!controller.isFollowing)
            try #require(view.contentOffset.y < view.maxOffsetY - 56)
            #expect(controller.canCollapseTrajectory)
            availability = []
            for _ in 0..<4 {
                view.setNeedsLayout()
                await Self.settle(controller)
            }
            #expect(controller.canCollapseTrajectory)
            #expect(availability.isEmpty)

            controller.collapseCurrentTrajectory()
            await Self.settle(controller)
            #expect(!controller.isOpen(.turn(ChatEntryID("a1"))))
            #expect(controller.isOpen(.turn(ChatEntryID("a0"))) == earlierOpen)
        }
    }

    /// A folded turn at the top edge does not hide the open turn under it.
    @Test func floatingCollapseFindsAnOpenTurnBelowAFoldedOne() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let (rows, turns) = await Self.turns(0..<2, steps: 8)
        let folded = ChatRowID.turn(ChatEntryID("a0"))
        let open = ChatRowID.turn(ChatEntryID("a1"))
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { _ in
            controller.apply(Self.foldState(rows, turns: turns))
            await Self.settle(controller)
            Self.drag(controller, to: controller.timeline.minOffsetY)
            controller.toggle(open)
            controller.toggle(.group(ChatEntryID("c1b")))
            await Self.settle(controller)
            let view = controller.timeline
            for _ in 0..<2 {
                let frame = try #require(controller.cellFrame(of: folded))
                Self.drag(controller, to: frame.minY - view.adjustedContentInset.top + 2)
                await Self.settle(controller)
            }
            try #require(controller.visibleRowIDs.prefix(3).contains(folded))
            try #require(controller.visibleRowIDs.contains(open))
            #expect(controller.canCollapseTrajectory)

            controller.collapseCurrentTrajectory()
            await Self.settle(controller)
            #expect(!controller.isOpen(open))
            #expect(!controller.canCollapseTrajectory)
        }
    }

    /// What an omp approval does to a list that follows: the keyboard goes
    /// down, a Blocked card takes the Composer's place, the room kept for
    /// Collapse Steps changes and the turn's rows arrive, in one SwiftUI
    /// update or in a row in either order. Reached by Jump to Latest or by a
    /// send, the list must end exactly at its end afterwards.
    @Test(arguments: [false, true], ChatTimelineChromeChange.allCases)
    func aFollowingListEndsAtItsEndAfterTheBottomChromeAndRowsChange(
        jumped: Bool, change: ChatTimelineChromeChange
    ) async throws {
        let (rows, turns) = await Self.turns(0..<2, steps: 8)
        let (newer, newerTurns) = await Self.turns(0..<3, steps: 8)
        let host = UIHostingController(rootView: ChatTimelineChromeHost(
            state: Self.foldState(rows, turns: turns), chrome: 300, clearance: 56))
        try await withTestWindow(frame: Self.frame, rootViewController: host) { _ in
            for _ in 0..<100 where Self.collectionView(in: host.view) == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            let view = try #require(Self.collectionView(in: host.view))
            let controller = try #require(view.next as? ChatTimelineController)
            await Self.settle(controller)
            Self.drag(controller, to: view.minOffsetY)
            controller.toggle(.turn(ChatEntryID("a0")))
            controller.toggle(.group(ChatEntryID("c0b")))
            await Self.settle(controller)
            if jumped {
                host.rootView.jumpRequest += 1
            } else {
                host.rootView.followRequest += 1
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline, abs(view.contentOffset.y - view.maxOffsetY) > 0.5 {
                try await Task.sleep(for: .milliseconds(20))
            }
            await Self.settle(controller)
            try #require(controller.isFollowing)
            try #require(abs(view.contentOffset.y - view.maxOffsetY) <= 0.5)
            // The send that starts the approval's turn.
            host.rootView.followRequest += 1
            await Self.settle(controller)

            let newState = Self.foldState(newer, turns: newerTurns, revision: 2)
            switch change {
            case .together:
                var root = host.rootView
                root.state = newState
                root.chrome = 120
                root.clearance = 60
                host.rootView = root
            case .rowsFirst:
                host.rootView.state = newState
                await Self.settle(controller)
                host.rootView.chrome = 120
                host.rootView.clearance = 60
            case .chromeFirst:
                host.rootView.chrome = 120
                host.rootView.clearance = 60
                await Self.settle(controller)
                host.rootView.state = newState
            }
            try await Task.sleep(for: .milliseconds(100))
            await Self.settle(controller)
            #expect(controller.isFollowing)
            #expect(
                abs(view.contentOffset.y - view.maxOffsetY) <= 0.5,
                "\(view.maxOffsetY - view.contentOffset.y) pt short of the end")
            let newest = try #require(controller.cellFrame(of: .entry(ChatEntryID("a2"))))
            #expect(newest.maxY - view.contentOffset.y <= view.bounds.height - view.adjustedContentInset.bottom + 0.5)
        }
    }

    /// An update that lands while Jump to Latest is still animating moves
    /// the offset itself. Once the jump is over, later layouts pin again.
    @Test func aJumpAnUpdateInterruptsStillLeavesTheListPinning() async throws {
        let controller = ChatTimelineController(actions: ChatTimelineActions())
        let builder = ChatRowBuilder()
        try await withTestWindow(frame: Self.frame, rootViewController: controller) { window in
            controller.apply(Self.state(await builder.rows(for: ChatTimelineInput(entries: Self.entries(0..<60)))))
            await Self.settle(controller)
            let view = controller.timeline
            Self.drag(controller, to: view.maxOffsetY - 400)
            await Self.settle(controller)
            try #require(!controller.isFollowing)

            controller.jumpToLatest()
            try await Task.sleep(for: .milliseconds(30))
            try #require(abs(view.contentOffset.y - view.maxOffsetY) > 0.5, "the jump animates")
            let rows = await builder.rows(for: ChatTimelineInput(entries: Self.entries(0..<62)))
            controller.apply(Self.state(rows, revision: 2))
            try await Task.sleep(for: .seconds(1))
            await Self.settle(controller)

            window.frame.size.height -= 180
            await Self.settle(controller)
            #expect(controller.isFollowing)
            #expect(
                abs(view.contentOffset.y - view.maxOffsetY) <= 0.5,
                "\(view.maxOffsetY - view.contentOffset.y) pt short of the end")
        }
    }

    // MARK: Helpers

    private static func foldState(
        _ rows: [ChatRow], turns: [ChatTurn], activity: ChatAgentActivity = .idle, revision: Int = 1
    ) -> ChatTimelineState {
        ChatTimelineState(
            generation: 1, revision: revision, rows: rows, isReady: true, turns: turns,
            signals: ChatTurnSignals(activity: activity))
    }

    /// Finished turns: a prompt, two commands, narration, `steps` more
    /// calls each after narration, and an answer.
    private static func turns(
        _ range: Range<Int>, steps: Int = 1, answerLength: Int = 4
    ) async -> ([ChatRow], [ChatTurn]) {
        let start = Date(timeIntervalSince1970: 1_791_266_142)
        var entries: [ChatEntry] = []
        var turns: [ChatTurn] = []
        func add(_ id: String, _ content: ChatEntry.Content) {
            entries.append(ChatEntry(id: ChatEntryID(id), sourceOffset: UInt64(entries.count), content: content))
        }
        func command(_ title: String) -> ChatEntry.Content {
            .tool(
                ChatToolActivity(
                    kind: .command, name: "Bash", title: title, status: .succeeded,
                    preview: ChatToolPreview(text: outputLines(12), isTruncated: false)))
        }
        for index in range {
            turns.append(
                ChatTurn(
                    firstEntryID: ChatEntryID("u\(index)"), startedAt: start, endedAt: start + 35, ending: .completed))
            add("u\(index)", .user(ChatUserMessage(text: "Question \(index)")))
            add("c\(index)a", command("ls \(index)"))
            add("c\(index)b", command("make \(index)"))
            add("n\(index)", .assistant(ChatAssistantMessage(text: "Looking at step \(index).")))
            for step in 0..<steps {
                add("m\(index)-\(step)", .assistant(ChatAssistantMessage(text: "Step \(step) of turn \(index) next.")))
                add("s\(index)-\(step)", command("swift test \(index) \(step)"))
            }
            add(
                "a\(index)",
                .assistant(
                    ChatAssistantMessage(
                        text: "Answer \(index). " + String(repeating: "This sentence adds length. ", count: answerLength))))
        }
        return (await ChatRowBuilder().rows(for: ChatTimelineInput(entries: entries)), turns)
    }

    private static func state(_ rows: [ChatRow], revision: Int = 1) -> ChatTimelineState {
        // Every finished turn here would fold its tool row away.
        ChatTimelineState(
            generation: 1, revision: revision, rows: rows, isReady: true,
            signals: ChatTurnSignals(foldsFinishedTurns: false))
    }

    /// `entries` with a line of the model's text after each, so consecutive
    /// tool calls show as their own rows rather than one group.
    nonisolated static func apart(_ entries: [ChatEntry]) -> [ChatEntry] {
        entries.flatMap { entry in
            [
                entry,
                ChatEntry(
                    id: ChatEntryID("after-\(entry.id.rawValue)"), sourceOffset: entry.sourceOffset,
                    content: .assistant(ChatAssistantMessage(text: "Next."))),
            ]
        }
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

    /// A user drag that pulls the list `distance` points past its top and
    /// lets go there.
    private static func pull(_ controller: ChatTimelineController, by distance: CGFloat) {
        let view = controller.timeline
        controller.scrollViewWillBeginDragging(view)
        view.contentOffset.y = view.minOffsetY - distance
        controller.scrollViewDidEndDragging(view, willDecelerate: true)
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

    private static func collectionView(in view: UIView) -> ChatCollectionView? {
        if let found = view as? ChatCollectionView { return found }
        return view.subviews.lazy.compactMap { collectionView(in: $0) }.first
    }

    /// Whether `view`'s layers draw anything in its bottom `band` points, as
    /// they are now: rendering a layer lays nothing out.
    private static func drawsAnything(in view: UIView, bottom band: CGFloat) -> Bool {
        let width = Int(view.bounds.width.rounded(.up))
        let height = Int(band)
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        // Top-down like UIKit, starting `band` above the bottom edge.
        context.translateBy(x: 0, y: band)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: band - view.bounds.height)
        view.layer.render(in: context)
        guard let data = context.data else { return false }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return (0..<(width * height)).contains { bytes[$0 * 4 + 3] > 0 }
    }

    private static func screenY(of id: ChatRowID, in controller: ChatTimelineController) -> CGFloat? {
        controller.cellFrame(of: id).map { $0.minY - controller.timeline.contentOffset.y }
    }

    private static func screenMaxY(of id: ChatRowID, in controller: ChatTimelineController) -> CGFloat? {
        controller.cellFrame(of: id).map { $0.maxY - controller.timeline.contentOffset.y }
    }

    private static func firstFullyVisibleRow(
        _ controller: ChatTimelineController, where include: (ChatRowID) -> Bool = { _ in true }
    ) -> (ChatRowID, CGFloat)? {
        let view = controller.timeline
        let top = view.contentOffset.y + view.adjustedContentInset.top
        for id in controller.visibleRowIDs where include(id) {
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

    /// VoiceOver reads a user bubble once, chips included. A label set on the
    /// bubble's stack alone once went to each of its children, so a bubble
    /// with a chip read "You: …, You: …" and never named the chip.
    @Test(arguments: [
        (ChatUserMessage(text: "also say PINEAPPLE", wasQueued: true), "You: also say PINEAPPLE, Sent while working"),
        (
            ChatUserMessage(text: "look", imageCount: 2, attachmentLabels: ["notes.md"]),
            "You: look, 2 images, notes.md"
        ),
        (ChatUserMessage(text: "plain"), "You: plain"),
    ])
    func aUserBubbleReadsAsOneLabel(message: ChatUserMessage, expected: String) async throws {
        let entry = ChatEntry(id: ChatEntryID("user"), sourceOffset: 0, content: .user(message))
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: [entry]))
        let row = try #require(rows.first { $0.id == .entry(entry.id) })
        let controller = UIHostingController(
            rootView: ChatRowView(row: row, isExpanded: false, actions: Self.actions)
                .frame(width: 402)
                .fixedSize(horizontal: false, vertical: true))
        controller.safeAreaRegions = []
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 400), rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let labels = AccessibilityProbe.labels(in: controller.view).filter { $0.contains("You") }
        #expect(labels == [expected])
    }

    private static let connectedActions = ChatRowActions(
        toggle: { _ in }, loadOlder: {}, copy: { _ in }, selectText: { _ in },
        missingOutputText: "Output is available when connected.")

    /// The accessibility labels a hosted tool row shows.
    private static func labels(of tool: ChatToolActivity, isExpanded: Bool = false) async throws -> [String] {
        let entry = ChatEntry(id: ChatEntryID("tool"), sourceOffset: 0, content: .tool(tool))
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: [entry]))
        let row = try #require(rows.first { $0.id == .entry(entry.id) })
        let controller = UIHostingController(
            rootView: ChatRowView(row: row, isExpanded: isExpanded, actions: Self.connectedActions)
                .frame(width: 402)
                .fixedSize(horizontal: false, vertical: true))
        controller.safeAreaRegions = []
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 400), rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        return AccessibilityProbe.labels(in: controller.view)
    }

    @Test func aSpawnedTeammateSaysStarted() async throws {
        let labels = try await Self.labels(
            of: ChatToolActivity(
                kind: .agent, name: "Agent", title: "worker w1", subtitle: "Teammate @w1", status: .started))
        #expect(labels.contains { $0.contains("Started") })
        #expect(!labels.contains { $0.contains("Done") })
    }

    /// A running call shown while nothing live backs the timeline says it
    /// ran when last seen instead of spinning.
    @Test func aCallNotUpdatingSaysRunningWhenLastSeen() async throws {
        var tool = ChatToolActivity(kind: .agent, name: "Agent", title: "review the diff", status: .running)
        #expect(try await Self.labels(of: tool).contains { $0.contains("Running") && !$0.contains("last seen") })
        tool.isNotUpdating = true
        let labels = try await Self.labels(of: tool)
        #expect(labels.contains { $0.contains("Running when last seen") })
        // Open, it claims no more than the last read showed.
        let expanded = try await Self.labels(of: tool, isExpanded: true)
        #expect(expanded.contains { $0.contains("No output when last seen.") }, "\(expanded)")
        #expect(!expanded.contains("No output."), "\(expanded)")
    }

    /// A call that never ran says nothing about output it has none of
    /// (CLB-02/03/04); one that ran still says it printed nothing.
    @Test func anExpandedCallThatNeverRanSaysNothingAboutOutput() async throws {
        var declined = ChatToolActivity(
            kind: .command, name: "Bash", title: "rm -rf build", status: .declined, note: "Not now",
            output: ChatOutputReference(offset: 0, length: 10))
        declined.outputRead = .read
        // Stop from the card can leave the call not completed in the record.
        var stopped = ChatToolActivity(
            kind: .command, name: "Bash", title: "make", status: .notCompleted,
            output: ChatOutputReference(offset: 0, length: 10))
        stopped.cardAnswer = .stopped
        let interrupted = ChatToolActivity(
            kind: .command, name: "Bash", title: "sleep 30", status: .interrupted,
            output: ChatOutputReference(offset: 0, length: 10))
        let chatInstead = ChatToolActivity(
            kind: .question, name: "AskUserQuestion", title: "Which color?", status: .chatInstead,
            questions: [ChatQuestion(text: "Which color?", options: ["Red", "Blue"])],
            output: ChatOutputReference(offset: 0, length: 10))
        for tool in [declined, stopped, interrupted, chatInstead] {
            let labels = try await Self.labels(of: tool, isExpanded: true)
            #expect(!labels.contains { $0.contains("No output.") }, "\(tool.title): \(labels)")
            #expect(!labels.contains { $0.contains("Output is available") }, "\(tool.title): \(labels)")
        }
        let declinedLabels = try await Self.labels(of: declined, isExpanded: true)
        #expect(declinedLabels.contains { $0.contains("Not now") }, "\(declinedLabels)")
        let ran = ChatToolActivity(kind: .command, name: "Bash", title: "true", status: .succeeded)
        let ranLabels = try await Self.labels(of: ran, isExpanded: true)
        #expect(ranLabels.contains { $0.contains("No output.") }, "\(ranLabels)")
    }
}

/// Exercises UIKit's commit callback without completing the animation early.
@MainActor
private final class ImagePreviewCommitAnimator: NSObject, UIContextMenuInteractionCommitAnimating {
    let previewViewController: UIViewController?
    var preferredCommitStyle: UIContextMenuInteractionCommitStyle = .dismiss
    private var completions: [() -> Void] = []

    init(preview: UIViewController) { previewViewController = preview }
    func addAnimations(_ animations: @escaping () -> Void) { animations() }
    func addCompletion(_ completion: @escaping () -> Void) { completions.append(completion) }
    func complete() { completions.forEach { $0() } }
}

/// How an approval's changes reach the timeline.
enum ChatTimelineChromeChange: String, CaseIterable, Sendable {
    /// Rows, chrome and clearance in one SwiftUI update.
    case together
    case rowsFirst
    case chromeFirst
}

/// The timeline above bottom chrome of a given height, as in Chat.
private struct ChatTimelineChromeHost: View {
    var state: ChatTimelineState
    var chrome: CGFloat
    var clearance: CGFloat
    var jumpRequest = 0
    var followRequest = 0

    var body: some View {
        ChatTimelineView(
            state: state, jumpRequest: jumpRequest, followRequest: followRequest,
            collapseControlClearance: clearance, actions: ChatTimelineActions()
        )
        .padding(.bottom, chrome)
        .ignoresSafeArea()
    }
}

