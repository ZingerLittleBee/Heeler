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

    /// One group, so the shell reads the `exit` before it runs the pipeline.
    /// tmux's input goes through a feeder that sends `kill-session` on channel
    /// drop, its output is drained until tmux exits, a fallback `kill-session`
    /// runs after the pipeline, and nothing in the outer shell execs.
    @Test func theScriptDrainsStdoutAndExitsInTheGroup() throws {
        let text = try script()
        #expect(text.hasPrefix("{\n"))
        #expect(text.hasSuffix("\n}\n"))
        #expect(!text.contains("\nexec "))
        #expect(!text.contains("&;"))
        #expect(text.contains("trap '' HUP\n"))
        #expect(text.contains("t='/opt/home brew/bin/tmux'\n"))
        #expect(text.contains("s='/private/tmp/tmux-501/a $b'\n"))
        #expect(text.contains("n='heeler-attach-0a1b2c3d'\n"))
        #expect(text.contains("k='kill-session -t \"=heeler-attach-0a1b2c3d\"'\n"))
        #expect(text.contains("sh \"$k\" 3<&0 | {\nIFS= read -r p\n"))
        #expect(text.contains("\"$t\" -u -N -S \"$s\" -C "))
        #expect(text.contains("\nkill \"$p\" 2>/dev/null || :\n} | { cat; cat >/dev/null; }\n"))
        #expect(text.contains("\"$t\" -u -N -S \"$s\" kill-session -t \"=$n\" >/dev/null 2>&1 || :\nexit\n}"))
    }

    /// The commands the client starts with, one block each: a failed one stops
    /// the rest, `destroy-unattached` stays off while `detach-on-destroy` stays
    /// on, and the placeholder window closes once the Pane's window is linked.
    @Test func theClientStartsTheSessionMarksItAndLinksThePanesWindow() throws {
        let line = try #require(try script().split(separator: "\n").first { $0.contains(" -C ") })
        let expected: [String] = [
            "\"$t\" -u -N -S \"$s\" -C new-session -E -s heeler-attach-0a1b2c3d -f 'pause-after=10'",
            "sleep 2147483647",
            "';' set-option -t '=heeler-attach-0a1b2c3d:' @heeler-attach '%12'",
            "';' set-option -t '=heeler-attach-0a1b2c3d:' destroy-unattached off",
            "';' set-option -t '=heeler-attach-0a1b2c3d:' detach-on-destroy on",
            "';' link-window -s '%12' -t '=heeler-attach-0a1b2c3d:'",
            "';' kill-window -t '=heeler-attach-0a1b2c3d:^'",
        ]
        #expect(String(line) == expected.joined(separator: " "))
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
