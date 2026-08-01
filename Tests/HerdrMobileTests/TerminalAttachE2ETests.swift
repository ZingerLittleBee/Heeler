import Foundation
import Testing

@testable import HerdrMobile

/// The Attach terminal channel (#11) over the real stack: Citadel `withPTY`
/// -> localhost sshd -> a script standing in for `herdr agent attach`
/// (injectable at the environment boundary). The
/// M1 spec's required proof: attach round-trips keystrokes through a real
/// PTY, and window-change reaches the remote terminal.
///
/// The bootstrap line rides through the test user's real login shell
/// (whatever it is — fish included), which is exactly the production path.
@Suite(
    "Terminal attach e2e",
    .enabled(
        if: LocalSSHTestEnvironment.isAvailable,
        "requires localhost sshd, socat, and an authorized Ed25519 test key"),
    .timeLimit(.minutes(1)))
struct TerminalAttachE2ETests {
    @Test func attachRoundTripsKeystrokesThroughARealPTY() async throws {
        // The script proves three load-bearing things at once: the channel
        // has a PTY (herdr agent attach refuses to run without one, M0
        // spike), the quoted target arrived as a plain argument, and raw
        // keystrokes — escape sequences included — round-trip.
        try await withAttachTransport(
            script: """
            stty -echo
            [ -t 0 ] && printf 'TTY-OK\\n'
            printf 'READY %s\\n' "$*"
            while IFS= read -r line; do printf 'GOT:%s\\n' "$line"; done
            """
        ) { transport in
            let session = try await transport.attachTerminal(
                TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24))
            var iterator = session.output.makeAsyncIterator()
            var seen = ""
            try await expectOutput(&iterator, accumulated: &seen, contains: "TTY-OK")
            try await expectOutput(&iterator, accumulated: &seen, contains: "READY w1:p1")

            session.send(Data("ping-1\n".utf8))
            try await expectOutput(&iterator, accumulated: &seen, contains: "GOT:ping-1")

            // An Up-arrow escape sequence followed by text, as the terminal
            // would emit while navigating a TUI menu.
            session.send(Data("\u{1B}[Aok\n".utf8))
            try await expectOutput(&iterator, accumulated: &seen, contains: "GOT:\u{1B}[Aok")

            await session.end()
        }
    }

    @Test func windowChangeReachesTheRemotePTY() async throws {
        // The rotation path: resize() must change the remote PTY's winsize.
        // `stty size` reads it back on demand — no SIGWINCH handling needed.
        try await withAttachTransport(
            script: """
            stty -echo
            printf 'READY\\n'
            while IFS= read -r line; do stty size; done
            """
        ) { transport in
            let session = try await transport.attachTerminal(
                TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24))
            var iterator = session.output.makeAsyncIterator()
            var seen = ""
            try await expectOutput(&iterator, accumulated: &seen, contains: "READY")

            session.send(Data("\n".utf8))
            try await expectOutput(&iterator, accumulated: &seen, contains: "24 80")

            // Keystrokes and resizes share one ordered stream, so the probe
            // newline cannot overtake the window change.
            // Exercise repeated geometry changes in one live channel. A
            // silently dead writer would leave the stream alive while one of
            // these probes kept reporting the previous PTY size.
            for step in 0..<20 {
                let cols = 100 + step
                let rows = 40 + step
                session.resize(cols: cols, rows: rows)
                session.send(Data("\n".utf8))
                try await expectOutput(
                    &iterator, accumulated: &seen, contains: "\(rows) \(cols)")
            }

            await session.end()
        }
    }

    @Test func endClosesTheChannelPromptlyAndFreesTheHost() async throws {
        // A PTY channel needs no kill-on-EOF wrapper: closing it HUPs the
        // remote process group. Promptness is
        // load-bearing — without the HUP this end() would sit out the
        // script's full 15s hold.
        try await withAttachTransport(
            script: """
            printf 'READY\\n'
            exec sleep 15
            """
        ) { transport in
            let session = try await transport.attachTerminal(
                TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24))
            var iterator = session.output.makeAsyncIterator()
            var seen = ""
            try await expectOutput(&iterator, accumulated: &seen, contains: "READY")

            let start = ContinuousClock.now
            await session.end()
            let elapsed = ContinuousClock.now - start
            #expect(
                elapsed < .seconds(5), "end() must not wait out the remote hold, took \(elapsed)")
            #expect(try await iterator.next() == nil)

            let second = try await transport.attachTerminal(
                TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24))
            var secondIterator = second.output.makeAsyncIterator()
            var secondSeen = ""
            try await expectOutput(&secondIterator, accumulated: &secondSeen, contains: "READY")
            await second.end()
        }
    }

    @Test func cleanRemoteExitFinishesTheStreamAndFreesTheHost() async throws {
        // The user detaching inside the TUI: attach exits 0, the stream
        // finishes without error, and the Host is free to reattach.
        try await withAttachTransport(
            script: """
            printf 'BYE\\n'
            """
        ) { transport in
            let session = try await transport.attachTerminal(
                TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24))
            var iterator = session.output.makeAsyncIterator()
            var seen = ""
            try await expectOutput(&iterator, accumulated: &seen, contains: "BYE")
            while let chunk = try await iterator.next() {
                seen += String(decoding: chunk, as: UTF8.self)
            }

            let second = try await transport.attachTerminal(
                TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24))
            await second.end()
        }
    }

    /// Reads the session's output until `accumulated` contains `marker`,
    /// recording an issue if the stream ends first. The suite's time limit
    /// bounds a marker that never comes.
    private func expectOutput(
        _ iterator: inout AsyncThrowingStream<Data, any Error>.AsyncIterator,
        accumulated: inout String,
        contains marker: String
    ) async throws {
        while !accumulated.contains(marker) {
            guard let chunk = try await iterator.next() else {
                Issue.record("stream ended before \(marker.debugDescription); saw: \(accumulated)")
                return
            }
            accumulated += String(decoding: chunk, as: UTF8.self)
        }
    }

    /// Connects a real SSH transport to localhost whose attach command is a
    /// throwaway `/bin/sh` script (the simulator shares the host
    /// filesystem), and tears everything down afterwards. The wake command
    /// is stubbed to a no-op so no test path can ever poke the machine's
    /// real herdr server.
    private func withAttachTransport(
        script: String,
        body: (SSHTransport) async throws -> Void
    ) async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        var scriptURLs: [URL] = []
        defer { scriptURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
        func write(_ contents: String, prefix: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8)).sh")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            scriptURLs.append(url)
            return url
        }

        var settings = environment.makeSettings(
            socket: .absolutePath("/tmp/herdr-unused.sock"),
            wakeCommand: "false")
        settings.attachCommand = "/bin/sh \(try write(script, prefix: "attach").path)"
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
