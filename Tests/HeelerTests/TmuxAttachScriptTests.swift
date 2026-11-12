import Foundation
import Testing

@testable import Heeler

/// How an Attach starts (ADR 0043): its own session around a placeholder
/// window, marked, ending with its client, holding a link to the Pane's window.
@Suite("tmux attach script")
struct TmuxAttachScriptTests {
    private let paths = TmuxPaths(executable: "/opt/home brew/bin/tmux", socket: "/private/tmp/tmux-501/a $b")

    private func script(pane: String = "%12") throws -> String {
        let paths = try #require(paths)
        return try #require(
            TmuxAttachScript.script(paths: paths, session: "heeler-attach-0a1b2c3d", pane: pane, pauseAfter: 10))
    }

    /// One group, so the shell reads the `exit` before it runs anything.
    /// `new-session` runs first and must return the created `session_id` before
    /// the line-only feeder, `tmux -C`, or any `kill-session` runs; stdout is
    /// drained until tmux exits, and nothing in the outer shell execs.
    @Test func theScriptDrainsStdoutAndExitsInTheGroup() throws {
        let text = try script()
        #expect(text.hasPrefix("{\n"))
        #expect(text.hasSuffix("\n}\n"))
        #expect(!text.contains("\nexec "))
        #expect(!text.contains("&;"))
        #expect(!text.contains("x\" \\047x"))
        #expect(text.contains("trap '' HUP\n"))
        #expect(text.contains("t='/opt/home brew/bin/tmux'\n"))
        #expect(text.contains("s='/private/tmp/tmux-501/a $b'\n"))
        #expect(text.contains("n='heeler-attach-0a1b2c3d'\n"))
        #expect(text.contains("a='%12'\n"))
        #expect(text.contains("while IFS= read -r l; do printf"))
        #expect(text.contains("kill-session -t"))
        #expect(text.contains("sh \"$id\" 3<&0 | {\nIFS= read -r p\n"))
        #expect(text.contains("\"$t\" -u -N -S \"$s\" -C "))
        #expect(text.contains("\nkill \"$p\" 2>/dev/null || :\n} | { cat; cat >/dev/null; }\n"))
        #expect(
            text.contains(
                "\"$t\" -u -N -S \"$s\" kill-session -t \"$id\" </dev/null >/dev/null 2>&1 || :\nfi\nexit\n}"))
    }

    /// `new-session -d` creates the session, prints `#{session_id}`, and sets
    /// `@heeler-attach`, `destroy-unattached off` and `detach-on-destroy on` in
    /// one command queue before `tmux -C` attaches to `"$id"`, links the Pane's
    /// window and closes the placeholder.
    @Test func theClientStartsTheSessionMarksItAndLinksThePanesWindow() throws {
        let lines = try script().split(separator: "\n").map(String.init)
        let createLine = try #require(lines.first { $0.hasPrefix("if id=") })
        let expectedCreate = [
            "if id=$(\"$t\" -u -N -S \"$s\"",
            "new-session -d -E -s \"$n\" -P -F '#{session_id}' sleep 2147483647",
            "';' set-option -t \"=$n:\" @heeler-attach \"$a\"",
            "';' set-option -t \"=$n:\" destroy-unattached off",
            "';' set-option -t \"=$n:\" detach-on-destroy on",
            "</dev/null 2>/dev/null) && [ -n \"$id\" ]; then",
        ].joined(separator: " ")
        #expect(createLine == expectedCreate)

        let attachLine = try #require(lines.first { $0.contains(" -C ") })
        let expectedAttach = [
            "\"$t\" -u -N -S \"$s\" -C attach-session -t \"$id\" -f 'pause-after=10'",
            "';' link-window -s \"$a\" -t \"$id:\"",
            "';' kill-window -t \"$id:^\"",
        ].joined(separator: " ")
        #expect(attachLine == expectedAttach)
    }

    @Test func killSessionTargetsTheExactAttachSessionName() {
        #expect(
            ScriptedTmuxHost.words(of: TmuxAttachScript.killSession(session: "heeler-attach-0a1b2c3d").line)
                == ["kill-session", "-t", "=heeler-attach-0a1b2c3d"])
    }

    @Test func onlyAPaneIDIsAttached() throws {
        let paths = try #require(paths)
        for pane in ["12", "%", "%1a", "%1;kill-server", "@1", "$1", "%-1"] {
            #expect(TmuxAttachScript.script(paths: paths, session: "heeler-attach-1", pane: pane, pauseAfter: 10) == nil)
        }
    }

    @Test func theBarrierListsTheSessionsPanes() {
        #expect(
            ScriptedTmuxHost.words(of: TmuxAttachScript.barrier(session: "heeler-attach-0a1b2c3d").line)
                == [
                    "list-panes", "-s", "-t", "=heeler-attach-0a1b2c3d:",
                    "-F", "#{pid} #{start_time} #{session_id} #{window_id} #{pane_id}",
                ])
    }

    // MARK: What the barrier says

    private let instance = "tmux-4242-1794339265"

    private func reply(_ lines: [String], succeeded: Bool = true) -> TmuxControlReply {
        TmuxControlReply(number: 9, fromClient: true, succeeded: succeeded, lines: lines.map { Data($0.utf8) })
    }

    private func rows(_ rows: [String]) -> TmuxControlReply {
        reply(rows.map { "4242 1794339265 \($0)" })
    }

    @Test func aSessionHoldingOnlyThePanesWindowIsReady() {
        #expect(
            TmuxAttachScript.started(rows(["$7 @2 %11", "$7 @2 %12"]), pane: "%12", instance: instance)
                == .ready(session: "$7", window: "@2"))
        #expect(TmuxAttachScript.started(rows(["$7 @2 %12"]), pane: "%12", instance: nil) == .ready(session: "$7", window: "@2"))
    }

    /// The placeholder is still there: the link failed, and the commands after it never ran.
    @Test func aSessionStillHoldingThePlaceholderIsNot() {
        #expect(TmuxAttachScript.started(rows(["$7 @5 %20"]), pane: "%12", instance: instance) == .failed(session: "$7"))
        #expect(
            TmuxAttachScript.started(rows(["$7 @5 %20", "$7 @2 %12"]), pane: "%12", instance: instance)
                == .failed(session: "$7"))
    }

    @Test func aSessionThatNeverStartedHasNothingToEnd() {
        #expect(
            TmuxAttachScript.started(
                reply(["can't find session: =heeler-attach-1"], succeeded: false), pane: "%12", instance: instance)
                == .failed(session: nil))
        #expect(TmuxAttachScript.started(reply([]), pane: "%12", instance: instance) == .failed(session: nil))
    }

    /// Another server took the socket since the Terminal joined: its pane
    /// with the same id is another Pane.
    @Test func aSessionOnAnotherServerIsNotTheTerminals() {
        #expect(
            TmuxAttachScript.started(reply(["4242 1794339325 $7 @2 %12"]), pane: "%12", instance: instance)
                == .otherServer(session: "$7"))
        #expect(
            TmuxAttachScript.started(reply(["5151 1794339265 $7 @2 %12"]), pane: "%12", instance: instance)
                == .otherServer(session: "$7"))
    }
}
