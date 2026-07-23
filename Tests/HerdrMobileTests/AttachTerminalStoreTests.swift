import Foundation
import Testing

@testable import HerdrMobile

/// The Attach screen's store (#11) against a scripted transport: open on
/// first size report, bytes both ways, in-band resize (never a reattach),
/// remote-end surfacing with reattach — protocol level, no SSH, no UI.
@MainActor
@Suite("Attach terminal store")
struct AttachTerminalStoreTests {
    private func makeStore(
        transport: ScriptedTransport?, target: String = "w1:p1", takeover: Bool = false,
        input: TerminalInputController = TerminalInputController()
    ) -> (AttachTerminalStore, captured: Captured) {
        let store = AttachTerminalStore(
            target: target, takeover: takeover, input: input
        ) { transport }
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

    @Test func firstSizeReportOpensAttachWithGeometry() async throws {
        let transport = ScriptedTransport()
        let (store, captured) = makeStore(transport: transport)
        #expect(store.status == .waitingForSize)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }

        let request = try #require(await transport.attachRequests.first)
        #expect(
            request == TerminalAttachRequest(target: "w1:p1", takeover: false, cols: 80, rows: 24))

        // Raw PTY bytes feed straight through — no frame decoding anywhere.
        await transport.emitAttachOutput(Data("\u{1B}[2JTUI".utf8))
        try await waitUntil("output should reach the feed") {
            captured.text == "\u{1B}[2JTUI"
        }

        await store.stop()
    }

    @Test func takeoverRidesThroughToTheRequest() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport, takeover: true)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }

        #expect(await transport.attachRequests.first?.takeover == true)
        await store.stop()
    }

    @Test func keystrokesForwardToTheSession() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }

        store.send(Data("y".utf8))
        store.send(Data([0x1B, 0x5B, 0x41]))  // Up arrow from the terminal emulator.
        await store.stop()

        #expect(
            await transport.attachInputs == [
                .keystrokes(Data("y".utf8)),
                .keystrokes(Data([0x1B, 0x5B, 0x41])),
            ])
    }

    @Test func inputControllerOwnsTheLiveWriterAndPauseGate() async throws {
        let transport = ScriptedTransport()
        let input = TerminalInputController()
        let (store, _) = makeStore(transport: transport, input: input)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }
        #expect(input.liveGeneration != nil)

        store.send(Data("before".utf8))
        input.pause()
        store.send(Data("blocked".utf8))
        input.resume()
        store.send(Data("after".utf8))
        await store.stop()

        #expect(
            await transport.attachInputs == [
                .keystrokes(Data("before".utf8)),
                .keystrokes(Data("after".utf8)),
            ])
        #expect(input.liveGeneration == nil)
    }

    @Test func remoteOutputContinuesWhileLocalInputIsPaused() async throws {
        let transport = ScriptedTransport()
        let input = TerminalInputController()
        let (store, captured) = makeStore(transport: transport, input: input)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }

        input.pause()
        store.send(Data("blocked".utf8))
        await transport.emitAttachOutput(Data("still rendering".utf8))
        try await waitUntil("remote output should keep reaching the terminal feed") {
            captured.text == "still rendering"
        }

        #expect(input.isPaused)
        #expect(await transport.attachInputs.isEmpty)
        #expect(captured.text == "still rendering")

        input.resume()
        await store.stop()
    }

    @Test func reattachAdvancesTheInputSessionGeneration() async throws {
        let transport = ScriptedTransport()
        let input = TerminalInputController()
        let (store, _) = makeStore(transport: transport, input: input)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }
        let first = try #require(input.liveGeneration)

        await transport.endAttachFromRemote()
        try await waitUntil("the remote end should surface") {
            if case .ended = store.status { return true }
            return false
        }
        #expect(input.liveGeneration == nil)

        store.retry()
        try await waitUntil("store should reattach") { store.status == .live }
        let second = try #require(input.liveGeneration)
        #expect(first != second)

        await store.stop()
    }

    @Test func resizeForwardsWindowChangeWithoutReattaching() async throws {
        // The acceptance criterion's rotation path: geometry changes ride
        // SSH window-change on the live channel — attach is never reopened
        // (the whole point of a live PTY rather than fixed-size snapshots).
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }

        store.viewDidResize(cols: 100, rows: 30)
        await store.stop()

        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.attachInputs == [.resize(cols: 100, rows: 30)])
    }

    @Test func duplicateSizeReportsSendNothing() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }
        store.viewDidResize(cols: 80, rows: 24)
        await store.stop()

        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.attachInputs.isEmpty)
    }

    @Test func remoteEndSurfacesAndReattachWorks() async throws {
        // The user detaching inside the TUI (or the pane closing) ends the
        // stream cleanly; the store surfaces it and offers a way back.
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }

        await transport.endAttachFromRemote()
        try await waitUntil("the remote end should surface") {
            if case .ended = store.status { return true }
            return false
        }

        store.retry()
        try await waitUntil("retry should reattach") {
            await transport.attachRequests.count == 2 && store.status == .live
        }

        await store.stop()
    }

    @Test func channelFailureSurfacesItsMessage() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }

        await transport.failAttachStream(.channelFailed(detail: "host went away"))
        try await waitUntil("the failure should surface") {
            if case .ended = store.status { return true }
            return false
        }

        await store.stop()
    }

    @Test func missingTransportEndsActionably() async throws {
        let (store, _) = makeStore(transport: nil)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the store should surface the missing transport") {
            store.status == .ended("The Host is not connected.")
        }
    }

    @Test func stopEndsTheSessionAndIsTerminal() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }

        await store.stop()
        #expect(store.status == .stopped)
        #expect(await transport.hasLiveAttachSession == false)

        // Late size reports (the view tearing down) must not resurrect it.
        store.viewDidResize(cols: 40, rows: 12)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.attachRequests.count == 1)
        #expect(store.status == .stopped)
    }

    @Test func stopIsIdempotentAcrossDetachAndBackstopPaths() async throws {
        // The Detach button stops before dismissing; the cover's onDisappear
        // backstop then stops again. The first stop must end the session for
        // real, the second must be a harmless no-op.
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }

        await store.stop()
        #expect(store.status == .stopped)
        #expect(await transport.hasLiveAttachSession == false)

        await store.stop()
        #expect(store.status == .stopped)
        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.hasLiveAttachSession == false)
    }

    @Test func concurrentStopsFromDetachAndBackstopBothComplete() async throws {
        // The two paths can overlap (the backstop fires while the Detach
        // stop is still awaiting teardown); both must complete and the
        // session must be gone.
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("store should go live") { store.status == .live }

        async let detachStop: Void = store.stop()
        async let backstopStop: Void = store.stop()
        _ = await (detachStop, backstopStop)

        #expect(store.status == .stopped)
        #expect(await transport.hasLiveAttachSession == false)
        #expect(await transport.attachRequests.count == 1)
    }

    @Test func resizeRacingThePendingOpenIsForwardedOnceLive() async throws {
        // The view can resize (keyboard, rotation) while the channel is
        // still coming up; the session must end up at the latest geometry.
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        store.viewDidResize(cols: 100, rows: 30)
        try await waitUntil("store should go live") { store.status == .live }
        // Depending on when the open task read the dims, the session either
        // opened at the latest geometry or got a catch-up resize.
        try await waitUntil("the latest geometry should reach the session") {
            if let request = await transport.attachRequests.first,
                request.cols == 100, request.rows == 30
            {
                return true
            }
            return await transport.attachInputs.contains(.resize(cols: 100, rows: 30))
        }
        #expect(await transport.attachRequests.count == 1)

        await store.stop()
    }
}
