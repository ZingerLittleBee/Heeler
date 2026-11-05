import Foundation

/// A viewer's first paint (`viewers.rs` `first_paint`): the core's own repaint of
/// the screen, with its modes, cursor and styles, then whether the program wants
/// win32 key events, then its status reports. That win32 mode always goes out, so
/// its sequence says the screen is all here. Rows arrive as `agent.read`'s do,
/// CRLF apart with SGR styling, so this is the one styled read a core offers:
/// `terminal.read` has text only (ADR 0035).
///
/// After the last row the paint moves the cursor to where the program left it. A
/// cursor waiting to wrap at the end of a row is restored by printing that row's
/// last character again, which is not more of the screen, so the rows end there.
///
/// The core queues the paint whole, ahead of any live byte, but its writer can cut
/// it into frames anywhere.
struct HerdrCoreFirstPaint {
    private static let endOfScreen = [Data("\u{1B}[?9001h".utf8), Data("\u{1B}[?9001l".utf8)]
    private static let controlSequence = Data("\u{1B}[".utf8)

    private var received = Data()

    /// Takes the next output, and returns the screen once the paint holds it all.
    mutating func receive(_ output: Data) -> ANSIScreen? {
        received.append(output)
        let ends = Self.endOfScreen.compactMap { received.range(of: $0)?.lowerBound }
        guard let end = ends.min() else { return nil }
        let rows = Self.rows(in: received[received.startIndex..<end])
        return ANSIScreenDecoder.decode(String(decoding: rows, as: UTF8.self))
    }

    /// Up to the last `CSI row ; column H`. A cell holds no escape, and the only
    /// other cursor moves come before the rows, with one parameter or none.
    private static func rows(in painted: Data) -> Data {
        var searched = painted
        while let sequence = searched.range(of: controlSequence, options: .backwards) {
            let parameters = painted[sequence.upperBound...].prefix { isDigit($0) || $0 == UInt8(ascii: ";") }
            if parameters.contains(UInt8(ascii: ";")), parameters.endIndex < painted.endIndex,
                painted[parameters.endIndex] == UInt8(ascii: "H")
            {
                return painted[painted.startIndex..<sequence.lowerBound]
            }
            searched = searched[searched.startIndex..<sequence.lowerBound]
        }
        return painted
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}
