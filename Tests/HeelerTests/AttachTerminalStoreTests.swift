import Foundation
import Testing

@testable import Heeler

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
        ) { request, handler in
            guard let transport else {
                throw TransportError.sshUnreachable(detail: "The Host is not connected.")
            }
            let session = try await transport.attachTerminal(request)
            do {
                try await handler.run(session)
                await session.end()
            } catch {
                await session.end()
                throw error
            }
        }
        let captured = Captured()
        store.feed.attach(captured)
        return (store, captured)
    }

    /// Stands in for the Ghostty surface: a terminal the feed can deliver to,
    /// and one the test can drop to model SwiftUI replacing it.
    @MainActor
    private final class Captured: TerminalByteSink {
        var chunks: [Data] = []
        var text: String {
            String(decoding: chunks.reduce(Data(), +), as: UTF8.self)
        }

        func receive(_ data: Data) {
            chunks.append(data)
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

    /// What a real attach puts on the wire first: the TUI clearing the
    /// screen. The transport withholds the login shell's noise, so the first
    /// paint is also the moment the session stops being "Connecting…".
    private static let firstPaint = Data("\u{1B}[2J".utf8)

    /// The remote's first paint, once the channel is actually up.
    private func paint(
        _ transport: ScriptedTransport, _ bytes: Data = firstPaint
    ) async throws {
        try await waitUntil("attach should open") { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(bytes))
    }

    /// Brings a store up the way an attach does: the first size report opens
    /// the channel, the remote's first paint makes it live.
    private func goLive(
        _ store: AttachTerminalStore, _ transport: ScriptedTransport,
        cols: Int = 80, rows: Int = 24, firstPaint: Data = firstPaint
    ) async throws {
        store.viewDidResize(cols: cols, rows: rows)
        try await paint(transport, firstPaint)
        try await waitUntil("store should go live") { store.status == .live }
    }

    @Test func openChannelStaysConnectingUntilTheRemotePaints() async throws {
        // The flicker fix, from the store's side: an open channel with
        // nothing on it yet is still a blank screen, so the Connecting dialog
        // has to outlive the channel open.
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("attach should open") { await transport.hasLiveAttachSession }
        #expect(store.status == .connecting)

        #expect(await transport.emitAttachOutput(Self.firstPaint))
        try await waitUntil("the first paint should go live") { store.status == .live }

        await store.stop()
    }

    @Test func firstSizeReportOpensAttachWithGeometry() async throws {
        let transport = ScriptedTransport()
        let (store, captured) = makeStore(transport: transport)
        #expect(store.status == .waitingForSize)

        // Raw PTY bytes feed straight through — no frame decoding anywhere.
        try await goLive(store, transport, firstPaint: Data("\u{1B}[2JTUI".utf8))

        let request = try #require(await transport.attachRequests.first)
        #expect(
            request == TerminalAttachRequest(target: "w1:p1", takeover: false, cols: 80, rows: 24))
        #expect(captured.text == "\u{1B}[2JTUI")

        await store.stop()
    }

    @Test func takeoverRidesThroughToTheRequest() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport, takeover: true)

        try await goLive(store, transport)

        #expect(await transport.attachRequests.first?.takeover == true)
        await store.stop()
    }

    // MARK: Returning from the background (#141)

    @Test func returningToTheForegroundAsksTheRemoteToRepaint() async throws {
        // `herdr agent attach` is ratatui: it repaints on change, never on a
        // timer, so "no bytes" is its normal steady state and cannot itself
        // be a liveness signal. A window-change is the one thing that makes a
        // live remote speak without waiting on the agent — and the frame it
        // answers with is exactly what a surface that came back empty needs.
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        try await goLive(store, transport, cols: 80, rows: 24)
        store.didBecomeActive()

        try await waitUntil("the return should nudge the remote PTY") {
            await transport.attachInputs == [
                .resize(cols: 79, rows: 24),
                .resize(cols: 80, rows: 24),
            ]
        }
        await store.stop()
    }

    @Test func keystrokesForwardToTheSession() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        try await goLive(store, transport)

        store.send(Data("y".utf8))
        store.send(Data([0x1B, 0x5B, 0x41]))  // Up arrow from the terminal emulator.
        await store.stop()

        #expect(
            await transport.attachInputs == [
                .keystrokes(Data("y".utf8)),
                .keystrokes(Data([0x1B, 0x5B, 0x41])),
            ])
    }

    @Test func touchScrollingUsesTheBoundedScrollPath() async throws {
        let transport = ScriptedTransport()
        let input = TerminalInputController()
        let (store, _) = makeStore(transport: transport, input: input)
        let sequence = Data("wheel".utf8)

        try await goLive(store, transport)

        input.scroll(sequence, rows: 5)
        try await waitUntil("scroll rows should reach the session in bounded batches") {
            await transport.attachInputs.count == 2
        }
        await store.stop()

        #expect(
            await transport.attachInputs == [
                .scroll(sequence + sequence + sequence),
                .scroll(sequence + sequence),
            ])
    }

    @Test func inputControllerOwnsTheLiveWriterAndPauseGate() async throws {
        let transport = ScriptedTransport()
        let input = TerminalInputController()
        let (store, _) = makeStore(transport: transport, input: input)

        try await goLive(store, transport)
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

        try await goLive(store, transport)

        input.pause()
        store.send(Data("blocked".utf8))
        await transport.emitAttachOutput(Data("still rendering".utf8))
        try await waitUntil("remote output should keep reaching the terminal feed") {
            captured.text == "\u{1B}[2Jstill rendering"
        }

        #expect(input.isPaused)
        #expect(await transport.attachInputs.isEmpty)
        #expect(captured.text == "\u{1B}[2Jstill rendering")

        input.resume()
        await store.stop()
    }

    @Test func reattachAdvancesTheInputSessionGeneration() async throws {
        let transport = ScriptedTransport()
        let input = TerminalInputController()
        let (store, _) = makeStore(transport: transport, input: input)

        try await goLive(store, transport)
        let first = try #require(input.liveGeneration)

        await transport.endAttachFromRemote()
        try await waitUntil("the remote end should surface") {
            if case .ended = store.status { return true }
            return false
        }
        #expect(input.liveGeneration == nil)

        store.retry()
        try await paint(transport)
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

        try await goLive(store, transport)

        store.viewDidResize(cols: 100, rows: 30)
        await store.stop()

        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.attachInputs == [.resize(cols: 100, rows: 30)])
    }

    @Test func duplicateSizeReportsSendNothing() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        try await goLive(store, transport)
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

        try await goLive(store, transport)

        await transport.endAttachFromRemote()
        try await waitUntil("the remote end should surface") {
            if case .ended = store.status { return true }
            return false
        }

        store.retry()
        try await paint(transport)
        try await waitUntil("retry should reattach") {
            await transport.attachRequests.count == 2 && store.status == .live
        }

        await store.stop()
    }

    @Test func channelFailureSurfacesItsMessage() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        try await goLive(store, transport)

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

        try await goLive(store, transport)

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

        try await goLive(store, transport)

        await store.stop()
        #expect(store.status == .stopped)
        #expect(await transport.hasLiveAttachSession == false)

        await store.stop()
        #expect(store.status == .stopped)
        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.hasLiveAttachSession == false)
    }

    @Test func stopAbortsARunStillWaitingForTheTerminalChannel() async throws {
        // Before a session exists the run can be queued for the Host's
        // terminal channel. Teardown must abort that wait — a stop that sits
        // behind whoever holds the channel wedges the whole lifecycle queue.
        let store = AttachTerminalStore(target: "w1:p1") { _, _ in
            // Parked as a queued acquire would be: indefinitely, but
            // cancellation-aware.
            try await Task.sleep(for: .seconds(60))
        }
        store.viewDidResize(cols: 80, rows: 24)
        #expect(store.status == .connecting)

        let began = ContinuousClock.now
        await store.stop()
        #expect(store.status == .stopped)
        #expect(ContinuousClock.now - began < .seconds(5))
    }

    @Test func concurrentStopsFromDetachAndBackstopBothComplete() async throws {
        // The two paths can overlap (the backstop fires while the Detach
        // stop is still awaiting teardown); both must complete and the
        // session must be gone.
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        try await goLive(store, transport)

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
        try await paint(transport)
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

@MainActor
@Suite("Agent Attach store")
struct AgentAttachStoreTests {
    @Test func plainWebURLsBecomeAttachLinksInMostRecentOrder() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await transport.emitAttachOutput(
            Data(
                """
                Preview: https://example.com/build/42?mode=full#result
                Local: http://localhost:3000/health

                """.utf8))
        try await waitUntil("both links should become observable") {
            store.attachLinks.map(\.target) == [
                "http://localhost:3000/health",
                "https://example.com/build/42?mode=full#result",
            ]
        }

        await store.leave().value
    }

    @Test func aNewDistinctLinkIsIndexedWithoutSendingTerminalInput() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await transport.emitAttachOutput(
            Data("https://example.com/new?signature=exact#result\n".utf8))

        try await waitUntil("the new distinct link should be indexed") {
            store.attachLinks.first?.target
                == "https://example.com/new?signature=exact#result"
        }
        #expect(await transport.attachInputs.isEmpty)

        await store.leave().value
    }

    @Test func failedOpenKeepsTheLinkAndOffersExactCopyRecovery() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let exactTarget = "https://example.com/signed?q=a%2Fb#Exact"

        try await goLive(store, transport)
        await transport.emitAttachOutput(Data((exactTarget + "\n").utf8))
        try await waitUntil("the exact link should be collected") {
            store.attachLinks.first?.target == exactTarget
        }
        let link = try #require(store.attachLinks.first)

        store.openAttachLink(link) { url in
            #expect(url.absoluteString == exactTarget)
            return false
        }

        #expect(store.attachLinks.map(\.target) == [exactTarget])
        try await waitUntil("the failed open should offer copy recovery") {
            store.attachLinkOpenFailure?.link == link
        }
        #expect(store.attachLinkOpenFailure?.message.contains(link.host) == true)

        var copiedTarget: String?
        store.copyFailedAttachLink { copiedTarget = $0 }
        #expect(copiedTarget == exactTarget)
        #expect(store.attachLinks.map(\.target) == [exactTarget])
        #expect(store.attachLinkOpenFailure == nil)

        await store.leave().value
    }

    @Test func anOlderFailedOpenCannotReplaceTheLatestSuccessfulOpen() async throws {
        let transport = ScriptedTransport()
        let opener = DeferredAttachLinkOpener()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        await transport.emitAttachOutput(
            Data(
                """
                https://example.com/first
                https://example.com/latest

                """.utf8))
        try await waitUntil("both links should be collected") {
            store.attachLinks.count == 2
        }
        let first = try #require(
            store.attachLinks.first { $0.target == "https://example.com/first" })
        let latest = try #require(
            store.attachLinks.first { $0.target == "https://example.com/latest" })

        store.openAttachLink(first, using: opener.open)
        try await waitUntil("the first system open should be pending") {
            opener.pendingTargets == [first.target]
        }
        store.openAttachLink(latest, using: opener.open)
        try await waitUntil("both system opens should be pending") {
            Set(opener.pendingTargets) == Set([first.target, latest.target])
        }

        opener.complete(latest.target, accepted: true)
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(store.attachLinkOpenFailure == nil)

        opener.complete(first.target, accepted: false)
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(store.attachLinkOpenFailure == nil)
        #expect(store.attachLinks.count == 2)

        await store.leave().value
    }

    @Test func leavingAttachCancelsAPendingSystemOpenWithoutLaterMutation() async throws {
        let transport = ScriptedTransport()
        let opener = CancellationAwareAttachLinkOpener()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        await transport.emitAttachOutput(Data("https://example.com/leaving-open\n".utf8))
        try await waitUntil("the link should be collected") {
            store.attachLinks.count == 1
        }
        let link = try #require(store.attachLinks.first)

        store.openAttachLink(link, using: opener.open)
        try await waitUntil("the system open should be pending") {
            opener.pendingTarget == link.target
        }

        await store.leave().value
        try await waitUntil("leaving Attach should cancel the system open") {
            opener.cancelledTargets == [link.target]
        }

        #expect(store.attachLinks.isEmpty)
        #expect(store.attachLinkOpenFailure == nil)
    }

    @Test func styledTextAndOSC8HyperlinksExposeTheirRealTargets() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await transport.emitAttachOutput(
            Data(
                "\u{001B}Phttps://hidden-control.example\u{001B}\\"
                    .utf8))
        await transport.emitAttachOutput(
            Data(
                "\u{001B}]0;https://hidden-title.example\u{0007}"
                    .utf8))
        await transport.emitAttachOutput(
            Data("See (\u{001B}[31mhttps://styled.exa".utf8))
        await transport.emitAttachOutput(
            Data("mple/path\u{001B}[0m),\n".utf8))
        await transport.emitAttachOutput(
            Data(
                "\u{001B}]8;;https://actual.example/build/42?mode=full#result\u{0007}"
                    .utf8))
        await transport.emitAttachOutput(
            Data("https://misleading.example\u{001B}]8;;\u{0007}\n".utf8))
        await transport.emitAttachOutput(
            Data("\u{001B}]8;id=docs;https://docs.example/guide\u{001B}".utf8))
        await transport.emitAttachOutput(
            Data("\\Documentation\u{001B}]8;;\u{001B}\\\n".utf8))

        try await waitUntil("styled and explicit hyperlink targets should settle") {
            store.attachLinks.map(\.target) == [
                "https://docs.example/guide",
                "https://actual.example/build/42?mode=full#result",
                "https://styled.example/path",
            ]
        }

        await store.leave().value
    }

    @Test func redrawnViewportTextSupplementsOutputWithoutJoiningRows() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await transport.emitAttachOutput(
            Data("https://\nredrawn.example/result\n".utf8))
        store.viewportTextDidChange(
            """
            Result: (https://redrawn.example/result).
            https://
            split.example/path
            """)

        try await waitUntil("the complete redrawn target should be observed") {
            store.attachLinks.map(\.target) == [
                "https://redrawn.example/result"
            ]
        }

        await store.leave().value
    }

    @Test func softWrappedViewportDoesNotAddPrefixesOfStreamTargets() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let target = "https://127.0.0.1:8443/private?token=literal#frag"

        try await goLive(store, transport)

        await transport.emitAttachOutput(Data("\(target)\n".utf8))
        try await waitUntil("the complete stream target should be observed") {
            store.attachLinks.map(\.target) == [target]
        }

        store.viewportTextDidChange(
            "https://127.0.0                  \n"
                + ".1:8443/private?to             \n"
                + "ken=literal#frag               ")

        #expect(store.attachLinks.map(\.target) == [target])

        await store.leave().value
    }

    /// The screen is rescanned on every viewport snapshot, so a screen holding
    /// more links than the index keeps must settle. It did not: the overflow
    /// was evicted, the next scan read the evicted targets as new, and
    /// reinserting them evicted others — the list churned forever. Each churn
    /// invalidated every view observing it, which drove SwiftUI back into the
    /// terminal's update, which took another snapshot. That loop hung the app
    /// on any agent whose screen carried enough links.
    @MainActor
    @Test func rescanningACrowdedScreenLeavesTheLinkListAlone() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        try await goLive(store, transport)
        // Equal-length and mutually non-prefixing, so the index's ambiguous
        // prefix rule cannot quietly drop them instead.
        let crowded = (0..<30)
            .map { "https://example.com/p\(String(format: "%03d", $0))" }
            .joined(separator: " \n")

        store.viewportTextDidChange(crowded)
        let settled = store.attachLinks.map(\.target)
        #expect(!settled.isEmpty)

        for _ in 0..<5 {
            store.viewportTextDidChange(crowded)
            #expect(
                store.attachLinks.map(\.target) == settled,
                "the same screen produced a different link list on rescan")
        }

        await store.leave().value
    }

    @Test func repeatedViewportLayoutsKeepTheLongestAmbiguousTarget() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let target =
            "https://softwrap.example/this/is/a/very/long/path?token=literal#finish"

        try await goLive(store, transport)

        store.viewportTextDidChange(target)
        #expect(store.attachLinks.map(\.target) == [target])

        store.viewportTextDidChange(
            "https://softwrap.example/this/is/a/very")
        store.viewportTextDidChange("https://softwrap")

        #expect(store.attachLinks.map(\.target) == [target])

        await store.leave().value
    }

    @Test func repeatedViewportSnapshotsDoNotRewriteStreamRecency() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        await transport.emitAttachOutput(
            Data(
                """
                https://older.example/result
                https://newer.example/result

                """.utf8))
        try await waitUntil("stream order should settle") {
            store.attachLinks.map(\.target) == [
                "https://newer.example/result",
                "https://older.example/result",
            ]
        }

        store.viewportTextDidChange("https://older.example/result")

        #expect(
            store.attachLinks.map(\.target) == [
                "https://newer.example/result",
                "https://older.example/result",
            ])

        await store.leave().value
    }

    @Test func osc8AcceptsC1IntroducerAndStringTerminatorForms() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        var output = Data([0x1B, 0x5D])
        output.append(Data("8;;https://c1-st.example/result".utf8))
        output.append(0x9C)
        output.append(Data("Result".utf8))
        output.append(contentsOf: [0x1B, 0x5D])
        output.append(Data("8;;".utf8))
        output.append(0x9C)
        output.append(0x0A)
        output.append(0x9D)
        output.append(Data("8;;https://c1-osc.example/docs".utf8))
        output.append(0x07)
        output.append(Data("Docs".utf8))
        output.append(0x9D)
        output.append(Data("8;;".utf8))
        output.append(0x07)
        output.append(0x0A)

        try await goLive(store, transport)
        await transport.emitAttachOutput(output)

        try await waitUntil("both C1 forms should expose their targets") {
            store.attachLinks.map(\.target) == [
                "https://c1-osc.example/docs",
                "https://c1-st.example/result",
            ]
        }

        await store.leave().value
    }

    @Test func c1ControlsSeparateAdjacentVisibleURLs() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        var output = Data("https://before-nel.example/result".utf8)
        output.append(0x85)
        output.append(Data("https://after-nel.example/result\n".utf8))
        output.append(Data("https://before-st.example/result".utf8))
        output.append(0x9C)
        output.append(Data("https://after-st.example/result\n".utf8))

        try await goLive(store, transport)
        await transport.emitAttachOutput(output)

        try await waitUntil("C1 controls should separate visible targets") {
            store.attachLinks.map(\.target) == [
                "https://after-st.example/result",
                "https://before-st.example/result",
                "https://after-nel.example/result",
                "https://before-nel.example/result",
            ]
        }

        await store.leave().value
    }

    @Test func osc8TargetsReuseWebValidationAndCollectionBounds() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let prefix = "https://bounded.example/"
        let maximumTarget =
            prefix
            + String(
                repeating: "a",
                count: 32 * 1024 - prefix.utf8.count)
        let oversizedTarget = maximumTarget + "b"

        try await goLive(store, transport)

        await emitOSC8(
            maximumTarget, label: "maximum", transport: transport)
        await emitOSC8(
            oversizedTarget, label: "oversized", transport: transport)
        await emitOSC8(
            "file:///tmp/result", label: "unsafe", transport: transport)
        await emitOSC8(
            "https:///missing-host", label: "missing", transport: transport)

        try await waitUntil("only the maximum valid target should be observed") {
            store.attachLinks.map(\.target) == [maximumTarget]
        }

        for index in 0..<21 {
            await emitOSC8(
                "https://example.com/item/\(index)",
                label: "item \(index)",
                transport: transport)
        }

        try await waitUntil("OSC targets should use the same bounded collection") {
            store.attachLinks.count == 20
                && store.attachLinks.first?.target == "https://example.com/item/20"
        }
        #expect(store.attachLinks.last?.target == "https://example.com/item/1")
        #expect(!store.attachLinks.contains { $0.target == maximumTarget })

        await store.leave().value
    }

    @Test func exactRepeatsMoveToFrontAndTheLeastRecentLinkIsEvicted() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        for index in 0..<21 {
            await transport.emitAttachOutput(
                Data("https://example.com/item?index=\(index)#detail\n".utf8))
        }
        await transport.emitAttachOutput(
            Data("https://example.com/item?index=1#detail\n".utf8))

        try await waitUntil("the bounded collection should settle") {
            store.attachLinks.count == 20
                && store.attachLinks.first?.target
                    == "https://example.com/item?index=1#detail"
        }
        #expect(
            !store.attachLinks.contains {
                $0.target == "https://example.com/item?index=0#detail"
            })
        #expect(
            store.attachLinks.contains {
                $0.target == "https://example.com/item?index=20#detail"
            })

        await store.leave().value
    }

    @Test func oneOutputChunkKeepsTheLatestLinksBeyondCollectionCapacity() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let output = (0..<25)
            .map { "https://example.com/item/\($0)" }
            .joined(separator: "\n") + "\n"

        try await goLive(store, transport)

        await transport.emitAttachOutput(Data(output.utf8))

        try await waitUntil("the complete output chunk should be observed") {
            store.attachLinks.count == 20
                && store.attachLinks.first?.target == "https://example.com/item/24"
        }
        #expect(store.attachLinks.last?.target == "https://example.com/item/5")
        #expect(
            !store.attachLinks.contains {
                $0.target == "https://example.com/item/4"
            })

        await store.leave().value
    }

    @Test func targetAtTheByteLimitIsAcceptedAndAnOversizedTargetIsIgnoredWhole()
        async throws
    {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let prefix = "https://example.com/"
        let maximumTarget =
            prefix
            + String(
                repeating: "a",
                count: 32 * 1024 - prefix.utf8.count)
        let oversizedTarget = maximumTarget + "b"

        try await goLive(store, transport)

        await transport.emitAttachOutput(Data((maximumTarget + "\n").utf8))
        await transport.emitAttachOutput(Data((oversizedTarget + "\n").utf8))
        await transport.emitAttachOutput(Data("https://example.com/sentinel\n".utf8))

        try await waitUntil("the output after the oversized target should be observed") {
            store.attachLinks.first?.target == "https://example.com/sentinel"
        }
        #expect(
            store.attachLinks.map(\.target) == [
                "https://example.com/sentinel",
                maximumTarget,
            ])

        await store.leave().value
    }

    @Test func balancedURLPunctuationIsRetainedWhileSurroundingPunctuationIsExcluded()
        async throws
    {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await transport.emitAttachOutput(
            Data(
                """
                Docs: (https://example.com/wiki/Function_(mathematics)).

                """.utf8))
        try await waitUntil("the literal target should be observed") {
            !store.attachLinks.isEmpty
        }
        #expect(
            store.attachLinks.map(\.target) == [
                "https://example.com/wiki/Function_(mathematics)"
            ])

        await store.leave().value
    }

    @Test func arbitraryOutputChunksJoinButRealLineBreaksDoNot() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await transport.emitAttachOutput(Data("Preview https://exa".utf8))
        await transport.emitAttachOutput(Data("mple.com/a/visually-".utf8))
        await transport.emitAttachOutput(Data("wrapped?q=1#result ".utf8))
        await transport.emitAttachOutput(Data("https://\nexample.com\n".utf8))

        try await waitUntil("the complete chunked target should be observed") {
            store.attachLinks.map(\.target) == [
                "https://example.com/a/visually-wrapped?q=1#result"
            ]
        }

        await store.leave().value
    }

    @Test func webPolicyRejectsUnsafeTargetsAndKeepsPrivateTargetsLiteral() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await transport.emitAttachOutput(
            Data(
                """
                file:///tmp/result https:///missing-host
                echo http://127.0.0.1:8443/path?q=x#fragment
                http://192.168.1.9:3000/private

                """.utf8))
        try await waitUntil("both literal private targets should be observed") {
            store.attachLinks.count == 2
        }
        #expect(
            store.attachLinks.map(\.target) == [
                "http://192.168.1.9:3000/private",
                "http://127.0.0.1:8443/path?q=x#fragment",
            ])

        await store.leave().value
    }

    @Test func linksSurviveTerminalRecoveryButLeavingAttachClearsThem() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        await transport.emitAttachOutput(Data("https://before.example/retry\n".utf8))
        try await waitUntil("the first link should be observed") {
            store.attachLinks.count == 1
        }

        await transport.endAttachFromRemote()
        try await waitUntil("the terminal end should surface") {
            if case .ended = store.terminalStatus { return true }
            return false
        }
        store.retryTerminal()
        try await paint(transport)
        try await waitUntil("the terminal should retry") {
            store.terminalStatus == .live
        }
        #expect(store.attachLinks.map(\.target) == ["https://before.example/retry"])

        await transport.emitAttachOutput(Data("https://after.example/retry\n".utf8))
        try await waitUntil("the retry output should be observed") {
            store.attachLinks.count == 2
        }
        let terminalID = store.terminalID
        store.transportGenerationDidChange(1)
        try await waitUntil("the Transport replacement should land") {
            store.terminalID != terminalID
        }
        #expect(
            store.attachLinks.map(\.target) == [
                "https://after.example/retry",
                "https://before.example/retry",
            ])

        await store.leave().value
        #expect(store.attachLinks.isEmpty)

        let laterAttach = makeStore(transport: transport, generation: 1)
        #expect(laterAttach.attachLinks.isEmpty)
        await laterAttach.leave().value
    }

    @Test func transportReplacementStopsTheOldTerminalBeforeReattaching() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let initialID = store.terminalID

        try await goLive(store, transport)

        store.transportGenerationDidChange(1)
        try await waitUntil("the terminal pipeline should be replaced") {
            store.terminalID != initialID
        }
        #expect(await transport.hasLiveAttachSession == false)

        try await goLive(store, transport, cols: 100, rows: 30)
        #expect(await transport.attachRequests.count == 2)

        await store.leave().value
    }

    @Test func rapidTransportReplacementsCoalesceToTheLatestGeneration() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let initialID = store.terminalID

        try await goLive(store, transport)

        store.transportGenerationDidChange(1)
        store.transportGenerationDidChange(2)
        try await waitUntil("the latest replacement should land") {
            store.terminalID != initialID
        }
        try await goLive(store, transport, cols: 100, rows: 30)
        #expect(await transport.attachRequests.count == 2)

        await store.leave().value
    }

    @Test func transportReplacementPreservesImageAttachState() async throws {
        // A reconnect replaces the terminal pipeline but must not touch the
        // image interaction: its stager resolves the live Transport per
        // call, so surfaced failures and results stay actionable.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        // One byte of garbage: preparation fails and the failure surfaces.
        store.selectImage(DataImageSelection(data: Data([0x01])))
        try await waitUntil("the failed image attach should surface") {
            store.imageState.isFailed
        }
        let surfacedFailure = store.imageState
        let initialID = store.terminalID

        store.transportGenerationDidChange(1)
        try await waitUntil("the terminal pipeline should be replaced") {
            store.terminalID != initialID
        }

        #expect(store.imageState == surfacedFailure)

        await store.leave().value
        #expect(store.imageState == .idle)
    }

    @Test func leaveDuringQueuedReplacementDoesNotResurrectTheTerminal() async throws {
        // leave() can race in behind a queued transport replacement; the
        // replacement must observe it and never rebuild the pipeline.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        let initialID = store.terminalID

        store.transportGenerationDidChange(1)
        await store.leave().value

        #expect(store.terminalID == initialID)
        #expect(store.terminalStatus == .stopped)
        #expect(await transport.hasLiveAttachSession == false)
        #expect(await transport.attachRequests.count == 1)

        // Generation changes arriving after leave must stay dead too.
        store.transportGenerationDidChange(2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.terminalID == initialID)
        #expect(await transport.attachRequests.count == 1)
    }

    @Test func rejoinAfterLeaveReattachesTheScreenThatCameBack() async throws {
        // onDisappear/onAppear are not always a real departure and return:
        // SwiftUI hands out removals the user never made, and the state that
        // comes back is the one that left. The store that comes back must
        // attach again instead of staying stopped behind a black surface.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        let leftID = store.terminalID

        await store.leave().value
        #expect(store.terminalStatus == .stopped)

        store.rejoin()
        // The screen is on stage again, so it must never read as a finished
        // session while the replacement is on its way.
        #expect(store.terminalStatus == .connecting)
        try await waitUntil("the terminal pipeline should be rebuilt") {
            store.terminalID != leftID
        }

        try await goLive(store, transport)
        #expect(await transport.attachRequests.count == 2)

        // The rejoined pipeline is wired end to end, not just opened.
        await transport.emitAttachOutput(Data("https://example.com/back\n".utf8))
        try await waitUntil("output should reach the rejoined screen") {
            store.attachLinks.map(\.target) == ["https://example.com/back"]
        }

        await store.leave().value
    }

    @Test func sameTransactionDisappearAppearPairComesBackConnecting() async throws {
        // SwiftUI can hand the spurious disappear/appear pair out
        // back-to-back in one transaction (a notification deep link or the
        // new-agent push landing amid sheet-dismissal churn). The departure
        // must be recorded synchronously: a Task-deferred leave() runs only
        // after rejoin() has already no-opped on hasLeft == false, and the
        // visible screen keeps a permanently stopped terminal — black, no
        // overlay, no recovery.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        let leftID = store.terminalID

        store.leave()
        store.rejoin()

        // On stage throughout: never a black surface with nothing to say.
        #expect(store.terminalStatus != .stopped)
        try await waitUntil("the terminal pipeline should be rebuilt") {
            store.terminalID != leftID
        }

        try await goLive(store, transport)
        #expect(await transport.attachRequests.count == 2)

        await store.leave().value
    }

    @Test func teardownRunsEvenAfterTheStoreItselfIsReleased() async throws {
        // The owner is `@State` on a view SwiftUI discards right after
        // `onDisappear`, so the teardown task is often the store's last
        // holder. It must run to completion regardless — a skipped teardown
        // leaves the live session holding the Host's only terminal channel,
        // and every later attach queues behind it forever.
        let transport = ScriptedTransport()
        var store: AgentAttachStore? = makeStore(transport: transport, generation: 0)
        try await goLive(store!, transport)

        store!.leave()
        store = nil  // SwiftUI discarding the view's state.

        try await waitUntil("the session must end without its owner") {
            await transport.hasLiveAttachSession == false
        }
    }

    @Test func aSpuriousReappearanceOffStageDoesNotResurrectTheTerminal() async throws {
        // The same disappear/appear pair also lands on *departing* screens
        // (an Agent switch, a notification deep link), whose views keep
        // laying out through the exit transition. A rebuilt pipeline there
        // would attach unseen and hold the Host's only terminal channel.
        let transport = ScriptedTransport()
        let stage = SelectedPane(current: "w1:p1")
        let store = makeStore(
            transport: transport, generation: 0,
            isOnStage: { stage.current == "w1:p1" })

        try await goLive(store, transport)
        let leftID = store.terminalID

        // The Console moves to another Agent; churn hands this screen a
        // spurious pair while its view keeps reporting sizes on the way out.
        stage.current = "w1:p2"
        store.leave()
        store.rejoin()
        for _ in 0..<20 {
            store.viewDidResize(cols: 100, rows: 30)
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(store.terminalID == leftID)
        #expect(store.terminalStatus == .stopped)
        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.hasLiveAttachSession == false)
    }

    @Test func aDepartingScreensChurnCannotStarveTheNextScreensAttach() async throws {
        // The stuck-Connecting regression: the Host has one terminal channel
        // and attaches queue FIFO behind it (EventsSession's permit). A
        // departing screen resurrected by the spurious pair would take that
        // channel unseen, and the screen the user is actually looking at
        // would wait on "Connecting…" forever.
        let transport = ScriptedTransport()
        let permit = TerminalChannelPermit()
        let stage = SelectedPane(current: "w1:p1")
        let runner = permitGatedRunner(transport, permit)

        let departing = makeStore(
            transport: transport, generation: 0, target: "w1:p1",
            isOnStage: { stage.current == "w1:p1" }, runTerminal: runner)
        try await goLive(departing, transport)

        stage.current = "w1:p2"
        departing.leave()
        departing.rejoin()
        for _ in 0..<20 {
            departing.viewDidResize(cols: 100, rows: 30)
            try await Task.sleep(for: .milliseconds(5))
        }
        try await waitUntil("the departing screen's attach should end") {
            await transport.hasLiveAttachSession == false
        }

        let incoming = makeStore(
            transport: transport, generation: 0, target: "w1:p2",
            isOnStage: { stage.current == "w1:p2" }, runTerminal: runner)
        try await goLive(incoming, transport)

        // The channel went to the screen on stage, never to a zombie.
        #expect(await transport.attachRequests.map(\.target) == ["w1:p1", "w1:p2"])

        await incoming.leave().value
    }

    @Test func rejoinWithoutLeaveLeavesTheLiveTerminalAlone() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        let liveID = store.terminalID

        store.rejoin()
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.terminalID == liveID)
        #expect(store.terminalStatus == .live)
        #expect(await transport.attachRequests.count == 1)

        await store.leave().value
    }

    @Test func leaveRacingARejoinKeepsTheAttachDown() async throws {
        // The reverse race of `leaveDuringQueuedReplacementDoesNotResurrect…`:
        // a rejoin already queued must not rebuild behind a later leave.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await store.leave().value
        let leftID = store.terminalID
        store.rejoin()
        await store.leave().value

        try await Task.sleep(for: .milliseconds(50))
        #expect(store.terminalID == leftID)
        #expect(store.terminalStatus == .stopped)
        #expect(await transport.attachRequests.count == 1)
    }

    @Test func everyTerminalPresentsAnIdentityNoDiscardedTerminalEverHeld() {
        // The reconnect path is a teardown followed by a replacement moments
        // later, which is the allocation pattern most likely to hand the
        // replacement its predecessor's address. Building and dropping stores
        // in a tight loop is that pattern with the timing taken out: an
        // address-derived identity collapses onto a handful of reused values,
        // an identity the store owns cannot (#143).
        let transport = ScriptedTransport()
        var identities: [AnyHashable] = []
        for _ in 0..<200 {
            identities.append(
                AnyHashable(makeStore(transport: transport, generation: 0).terminalID))
        }

        #expect(Set(identities).count == 200)
    }

    @Test func aReplacedTerminalGetsASurfaceOfItsOwnThatItsBytesReach() async throws {
        // The identity's whole job: a replacement terminal must make SwiftUI
        // build a new surface, because `makeUIView` is the only place the new
        // feed is attached. A surface that is not rebuilt leaves the new
        // session writing into a feed with nowhere to go — bytes buffered
        // forever behind a stale screen, with the session reading as live.
        //
        // One replacement pins the identity being *per pipeline* rather than
        // shared, and nothing more: the predecessor is still held while the
        // replacement is allocated, so even an address could not collide here.
        // Address reuse needs two replacements between renders — see
        // `aTerminalTwoReplacementsPastTheLastRenderStillGetsASurfaceOfItsOwn`.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let stage = SurfaceIdentityStage()
        stage.update(id: store.terminalID, feed: store.terminalFeed)

        try await goLive(store, transport)
        await transport.emitAttachOutput(Data("before".utf8))
        try await waitUntil("the first session should reach the first surface") {
            stage.surfaces.last?.text.contains("before") == true
        }
        #expect(stage.surfaces.count == 1)

        let replacedID = store.terminalID
        store.transportGenerationDidChange(1)
        try await waitUntil("the terminal pipeline should be replaced") {
            store.terminalID != replacedID
        }

        stage.update(id: store.terminalID, feed: store.terminalFeed)
        #expect(stage.surfaces.count == 2)

        try await goLive(store, transport, cols: 100, rows: 30)
        await transport.emitAttachOutput(Data("after".utf8))
        try await waitUntil("the replacement's bytes should reach its own surface") {
            stage.surfaces.last?.text.contains("after") == true
        }
        #expect(stage.surfaces.first?.text.contains("after") == false)

        await store.leave().value
    }

    @Test func aTerminalTwoReplacementsPastTheLastRenderStillGetsASurfaceOfItsOwn() async throws {
        // SwiftUI does not compare a pipeline's identity against the live
        // predecessor — it compares against the identity it recorded at its
        // last render. Two replacements between renders put a *freed*
        // generation on the other side of that comparison: generation N is
        // released before N+2 is allocated, and the allocator hands the
        // address straight back. Measured, thirteen consecutive terminal
        // generations occupied two addresses, so N and N+2 necessarily share
        // one. An address-derived identity leaves the surface unbuilt and the
        // third generation's feed without a sink (#143).
        //
        // Whether the shipped screen really skips a render between two
        // replacements is unproven and needs a hosted-view harness (#152).
        // The identity has to survive it either way.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let stage = SurfaceIdentityStage()
        stage.update(id: store.terminalID, feed: store.terminalFeed)

        try await goLive(store, transport)
        await transport.emitAttachOutput(Data("before".utf8))
        try await waitUntil("the first session should reach the first surface") {
            stage.surfaces.last?.text.contains("before") == true
        }
        #expect(stage.surfaces.count == 1)

        for generation in UInt64(1)...2 {
            let replacedID = store.terminalID
            store.transportGenerationDidChange(generation)
            try await waitUntil("terminal generation \(generation) should be built") {
                store.terminalID != replacedID
            }
        }

        stage.update(id: store.terminalID, feed: store.terminalFeed)
        #expect(stage.surfaces.count == 2)

        try await goLive(store, transport, cols: 100, rows: 30)
        await transport.emitAttachOutput(Data("after".utf8))
        try await waitUntil("the third generation's bytes should reach its own surface") {
            stage.surfaces.last?.text.contains("after") == true
        }
        #expect(stage.surfaces.first?.text.contains("after") == false)

        await store.leave().value
    }

    /// SwiftUI's `.id()` rule with nothing else in it: an unchanged identity
    /// keeps the surface already built, a changed one builds another. The
    /// attach mirrors `TerminalScreenView.makeUIView`, which is the only place
    /// a feed ever acquires a sink.
    @MainActor
    private final class SurfaceIdentityStage {
        private(set) var surfaces: [Surface] = []
        private var currentID: AnyHashable?

        func update(id: some Hashable, feed: TerminalByteFeed) {
            let id = AnyHashable(id)
            guard id != currentID else { return }
            currentID = id
            let surface = Surface()
            surfaces.append(surface)
            feed.attach(surface)
        }
    }

    @MainActor
    private final class Surface: TerminalByteSink {
        private(set) var chunks: [Data] = []
        var text: String {
            String(decoding: chunks.reduce(Data(), +), as: UTF8.self)
        }

        func receive(_ data: Data) {
            chunks.append(data)
        }
    }

    @Test func successfulCloseLeavesTheWholeAttachInteraction() async throws {
        let transport = ScriptedTransport()
        let closeCalls = CloseCallRecorder()
        let store = makeStore(
            transport: transport, generation: 0,
            close: { await closeCalls.record() })

        try await goLive(store, transport)

        #expect(await store.confirmClose())
        #expect(await closeCalls.count == 1)
        #expect(store.terminalStatus == .stopped)
        #expect(await transport.hasLiveAttachSession == false)
    }

    private func makeStore(
        transport: ScriptedTransport,
        generation: UInt64?,
        target: String = "w1:p1",
        isOnStage: @escaping () -> Bool = { true },
        runTerminal: TerminalSessionRunner? = nil,
        close: @escaping () async throws -> Void = {}
    ) -> AgentAttachStore {
        AgentAttachStore(
            target: target,
            paneTitle: "Agent",
            transportGeneration: generation,
            isOnStage: isOnStage,
            runTerminal: runTerminal ?? { request, handler in
                let session = try await transport.attachTerminal(request)
                do {
                    try await handler.run(session)
                    await session.end()
                } catch {
                    await session.end()
                    throw error
                }
            },
            stageImage: { _, _ in
                throw ImageStagingError.transferFailed
            },
            closePane: close)
    }

    /// Brings the terminal up the way an attach does: the size report opens
    /// the channel, and the remote's first paint is what makes it live. The
    /// paint is a bare screen clear, so it adds nothing for the link index to
    /// find.
    private func goLive(
        _ store: AgentAttachStore, _ transport: ScriptedTransport,
        cols: Int = 80, rows: Int = 24
    ) async throws {
        store.viewDidResize(cols: cols, rows: rows)
        try await paint(transport)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }
    }

    /// The remote's first paint, once the channel is actually up.
    private func paint(_ transport: ScriptedTransport) async throws {
        try await waitUntil("attach should open") { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(Data("\u{1B}[2J".utf8)))
    }

    private func emitOSC8(
        _ target: String,
        label: String,
        transport: ScriptedTransport
    ) async {
        await transport.emitAttachOutput(
            Data(
                "\u{001B}]8;;\(target)\u{0007}\(label)\u{001B}]8;;\u{0007}\n"
                    .utf8))
    }

    private func waitUntil(
        _ comment: Comment,
        timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }

    /// A runner with `EventsSession.withTerminalTransport`'s semantics: one
    /// Attach owns the Host's terminal channel for its entire lifetime,
    /// including teardown, and later attaches queue FIFO behind it.
    private func permitGatedRunner(
        _ transport: ScriptedTransport, _ permit: TerminalChannelPermit
    ) -> TerminalSessionRunner {
        { request, handler in
            try await permit.acquire()
            do {
                let session = try await transport.attachTerminal(request)
                do {
                    try await handler.run(session)
                    await session.end()
                } catch {
                    await session.end()
                    throw error
                }
            } catch {
                await permit.release()
                throw error
            }
            await permit.release()
        }
    }
}

/// Which pane the Console's router currently has on stage.
@MainActor
private final class SelectedPane {
    var current: String

    init(current: String) {
        self.current = current
    }
}

/// The Host's single terminal channel, as `EventsSession` arbitrates it:
/// waiters are FIFO and, like the real `acquireTerminal`, cancellation-aware.
private actor TerminalChannelPermit {
    private var inUse = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    func acquire() async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if inUse {
                    waiters.append((id, continuation))
                } else {
                    inUse = true
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            inUse = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private actor CloseCallRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

@MainActor
private final class DeferredAttachLinkOpener {
    private var continuations: [String: CheckedContinuation<Bool, Never>] = [:]

    var pendingTargets: [String] {
        continuations.keys.sorted()
    }

    func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            continuations[url.absoluteString] = continuation
        }
    }

    func complete(_ target: String, accepted: Bool) {
        continuations.removeValue(forKey: target)?.resume(returning: accepted)
    }
}

@MainActor
private final class CancellationAwareAttachLinkOpener {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var pendingTarget: String?
    private(set) var cancelledTargets: [String] = []

    func open(_ url: URL) async -> Bool {
        let target = url.absoluteString
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                pendingTarget = target
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(target)
            }
        }
    }

    private func cancel(_ target: String) {
        guard pendingTarget == target else { return }
        pendingTarget = nil
        cancelledTargets.append(target)
        continuation?.resume(returning: false)
        continuation = nil
    }
}

/// The Attach screen's owner, covering only what the foreground return has to
/// travel through to reach the terminal pipeline (#141).
@MainActor
@Suite("Agent attach store foreground")
struct AgentAttachStoreForegroundTests {
    private func makeStore(
        transport: ScriptedTransport, isOnStage: @escaping () -> Bool = { true }
    ) -> AgentAttachStore {
        AgentAttachStore(
            target: "w1:p1",
            paneTitle: "pane",
            transportGeneration: 1,
            isOnStage: isOnStage,
            runTerminal: { request, handler in
                let session = try await transport.attachTerminal(request)
                do {
                    try await handler.run(session)
                    await session.end()
                } catch {
                    await session.end()
                    throw error
                }
            },
            stageImage: { _, _ in throw TransportError.cancelled },
            closePane: {})
    }

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

    @Test func theForegroundReturnReachesTheLiveTerminal() async throws {
        // `didBecomeActive()` used to forward to the image store alone, so
        // nothing on the Attach path reacted to foregrounding at all.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("attach should open") { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(Data("\u{1B}[2J".utf8)))
        try await waitUntil("terminal should go live") { store.terminalStatus == .live }

        store.didBecomeActive()

        try await waitUntil("the return should reach the terminal's remote") {
            await transport.attachInputs == [
                .resize(cols: 79, rows: 24),
                .resize(cols: 80, rows: 24),
            ]
        }
        await store.leave().value
    }

}

/// The Attach store's byte pipe: opening bytes buffer for the first surface,
/// while bytes from an obsolete pipeline are not replayed into a later one.
@MainActor
@Suite("Terminal byte feed")
struct TerminalByteFeedTests {
    /// Stands in for the Ghostty surface the representable view creates.
    @MainActor
    private final class Surface: TerminalByteSink {
        var chunks: [Data] = []

        func receive(_ data: Data) {
            chunks.append(data)
        }
    }

    @Test func bytesWrittenBeforeAnySurfaceAreHeldForTheFirstOne() {
        let feed = TerminalByteFeed()

        feed.write(Data("opening".utf8))

        let surface = Surface()
        feed.attach(surface)
        #expect(surface.chunks == [Data("opening".utf8)])
    }

    @Test func bytesWrittenIntoALiveSurfaceAreDelivered() {
        let feed = TerminalByteFeed()
        let surface = Surface()
        feed.attach(surface)

        feed.write(Data("frame".utf8))
        #expect(surface.chunks == [Data("frame".utf8)])
    }

    @Test func bytesWrittenAfterTheSurfaceIsGoneAreNotReplayed() {
        let feed = TerminalByteFeed()
        var surface: Surface? = Surface()
        if let surface { feed.attach(surface) }
        surface = nil

        feed.write(Data("obsolete".utf8))
        let replacement = Surface()
        feed.attach(replacement)
        #expect(replacement.chunks.isEmpty)
    }

    @Test func anEmptyChunkDoesNotReachTheSurface() {
        let feed = TerminalByteFeed()
        let surface = Surface()
        feed.attach(surface)

        feed.write(Data())
        #expect(surface.chunks.isEmpty)
    }
}
