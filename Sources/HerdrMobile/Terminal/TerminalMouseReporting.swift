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
///  ┌───────────────────────────┐   Ghostty anchors the grid at a fixed
///  │ ↘ padding                 │   padding: with window-padding-balance off
///  │   ┌────┬────┬────┐        │   (the default), whatever does not divide
///  │   │ 1,1│ 2,1│ 3,1│ …      │   into whole cells is left over on the
///  │   ├────┼────┼────┤        │   right and bottom edges only.
///  │   │ 1,2│ 2,2│ 3,2│        │
/// ```
///
/// Verified against the live surface in TerminalMouseReportingTests.
struct TerminalGridPointMapper {
    var viewSize: CGSize
    var cellSize: CGSize
    var columns: Int
    var rows: Int
    /// The screen scale, used to reproduce Ghostty's pixel-space padding.
    var scale: CGFloat

    /// Where Ghostty draws cell (1,1): the pinned libghostty renders with its
    /// default `window-padding-x/y = 2` at a 96 dpi convention and floors to
    /// whole pixels — `floor(2pt · 96/72 · scale)` pixels from the top-left
    /// (5px at 2x, 8px at 3x; see ghostty's Surface.zig `scaledPadding`).
    /// Derived empirically from the IME caret in TerminalMouseReportingTests;
    /// a libghostty update that changes the padding fails that suite.
    var gridOrigin: CGPoint {
        guard scale > 0 else { return .zero }
        let paddingPixels = (2 * 96 / 72 * scale).rounded(.down)
        let padding = paddingPixels / scale
        return CGPoint(x: padding, y: padding)
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
