import Foundation
import SwiftTerm
import Testing

@testable import HerdrMobile

/// The Observe terminal channel (#9) over the real stack: Citadel ->
/// localhost sshd -> a frame-emitting script standing in for `herdr terminal
/// session control` (injectable at the environment boundary, like the wake
/// command). No PTY exists on this SSH channel; herdr controls the Agent's
/// existing PTY remotely.
@Suite(
    "Terminal observe e2e",
    .enabled(
        if: LocalSSHTestEnvironment.isAvailable,
        "requires localhost sshd, socat, and an authorized Ed25519 test key"),
    .timeLimit(.minutes(1)))
struct TerminalObserveE2ETests {
    private static func frameLine(
        seq: Int, full: Bool = false, bytes: String, type: String = "terminal.frame"
    ) -> String {
        let base64 = Data(bytes.utf8).base64EncodedString()
        return
            #"{"type":"\#(type)","seq":\#(seq),"full":\#(full),"width":80,"height":24,"# +
            #""encoding":"ansi","bytes":"\#(base64)"}"#
    }

    @Test func framesStreamDecodedAndRenderThroughSwiftTerm() async throws {
        // A full repaint, then an incremental frame written 300ms later,
        // proving live streaming. The decoded bytes must drive a real
        // terminal emulator: base64-in-JSON in, rendered characters out.
        let repaint = "\u{1B}[2J\u{1B}[Hhello \u{1B}[31mred\u{1B}[0m"
        try await withObserveTransport(
            script: """
            echo '\(Self.frameLine(seq: 1, full: true, bytes: repaint))'
            sleep 0.3
            echo '\(Self.frameLine(seq: 2, bytes: " more"))'
            exec sleep 15
            """
        ) { transport in
            let stream = try await transport.observeTerminal(
                TerminalObserveRequest(target: "w1:p1", cols: 80, rows: 24))
            var iterator = stream.frames.makeAsyncIterator()

            let first = try #require(try await iterator.next())
            #expect(first.seq == 1)
            #expect(first.isFull)
            #expect(first.width == 80)
            let second = try #require(try await iterator.next())
            #expect(second.seq == 2)
            #expect(!second.isFull)

            // The pipeline's contract: what came off the wire renders.
            let delegate = RenderDelegate()
            let terminal = Terminal(
                delegate: delegate, options: TerminalOptions(cols: 80, rows: 24))
            terminal.feed(byteArray: [UInt8](first.bytes))
            terminal.feed(byteArray: [UInt8](second.bytes))
            let topLine = terminal.getLine(row: 0)?.translateToString(trimRight: true)
            #expect(topLine == "hello red more")

            await stream.end()
        }
    }

    @Test func commandLineCarriesQuotedTargetAndGeometry() async throws {
        // The script echoes its own arguments back as a frame payload,
        // verifying the exact command line the transport constructs.
        try await withObserveTransport(
            script: """
            printf '{"type":"terminal.frame","seq":1,"encoding":"ansi","bytes":"%s"}\\n' \
                "$(printf '%s' "$*" | base64 | tr -d '\\n')"
            exec sleep 15
            """
        ) { transport in
            let stream = try await transport.observeTerminal(
                TerminalObserveRequest(target: "w1:p1", cols: 100, rows: 42))
            var iterator = stream.frames.makeAsyncIterator()
            let frame = try #require(try await iterator.next())
            #expect(String(decoding: frame.bytes, as: UTF8.self) == "w1:p1 --cols 100 --rows 42")
            await stream.end()
        }
    }

    @Test func junkAndUnknownFrameTypesAreDroppedButStreamSurvives() async throws {
        try await withObserveTransport(
            script: """
            echo 'not json at all'
            echo '\(Self.frameLine(seq: 1, bytes: "spooky", type: "terminal.haunted"))'
            echo '\(Self.frameLine(seq: 2, bytes: "kept"))'
            exec sleep 15
            """
        ) { transport in
            let stream = try await transport.observeTerminal(
                TerminalObserveRequest(target: "w1:p1", cols: 80, rows: 24))
            var iterator = stream.frames.makeAsyncIterator()
            let frame = try #require(try await iterator.next())
            #expect(frame.seq == 2)
            #expect(String(decoding: frame.bytes, as: UTF8.self) == "kept")
            await stream.end()
        }
    }

    @Test func endClosesTheChannelPromptlyAndFreesTheHost() async throws {
        // The spike gotcha again: a live exec channel ignores task
        // cancellation, so end() must close it explicitly, after which a
        // new observe must be possible. This injected command ignores stdin
        // EOF, exercising the fallback kill-on-EOF wrapper; without it,
        // end() would sit out the script's full 15s hold.
        try await withObserveTransport(
            script: """
            echo '\(Self.frameLine(seq: 1, full: true, bytes: "one"))'
            exec sleep 15
            """
        ) { transport in
            let stream = try await transport.observeTerminal(
                TerminalObserveRequest(target: "w1:p1", cols: 80, rows: 24))
            var iterator = stream.frames.makeAsyncIterator()
            _ = try #require(try await iterator.next())
            let start = ContinuousClock.now
            await stream.end()
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .seconds(5), "end() must not wait out the remote hold, took \(elapsed)")
            #expect(try await iterator.next() == nil)

            let second = try await transport.observeTerminal(
                TerminalObserveRequest(target: "w1:p1", cols: 80, rows: 24))
            var secondIterator = second.frames.makeAsyncIterator()
            _ = try #require(try await secondIterator.next())
            await second.end()
        }
    }

    @Test func stdinAwareControlCommandDetachesOnChannelEOF() async throws {
        try await withObserveTransport(
            script: """
            echo '\(Self.frameLine(seq: 1, full: true, bytes: "one"))'
            cat >/dev/null
            """,
            commandHandlesStdinEOF: true
        ) { transport in
            let stream = try await transport.observeTerminal(
                TerminalObserveRequest(target: "w1:p1", cols: 64, rows: 30))
            var iterator = stream.frames.makeAsyncIterator()
            _ = try #require(try await iterator.next())

            let start = ContinuousClock.now
            await stream.end()
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .seconds(5), "EOF-aware command took \(elapsed) to detach")
            #expect(try await iterator.next() == nil)
        }
    }

    @Test func secondObserveWhileOneIsLiveIsRefused() async throws {
        // One dedicated terminal channel per Host, by design (the session
        // slot budget: 8 RPC + events + terminal = MaxSessions 10).
        try await withObserveTransport(
            script: """
            echo '\(Self.frameLine(seq: 1, full: true, bytes: "one"))'
            exec sleep 15
            """
        ) { transport in
            let stream = try await transport.observeTerminal(
                TerminalObserveRequest(target: "w1:p1", cols: 80, rows: 24))
            await #expect(throws: TransportError.terminalChannelAlreadyOpen) {
                _ = try await transport.observeTerminal(
                    TerminalObserveRequest(target: "w1:p1", cols: 80, rows: 24))
            }
            await stream.end()
        }
    }

    @Test func remoteExitSurfacesAsChannelFailedAndFreesTheHost() async throws {
        // The observe command exiting (pane closed, herdr died) must finish
        // the stream with an error and leave the Host free to re-observe.
        try await withObserveTransport(
            script: """
            echo '\(Self.frameLine(seq: 1, full: true, bytes: "one"))'
            """
        ) { transport in
            let stream = try await transport.observeTerminal(
                TerminalObserveRequest(target: "w1:p1", cols: 80, rows: 24))
            var iterator = stream.frames.makeAsyncIterator()
            _ = try #require(try await iterator.next())
            do {
                _ = try await iterator.next()
                Issue.record("stream should have failed on remote exit")
            } catch TransportError.channelFailed {}

            let second = try await transport.observeTerminal(
                TerminalObserveRequest(target: "w1:p1", cols: 80, rows: 24))
            await second.end()
        }
    }

    @Test func observeIsExemptFromTheExecSlotQueue() async throws {
        // The queue bounds RPC exec channels at 8 precisely so the terminal
        // channel can hold its own session slot. With an observe stream
        // live, a full queue-width of hanging RPCs must still all reach the
        // fake herdr server: 8 concurrent socket connections.
        let server = try FakeHerdrServer { _ in nil }
        defer { server.stop() }
        try await withObserveTransport(
            script: """
            echo '\(Self.frameLine(seq: 1, full: true, bytes: "one"))'
            exec sleep 15
            """,
            socketPath: server.socketPath,
            requestTimeout: .seconds(3)
        ) { transport in
            let stream = try await transport.observeTerminal(
                TerminalObserveRequest(target: "w1:p1", cols: 80, rows: 24))
            var iterator = stream.frames.makeAsyncIterator()
            _ = try #require(try await iterator.next())

            await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask { _ = try await transport.listAgents() }
                }
                _ = await server.wait(for: { $0.connectionCount == 8 })
                while let result = await group.nextResult() {
                    if case .success = result {
                        Issue.record("hung agent.list unexpectedly succeeded")
                    }
                }
            }
            #expect(server.connectionCount == 8)
            await stream.end()
        }
    }

    /// Connects a real SSH transport to localhost whose observe command is a
    /// throwaway `/bin/sh` script (the simulator shares the host
    /// filesystem), and tears everything down afterwards. The wake command
    /// is stubbed to a no-op so no test path can ever poke the machine's
    /// real herdr server.
    private func withObserveTransport(
        script: String,
        socketPath: String? = nil,
        requestTimeout: Duration = .seconds(15),
        commandHandlesStdinEOF: Bool = false,
        body: (SSHTransport) async throws -> Void
    ) async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("observe-\(UUID().uuidString.prefix(8)).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        var settings = environment.makeSettings(
            socket: .absolutePath(socketPath ?? "/tmp/herdr-unused.sock"),
            wakeCommand: "false",
            requestTimeout: requestTimeout)
        settings.observeCommand = "/bin/sh \(scriptURL.path)"
        settings.observeCommandHandlesStdinEOF = commandHandlesStdinEOF
        let transport = try await SSHTransport.connect(settings: settings)
        do {
            try await body(transport)
        } catch {
            try? await transport.close()
            throw error
        }
        try await transport.close()
    }
}

/// Minimal SwiftTerm delegate for headless rendering; Observe never sends
/// input, so the response channel goes nowhere.
private final class RenderDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
