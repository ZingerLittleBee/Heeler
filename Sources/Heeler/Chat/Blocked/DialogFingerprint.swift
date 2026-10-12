import CryptoKit
import Foundation

/// Identifies a dialog by what it asks, not by where the user is in it.
///
/// Before sending keys the card re-reads the screen and compares
/// fingerprints: a different one means the dialog changed (answered
/// elsewhere, the next queued request, a page turn) and the keys would land
/// on something the user never saw. Focus, check marks, typed text, the
/// footer and queue counters change while the same dialog waits, so they
/// stay out; whitespace stays out too, so the same dialog wrapped at another
/// width keeps its fingerprint.
struct DialogFingerprint: Hashable, Sendable, CustomStringConvertible {
    /// The SHA-256 digest as lowercase hex.
    let value: String

    init(
        program: ChatProgram, kind: BlockedDialogKind, title: String, sourceSuffix: String?,
        body: [String], progress: String?, options: [DialogOption]
    ) {
        let heading = title + (sourceSuffix.map { "·" + $0 } ?? "")
        let optionFields = options.map { option in
            "\(option.number.map(String.init) ?? "-"):\(Self.fingerprintLabel(of: option))"
        }
        self.init(fields: [
            program.rawValue, kind.rawValue, heading, Self.list(body), progress ?? "", Self.list(optionFields),
        ])
    }

    /// For the generic card: the excerpt's rows without pointer glyphs, so
    /// moving focus with the key pad keeps the fingerprint. The caller
    /// leaves footer rows out, since footers change with focus.
    init(program: ChatProgram, excerptRows: [String]) {
        let rows = excerptRows.map { row in
            row.trimmingCharacters(in: .whitespaces).drop { $0 == "❯" || $0 == "›" }
        }
        self.init(fields: [program.rawValue, "generic", Self.list(rows.map(String.init))])
    }

    private init(fields: [String]) {
        let canonical = fields.map(DialogRowScanner.comparable).joined(separator: "\u{1E}")
        value = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var description: String { String(value.prefix(12)) }

    private static func list(_ items: [String]) -> String {
        items.map(DialogRowScanner.comparable).joined(separator: "\u{1F}")
    }

    /// A text field's label is whatever the user typed into it once they
    /// type, so every text field reads the same.
    private static func fingerprintLabel(of option: DialogOption) -> String {
        option.role == .otherText && option.input != nil ? "\u{1A}input" : option.label
    }
}
