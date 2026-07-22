import CoreGraphics
import Foundation

enum TerminalKeyboardTapTarget {
    static let minimumHeight: CGFloat = 44

    static func region(caretRect: CGRect, in bounds: CGRect) -> CGRect {
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

struct TerminalModeTracker {
    private static let privateModePrefix: [UInt8] = [0x1B, 0x5B, 0x3F]

    private var pending: [UInt8] = []
    private var mouseTrackingModes: Set<Int> = []
    private(set) var usesApplicationCursorKeys = false
    private(set) var isAlternateScreen = false
    private(set) var usesSGRMouseEncoding = false

    var tracksMouse: Bool {
        !mouseTrackingModes.isEmpty
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
            let button = towardOlderContent ? 64 : 65
            let column = max(1, columns / 2)
            let row = max(1, rows / 2)

            if usesSGRMouseEncoding {
                return Data("\u{1B}[<\(button);\(column);\(row)M".utf8)
            }

            let legacyColumn = UInt8(clamping: min(column, 223) + 32)
            let legacyRow = UInt8(clamping: min(row, 223) + 32)
            return Data([0x1B, 0x5B, 0x4D, UInt8(button + 32), legacyColumn, legacyRow])
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
