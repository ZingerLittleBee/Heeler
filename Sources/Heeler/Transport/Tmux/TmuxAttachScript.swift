import Foundation

/// How an Attach starts on a tmux Host (ADR 0043). One exec runs a script for
/// `/bin/sh -s` that execs a control-mode client with commands to start with:
/// a session of Heeler's own around a placeholder window, marked
/// `@heeler-attach`, set to end with its client, holding a link to the Pane's
/// window, with the placeholder closed. tmux runs them in order and stops at
/// the first that fails, so once the third ran the session ends with its
/// client whatever fails after it. The client never starts a server (`-N`).
///
/// The client's first reply to a command it wrote answers the barrier, after
/// every block of the start: it says whether the session came out as meant.
enum TmuxAttachScript {
    /// What the barrier said of the session.
    enum Start: Equatable, Sendable {
        /// The session holds the Pane's window and nothing else.
        case ready(session: String, window: String)
        /// It does not. A session that started is named, so it can be ended.
        case failed(session: String?)
    }

    /// The prefix of every Attach's session name. The inventory lists these
    /// sessions with their mark, and the Console shows none of them.
    static let sessionPrefix = "heeler-attach-"

    /// A script for `/bin/sh -s`, which must be its whole standard input until
    /// tmux prints: it is one group, so the shell has read all of it before it
    /// execs tmux, and tmux reads what follows. Nil for anything but a pane id.
    static func script(paths: TmuxPaths, session: String, pane: String, pauseAfter: Int) -> String? {
        guard isPaneID(pane) else { return nil }
        let target = "=\(session):"
        let commands: [[String]] = [
            ["new-session", "-E", "-s", session, "-f", "pause-after=\(pauseAfter)", "sleep", "2147483647"],
            ["set-option", "-t", target, "@heeler-attach", pane],
            ["set-option", "-t", target, "destroy-unattached", "on"],
            ["link-window", "-s", pane, "-t", target],
            ["kill-window", "-t", "\(target)^"],
        ]
        let words = commands.map { $0.map(shellWord).joined(separator: " ") }.joined(separator: " ';' ")
        return [
            "{",
            "t=\(quoted(paths.executable))",
            "s=\(quoted(paths.socket))",
            "exec \"$t\" -u -N -S \"$s\" -C \(words)",
            "}",
            "",
        ].joined(separator: "\n")
    }

    /// The first command the client writes. Its reply lists the session's panes.
    static func barrier(session: String) -> TmuxControlCommand {
        TmuxControlCommand(["list-panes", "-s", "-t", "=\(session):", "-F", "#{session_id} #{window_id} #{pane_id}"])
    }

    static func started(_ reply: TmuxControlReply, pane: String) -> Start {
        let rows = reply.lines.map { String(decoding: $0, as: UTF8.self).split(separator: " ").map(String.init) }
            .filter { $0.count == 3 }
        guard reply.succeeded, let first = rows.first else { return .failed(session: nil) }
        let window = first[1]
        guard rows.allSatisfy({ $0[1] == window }), rows.contains(where: { $0[2] == pane }) else {
            return .failed(session: first[0])
        }
        return .ready(session: first[0], window: window)
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
