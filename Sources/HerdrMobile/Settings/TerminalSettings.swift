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
}
