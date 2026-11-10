import Foundation
import Testing

@testable import Heeler

/// An Attach on a tmux Pane through the tmux transport (ADR 0043): a session
/// of Heeler's own with one control client, a first paint, the Pane's output
/// after it, and an end for each way the Pane or the connection can go.
@Suite("tmux pane attach")
struct TmuxPaneAttachTests {
    private let request = TerminalAttachRequest(target: .terminal("%0"), surfaceHasHistory: true, cols: 80, rows: 4)

    private func host(height: Int = 4) async -> ScriptedTmuxHost {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            .make(pane: 0, command: "claude", height: height),
            .make(pane: 1, paneIndex: 1, command: "zsh", height: height),
            .make(session: 1, sessionName: "other", window: 2, pane: 2, command: "zsh", height: height),
        ])
        return tmux
    }

    private func attach(
        _ pane: String = "%0", on tmux: ScriptedTmuxHost, startLimit: Duration = .seconds(5)
    ) async throws -> TerminalAttachSession {
        let transport = await tmux.transport(
            socketName: "default", storedPaths: ScriptedTmuxHost.paths(), attachStartLimit: startLimit)
        return try await transport.attachPane(pane, request: request)
    }

    private func waitUntil(
        _ what: String, _ condition: () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    /// Reads output until `text` shows up in it.
    private func read(
        until text: String, from output: inout AsyncThrowingStream<Data, any Error>.Iterator
    ) async throws -> String {
        var read = ""
        while !read.contains(text), let bytes = try await output.next() {
            read += String(decoding: bytes, as: UTF8.self)
        }
        return read
    }

    private func ending(of output: inout AsyncThrowingStream<Data, any Error>.Iterator) async -> (any Error)? {
        do {
            while try await output.next() != nil {}
            return nil
        } catch {
            return error
        }
    }

    // MARK: Starting

    @Test func anAttachStartsItsOwnSessionOnThePane() async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        let script = try #require(await tmux.controlScripts.first)
        #expect(script.contains("exec \"$t\" -u -N -S \"$s\" -C new-session -E -s heeler-attach-"))
        #expect(script.contains("@heeler-attach '%0'"))
        #expect(script.contains("link-window -s '%0'"))
        #expect(await tmux.openControlClients == 1)
        let commands = await tmux.controlCommands
        #expect(commands.first?.hasPrefix("list-panes -s -t '=heeler-attach-") == true)
    }

    @Test func theFirstPaintComesFirstThenThePanesOutput() async throws {
        let tmux = await host()
        await tmux.setScreen(["$ claude", "> hello", "", ""], of: "%0")
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        var output = session.output.makeAsyncIterator()
        let painted = try await read(until: "> hello", from: &output)
        #expect(painted.hasPrefix(TmuxPanePaint.reset))
        await tmux.paneOutput("other pane\r\n", in: "%1")
        await tmux.paneOutput("thinking\r\n", in: "%0")
        let live = try await read(until: "thinking", from: &output)
        #expect(live == "thinking\r\n")
    }

    /// A Pane gone before its session linked it ends the Terminal, and the
    /// session that started around its placeholder is ended.
    @Test func aPaneThatIsGoneEndsTheAttachAndItsSession() async throws {
        let tmux = await host()
        await #expect(throws: TransportError.tmuxPaneGone) { try await attach("%7", on: tmux) }
        #expect(await tmux.controlCommands.contains { $0.hasPrefix("kill-session -t '$") })
        try await waitUntil("the client to go") { await tmux.openControlClients == 0 }
    }

    @Test func aStartThatNeverAnswersTimesOutAndClosesItsExec() async throws {
        let tmux = await host()
        await tmux.silenceNextControlClient()
        await #expect(throws: TransportError.timedOut) {
            try await attach(on: tmux, startLimit: .milliseconds(100))
        }
    }

    // MARK: While attached

    @Test func aPausedPaneIsPaintedAgain() async throws {
        let tmux = await host()
        await tmux.setScreen(["first", "", "", ""], of: "%0")
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        var output = session.output.makeAsyncIterator()
        _ = try await read(until: "first", from: &output)
        await tmux.setScreen(["after the pause", "", "", ""], of: "%0")
        await tmux.pause("%0")
        let repainted = try await read(until: "after the pause", from: &output)
        #expect(repainted.hasPrefix(TmuxPanePaint.reset))
        #expect(await tmux.controlCommands.contains("refresh-client -A '%0:continue'"))
    }

    // MARK: Ending

    @Test func endingTheSessionClosesTheClient() async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        var output = session.output.makeAsyncIterator()
        _ = try await output.next()
        await session.end()
        try await waitUntil("the client to go") { await tmux.openControlClients == 0 }
        #expect(await ending(of: &output) == nil)
    }

    /// Heeler's session would keep the window, and its program, alive.
    @Test func aWindowOnlyHeelerHoldsIsClosedAndTheAttachEnds() async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        var output = session.output.makeAsyncIterator()
        _ = try await output.next()
        await tmux.endUserSessions(holding: "%0")
        let error = await ending(of: &output)
        #expect(error as? TransportError == .tmuxPaneGone)
        #expect(await tmux.controlCommands.contains("kill-window -t '@0'"))
    }

    @Test func aServerThatStopsEndsTheAttach() async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        var output = session.output.makeAsyncIterator()
        _ = try await output.next()
        await tmux.stopServer()
        #expect(await ending(of: &output) as? TransportError == .tmuxPaneGone)
    }

    @Test func aLostConnectionEndsTheAttachWithTheLoss() async throws {
        let tmux = await host()
        let transport = await tmux.transport(socketName: "default", storedPaths: ScriptedTmuxHost.paths())
        let session = try await transport.attachPane("%0", request: request)
        var output = session.output.makeAsyncIterator()
        _ = try await output.next()
        try await transport.close()
        guard case .sshUnreachable = await ending(of: &output) as? TransportError else {
            Issue.record("The attach did not end with the loss")
            return
        }
    }

    @Test func keysAreTakenAndNotSentYet() async throws {
        let tmux = await host()
        let session = try await attach(on: tmux)
        defer { Task { await session.end() } }
        var output = session.output.makeAsyncIterator()
        _ = try await output.next()
        let before = await tmux.controlCommands
        try await session.sendAcknowledged(Data("ls\r".utf8))
        #expect(await tmux.controlCommands == before)
    }
}
