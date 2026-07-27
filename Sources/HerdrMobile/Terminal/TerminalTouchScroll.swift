import CoreGraphics
import Foundation

/// What a tap on the terminal surface means.
enum TerminalTapAction: Equatable {
    /// A flick is still running: halt it, and let the tap mean nothing else.
    case haltMomentum
    /// Report the tap to the remote application, raising the keyboard if the
    /// tap also landed somewhere that asks for it.
    case report(raisesKeyboard: Bool)
}

enum TerminalKeyboardTapTarget {
    static let minimumHeight: CGFloat = 44
    /// An agent TUI parks its caret below the row the user reads as the
    /// prompt: Claude Code's visible `>` measured 16–40 pt above the caret
    /// inside its bordered input box (#90). Three times the normal band
    /// covers that whole box with thumb margin while leaving the output area
    /// inert — whole-screen activation (#92) overshot, answering every
    /// output-area tap with a keyboard nobody asked for.
    static let alternateScreenMinimumHeight: CGFloat = 132

    static func region(
        caretRect: CGRect,
        in bounds: CGRect,
        minimumHeight: CGFloat = TerminalKeyboardTapTarget.minimumHeight
    ) -> CGRect {
        guard caretRect.height > 0, !bounds.isEmpty else { return .null }
        let height = max(caretRect.height, minimumHeight)
        let region = CGRect(
            x: bounds.minX,
            y: caretRect.midY - height / 2,
            width: bounds.width,
            height: height)
        return region.intersection(bounds)
    }
}

/// Gates first-responder changes on the terminal surface against Ghostty's own
/// touch handling. Ghostty's `UITerminalView` raises the keyboard from
/// `touchesBegan` and takes it down from `touchesEnded` — on any touch,
/// anywhere in the body — bypassing this app's input-row tap policy. Both
/// arrive in the middle of a direct-touch sequence, so a responder change
/// during one is Ghostty's and is refused unless the app itself is driving it.
/// UIKit's own resigns and restores (a sheet taking focus, backgrounding)
/// arrive outside touch sequences and pass.
struct TerminalKeyboardResponderGate {
    /// The user's standing wish for the keyboard: set by the input-row tap,
    /// cleared only by an explicit dismiss. It survives UIKit-initiated
    /// resigns so UIKit can restore the keyboard afterwards by asking again.
    private(set) var userWantsKeyboard = false
    private var activeDirectTouchCount = 0
    private var isUserDriven = false

    var mayBecomeFirstResponder: Bool {
        userWantsKeyboard && (isUserDriven || activeDirectTouchCount == 0)
    }

    var mayResignFirstResponder: Bool {
        isUserDriven || activeDirectTouchCount == 0
    }

    /// Brackets a responder change the app makes on the user's behalf, so it
    /// passes even mid-touch: the input-row tap fires while its own touch is
    /// still active.
    mutating func beginUserDrivenChange(wantsKeyboard: Bool) {
        userWantsKeyboard = wantsKeyboard
        isUserDriven = true
    }

    mutating func endUserDrivenChange() {
        isUserDriven = false
    }

    mutating func directTouchesBegan(_ count: Int) {
        activeDirectTouchCount += count
    }

    mutating func directTouchesEnded(_ count: Int) {
        activeDirectTouchCount = max(0, activeDirectTouchCount - count)
    }

    /// A view leaving its window may never see `touchesCancelled`.
    mutating func invalidateTouches() {
        activeDirectTouchCount = 0
    }
}

struct TerminalModeTracker {
    private static let privateModePrefix: [UInt8] = [0x1B, 0x5B, 0x3F]

    private var pending: [UInt8] = []
    private var mouseTrackingModes: Set<Int> = []
    private(set) var usesApplicationCursorKeys = false
    private(set) var isAlternateScreen = false
    private(set) var usesSGRMouseEncoding = false
    /// DECSET 2004. When the remote application has asked for it, pasted text
    /// can be framed as a paste instead of arriving as a run of keystrokes.
    private(set) var usesBracketedPaste = false

    var tracksMouse: Bool {
        !mouseTrackingModes.isEmpty
    }

    private var mouseEncoding: TerminalMouseEncoding {
        usesSGRMouseEncoding ? .sgr : .legacy
    }

    mutating func receive(_ data: Data) {
        pending.append(contentsOf: data)

        while let prefixIndex = nextPrivateModePrefixIndex() {
            if prefixIndex > 0 {
                pending.removeFirst(prefixIndex)
            }

            guard let terminatorIndex = privateModeTerminatorIndex() else {
                retainIncompletePrefix()
                return
            }

            let terminator = pending[terminatorIndex]
            let modeBytes = pending[Self.privateModePrefix.count..<terminatorIndex]
            if let modeList = String(bytes: modeBytes, encoding: .ascii) {
                let enabled = terminator == 0x68
                for mode in modeList.split(separator: ";").compactMap({ Int($0) }) {
                    update(mode: mode, enabled: enabled)
                }
            }
            pending.removeFirst(terminatorIndex + 1)
        }

        retainIncompletePrefix()
    }

    func remoteScrollSequence(
        towardOlderContent: Bool,
        columns: Int,
        rows: Int
    ) -> Data? {
        if tracksMouse {
            return mouseEncoding.report(
                button: towardOlderContent ? .wheelUp : .wheelDown,
                column: max(1, columns / 2),
                row: max(1, rows / 2))
        }

        guard isAlternateScreen else { return nil }
        if towardOlderContent {
            return Data(
                usesApplicationCursorKeys
                    ? [0x1B, 0x4F, 0x41]
                    : [0x1B, 0x5B, 0x41])
        }
        return Data(
            usesApplicationCursorKeys
                ? [0x1B, 0x4F, 0x42]
                : [0x1B, 0x5B, 0x42])
    }

    /// A full left-button click on a 1-based cell, or nil when the remote
    /// application never asked for mouse tracking — a plain shell has no use
    /// for the report and would echo it as garbage.
    func remoteClickSequence(column: Int, row: Int) -> Data? {
        guard tracksMouse else { return nil }
        let encoding = mouseEncoding
        return encoding.report(button: .left, column: column, row: row)
            + encoding.report(button: .left, column: column, row: row, isRelease: true)
    }

    private mutating func update(mode: Int, enabled: Bool) {
        switch mode {
        case 1:
            usesApplicationCursorKeys = enabled
        case 47, 1047, 1049:
            isAlternateScreen = enabled
        case 1000, 1002, 1003:
            if enabled {
                mouseTrackingModes.insert(mode)
            } else {
                mouseTrackingModes.remove(mode)
            }
        case 1006:
            usesSGRMouseEncoding = enabled
        case 2004:
            usesBracketedPaste = enabled
        default:
            break
        }
    }

    private func nextPrivateModePrefixIndex() -> Int? {
        guard pending.count >= Self.privateModePrefix.count else { return nil }
        return pending.indices.dropLast(Self.privateModePrefix.count - 1).first { index in
            pending[index] == Self.privateModePrefix[0]
                && pending[index + 1] == Self.privateModePrefix[1]
                && pending[index + 2] == Self.privateModePrefix[2]
        }
    }

    private func privateModeTerminatorIndex() -> Int? {
        guard pending.count > Self.privateModePrefix.count else { return nil }
        for index in Self.privateModePrefix.count..<pending.count {
            let byte = pending[index]
            if byte == 0x68 || byte == 0x6C {
                return index
            }
            if byte != 0x3B && !(0x30...0x39).contains(byte) {
                return index
            }
        }
        return nil
    }

    private mutating func retainIncompletePrefix() {
        if pending.suffix(2) == Self.privateModePrefix.prefix(2) {
            pending = Array(pending.suffix(2))
        } else if pending.last == Self.privateModePrefix.first {
            pending = [Self.privateModePrefix[0]]
        } else if nextPrivateModePrefixIndex() == nil {
            pending.removeAll(keepingCapacity: true)
        }
    }
}

struct TerminalTouchScrollAccumulator {
    private(set) var remainder: CGFloat = 0

    mutating func reset() {
        remainder = 0
    }

    mutating func rows(for translationY: CGFloat, pointsPerRow: CGFloat) -> Int {
        guard pointsPerRow > 0 else { return 0 }
        if remainder * translationY < 0 {
            remainder = 0
        }
        remainder += translationY
        let rows = Int(remainder / pointsPerRow)
        remainder -= CGFloat(rows) * pointsPerRow
        return rows
    }
}
