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
    /// Chat-style agent TUIs (Claude Code, Codex, Amp, Droid, …) all pin
    /// their input box to the bottom rows but park the caret in tool-specific
    /// spots the caret band cannot chase. The bottom quarter of the surface
    /// is the tool-agnostic floor: on the alternate screen a tap there raises
    /// the keyboard no matter where the caret sits.
    static let alternateScreenBottomFraction: CGFloat = 0.25

    static func alternateScreenBottomRegion(in bounds: CGRect) -> CGRect {
        guard !bounds.isEmpty else { return .null }
        let height = bounds.height * alternateScreenBottomFraction
        return CGRect(
            x: bounds.minX,
            y: bounds.maxY - height,
            width: bounds.width,
            height: height)
    }

    static func region(
        caretRect: CGRect,
        in bounds: CGRect,
        minimumHeight: CGFloat = TerminalKeyboardTapTarget.minimumHeight
    ) -> CGRect {
        guard caretRect.height > 0, !bounds.isEmpty else { return .null }
        let height = min(max(caretRect.height, minimumHeight), bounds.height)
        let centeredY = caretRect.midY - height / 2
        let originY = min(
            max(centeredY, bounds.minY),
            bounds.maxY - height)
        return CGRect(
            x: bounds.minX,
            y: originY,
            width: bounds.width,
            height: height)
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

/// What the remote application asked of its terminal, read from the output
/// stream in order. Only set and reset requests change a mode: a restore
/// (`CSI ? Pm r`) leaves the tracker where it was, although an emulator would
/// go back to the saved value.
struct TerminalModeTracker: Equatable {
    private enum ParseState: Equatable {
        case ground
        case escape
        case controlSequence
    }

    /// One CSI sequence as it arrives. A chunk can end anywhere, so this is
    /// all that is kept between chunks, and it never grows with the input.
    private struct ControlSequence: Equatable {
        /// More parameters than any request the tracker reads carries.
        private static let parameterLimit = 32
        /// Larger than any mode or flags value, and small enough to add to.
        private static let parameterCeiling = 99_999

        /// The private marker that opens the sequence: `?`, `>`, `<` or `=`.
        private(set) var marker: UInt8?
        /// An intermediate byte (`$` in DECRQM) or a shape no request here
        /// has. Either way the sequence changes nothing the tracker follows.
        private(set) var isIgnored = false
        private(set) var parameters: [Int] = []
        private var hasParameterBytes = false
        private var current = 0

        mutating func appendDigit(_ digit: Int) {
            hasParameterBytes = true
            current = min(current * 10 + digit, Self.parameterCeiling)
        }

        mutating func endParameter() {
            hasParameterBytes = true
            appendCurrent()
        }

        /// A marker counts only as the sequence's first byte.
        mutating func setMarker(_ byte: UInt8) {
            if marker != nil || hasParameterBytes {
                isIgnored = true
            } else {
                marker = byte
            }
        }

        mutating func ignore() {
            isIgnored = true
        }

        /// Closes the parameter list at the final byte. `CSI > u` has no
        /// parameters at all, which `CSI > 0 u` does.
        mutating func finish() {
            if hasParameterBytes { appendCurrent() }
        }

        private mutating func appendCurrent() {
            if parameters.count < Self.parameterLimit {
                parameters.append(current)
            }
            current = 0
        }
    }

    /// The kitty keyboard protocol's progressive enhancement flags, as a
    /// stack. Each screen has its own.
    private struct KittyKeyboardStack: Equatable {
        /// The emulator's depth: a full stack loses its oldest entry.
        private static let capacity = 8

        private var entries: [UInt8] = []

        var current: UInt8 { entries.last ?? 0 }

        mutating func push(_ flags: UInt8) {
            if entries.count == Self.capacity {
                entries.removeFirst()
            }
            entries.append(flags)
        }

        mutating func pop(_ count: Int) {
            entries.removeLast(min(count, entries.count))
        }

        /// An empty stack still has a current value to change: the base that
        /// later pushes sit on.
        mutating func replaceCurrent(with flags: UInt8) {
            if entries.isEmpty {
                entries.append(flags)
            } else {
                entries[entries.count - 1] = flags
            }
        }
    }

    /// Five flags are defined; a larger value is not a request.
    private static let kittyFlagsCeiling = 31

    private var parseState = ParseState.ground
    private var sequence = ControlSequence()
    private var mainKittyStack = KittyKeyboardStack()
    private var alternateKittyStack = KittyKeyboardStack()
    private var mouseTrackingModes: Set<Int> = []
    private(set) var usesApplicationCursorKeys = false
    private(set) var isAlternateScreen = false
    private(set) var usesSGRMouseEncoding = false
    /// DECSET 2004, once the stream has set or reset it; nil before it has said either.
    private(set) var bracketedPasteSetting: Bool?
    /// DECSET 2004. When the remote application has asked for it, pasted text
    /// can be framed as a paste instead of arriving as a run of keystrokes.
    var usesBracketedPaste: Bool { bracketedPasteSetting == true }
    /// Whether the stream has said anything of DECSET 9001. A herdr-core viewer's
    /// first paint ends by saying whether the program wants win32 key events, and
    /// always does, so on such a stream this means that paint is in.
    private(set) var hasNamedWin32InputMode = false

    var tracksMouse: Bool {
        !mouseTrackingModes.isEmpty
    }

    /// The kitty keyboard flags in force on the current screen.
    var kittyKeyboardFlags: UInt8 {
        isAlternateScreen ? alternateKittyStack.current : mainKittyStack.current
    }

    private var mouseEncoding: TerminalMouseEncoding {
        usesSGRMouseEncoding ? .sgr : .legacy
    }

    mutating func receive(_ data: Data) {
        for byte in data {
            advance(byte)
        }
    }

    /// A wheel report lands on `cell` when the scroll has a pointer to aim
    /// it, otherwise on the grid's centre.
    func remoteScrollSequence(
        towardOlderContent: Bool,
        columns: Int,
        rows: Int,
        at cell: (column: Int, row: Int)? = nil
    ) -> Data? {
        if tracksMouse {
            return mouseEncoding.report(
                button: towardOlderContent ? .wheelUp : .wheelDown,
                column: cell?.column ?? max(1, columns / 2),
                row: cell?.row ?? max(1, rows / 2))
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
            bracketedPasteSetting = enabled
        case 9001:
            hasNamedWin32InputMode = true
        default:
            break
        }
    }

    private mutating func advance(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            enter(.escape)
            return
        case 0x18, 0x1A:
            // CAN and SUB cancel whatever is in progress.
            enter(.ground)
            return
        default:
            break
        }
        switch parseState {
        case .ground:
            break
        case .escape:
            enter(byte == 0x5B ? .controlSequence : .ground)
        case .controlSequence:
            switch byte {
            case 0x00...0x1F, 0x7F:
                // Other control bytes take effect without ending the sequence.
                break
            case 0x30...0x39:
                sequence.appendDigit(Int(byte - 0x30))
            case 0x3B:
                sequence.endParameter()
            case 0x3C...0x3F:
                sequence.setMarker(byte)
            case 0x20...0x2F, 0x3A:
                // An intermediate, or a colon sub-parameter.
                sequence.ignore()
            case 0x40...0x7E:
                sequence.finish()
                if !sequence.isIgnored {
                    dispatchSequence(final: byte)
                }
                enter(.ground)
            default:
                enter(.ground)
            }
        }
    }

    /// Whatever state comes next, a sequence in progress is over.
    private mutating func enter(_ state: ParseState) {
        parseState = state
        sequence = ControlSequence()
    }

    private mutating func dispatchSequence(final: UInt8) {
        switch (sequence.marker, final) {
        case (0x3F, 0x68), (0x3F, 0x6C):
            // `CSI ? Pm h` and `CSI ? Pm l`. Every other final byte is a
            // different request about those modes: a query (`$p`), a save
            // (`s`) or a restore (`r`).
            for mode in sequence.parameters {
                update(mode: mode, enabled: final == 0x68)
            }
        case (0x3E, 0x75):
            pushKittyFlags(sequence.parameters)
        case (0x3C, 0x75):
            popKittyFlags(sequence.parameters)
        case (0x3D, 0x75):
            setKittyFlags(sequence.parameters)
        default:
            break
        }
    }

    /// `CSI > flags u`. Flags default to none.
    private mutating func pushKittyFlags(_ parameters: [Int]) {
        guard let flags = Self.kittyFlags(parameters.count == 1 ? parameters[0] : 0) else {
            return
        }
        changeKittyStack { $0.push(flags) }
    }

    /// `CSI < n u`. One entry by default; zero pops nothing.
    private mutating func popKittyFlags(_ parameters: [Int]) {
        let count = parameters.count == 1 ? parameters[0] : 1
        changeKittyStack { $0.pop(count) }
    }

    /// `CSI = flags ; mode u`. Mode 1, the default, replaces every flag; 2 adds
    /// the set bits; 3 removes them.
    private mutating func setKittyFlags(_ parameters: [Int]) {
        guard let flags = Self.kittyFlags(parameters.first ?? 0) else { return }
        let mode = parameters.count >= 2 ? parameters[1] : 1
        changeKittyStack { stack in
            switch mode {
            case 1: stack.replaceCurrent(with: flags)
            case 2: stack.replaceCurrent(with: stack.current | flags)
            case 3: stack.replaceCurrent(with: stack.current & ~flags)
            default: break
            }
        }
    }

    private mutating func changeKittyStack(_ change: (inout KittyKeyboardStack) -> Void) {
        if isAlternateScreen {
            change(&alternateKittyStack)
        } else {
            change(&mainKittyStack)
        }
    }

    private static func kittyFlags(_ value: Int) -> UInt8? {
        value <= kittyFlagsCeiling ? UInt8(value) : nil
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
