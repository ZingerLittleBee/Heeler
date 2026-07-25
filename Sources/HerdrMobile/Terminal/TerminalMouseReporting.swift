import CoreGraphics
import Foundation

/// Mouse reports for a remote application that enabled tracking.
///
/// Ghostty's UIKit layer only turns indirect pointers (trackpad, mouse) into
/// mouse events; a direct touch never produces one. Touch input therefore has
/// to be encoded here before it can reach a TUI behind the PTY.
enum TerminalMouseEncoding {
    /// Normal tracking (DECSET 1000): `ESC [ M Cb Cx Cy`, every value biased
    /// by 32 and capped at 223.
    case legacy
    /// SGR extended tracking (DECSET 1006): `ESC [ < b ; col ; row M|m`, with
    /// no coordinate limit and a distinct release terminator.
    case sgr

    /// Button codes as they appear on the wire, before the legacy +32 bias.
    enum Button: Int {
        case left = 0
        case wheelUp = 64
        case wheelDown = 65
    }

    /// Encodes one report for a 1-based cell coordinate.
    func report(button: Button, column: Int, row: Int, isRelease: Bool = false) -> Data {
        switch self {
        case .sgr:
            let terminator = isRelease ? "m" : "M"
            return Data("\u{1B}[<\(button.rawValue);\(column);\(row)\(terminator)".utf8)
        case .legacy:
            // Legacy reports carry no button identity on release: the
            // terminator stays 'M' and the button becomes 3, "released".
            let code = isRelease ? 3 : button.rawValue
            return Data([
                0x1B, 0x5B, 0x4D,
                UInt8(clamping: code + 32),
                UInt8(clamping: min(column, 223) + 32),
                UInt8(clamping: min(row, 223) + 32),
            ])
        }
    }
}

/// Maps a touch in view coordinates onto a 1-based terminal cell.
///
/// ```
///  view origin
///  ┌───────────────────────────┐   Ghostty centres the grid: whatever does
///  │        ↕ inset            │   not divide into whole cells is split
///  │   ┌────┬────┬────┐        │   evenly between the opposite edges, so the
///  │ ↔ │ 1,1│ 2,1│ 3,1│ …      │   first cell starts half a leftover in.
///  │   ├────┼────┼────┤        │   Verified against the live surface in
///  │   │ 1,2│ 2,2│ 3,2│        │   TerminalMouseReportingTests.
/// ```
struct TerminalGridPointMapper {
    var viewSize: CGSize
    var cellSize: CGSize
    var columns: Int
    var rows: Int

    var gridOrigin: CGPoint {
        CGPoint(
            x: max(0, (viewSize.width - CGFloat(columns) * cellSize.width) / 2),
            y: max(0, (viewSize.height - CGFloat(rows) * cellSize.height) / 2))
    }

    /// Returns the cell under `point`, clamped to the grid so a touch in the
    /// surrounding inset still lands on the nearest edge cell.
    func cell(at point: CGPoint) -> (column: Int, row: Int)? {
        guard cellSize.width > 0, cellSize.height > 0, columns > 0, rows > 0 else {
            return nil
        }
        let origin = gridOrigin
        let column = Int(((point.x - origin.x) / cellSize.width).rounded(.down)) + 1
        let row = Int(((point.y - origin.y) / cellSize.height).rounded(.down)) + 1
        return (min(max(column, 1), columns), min(max(row, 1), rows))
    }
}
