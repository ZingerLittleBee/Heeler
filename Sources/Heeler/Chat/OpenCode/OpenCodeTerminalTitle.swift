import Foundation

/// Which conversation OpenCode 2.0.32's terminal title says its TUI shows
/// (`tui/src/app.tsx:598-628`). OpenCode writes `OpenCode` on its home
/// screen and for a conversation it hasn't titled, `OC | ` and the
/// conversation's title otherwise, or the route's name on a plugin's route,
/// and nothing at all while its `terminal.title` setting is off, when the
/// pane keeps the title it had.
enum OpenCodeTerminalTitle {
    enum Verdict: Equatable, Sendable {
        /// The exact title of the conversation Chat follows.
        case matches
        /// Another `OC | ` title, carrying the text after the prefix:
        /// another conversation, or a plugin's route.
        case differs(String)
        /// `OpenCode`, no title, or one OpenCode never writes, none of
        /// which tells which conversation shows.
        case saysNothing
    }

    /// The title on the home screen and for an untitled conversation.
    static let untitled = "OpenCode"
    private static let prefix = "OC | "

    /// The title OpenCode writes while it shows a conversation titled
    /// `sessionTitle`. One past 40 UTF-16 units keeps its first 37 and an
    /// ellipsis; a surrogate pair split there becomes U+FFFD, as Bun writes
    /// it.
    static func expected(sessionTitle: String?) -> String {
        guard let sessionTitle, !sessionTitle.isEmpty, !isFallback(sessionTitle) else { return untitled }
        let units = sessionTitle.utf16
        guard units.count > 40 else { return prefix + sessionTitle }
        return prefix + String(decoding: units.prefix(37), as: UTF16.self) + "…"
    }

    /// `OpenCode` never matches, even for an untitled conversation: the
    /// home screen writes it too.
    static func verdict(terminalTitle: String?, sessionTitle: String?) -> Verdict {
        guard let terminalTitle, terminalTitle != untitled else { return .saysNothing }
        if terminalTitle == expected(sessionTitle: sessionTitle) { return .matches }
        guard terminalTitle.hasPrefix(prefix) else { return .saysNothing }
        return .differs(String(terminalTitle.dropFirst(prefix.count)))
    }

    /// The timestamped title OpenCode gives a conversation until it names
    /// it (`util/src/session-title-fallback.ts`).
    private static func isFallback(_ title: String) -> Bool {
        title.wholeMatch(of: /(New|Child) session - \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/) != nil
    }
}
