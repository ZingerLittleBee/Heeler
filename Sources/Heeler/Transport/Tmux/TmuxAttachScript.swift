import Foundation

/// How an Attach starts on a tmux Host (ADR 0045). One exec runs a script for
/// `/bin/sh -s` that first creates a detached session of Heeler's own around a
/// placeholder window, prints its `#{session_id}`, and sets `@heeler-attach`,
/// `destroy-unattached off` and `detach-on-destroy on` in the same command
/// queue, then attaches a control-mode client to that `session_id`, links the
/// Pane's window and closes the placeholder. tmux stops a command queue at the
/// first command that fails and never starts a server (`-N`); if `new-session`
/// fails (for example because a session of that name already exists), it prints
/// no `session_id` and the script neither starts the feeder nor kills anything,
/// while if `new-session` prints a `session_id` and a later setup command fails
/// (before or after `@heeler-attach` is set), the script ends that `session_id`
/// by id and never by session name.
///
/// Leaving `destroy-unattached` on lets `server_check_unattached` destroy the
/// session (`s->curw = NULL`) as soon as `CLIENT_EXIT` marks `s->attached == 0`
/// while `c->session` still points to `s`, crashing the server on any command or
/// disconnect hook that reads a client's pane; and setting `CLIENT_EXIT` on
/// stdin EOF or `detach-client` while `c->session != NULL` and output blocks
/// are queued aborts the server in `control_append_data` when the pane writes
/// again. Instead, polite close and abrupt SSH stdin EOF both end the session
/// with `kill-session`, whose `server_destroy_session` clears `c->session`
/// before setting `CLIENT_EXIT` and before destroying `s`, while
/// `detach-on-destroy on` keeps window exit from switching the client onto a
/// user session.
///
/// Once the detached setup queue has exited 0 with a valid `session_id`, tmux's
/// standard input comes through a line-only feeder (`IFS= read -r`) that
/// forwards only newline-terminated lines, drops any trailing partial line
/// whatever its quote state, and writes `kill-session -t '<session_id>'` on EOF
/// before closing tmux's input; when tmux exits first, the pipeline terminates
/// that feeder at once. tmux's standard output goes through a drain that keeps
/// reading until tmux exits, `kill-session -t "$id"` cleans up that same created
/// session on every failure path or if tmux exited before reading stdin, and the
/// shell exits in the same group so nothing written later can run as a shell
/// command.
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
        let createWords = [
            "new-session -d -E -s \"$n\" -P -F '#{session_id}' sleep 2147483647",
            "set-option -t \"=$n:\" @heeler-attach \"$a\"",
            "set-option -t \"=$n:\" destroy-unattached off",
            "set-option -t \"=$n:\" detach-on-destroy on",
        ].joined(separator: " ';' ")
        let attachWords = [
            "attach-session -t \"$id\" -f \(shellWord("pause-after=\(pauseAfter)"))",
            "link-window -s \"$a\" -t \"$id:\"",
            "kill-window -t \"$id:^\"",
        ].joined(separator: " ';' ")
        let feeder = [
            "trap 'kill \"$!\" 2>/dev/null || :; exit 0' TERM;",
            "echo \"$$\";",
            "(LC_ALL=C; while IFS= read -r l; do printf '%s\\n' \"$l\" || exit 0; done) <&3 3<&- &",
            "exec 3<&-;",
            "wait \"$!\" 2>/dev/null || :;",
            "trap \"\" PIPE;",
            "printf \"kill-session -t '%s'\\n\" \"$1\" 2>/dev/null || :;",
            "sleep 2 &",
            "wait \"$!\" 2>/dev/null || :",
        ].joined(separator: " ")
        // Only complete `\n`-terminated lines reach `tmux -C`; on channel drop,
        // any trailing partial line is discarded by `read` and `kill-session`
        // ends only `$id`, the session created above. Whenever `new-session`
        // printed a `$<digits>` id, `$id` is ended by id even if a later setup
        // command in `createWords` failed; if `new-session` itself failed,
        // neither the feeder nor any `kill-session` runs.
        return [
            "{",
            "trap '' HUP",
            "t=\(quoted(paths.executable))",
            "s=\(quoted(paths.socket))",
            "n=\(quoted(session))",
            "a=\(quoted(pane))",
            "rc=0",
            "id=$(\"$t\" -u -N -S \"$s\" \(createWords) </dev/null 2>/dev/null) || rc=$?",
            "case \"${id#\\$}\" in",
            "\"$id\"|''|*[!0-9]*) ;;",
            "*)",
            "if [ \"$rc\" -eq 0 ]; then",
            "sh -c \(quoted(feeder)) sh \"$id\" 3<&0 | {",
            "IFS= read -r p",
            "\"$t\" -u -N -S \"$s\" -C \(attachWords)",
            "kill \"$p\" 2>/dev/null || :",
            "} | { cat; cat >/dev/null; }",
            "fi",
            "\"$t\" -u -N -S \"$s\" kill-session -t \"$id\" </dev/null >/dev/null 2>&1 || :",
            ";;",
            "esac",
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
