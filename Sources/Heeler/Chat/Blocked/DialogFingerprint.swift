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
///
/// OpenCode 2.0.32 draws a shell command's permission without an action
/// row, so only its lines about the request (`$ git status`) tell one
/// command from the next. While `Always allow` has focus it shows the rule
/// that option would save (`- git status *`) in their place, so a read
/// carries one set or the other. Equal fingerprints show the same lines;
/// `matches(_:)` asks only that the lines both reads show agree, for the
/// checks between keys and after them.
struct DialogFingerprint: Hashable, Sendable, CustomStringConvertible {
    /// The SHA-256 digest as lowercase hex.
    let value: String
    /// The digest of the lines about the request, when the read shows them.
    let requestLines: String?
    /// The digest of the rule's lines shown in their place.
    let ruleLines: String?

    init(
        program: ChatProgram, kind: BlockedDialogKind, title: String, sourceSuffix: String?,
        body: [String], progress: String?, options: [DialogOption], requestLines: [String]? = nil,
        ruleLines: [String]? = nil
    ) {
        let heading = title + (sourceSuffix.map { "·" + $0 } ?? "")
        let optionFields = options.map { option in
            "\(option.number.map(String.init) ?? "-"):\(Self.fingerprintLabel(of: option))"
        }
        self.init(
            value: Self.digest([
                program.rawValue, kind.rawValue, heading, Self.list(body), progress ?? "", Self.list(optionFields),
            ]),
            requestLines: requestLines.map { Self.digest([Self.list($0)]) },
            ruleLines: ruleLines.map { Self.digest([Self.list($0)]) })
    }

    /// For the generic card: the excerpt's rows without pointer glyphs, so
    /// moving focus with the key pad keeps the fingerprint. The caller
    /// leaves footer rows out, since footers change with focus.
    init(program: ChatProgram, excerptRows: [String]) {
        let rows = excerptRows.map { row in
            row.trimmingCharacters(in: .whitespaces).drop { $0 == "❯" || $0 == "›" }
        }
        self.init(
            value: Self.digest([program.rawValue, "generic", Self.list(rows.map(String.init))]), requestLines: nil,
            ruleLines: nil)
    }

    private init(value: String, requestLines: String?, ruleLines: String?) {
        self.value = value
        self.requestLines = requestLines
        self.ruleLines = ruleLines
    }

    /// Whether `other` can be a read of the same dialog: the same
    /// fingerprint, with the lines both reads show alike.
    func matches(_ other: DialogFingerprint) -> Bool {
        value == other.value && Self.agree(requestLines, other.requestLines)
            && Self.agree(ruleLines, other.ruleLines)
    }

    /// This read with the lines that `other`, a read of the same dialog,
    /// shows and this one doesn't.
    func merging(_ other: DialogFingerprint) -> DialogFingerprint {
        DialogFingerprint(
            value: value, requestLines: requestLines ?? other.requestLines, ruleLines: ruleLines ?? other.ruleLines)
    }

    var description: String {
        String(value.prefix(12)) + (requestLines.map { "+r" + $0.prefix(6) } ?? "")
            + (ruleLines.map { "+a" + $0.prefix(6) } ?? "")
    }

    private static func agree(_ lines: String?, _ other: String?) -> Bool {
        lines == nil || other == nil || lines == other
    }

    private static func digest(_ fields: [String]) -> String {
        let canonical = fields.map(DialogRowScanner.comparable).joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func list(_ items: [String]) -> String {
        items.map(DialogRowScanner.comparable).joined(separator: "\u{1F}")
    }

    /// A text field's label is whatever the user typed into it once they
    /// type, so every text field reads the same.
    private static func fingerprintLabel(of option: DialogOption) -> String {
        option.role == .otherText && option.input != nil ? "\u{1A}input" : option.label
    }
}
