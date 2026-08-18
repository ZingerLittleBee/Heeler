import Foundation

/// Strips the animated status glyphs coding agents prepend to their
/// terminal titles (Claude Code's moon-phase and spark spinners, braille
/// spinners) — herdr's `terminal_title_stripped` removes its own glyphs
/// but not the agent's. Display-layer only: the wire keeps the raw title.
enum TerminalTitleGlyphs {
    /// The title without any leading status glyphs and the whitespace
    /// around them. A title that was nothing but glyphs comes back empty.
    static func strip(_ title: String) -> String {
        var text = Substring(title)
        while let first = text.first, isStatusGlyph(first) || first.isWhitespace {
            text = text.dropFirst()
        }
        return String(text)
    }

    private static func isStatusGlyph(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
            let scalar = character.unicodeScalars.first
        else { return false }
        switch scalar.value {
        case 0x2800...0x28FF: return true  // braille spinner frames
        case 0x25D0...0x25D3: return true  // ◐◑◒◓ moon-phase spinner
        case 0x25CB...0x25CF: return true  // ○◌◍◎● circle frames
        case 0x2722, 0x2731, 0x2733, 0x2736, 0x273B, 0x273D:
            return true  // ✢✱✳✶✻✽ spark frames
        default: return false
        }
    }
}
