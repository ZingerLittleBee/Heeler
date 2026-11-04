import Foundation

/// What a visible-screen read shows of OpenCode's prompt: the route, the
/// input box, and the footer's running signal.
struct OpenCodeScreen: Equatable, Sendable {
    enum Route: Equatable, Sendable {
        /// The home screen, where a message starts a new conversation.
        case home
        /// A conversation with its input box.
        case session
        /// The subagent panel, or a subagent's view under it, in place of
        /// the input box.
        case subagentPanel
        /// Anything else, such as a prompt in place of the input box.
        case unknown
    }

    var route: Route
    var state: InputBoxState
    /// The footer shows a turn running: its progress bar or `esc
    /// interrupt`.
    var isRunning: Bool
    /// One Esc armed the interrupt: `esc again to interrupt`.
    var isArmed: Bool
    /// The title of a picker or menu over the screen, or the first row of a
    /// `/` or `@` popup over the input box.
    var overlayTitle: String?
}

/// Reads OpenCode 2.0.32's prompt from a visible-screen read, anchored on
/// text and layout rather than the theme's colors.
///
/// The input box is a block of rows behind a left bar `┃`, closed by an
/// edge row `╹▀▀▀`, with the footer the first row below it. Inside the
/// bar: a padding row, the input rows, a padding row, then the agent row
/// (`Build · <model>`, or `Shell` in shell mode). A blank row ends the
/// box, which keeps out the transcript's barred blocks and the
/// queued-prompt dock; popups sit directly on it with a bar at both edges.
/// Permission and question prompts take the box's place and are the
/// Blocked parser's: `InputBoxStateDetector` reads them first, and here
/// they read as no box.
enum OpenCodeScreenReader {
    static func read(_ screen: ANSIScreen) -> OpenCodeScreen {
        let rows = screen.rows
        guard let edge = rows.lastIndex(where: { $0.trimmedText.hasPrefix("╹▀") }), let column = rows[edge].indent
        else {
            if showsSubagentPanel(screen) {
                return OpenCodeScreen(
                    route: .subagentPanel, state: .noComposer(subagentPanelReason), isRunning: false,
                    isArmed: false, overlayTitle: nil)
            }
            return OpenCodeScreen(
                route: .unknown, state: .unknown("OpenCode's input box is not on screen."), isRunning: false,
                isArmed: false, overlayTitle: nil)
        }

        let footer = rows[(edge + 1)...].first { !$0.isBlank }
        let footerText = footer?.trimmedText ?? ""
        let isArmed = footerText.contains("esc again to interrupt")
        let isRunning = isArmed || showsRunningTurn(footerText)

        var top = edge
        while top > 0, isBoxRow(rows[top - 1], column: column) { top -= 1 }
        let hasLogo = rows[..<top].contains { $0.trimmedText.hasPrefix(logoTopRow) }
        let overlayTitle = modalTitle(above: edge, in: rows) ?? popupRow(above: top, column: column, in: rows)
        var screenRead = OpenCodeScreen(
            route: hasLogo ? .home : .unknown, state: .unknown("OpenCode's input box is not recognized."),
            isRunning: isRunning, isArmed: isArmed, overlayTitle: overlayTitle)
        if let overlayTitle { screenRead.state = .overlay(overlayTitle) }

        // A padding row, the input rows, a padding row, the agent row.
        let box = Array(rows[top..<edge])
        guard box.count >= 4, content(box[0], column: column).isEmpty,
            content(box[box.count - 2], column: column).isEmpty
        else { return screenRead }
        let label = content(box[box.count - 1], column: column)
        guard !label.isEmpty else { return screenRead }
        let input = Array(box[1..<(box.count - 2)])
        let showsPlaceholder = isPlaceholder(input, column: column, muted: footer?.visibleRuns.first?.style.foreground)
        screenRead.route = hasLogo || showsPlaceholder ? .home : .session
        guard overlayTitle == nil else { return screenRead }

        let lines = showsPlaceholder ? [] : input.map { content($0, column: column) }.filter { !$0.isEmpty }
        let draft = lines.joined(separator: "\n")
        // Blank rows past the first are newlines typed into the box.
        let isEmpty = lines.isEmpty && (showsPlaceholder || input.count == 1)
        if label == "Shell" || footerText.hasSuffix("exit shell mode") {
            screenRead.state = .shellMode(draft)
        } else if screenRead.route == .home {
            screenRead.state = isEmpty ? .noComposer(homeReason) : .text(draft)
        } else if !isEmpty {
            screenRead.state = .text(draft)
        } else if isRunning {
            // Enter would steer the turn, and a prompt that appears before
            // herdr's Enter would take it as its answer.
            screenRead.state = .disabled("OpenCode is working. Send once it's idle, or steer from the terminal.")
        } else {
            screenRead.state = .empty(placeholder: nil)
        }
        return screenRead
    }

    private static let homeReason =
        "OpenCode is on its home screen, where a message starts a new conversation. Open this conversation in the terminal first."
    private static let subagentPanelReason =
        "OpenCode shows its subagent panel instead of the input box. Close it in the terminal first."

    /// The top row of the logo the home screen draws above its box.
    private static let logoTopRow = "█▀▀█ █▀▀█ █▀▀█ █▀▀▄"

    /// A row of the input box: the bar at the edge's column, without the
    /// second bar a popup row closes with.
    private static func isBoxRow(_ row: ScreenRow, column: Int) -> Bool {
        row.indent == column && row.text(from: column).first == "┃" && !isPopupRow(row)
    }

    private static func isPopupRow(_ row: ScreenRow) -> Bool {
        let text = row.trimmedText
        return text.count > 1 && text.hasPrefix("┃") && text.hasSuffix("┃")
    }

    /// The text right of the bar.
    private static func content(_ row: ScreenRow, column: Int) -> String {
        ScreenRow.normalizedSpaces(row.text(from: column + 1)).trimmingCharacters(in: .whitespaces)
    }

    /// The `/` or `@` popup on the box: rows with a bar at both edges. Its
    /// first row, without the bars.
    private static func popupRow(above top: Int, column: Int, in rows: [ScreenRow]) -> String? {
        var first: Int?
        var index = top - 1
        while index >= 0, rows[index].indent == column, isPopupRow(rows[index]) {
            first = index
            index -= 1
        }
        return first.map { String(rows[$0].trimmedText.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
    }

    /// A picker or menu, such as the session picker or the command list,
    /// drawn over the screen: its title row ends in `esc`, the key that
    /// closes it, set apart by blanks. Rows behind a bar are the
    /// transcript's or a panel's.
    private static func modalTitle(above edge: Int, in rows: [ScreenRow]) -> String? {
        for row in rows[..<edge] {
            let text = row.trimmedText
            guard !text.hasPrefix("┃"), text.hasSuffix("  esc") else { continue }
            let title = String(text.dropLast(3)).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// OpenCode shows a placeholder only on its home screen, `Ask anything…
    /// "…"` or `Run a command… "…"` in shell mode, in its muted color: the
    /// color its footer starts with, the directory's. A draft takes the
    /// text color, so one that happens to read the same stays a draft.
    private static func isPlaceholder(_ input: [ScreenRow], column: Int, muted: ScreenColor?) -> Bool {
        guard input.count == 1, let row = input.first else { return false }
        let text = content(row, column: column)
        guard text.hasPrefix("Ask anything… \"") || text.hasPrefix("Run a command… \"") else { return false }
        // A row without color is one run, the bar included.
        let runs = row.visibleRuns.filter { $0.endColumn > column + 1 }
        return !runs.isEmpty && runs.allSatisfy { $0.style.foreground == muted }
    }

    /// `esc interrupt`, or the progress bar of four or more `■`/`⬝` cells
    /// that starts the footer while a turn runs (`[⋯]` with animations
    /// off). At 62 columns the footer can cut the hint (`esc...rupt`, or
    /// `esc...upt` beside `↓ 1 subagent`) and keeps the bar.
    private static func showsRunningTurn(_ footer: String) -> Bool {
        footer.contains("esc interrupt") || footer.hasPrefix("[⋯]")
            || footer.prefix(while: { $0 == "■" || $0 == "⬝" }).count >= 4
    }

    /// The panel Down opens on an empty box, and that a subagent's view
    /// shows, in place of the box: a bar block that ends the screen under
    /// the `Subagents  Shell  Terminals` tabs.
    private static func showsSubagentPanel(_ screen: ANSIScreen) -> Bool {
        guard let header = OpenCodeBlock.bottom(of: screen)?.sections.first?.first?.text else { return false }
        return header.split(whereSeparator: \.isWhitespace).prefix(3).map(String.init)
            == ["Subagents", "Shell", "Terminals"]
    }
}
