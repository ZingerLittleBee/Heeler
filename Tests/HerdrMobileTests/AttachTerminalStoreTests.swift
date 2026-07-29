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

@MainActor
@Suite("Agent Attach store")
struct AgentAttachStoreTests {
    @Test func plainWebURLsBecomeAttachLinksInMostRecentOrder() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }

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

        await store.leave()
    }

    @Test func styledTextAndOSC8HyperlinksExposeTheirRealTargets() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }

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

        await store.leave()
    }

    @Test func redrawnViewportTextSupplementsOutputWithoutJoiningRows() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }

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

        await store.leave()
    }

    @Test func repeatedViewportSnapshotsDoNotRewriteStreamRecency() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }
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

        await store.leave()
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

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }
        await transport.emitAttachOutput(output)

        try await waitUntil("both C1 forms should expose their targets") {
            store.attachLinks.map(\.target) == [
                "https://c1-osc.example/docs",
                "https://c1-st.example/result",
            ]
        }

        await store.leave()
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

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }

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

        await store.leave()
    }

    @Test func exactRepeatsMoveToFrontAndTheLeastRecentLinkIsEvicted() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }

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

        await store.leave()
    }

    @Test func oneOutputChunkKeepsTheLatestLinksBeyondCollectionCapacity() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let output = (0..<25)
            .map { "https://example.com/item/\($0)" }
            .joined(separator: "\n") + "\n"

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }

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

        await store.leave()
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

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }

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

        await store.leave()
    }

    @Test func balancedURLPunctuationIsRetainedWhileSurroundingPunctuationIsExcluded()
        async throws
    {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }

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

        await store.leave()
    }

    @Test func arbitraryOutputChunksJoinButRealLineBreaksDoNot() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }

        await transport.emitAttachOutput(Data("Preview https://exa".utf8))
        await transport.emitAttachOutput(Data("mple.com/a/visually-".utf8))
        await transport.emitAttachOutput(Data("wrapped?q=1#result ".utf8))
        await transport.emitAttachOutput(Data("https://\nexample.com\n".utf8))

        try await waitUntil("the complete chunked target should be observed") {
            store.attachLinks.map(\.target) == [
                "https://example.com/a/visually-wrapped?q=1#result"
            ]
        }

        await store.leave()
    }

    @Test func webPolicyRejectsUnsafeTargetsAndKeepsPrivateTargetsLiteral() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }

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

        await store.leave()
    }

    @Test func linksSurviveTerminalRecoveryButLeavingAttachClearsThem() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }
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

        await store.leave()
        #expect(store.attachLinks.isEmpty)

        let laterAttach = makeStore(transport: transport, generation: 1)
        #expect(laterAttach.attachLinks.isEmpty)
        await laterAttach.leave()
    }

    @Test func transportReplacementStopsTheOldTerminalBeforeReattaching() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let initialID = store.terminalID

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the initial terminal should go live") {
            store.terminalStatus == .live
        }

        store.transportGenerationDidChange(1)
        try await waitUntil("the terminal pipeline should be replaced") {
            store.terminalID != initialID
        }
        #expect(await transport.hasLiveAttachSession == false)

        store.viewDidResize(cols: 100, rows: 30)
        try await waitUntil("the replacement terminal should go live") {
            store.terminalStatus == .live
        }
        #expect(await transport.attachRequests.count == 2)

        await store.leave()
    }

    @Test func rapidTransportReplacementsCoalesceToTheLatestGeneration() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let initialID = store.terminalID

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the initial terminal should go live") {
            store.terminalStatus == .live
        }

        store.transportGenerationDidChange(1)
        store.transportGenerationDidChange(2)
        try await waitUntil("the latest replacement should land") {
            store.terminalID != initialID
        }
        store.viewDidResize(cols: 100, rows: 30)
        try await waitUntil("the replacement terminal should go live") {
            store.terminalStatus == .live
        }
        #expect(await transport.attachRequests.count == 2)

        await store.leave()
    }

    @Test func transportReplacementPreservesImageAttachState() async throws {
        // A reconnect replaces the terminal pipeline but must not touch the
        // image interaction: its stager resolves the live Transport per
        // call, so surfaced failures and results stay actionable.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }

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

        await store.leave()
        #expect(store.imageState == .idle)
    }

    @Test func leaveDuringQueuedReplacementDoesNotResurrectTheTerminal() async throws {
        // leave() can race in behind a queued transport replacement; the
        // replacement must observe it and never rebuild the pipeline.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the initial terminal should go live") {
            store.terminalStatus == .live
        }
        let initialID = store.terminalID

        store.transportGenerationDidChange(1)
        await store.leave()

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

    @Test func successfulCloseLeavesTheWholeAttachInteraction() async throws {
        let transport = ScriptedTransport()
        let closeCalls = CloseCallRecorder()
        let store = makeStore(transport: transport, generation: 0) {
            await closeCalls.record()
        }

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }

        #expect(await store.confirmClose())
        #expect(await closeCalls.count == 1)
        #expect(store.terminalStatus == .stopped)
        #expect(await transport.hasLiveAttachSession == false)
    }

    private func makeStore(
        transport: ScriptedTransport,
        generation: UInt64?,
        close: @escaping () async throws -> Void = {}
    ) -> AgentAttachStore {
        AgentAttachStore(
            target: "w1:p1",
            paneTitle: "Agent",
            transportGeneration: generation,
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
            stageImage: { _, _ in
                throw ImageStagingError.transferFailed
            },
            closePane: close)
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
}

private actor CloseCallRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
