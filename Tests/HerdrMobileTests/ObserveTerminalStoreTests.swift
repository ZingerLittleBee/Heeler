import Foundation
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
        let columns = terminal.getTerminal().cols
        let rowsForDesktopLine = (185 + columns - 1) / columns
        #expect(columns >= 64)
        #expect(rowsForDesktopLine <= 3)
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
