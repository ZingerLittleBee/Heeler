import Foundation

/// How an Attach starts on a tmux Host (ADR 0043). One exec runs a script for
/// `/bin/sh -s` that starts a control-mode client with commands to start with:
/// a session of Heeler's own around a placeholder window, marked
/// `@heeler-attach`, with `destroy-unattached off` and `detach-on-destroy on`,
/// holding a link to the Pane's window, with the placeholder closed. tmux runs
/// them in order and stops at the first that fails. The client never starts a
/// server (`-N`).
///
/// Leaving `destroy-unattached` on lets `server_check_unattached` destroy the
/// session (`s->curw = NULL`) as soon as `CLIENT_EXIT` marks `s->attached == 0`
/// while `c->session` still points to `s`, crashing the server on any command or
/// disconnect hook that reads a client's pane; and setting `CLIENT_EXIT` on
/// stdin EOF or `detach-client` while `c->session != NULL` and output blocks
/// are queued aborts the server in `control_append_data` when the pane writes
/// again. Instead, polite close and abrupt SSH stdin EOF both end the session
/// with `kill-session -t "=<session>"`, whose `server_destroy_session` clears
/// `c->session` before setting `CLIENT_EXIT` and before destroying `s`, while
/// `detach-on-destroy on` keeps window exit from switching the client onto a
/// user session.
///
/// tmux's standard input comes through a feeder that forwards the channel and,
/// if the channel drops, cancels any partial line and writes `kill-session`
/// before closing tmux's input; when tmux exits first, the pipeline terminates
/// that feeder at once. tmux's standard output goes through a drain that keeps
/// reading until tmux exits, a fallback `kill-session` cleans up any session
/// started before stdin ran, and the shell exits in the same group so nothing
/// written later can run as a shell command.
///
/// The client's first reply to a command it wrote answers the barrier, after
/// every block of the start: it says whether the session came out as meant,
/// and on which server. A server that replaced the one the Terminal joined
/// has a Pane with the same id and nothing else in common.
enum TmuxAttachScript {
    /// What the barrier said of the session.
    enum Start: Equatable, Sendable {
        /// The session holds the Pane's window and nothing else.
        case ready(session: String, window: String)
        /// It does not. A session that started is named, so it can be ended.
        case failed(session: String?)
        /// It started on another server than the one asked for.
        case otherServer(session: String)
    }

    /// The prefix of every Attach's session name. The inventory lists these
    /// sessions with their mark, and the Console shows none of them.
    static let sessionPrefix = "heeler-attach-"

    /// Ends the Attach's session by exact name (`server_destroy_session` clears
    /// `c->session` before `CLIENT_EXIT` and before `session_destroy`).
    static func killSession(session: String) -> TmuxControlCommand {
        TmuxControlCommand(["kill-session", "-t", "=\(session)"])
    }

    /// A script for `/bin/sh -s`. It is one group, so the shell reads all of
    /// it, including the `exit` after the pipeline, before it runs anything.
    /// Nil for anything but a pane id.
    static func script(paths: TmuxPaths, session: String, pane: String, pauseAfter: Int) -> String? {
        guard isPaneID(pane) else { return nil }
        let target = "=\(session):"
        let commands: [[String]] = [
            ["new-session", "-E", "-s", session, "-f", "pause-after=\(pauseAfter)", "sleep", "2147483647"],
            ["set-option", "-t", target, "@heeler-attach", pane],
            ["set-option", "-t", target, "destroy-unattached", "off"],
            ["set-option", "-t", target, "detach-on-destroy", "on"],
            ["link-window", "-s", pane, "-t", target],
            ["kill-window", "-t", "\(target)^"],
        ]
        let words = commands.map { $0.map(shellWord).joined(separator: " ") }.joined(separator: " ';' ")
        let killLine = killSession(session: session).line
        let feeder = [
            "trap 'kill \"$!\" 2>/dev/null || :; exit 0' TERM;",
            "echo \"$$\";",
            "cat <&3 3<&- &",
            "exec 3<&-;",
            "wait \"$!\" 2>/dev/null || :;",
            "trap \"\" PIPE;",
            "printf 'x\" \\047x\\n%s\\n' \"$1\" 2>/dev/null || :;",
            "sleep 2 &",
            "wait \"$!\" 2>/dev/null || :",
        ].joined(separator: " ")
        // On channel drop, the feeder breaks any partial control-mode line with
        // an unclosed quote and sends `kill-session` while holding the pipe open
        // until tmux exits; on normal exit, `kill "$p"` ends the feeder at once.
        // The second cat keeps reading after the channel stops so tmux finishes
        // writing, and `exit` is already parsed with the group.
        return [
            "{",
            "trap '' HUP",
            "t=\(quoted(paths.executable))",
            "s=\(quoted(paths.socket))",
            "n=\(quoted(session))",
            "k=\(quoted(killLine))",
            "sh -c \(quoted(feeder)) sh \"$k\" 3<&0 | {",
            "IFS= read -r p",
            "\"$t\" -u -N -S \"$s\" -C \(words)",
            "kill \"$p\" 2>/dev/null || :",
            "} | { cat; cat >/dev/null; }",
            "\"$t\" -u -N -S \"$s\" kill-session -t \"=$n\" >/dev/null 2>&1 || :",
            "exit",
            "}",
            "",
        ].joined(separator: "\n")
    }

    /// The first command the client writes. Its reply lists the session's
    /// panes, each with the server's instance.
    static func barrier(session: String) -> TmuxControlCommand {
        TmuxControlCommand([
            "list-panes", "-s", "-t", "=\(session):", "-F",
            "#{pid} #{start_time} #{session_id} #{window_id} #{pane_id}",
        ])
    }

    /// `instance` is the server the Terminal keeps to, as
    /// `TmuxServerInstance.id` names it; nil for whichever answers.
    static func started(_ reply: TmuxControlReply, pane: String, instance: String?) -> Start {
        let rows = reply.lines.map { String(decoding: $0, as: UTF8.self).split(separator: " ").map(String.init) }
            .filter { $0.count == 5 }
        guard reply.succeeded, let first = rows.first else { return .failed(session: nil) }
        let session = first[2]
        if let instance, "tmux-\(first[0])-\(first[1])" != instance { return .otherServer(session: session) }
        let window = first[3]
        guard rows.allSatisfy({ $0[3] == window }), rows.contains(where: { $0[4] == pane }) else {
            return .failed(session: session)
        }
        return .ready(session: session, window: window)
    }

    /// `%` and a decimal number, as tmux names a pane.
    static func isPaneID(_ word: String) -> Bool {
        let digits = word.utf8.dropFirst()
        return word.utf8.first == UInt8(ascii: "%") && !digits.isEmpty
            && digits.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    /// A word sh passes on as it is: plain words bare, the rest single-quoted.
    private static func shellWord(_ word: String) -> String {
        let plain = word.utf8.allSatisfy {
            switch $0 {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "@"):
                true
            default:
                false
            }
        }
        return plain && !word.isEmpty ? word : quoted(word)
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
