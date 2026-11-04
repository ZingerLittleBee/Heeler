import Foundation

@testable import Heeler

/// Synthetic Grok Build screens at any width, for states and widths no
/// capture shows yet. Rows follow the 1.0.62 captures and the 1.0.45
/// source: a two-column margin, the turn status row at column 3 with its
/// label cut to fit (`views/turn_status.rs`), dock rows, the composer box,
/// and a footer whose hints stop at the right edge
/// (`views/shortcuts_bar.rs`). Every row carries the captures' background.
struct GrokScreenBuilder {
    /// The turn status row: the spinner and label, then the timers Grok
    /// right-aligns.
    struct Status {
        var label: String
        var spinner = "⠋"
        /// The phase timer after the label; Grok drops it when the row is
        /// narrower than 60 cells.
        var phase: String? = "3.5s"
        /// The turn timer and tokens.
        var turn = "6.0s ⇣25.1k"
        /// ` [stop]`, or ` [↓][stop]` while a command runs.
        var buttons = " [stop]"
        /// ` · N queued, Enter to send now`, which shows only when the label
        /// and it fit.
        var queued: String?
    }

    var columns = 120
    var height = 30
    /// Scrollback rows, drawn from column 5.
    var scrollback = ["❯ Reply with the word kiwi.", "", "kiwi", "", "Worked for 3.4s"]
    var status: Status?
    /// A cue drawn behind a `◎` icon in the status row's place.
    var cue: String?
    /// Dock rows as drawn, indentation included, such as `   ▾ Queued 1`.
    var dock: [String] = []
    var glyph = "❯"
    /// Typed text; a newline starts another row.
    var typed = ""
    /// Italic text after the typed text.
    var ghost = ""
    /// What Grok draws in an empty box without focus.
    var placeholder: String?
    var topLabel: String?
    var bottomLabel = "Grok 4.7 Fast (high)"
    var multiline = false
    var hints = ["Shift+Tab:mode", "Ctrl+.:shortcuts"]
    /// A footer drawn as is in place of the hints, such as a pending
    /// double press.
    var footer: String?
    /// The header row from column 2: the location, then the items Grok
    /// sets at its right, such as `‹ 1/2 ›` and `[Dashboard]`.
    var header = "master ~/s/cap-grok-a/proj"

    var screen: ANSIScreen { ANSIScreenDecoder.decode(ansi) }

    var ansi: String {
        var bottom: [String] = []
        if let status {
            bottom += [statusRow(status), blank]
        } else if let cue {
            bottom += [row([("   ", ""), ("◎ ", Self.accent), (Self.clip(cue, to: columns - 7), Self.muted)]), blank]
        }
        if !dock.isEmpty {
            bottom += dock.map { row([(Self.cut($0, to: columns - 2), Self.muted)]) } + [blank]
        }
        bottom += composerRows() + [blank, footerRow(), blank]
        var top = [blank, row([("  ", ""), (header, Self.muted)]), blank]
        top += scrollback.map { row([("     ", ""), (Self.cut($0, to: columns - 8), Self.text)]) }
        let filler = Array(repeating: blank, count: max(0, height - top.count - bottom.count))
        return (top + filler + bottom).joined(separator: "\r\n")
    }

    // MARK: Rows

    private static let background = SGR.reset + SGR.bg(20, 20, 20)
    private static let border = SGR.fg(80, 80, 88)
    private static let text = SGR.fg(225, 225, 225)
    private static let muted = SGR.fg(108, 108, 108)
    private static let accent = SGR.fg(200, 200, 200)
    private static let key = SGR.bold + SGR.fg(200, 200, 200)
    private static let ghostText = SGR.dim + SGR.italic + SGR.fg(120, 120, 120)

    private var blank: String { row([]) }

    /// `(text, style)` segments from column 0, padded to the full width.
    private func row(_ segments: [(String, String)]) -> String {
        var result = ""
        var width = 0
        for (text, style) in segments where !text.isEmpty {
            result += Self.background + style + text
            width += TerminalCellWidth.width(of: text)
        }
        return result + Self.background + String(repeating: " ", count: max(0, columns - width))
    }

    private func statusRow(_ status: Status) -> String {
        let area = columns - 5
        let right = status.turn + status.buttons
        let phase = area >= 60 ? status.phase.map { " " + $0 } ?? "" : ""
        let available =
            area - 2 - TerminalCellWidth.width(of: phase) - 1 - TerminalCellWidth.width(of: right) - 2
        var label = Self.cut(status.label, to: available)
        var queued = ""
        if let hint = status.queued, TerminalCellWidth.width(of: status.label + hint) <= available {
            label = status.label
            queued = hint
        }
        let left = status.spinner + " " + label + phase + queued
        let gap = area - TerminalCellWidth.width(of: left) - TerminalCellWidth.width(of: right)
        return row([
            ("   ", ""), (status.spinner + " ", Self.accent), (label, Self.text), (phase + queued, Self.muted),
            (String(repeating: " ", count: max(1, gap)), ""), (right, Self.muted),
        ])
    }

    /// The box is `columns - 4` wide from column 2. Its content area starts
    /// two cells in and ends two cells short of the right edge; the captions
    /// in its borders end there (`views/prompt_widget`).
    private func composerRows() -> [String] {
        let inner = columns - 6
        let content = columns - 8
        var top = "╭" + String(repeating: "─", count: inner) + "╮"
        if let topLabel {
            let label = Self.cut(" \(topLabel) ", to: content - 1)
            let fill = String(repeating: "─", count: max(0, inner - 1 - TerminalCellWidth.width(of: label)))
            top = "╭" + fill + label + "─╮"
        }
        var rows = [row([("  ", ""), (top, Self.border)])]
        let lines = typed.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let lead = index == 0 ? " \(glyph) " : "   "
            let ghost = index == lines.count - 1 ? self.ghost : ""
            let hint = line.isEmpty && ghost.isEmpty && lines.count == 1 ? placeholder ?? "" : ""
            let used = TerminalCellWidth.width(of: lead + line + ghost + hint)
            rows.append(
                row([
                    ("  ", ""), ("│", Self.border), (lead, Self.accent), (line, Self.text), (ghost, Self.ghostText),
                    (hint, Self.muted), (String(repeating: " ", count: max(0, inner - used)), ""), ("│", Self.border),
                ]))
        }
        // The info line, right-aligned (`render_info_line`): the model with a
        // space each side and, in /multiline, a gap and `multiline ` at the
        // end, the model cut to leave them room.
        let model = " \(bottomLabel) "
        let modelWidth = min(TerminalCellWidth.width(of: model), multiline ? content - 11 : content)
        var info = [(Self.clip(model, to: modelWidth), Self.muted)]
        if multiline { info += [("─", Self.border), ("multiline ", Self.muted)] }
        let used = modelWidth + (multiline ? 11 : 0)
        let fill = "╰─" + String(repeating: "─", count: max(0, content - used))
        rows.append(row([("  ", ""), (fill, Self.border)] + info + [("─╯", Self.border)]))
        return rows
    }

    /// Each hint's separator, key, colon and label, stopping at the first
    /// that doesn't fit, as Grok paints them.
    private func footerRow() -> String {
        if let footer { return row([("  ", ""), (footer, Self.muted)]) }
        let area = columns - 4
        var segments: [(String, String)] = [("  ", "")]
        var used = 0
        func fits(_ text: String) -> Bool { used + TerminalCellWidth.width(of: text) <= area }
        for (index, hint) in hints.enumerated() {
            let parts = hint.split(separator: ":", maxSplits: 1).map(String.init)
            let pieces = [index > 0 ? "  │  " : "", parts[0], ":", parts.count > 1 ? parts[1] : ""]
            var stop = false
            for (position, piece) in pieces.enumerated() where !piece.isEmpty {
                guard fits(piece) else {
                    stop = true
                    break
                }
                segments.append((piece, position == 1 ? Self.key : position == 0 ? SGR.dim + Self.muted : Self.muted))
                used += TerminalCellWidth.width(of: piece)
            }
            if stop { break }
        }
        return row(segments)
    }

    /// What fits in `width` cells, as a row clips text drawn past its edge.
    static func clip(_ text: String, to width: Int) -> String {
        var result = ""
        for character in text {
            guard TerminalCellWidth.width(of: result) + TerminalCellWidth.width(of: character) <= width else { break }
            result.append(character)
        }
        return result
    }

    /// Grok's `truncate_to_width`: a prefix one cell short of `width`, then
    /// `…`.
    static func cut(_ text: String, to width: Int) -> String {
        guard TerminalCellWidth.width(of: text) > width else { return text }
        guard width > 0 else { return "" }
        return clip(text, to: width - 1) + "…"
    }
}
