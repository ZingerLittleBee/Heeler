import Foundation
import Testing

@testable import Heeler

/// Heeler's own `@heeler-status` write (ADR 0044): the counts continue, a
/// Claude Code write clears `@heeler-ask`, and a value that changed first is
/// left alone.
@Suite struct TmuxStatusWriteTests {
    private func write(
        _ tmux: ScriptedTmuxHost, report: TmuxStatusReport, expecting current: String,
        pane: String = "%0", clearAsk: Bool = false
    ) async -> TmuxStatusWrite.Outcome {
        await TmuxStatusWrite.apply(
            report, expecting: current, pane: pane, clearAsk: clearAsk, paths: ScriptedTmuxHost.paths()
        ) { command in
            try await tmux.runTmuxCommand(command.script, throughLoginShell: command.throughLoginShell)
        }
    }

    @Test func anIdleWriteContinuesTheCountsAndLeavesAnotherProgramsAsk() async {
        let tmux = ScriptedTmuxHost()
        let current = "state=working:app=opencode:turn=0:blocked=0"
        await tmux.setPanes([
            .make(command: "opencode", status: current, arguments: ["opencode"])
        ])
        await tmux.setAsk("kept", of: "%0")

        let outcome = await write(
            tmux, report: TmuxStatusReport(state: "idle", app: "opencode"), expecting: current)

        #expect(outcome == .applied("state=idle:app=opencode:turn=1:blocked=0"))
        #expect(await tmux.status(of: "%0") == "state=idle:app=opencode:turn=1:blocked=0")
        #expect(await tmux.ask(of: "%0") == "kept")
    }

    @Test func aClaudeCodeWriteClearsTheAskAndKeepsTheTurn() async {
        let tmux = ScriptedTmuxHost()
        let current = "state=working:app=claude-code:turn=4:blocked=1"
        await tmux.setPanes([
            .make(command: "claude", status: current, arguments: ["claude"])
        ])
        await tmux.setAsk("UGljaw==", of: "%0")

        let outcome = await write(
            tmux, report: TmuxStatusReport(state: "idle", app: "claude-code"), expecting: current,
            clearAsk: true)

        #expect(outcome == .applied("state=idle:app=claude-code:turn=4:blocked=1"))
        #expect(await tmux.status(of: "%0") == "state=idle:app=claude-code:turn=4:blocked=1")
        #expect(await tmux.ask(of: "%0") == "")
    }

    @Test func aChangedStatusIsLeftToTheWriterThatChangedIt() async {
        let tmux = ScriptedTmuxHost()
        let live = "state=blocked:app=pi:kind=question:turn=2:blocked=1"
        await tmux.setPanes([
            .make(command: "pi", status: live, arguments: ["pi"])
        ])

        let outcome = await write(
            tmux, report: TmuxStatusReport(state: "idle", app: "pi"),
            expecting: "state=working:app=pi:turn=2:blocked=0")

        #expect(outcome == .superseded(live))
        #expect(await tmux.status(of: "%0") == live)
    }
}
