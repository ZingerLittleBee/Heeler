import Foundation

/// Formats the unsafe-paste alert: which control characters the committed text
/// carries, and a single-line preview that never emits one into the alert
/// itself. Pure, so the escaping stays testable without UIKit. `refs #243`.
enum TerminalUnsafePasteText: Sendable {
    /// How many distinct control-character names the alert lists before
    /// collapsing the rest into a count.
    static let maxReportedControls = 5

    /// How many characters of committed text the preview shows before it
    /// truncates.
    static let previewLimit = 200

    /// The short name of a control scalar, or nil when the scalar is ordinary
    /// text. Every control character is named: C0 and DEL use their
    /// conventional abbreviations, and anything else in the control set reports
    /// its code point, so nothing control-shaped reaches the alert unescaped.
    static func shortName(for scalar: Unicode.Scalar) -> String? {
        switch scalar.value {
        case 0x00: return "NUL"
        case 0x01: return "SOH"
        case 0x02: return "STX"
        case 0x03: return "ETX"
        case 0x04: return "EOT"
        case 0x05: return "ENQ"
        case 0x06: return "ACK"
        case 0x07: return "BEL"
        case 0x08: return "BS"
        case 0x09: return "HT"
        case 0x0A: return "LF"
        case 0x0B: return "VT"
        case 0x0C: return "FF"
        case 0x0D: return "CR"
        case 0x0E: return "SO"
        case 0x0F: return "SI"
        case 0x10: return "DLE"
        case 0x11: return "DC1"
        case 0x12: return "DC2"
        case 0x13: return "DC3"
        case 0x14: return "DC4"
        case 0x15: return "NAK"
        case 0x16: return "SYN"
        case 0x17: return "ETB"
        case 0x18: return "CAN"
        case 0x19: return "EM"
        case 0x1A: return "SUB"
        case 0x1B: return "ESC"
        case 0x1C: return "FS"
        case 0x1D: return "GS"
        case 0x1E: return "RS"
        case 0x1F: return "US"
        case 0x7F: return "DEL"
        default:
            guard CharacterSet.controlCharacters.contains(scalar) else { return nil }
            let hex = String(scalar.value, radix: 16, uppercase: true)
            return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
        }
    }

    /// Renders `contents` on one line with every control character named:
    /// `"ls\r\n"` becomes `"ls<CR><LF>"`. An alert's message is plain text, so
    /// a raw newline would break its layout and a raw escape would be
    /// invisible; naming them also says what makes the paste unsafe.
    static func escaped(_ contents: String) -> String {
        var escaped = String()
        // Escaping only ever lengthens the text, so the input is a floor.
        escaped.reserveCapacity(contents.utf8.count)
        for scalar in contents.unicodeScalars {
            guard let name = shortName(for: scalar) else {
                escaped.unicodeScalars.append(scalar)
                continue
            }
            escaped += "<\(name)>"
        }
        return escaped
    }

    /// Distinct control-character names in first-seen order.
    static func distinctControlNames(in contents: String) -> [String] {
        var seen: [String] = []
        for scalar in contents.unicodeScalars {
            guard let name = shortName(for: scalar), !seen.contains(name) else { continue }
            seen.append(name)
        }
        return seen
    }

    /// One-line summary for the alert, e.g. `"ESC, CR"`. Caps the list at
    /// ``maxReportedControls`` and notes how many more distinct controls were
    /// found.
    static func summary(in contents: String) -> String {
        let names = distinctControlNames(in: contents)
        guard !names.isEmpty else { return "none" }
        let shown = names.prefix(maxReportedControls).joined(separator: ", ")
        guard names.count > maxReportedControls else { return shown }
        return "\(shown), +\(names.count - maxReportedControls) more"
    }

    /// Escaped, length-capped preview that appends how much text it left out.
    /// The cap counts characters of the committed text rather than of the
    /// escaped result, so the alert's own length stays predictable.
    static func preview(of contents: String, limit: Int = previewLimit) -> String {
        guard contents.count > limit else { return escaped(contents) }
        let head = escaped(String(contents.prefix(limit)))
        return "\(head)… (+\(contents.count - limit) more characters)"
    }

    /// The alert's body: what the text contains, then what it looks like.
    static func message(for contents: String) -> String {
        """
        The program wants to paste text containing control characters \
        (\(summary(in: contents))). Review before allowing:

        \(preview(of: contents))
        """
    }
}
