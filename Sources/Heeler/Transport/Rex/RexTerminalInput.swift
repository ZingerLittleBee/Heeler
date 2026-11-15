import Foundation

/// The one gate on what a Rex terminal's view sends (ADR 0049). Shut in this
/// build: a Rex attach offers the view no writer, so keys, pastes, scrolling,
/// focus, the Keys panel and Stop send nothing and report nothing as sent.
/// Opening it is the input stage's change, together with what sends the bytes
/// `RexTerminalAnswerFilter.keystrokes(in:)` keeps.
enum RexTerminalInput {
    static let isOpen = false
}

/// Drops what Heeler's own emulator writes back in answer to a program's
/// queries, from bytes on their way to a Rex terminal (ADR 0049). Rex's server
/// answers every query itself (0.1.0-preview.14, API revision 12), so the
/// view's answer would reach the program a second time, as typed input.
///
/// Dropped: device attributes (`CSI … c`), status and cursor reports (`CSI …
/// n`, `CSI … R`), mode reports (`CSI … $ y`), window reports (`CSI … t`), the
/// terminal parameters report (`CSI … x`), the kitty keyboard flags report
/// (`CSI ? … u`), focus reports (`CSI I`, `CSI O`), and every OSC, DCS, APC, PM
/// and SOS string with its terminator. Kept: text, control bytes, keys in
/// every encoding Ghostty writes (an Alt key such as `ESC ]` or `ESC P` among
/// them, which no terminator follows), mouse reports, and a bracketed paste
/// whole. A legacy Shift+F3
/// (`CSI 1 ; 2 R`) reads as a cursor report and is dropped too, as
/// `TmuxKeyReader` drops it. Pure, and each call reads its bytes alone:
/// Ghostty writes an answer in one piece.
enum RexTerminalAnswerFilter {
    static func keystrokes(in data: Data) -> Data {
        let bytes = [UInt8](data)
        var kept: [UInt8] = []
        kept.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == escape, index + 1 < bytes.count else {
                kept.append(bytes[index])
                index += 1
                continue
            }
            switch bytes[index + 1] {
            case UInt8(ascii: "["):
                guard let sequence = controlSequence(in: bytes, at: index) else {
                    // No final byte: not something Ghostty writes as an answer.
                    kept.append(contentsOf: bytes[index...])
                    return Data(kept)
                }
                if sequence.isPasteStart {
                    let end = pasteEnd(in: bytes, from: sequence.end)
                    kept.append(contentsOf: bytes[index..<end])
                    index = end
                    continue
                }
                if !sequence.isAnswer { kept.append(contentsOf: bytes[index..<sequence.end]) }
                index = sequence.end
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"), UInt8(ascii: "X"):
                // A terminated string is an answer. Without its terminator it
                // is an Alt key, as Ghostty writes an answer in one piece.
                guard let end = stringEnd(in: bytes, from: index + 2, bell: bytes[index + 1] == UInt8(ascii: "]"))
                else {
                    kept.append(contentsOf: bytes[index...])
                    return Data(kept)
                }
                index = end
            default:
                kept.append(escape)
                index += 1
            }
        }
        return Data(kept)
    }

    private static let escape: UInt8 = 0x1B

    private struct ControlSequence {
        let parameters: ArraySlice<UInt8>
        let intermediates: ArraySlice<UInt8>
        let final: UInt8
        /// Just past the final byte.
        let end: Int

        var isPasteStart: Bool {
            final == UInt8(ascii: "~") && intermediates.isEmpty && parameters.elementsEqual("200".utf8)
        }

        var isAnswer: Bool {
            switch final {
            case UInt8(ascii: "c"), UInt8(ascii: "n"), UInt8(ascii: "R"), UInt8(ascii: "t"), UInt8(ascii: "x"):
                true
            case UInt8(ascii: "y"):
                intermediates.contains(UInt8(ascii: "$"))
            case UInt8(ascii: "u"):
                parameters.first == UInt8(ascii: "?")
            case UInt8(ascii: "I"), UInt8(ascii: "O"):
                parameters.isEmpty && intermediates.isEmpty
            default:
                false
            }
        }
    }

    /// The control sequence at `start`, or nil when it has no final byte.
    private static func controlSequence(in bytes: [UInt8], at start: Int) -> ControlSequence? {
        var at = start + 2
        let parametersStart = at
        while at < bytes.count, (0x30...0x3F).contains(bytes[at]) { at += 1 }
        let intermediatesStart = at
        while at < bytes.count, (0x20...0x2F).contains(bytes[at]) { at += 1 }
        guard at < bytes.count, (0x40...0x7E).contains(bytes[at]) else { return nil }
        return ControlSequence(
            parameters: bytes[parametersStart..<intermediatesStart], intermediates: bytes[intermediatesStart..<at],
            final: bytes[at], end: at + 1)
    }

    /// Just past a bracketed paste's end marker, or the end of the bytes.
    private static func pasteEnd(in bytes: [UInt8], from start: Int) -> Int {
        let marker: [UInt8] = [escape] + Array("[201~".utf8)
        var at = start
        while at + marker.count <= bytes.count {
            if bytes[at..<(at + marker.count)].elementsEqual(marker) { return at + marker.count }
            at += 1
        }
        return bytes.count
    }

    /// Just past a string's terminator, or nil when it has none.
    private static func stringEnd(in bytes: [UInt8], from start: Int, bell: Bool) -> Int? {
        var at = start
        while at < bytes.count {
            if bell, bytes[at] == 0x07 { return at + 1 }
            if bytes[at] == escape, at + 1 < bytes.count, bytes[at + 1] == UInt8(ascii: "\\") { return at + 2 }
            at += 1
        }
        return nil
    }
}
