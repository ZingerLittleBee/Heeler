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

    @Test func theScriptExecsOneControlClientAsOneGroup() throws {
        let text = try script()
        #expect(text.hasPrefix("{\n"))
        #expect(text.hasSuffix("\n}\n"))
        #expect(text.contains("t='/opt/home brew/bin/tmux'\n"))
        #expect(text.contains("s='/private/tmp/tmux-501/a $b'\n"))
        #expect(text.contains("exec \"$t\" -u -N -S \"$s\" -C "))
    }

    /// The commands the client starts with, one block each: a failed one stops
    /// the rest, and once the third ran the session ends with its client.
    @Test func theClientStartsTheSessionMarksItAndLinksThePanesWindow() throws {
        let exec = try #require(try script().split(separator: "\n").first { $0.hasPrefix("exec ") })
        let expected: [String] = [
            "exec \"$t\" -u -N -S \"$s\" -C new-session -E -s heeler-attach-0a1b2c3d -f 'pause-after=10'",
            "sleep 2147483647",
            "';' set-option -t '=heeler-attach-0a1b2c3d:' @heeler-attach '%12'",
            "';' set-option -t '=heeler-attach-0a1b2c3d:' destroy-unattached on",
            "';' link-window -s '%12' -t '=heeler-attach-0a1b2c3d:'",
            "';' kill-window -t '=heeler-attach-0a1b2c3d:^'",
        ]
        #expect(String(exec) == expected.joined(separator: " "))
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
