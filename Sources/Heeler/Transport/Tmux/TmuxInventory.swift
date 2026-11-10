import Foundation

/// What a tmux server lists at one moment (ADR 0043): every pane of every
/// session, in the order `list-panes -a` gives them. A window linked into
/// several sessions is listed once under each, and Heeler's own sessions are
/// listed like any other: `TmuxOrganization` decides what the Console shows.
struct TmuxInventory: Equatable, Sendable {
    /// The server every row came from. Nil for a server with no pane to name it.
    var instance: TmuxServerInstance?
    var panes: [Pane] = []

    /// One pane under one session that links its window.
    struct Pane: Equatable, Sendable {
        /// tmux's ids, as it writes them: `$1`, `@4`, `%7`. A server never
        /// gives one out twice, and another instance starts over.
        var sessionID: String
        var sessionName: String
        var windowID: String
        var windowIndex: Int
        var windowName: String
        var paneID: String
        var paneIndex: Int
        /// The process the pane started. Its terminal's foreground is asked of it.
        var processID: Int
        /// `pane_current_command`: the name of the process leading the pane's
        /// foreground process group, as tmux reads it.
        var command: String
        /// `pane_current_path`: where that process is.
        var path: String
        var width: Int
        var height: Int
        /// The pane's program exited and `remain-on-exit` kept the pane.
        var isDead: Bool
        /// A `pipe-pane` is attached, Heeler's or the user's.
        var hasPipe: Bool
        /// The pane's `@heeler-status`, `@heeler-session` and `@heeler-pipe`, as
        /// they are set. Empty when unset.
        var status = ""
        var agentSession = ""
        var pipeMark = ""
        /// The session's `@heeler-attach` and `@heeler-worktree`.
        var attachMark = ""
        var worktree = ""
        /// The arguments of the process leading the pane's foreground process
        /// group, as last read: the loop reads them again only when `command` or
        /// the program `status` names changed. Nil when they could not be read.
        var foregroundArguments: [String]?

        /// A session of Heeler's own, kept for showing one Pane (ADR 0043).
        var isInHeelerSession: Bool { !attachMark.isEmpty }
    }
}

extension TmuxServerInstance {
    /// One word for this run of the server, where a herdr-core Host has a core id.
    var id: String { "tmux-\(pid)-\(startTime)" }
}
