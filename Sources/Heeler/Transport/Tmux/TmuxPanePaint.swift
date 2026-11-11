import Foundation

/// A tmux Pane's modes as `TmuxPanePaint.modesFormat` prints them: what a
/// terminal showing the Pane needs beside its cells (ADR 0043). Positions are
/// tmux's, from 0.
struct TmuxPaneModes: Equatable, Sendable {
    var paneID: String
    var windowID: String
    var width: Int
    var height: Int
    /// Lines of history above the screen.
    var historySize: Int
    var cursorX: Int
    var cursorY: Int
    var cursorVisible: Bool
    var alternateScreen: Bool
    /// The cursor the alternate screen saved for the normal one.
    var savedCursorX: Int
    var savedCursorY: Int
    var scrollRegionTop: Int
    var scrollRegionBottom: Int
    var applicationCursorKeys: Bool
    var applicationKeypad: Bool
    var mouseStandard: Bool
    var mouseButton: Bool
    var mouseAll: Bool
    var mouseUTF8: Bool
    var mouseSGR: Bool
    var insert: Bool
    var wrap: Bool
    var origin: Bool
    /// Nil before tmux 3.7, which has no `bracket_paste_flag`.
    var bracketedPaste: Bool?

    /// Reads the line tmux printed. The Pane's place and size must be there;
    /// a field some version leaves empty reads as off, or as 0.
    init?(_ line: Data) {
        let fields = String(decoding: line, as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count == 23 || fields.count == 24, fields[0].hasPrefix("%"), fields[1].hasPrefix("@") else {
            return nil
        }
        func number(_ index: Int) -> Int? { Int(fields[index]) }
        func flag(_ index: Int) -> Bool { fields[index] == "1" }
        guard let width = number(2), let height = number(3), let historySize = number(4),
            let cursorX = number(5), let cursorY = number(6)
        else { return nil }
        paneID = fields[0]
        windowID = fields[1]
        self.width = width
        self.height = height
        self.historySize = historySize
        self.cursorX = cursorX
        self.cursorY = cursorY
        cursorVisible = flag(7)
        alternateScreen = flag(8)
        savedCursorX = number(9) ?? 0
        savedCursorY = number(10) ?? 0
        scrollRegionTop = number(11) ?? 0
        scrollRegionBottom = number(12) ?? height - 1
        applicationCursorKeys = flag(13)
        applicationKeypad = flag(14)
        mouseStandard = flag(15)
        mouseButton = flag(16)
        mouseAll = flag(17)
        mouseUTF8 = flag(18)
        mouseSGR = flag(19)
        insert = flag(20)
        wrap = flag(21)
        origin = flag(22)
        bracketedPaste =
            switch fields.count == 24 ? fields[23] : "" {
            case "1": true
            case "0": false
            default: nil
            }
    }
}

/// First paint of a tmux Pane (ADR 0043): the commands that read it, and the
/// bytes that put a terminal showing only that Pane where tmux has it. The
/// Pane's `%output` continues from there.
enum TmuxPanePaint {
    /// The most history one paint carries.
    static let historyLimit = 10_000

    static let modesFormat = [
        "pane_id", "window_id", "pane_width", "pane_height", "history_size", "cursor_x", "cursor_y", "cursor_flag",
        "alternate_on", "alternate_saved_x", "alternate_saved_y", "scroll_region_upper", "scroll_region_lower",
        "keypad_cursor_flag", "keypad_flag", "mouse_standard_flag", "mouse_button_flag", "mouse_all_flag",
        "mouse_utf8_flag", "mouse_sgr_flag", "insert_flag", "wrap_flag", "origin_flag", "bracket_paste_flag",
    ].map { "#{\($0)}" }.joined(separator: " ")

    enum Step: Equatable, Sendable {
        case modes, history, screen, normalScreen
    }

    /// One paint's commands in order: the modes, the history when asked, the
    /// screen, and the normal screen the alternate one saved, which is empty
    /// when the Pane is not on the alternate screen.
    static func steps(includingHistory: Bool) -> [Step] {
        includingHistory ? [.modes, .history, .screen, .normalScreen] : [.modes, .screen, .normalScreen]
    }

    static func command(_ step: Step, pane: String) -> TmuxControlCommand {
        switch step {
        case .modes:
            TmuxControlCommand(["display-message", "-p", "-t", pane, modesFormat])
        case .history:
            TmuxControlCommand(["capture-pane", "-p", "-e", "-t", pane, "-S", "-\(historyLimit)", "-E", "-1"])
        case .screen:
            TmuxControlCommand(["capture-pane", "-p", "-e", "-t", pane])
        case .normalScreen:
            TmuxControlCommand(["capture-pane", "-p", "-e", "-a", "-q", "-t", pane])
        }
    }

    static func commands(pane: String, includingHistory: Bool) -> [TmuxControlCommand] {
        steps(includingHistory: includingHistory).map { command($0, pane: pane) }
    }

    /// What any earlier stream left behind, undone: the alternate screen, the
    /// pen, the scroll region and every mode a paint can set.
    static let reset =
        "\u{1B}[?1049l\u{1B}[0m\u{1B}[r\u{1B}[?6l\u{1B}[?1l\u{1B}>\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l"
        + "\u{1B}[?1005l\u{1B}[?1006l\u{1B}[?2004l\u{1B}[4l\u{1B}[?7h\u{1B}[?25h\u{1B}(B"

    /// The paint. `history` is nil when the terminal keeps the history it
    /// has, and replaces it otherwise. `capture-pane -e` writes each line's
    /// colours as changes from the line before, so the lines of one capture go
    /// out in order from a reset pen. History lines scroll up into the
    /// terminal's scrollback; `viewRows` is how many rows the terminal shows.
    static func bytes(
        modes: TmuxPaneModes, history: [Data]?, screen: [Data], normalScreen: [Data], viewRows: Int
    ) -> Data {
        var paint = Data(reset.utf8)
        paint += control("[H")
        paint += control("[2J")
        if let history {
            paint += control("[3J")
            let lines = modes.historySize > 0 ? Array(history.suffix(min(modes.historySize, history.count))) : []
            if !lines.isEmpty {
                paint += control("[0m")
                for line in lines {
                    paint += line
                    paint += Data("\r\n".utf8)
                }
                let rows = viewRows > 0 ? viewRows : max(1, modes.height)
                paint += control("[0m")
                paint += position(row: rows, column: 1)
                paint += Data(repeating: 0x0A, count: min(lines.count, rows - 1))
            }
        }
        if modes.alternateScreen {
            paint += rows(normalScreen)
            paint += position(row: modes.savedCursorY + 1, column: modes.savedCursorX + 1)
            paint += control("[?1049h")
        }
        paint += rows(screen)
        paint += settings(modes, viewRows: viewRows)
        let row = modes.origin ? modes.cursorY - modes.scrollRegionTop : modes.cursorY
        paint += position(row: row + 1, column: modes.cursorX + 1)
        return paint
    }

    private static func rows(_ lines: [Data]) -> Data {
        var painted = control("[0m")
        for (index, line) in lines.enumerated() {
            painted += position(row: index + 1, column: 1)
            painted += line
        }
        return painted + control("[0m")
    }

    private static func settings(_ modes: TmuxPaneModes, viewRows: Int) -> Data {
        var set = ""
        let terminalRows = viewRows > 0 ? max(modes.height, viewRows) : modes.height
        if modes.scrollRegionTop != 0 || modes.scrollRegionBottom != terminalRows - 1 {
            set += "[\(modes.scrollRegionTop + 1);\(modes.scrollRegionBottom + 1)r"
        }
        let switches: [(Bool, String)] = [
            (modes.origin, "[?6h"), (modes.applicationCursorKeys, "[?1h"), (modes.applicationKeypad, "="),
            (modes.mouseStandard, "[?1000h"), (modes.mouseButton, "[?1002h"), (modes.mouseAll, "[?1003h"),
            (modes.mouseUTF8, "[?1005h"), (modes.mouseSGR, "[?1006h"), (modes.bracketedPaste == true, "[?2004h"),
            (modes.insert, "[4h"), (!modes.wrap, "[?7l"), (!modes.cursorVisible, "[?25l"),
        ]
        var bytes = Data()
        if !set.isEmpty { bytes += control(set) }
        for (on, sequence) in switches where on { bytes += control(sequence) }
        return bytes
    }

    private static func position(row: Int, column: Int) -> Data {
        control("[\(max(1, row));\(max(1, column))H")
    }

    private static func control(_ sequence: String) -> Data {
        Data(("\u{1B}" + sequence).utf8)
    }
}
