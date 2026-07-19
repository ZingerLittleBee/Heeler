import Foundation
import SwiftTerm
import SwiftUI
import Testing
import UIKit

@testable import HerdrMobile

/// The Observe screen's store (#9) against a scripted transport: backfill
/// then live-follow, restart on resize and seq gaps, failure surfacing —
/// protocol level, no SSH, no UI.
@MainActor
@Suite("Observe terminal store")
struct ObserveTerminalStoreTests {
    private func makeStore(
        transport: ScriptedTransport?, target: String = "w1:p1"
    ) -> (ObserveTerminalStore, captured: Captured) {
        let store = ObserveTerminalStore(target: target) { transport }
        let captured = Captured()
        store.feed.attach { data in captured.chunks.append(data) }
        return (store, captured)
    }

    /// Reference box for bytes the feed delivered, in order.
    @MainActor
    private final class Captured {
        var chunks: [Data] = []
        var text: String {
            String(decoding: chunks.reduce(Data(), +), as: UTF8.self)
        }
    }

    private func terminalView(in root: UIView) -> SizeReportingTerminalView? {
        if let terminal = root as? SizeReportingTerminalView {
            return terminal
        }
        for subview in root.subviews {
            if let terminal = terminalView(in: subview) {
                return terminal
            }
        }
        return nil
    }

    /// Polls until `condition` holds, yielding so the store's tasks progress.
    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }

    @Test func firstSizeReportBackfillsScrollbackThenFollowsLive() async throws {
        let transport = ScriptedTransport()
        await transport.setPaneText("old line 1\nold line 2", paneID: "w1:p1")
        let (store, captured) = makeStore(transport: transport)
        #expect(store.status == .waitingForSize)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }

        // The mobile view reads logical lines instead of the PC-width screen
        // so SwiftTerm can wrap them to the local geometry.
        let read = try #require(await transport.paneReadParams.first)
        #expect(read.paneID == "w1:p1")
        #expect(read.format == .ansi)
        #expect(read.source == .recentUnwrapped)
        #expect(read.stripANSI != true)
        #expect(captured.text == "old line 1\r\nold line 2")

        // Then the live-follow with the reported geometry.
        let request = try #require(await transport.observeRequests.first)
        #expect(request == TerminalObserveRequest(target: "w1:p1", cols: 80, rows: 24))

        let completeLine = "This line is wider than the phone and must keep its final words."
        await transport.setPaneText(completeLine, paneID: "w1:p1")
        await transport.emitFrame(
            TerminalFrame(seq: 1, isFull: true, bytes: Data("This line is cropped".utf8)))
        try await waitUntil("a frame should refresh the complete logical transcript") {
            await transport.paneReadParams.count == 2
                && captured.text.contains("must keep its final words.")
        }
        #expect(!captured.text.contains("This line is cropped"))

        // A second frame arriving during the coalescing interval must still
        // produce a trailing refresh after output becomes quiet.
        await transport.setPaneText(
            "The final answer has a distinct complete ending.", paneID: "w1:p1")
        await transport.emitFrame(
            TerminalFrame(seq: 2, isFull: false, bytes: Data("cropped ending".utf8)))
        try await waitUntil("the quiet tail should receive its final refresh") {
            await transport.paneReadParams.count == 3
                && captured.text.contains("distinct complete ending.")
        }
        #expect(!captured.text.contains("cropped ending"))

        await store.stop()
    }

    @Test func observeOmitsTheRemoteTerminalInputArea() async throws {
        let transport = ScriptedTransport()
        await transport.setPaneText(
            """
            › Previous submitted input

            Agent answer stays visible.

            \u{1B}[2m• Worked for 12s\u{1B}[0m

            \u{1B}[7m› Draft input owned by the remote terminal\u{1B}[0m

              Context 54% used · ~/project · model
            """,
            paneID: "w1:p1")
        let (store, captured) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the output-only transcript should render") {
            store.status == .live && captured.text.contains("Agent answer stays visible.")
        }

        #expect(!captured.text.contains("Draft input owned by the remote terminal"))
        #expect(!captured.text.contains("Context 54% used"))
        #expect(!captured.text.contains("Worked for 12s"))
        #expect(captured.text.contains("Previous submitted input"))

        await store.stop()
    }

    @Test func observeUsesEnoughColumnsToLimitWidePaneReflow() throws {
        // A 393-point iPhone showing the default 12-point terminal only fits
        // about 52 columns. A 185-column desktop line then expands to four
        // mobile rows, which makes the transcript unnecessarily tall.
        let host = UIHostingController(
            rootView: TerminalScreenView(feed: TerminalByteFeed(), style: .observe))
        let frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        let window = UIWindow(frame: frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = frame
        host.view.layoutIfNeeded()

        let terminal = try #require(terminalView(in: host.view))
        terminal.layoutIfNeeded()

        #expect(terminal.font.pointSize < 12)
        #expect(terminal.getTerminal().options.scrollback == 5_000)
        let columns = terminal.getTerminal().cols
        let rowsForDesktopLine = (185 + columns - 1) / columns
        #expect(columns >= 64)
        #expect(rowsForDesktopLine <= 3)
    }

    @Test func replacingObserveSnapshotKeepsScrollExtentAndViewportStable() async throws {
        let feed = TerminalByteFeed()
        let host = UIHostingController(
            rootView: TerminalScreenView(feed: feed, style: .observe))
        let frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        let window = UIWindow(frame: frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = frame
        host.view.layoutIfNeeded()

        let terminal = try #require(terminalView(in: host.view))
        terminal.layoutIfNeeded()
        let transcript = (0..<120)
            .map { String(format: "line %03d", $0) }
            .joined(separator: "\r\n")
        let updatedTranscript = transcript + "\r\nline 120"
        feed.write(Data(transcript.utf8))
        #expect(terminal.accessibilityScroll(.up))
        let originalExtent = terminal.contentSize.height
        let originalTopRow = terminal.getTerminal().getTopVisibleRow()

        feed.write(Data("\u{1B}[3J\u{1B}[2J\u{1B}[H\(updatedTranscript)".utf8))
        try await Task.sleep(for: .milliseconds(30))

        #expect(terminal.contentSize.height == originalExtent)
        #expect(terminal.getTerminal().getTopVisibleRow() == originalTopRow)

        for _ in 0..<10 {
            if !terminal.accessibilityScroll(.down) { break }
        }
        #expect(terminal.contentSize.height > originalExtent)
        #expect(terminal.scrollPosition == 1)
    }

    @Test func reachingTheTopLoadsEarlierHistoryWithoutMovingTheViewport() async throws {
        let feed = TerminalByteFeed()
        var loadRequests = 0
        let host = UIHostingController(
            rootView: TerminalScreenView(
                feed: feed, style: .observe,
                onLoadEarlier: {
                    loadRequests += 1
                    return true
                }))
        let frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        let window = UIWindow(frame: frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = frame
        host.view.layoutIfNeeded()

        let terminal = try #require(terminalView(in: host.view))
        terminal.layoutIfNeeded()
        let initialTranscript = (200..<320)
            .map { String(format: "line %03d", $0) }
            .joined(separator: "\r\n")
        feed.write(Data(initialTranscript.utf8))
        while terminal.accessibilityScroll(.up) {}

        #expect(loadRequests == 1)
        let originalTopLine = try #require(terminal.getTerminal().getLine(row: 0))
            .translateToString(trimRight: true)
        #expect(originalTopLine == "line 200")

        let expandedTranscript = (0..<320)
            .map { String(format: "line %03d", $0) }
            .joined(separator: "\r\n")
        feed.writeHistorySnapshot(
            Data("\u{1B}[3J\u{1B}[2J\u{1B}[H\(expandedTranscript)".utf8))
        try await Task.sleep(for: .milliseconds(30))

        let restoredTopLine = try #require(terminal.getTerminal().getLine(row: 0))
            .translateToString(trimRight: true)
        #expect(restoredTopLine == originalTopLine)
        #expect(terminal.getTerminal().getTopVisibleRow() > 0)
        #expect(loadRequests == 1)
    }

    @Test func loadingEarlierExpandsTheReadWindowUntilHistoryEnds() async throws {
        let transport = ScriptedTransport()
        let initial = (0..<80).map(String.init).joined(separator: "\n")
        await transport.setPaneText(initial, paneID: "w1:p1")
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }
        #expect(await transport.paneReadParams.first?.lines == 80)

        let expanded = (0..<280).map(String.init).joined(separator: "\n")
        await transport.setPaneText(expanded, paneID: "w1:p1")
        #expect(store.loadEarlier())
        try await waitUntil("the first pull should request 280 lines") {
            await transport.paneReadParams.count == 2 && !store.isLoadingEarlier
        }
        #expect(await transport.paneReadParams.last?.lines == 280)
        #expect(store.canLoadEarlier)

        let exhausted = (0..<350).map(String.init).joined(separator: "\n")
        await transport.setPaneText(exhausted, paneID: "w1:p1")
        #expect(store.loadEarlier())
        try await waitUntil("a short response should mark history exhausted") {
            await transport.paneReadParams.count == 3 && !store.isLoadingEarlier
        }
        #expect(await transport.paneReadParams.last?.lines == 480)
        #expect(!store.canLoadEarlier)
        #expect(!store.loadEarlier())

        await store.stop()
    }

    @Test func readOnlyTerminalKeepsCursorHiddenWhenRemoteShowsIt() {
        var responses = Data()
        let coordinator = TerminalScreenView.Coordinator(
            onSizeChanged: nil,
            onSend: { responses.append($0) })
        let terminalView = SizeReportingTerminalView(frame: .zero, font: nil)
        terminalView.terminalDelegate = coordinator
        terminalView.allowsInput = false

        // Simulate a remote TUI showing its cursor, then query DECTCEM.
        terminalView.feed(byteArray: ArraySlice([UInt8]("\u{1B}[?25h\u{1B}[?25$p".utf8)))

        #expect(String(decoding: responses, as: UTF8.self) == "\u{1B}[?25;2$y")
    }

    @Test func interactiveTerminalStillHonorsRemoteCursorVisibility() {
        var responses = Data()
        let coordinator = TerminalScreenView.Coordinator(
            onSizeChanged: nil,
            onSend: { responses.append($0) })
        let terminalView = SizeReportingTerminalView(frame: .zero, font: nil)
        terminalView.terminalDelegate = coordinator
        terminalView.allowsInput = true

        terminalView.feed(
            byteArray: ArraySlice([UInt8]("\u{1B}[?25l\u{1B}[?25h\u{1B}[?25$p".utf8)))

        #expect(String(decoding: responses, as: UTF8.self) == "\u{1B}[?25;1$y")
    }

    @Test func duplicateSizeReportsDoNotRestartTheStream() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }
        store.viewDidResize(cols: 80, rows: 24)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await transport.observeRequests.count == 1)
        await store.stop()
    }

    @Test func resizeRestartsTheLiveFollowWithNewGeometryWithoutRebackfilling() async throws {
        // The acceptance criterion's rotation path: new geometry means a new
        // observe (the server renders frames for one size); scrollback is
        // already on screen, so no second backfill.
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }

        store.viewDidResize(cols: 100, rows: 30)
        try await waitUntil("a second observe should start with the new size") {
            await transport.observeRequests.count == 2
        }
        #expect(
            await transport.observeRequests.last
                == TerminalObserveRequest(target: "w1:p1", cols: 100, rows: 30))
        try await waitUntil("the restarted stream should be live") {
            guard store.status == .live else { return false }
            return await transport.hasLiveFrameStream
        }
        #expect(await transport.paneReadParams.count == 1)

        await store.stop()
    }

    @Test func sequenceGapRestartsForAFreshFullRepaint() async throws {
        // A gap means change notifications were lost, so the store
        // re-observes before trusting later notifications.
        let transport = ScriptedTransport()
        let (store, captured) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }

        await transport.setPaneText("one two", paneID: "w1:p1")
        await transport.emitFrame(TerminalFrame(seq: 1, isFull: true, bytes: Data("one".utf8)))
        await transport.emitFrame(TerminalFrame(seq: 2, isFull: false, bytes: Data("two".utf8)))
        try await waitUntil("accepted notifications should refresh the transcript") {
            captured.text.contains("one two")
        }
        await transport.emitFrame(TerminalFrame(seq: 5, isFull: false, bytes: Data("FIVE".utf8)))

        try await waitUntil("the gap should trigger a re-observe") {
            await transport.observeRequests.count == 2
        }
        // The post-gap cropped payload was not rendered.
        #expect(!captured.text.contains("FIVE"))

        try await waitUntil("the restarted stream should be live") {
            guard store.status == .live else { return false }
            return await transport.hasLiveFrameStream
        }
        await transport.setPaneText("fresh complete transcript", paneID: "w1:p1")
        await transport.emitFrame(
            TerminalFrame(seq: 1, isFull: true, bytes: Data("REPAINT".utf8)))
        try await waitUntil("the restarted notification should refresh the transcript") {
            captured.text.contains("fresh complete transcript")
        }
        #expect(!captured.text.contains("REPAINT"))

        await store.stop()
    }

    @Test func streamFailureSurfacesAndRetryReobserves() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }

        await transport.failFrameStream(.channelFailed(detail: "pane closed"))
        try await waitUntil("the failure should surface") {
            if case .failed = store.status { return true }
            return false
        }

        store.retry()
        try await waitUntil("retry should re-observe") {
            await transport.observeRequests.count == 2 && store.status == .live
        }

        await store.stop()
    }

    @Test func backfillFailureIsNotFatal() async throws {
        // Scrollback is a nicety; the live view must come up without it.
        let transport = ScriptedTransport()
        await transport.setPaneReadFailure(.timedOut)
        let (store, captured) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live despite the failed backfill") {
            store.status == .live
        }
        await transport.emitFrame(
            TerminalFrame(seq: 1, isFull: true, bytes: Data("SCREEN".utf8)))
        try await waitUntil("frames should still flow") { captured.text == "SCREEN" }

        await store.stop()
    }

    @Test func missingTransportFailsActionably() async throws {
        let (store, _) = makeStore(transport: nil)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the store should fail without a transport") {
            if case .failed = store.status { return true }
            return false
        }
    }

    @Test func stopEndsTheStreamAndIsTerminal() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }

        await store.stop()
        #expect(store.status == .stopped)
        #expect(await transport.hasLiveFrameStream == false)

        // Late size reports (the view tearing down) must not resurrect it.
        store.viewDidResize(cols: 40, rows: 12)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.observeRequests.count == 1)
        #expect(store.status == .stopped)
    }

    @Test func feedBuffersBytesUntilASinkAttaches() {
        // The terminal view attaches after layout; backfill written before
        // that must not be lost.
        let feed = TerminalByteFeed()
        feed.write(Data("early".utf8))
        var seen: [Data] = []
        feed.attach { seen.append($0) }
        feed.write(Data("late".utf8))
        #expect(seen == [Data("early".utf8), Data("late".utf8)])
    }
}
