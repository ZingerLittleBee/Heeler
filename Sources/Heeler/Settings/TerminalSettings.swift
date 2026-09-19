import Foundation

/// Everything the Attach surface and the Keys keyboard need to know about how
/// a terminal should look and what the user can send into it. Bundled into one
/// value because it was already four separate parameters threaded through
/// three screens, and the Keys keyboard needs all of them at once.
@MainActor
struct TerminalSettings {
    let themes: TerminalThemeSettings
    let zoom: TerminalZoomSettings
    let fonts: TerminalFontSettings
    let snippets: SnippetStore
    /// Where the floating edge controls rest; defaulted so the many call
    /// sites that never move them need not know it exists.
    var edgeDock: EdgeDockSettings = EdgeDockSettings()
}
