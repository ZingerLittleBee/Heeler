import Foundation

/// The key a sent prompt and a recorded prompt are compared on
/// (docs/research/codex-rollout-format.md, "Prompt recording and echo
/// matching").
///
/// The Codex TUI changes a paste before recording it: CRLF and CR become
/// LF, control characters other than newline and tab and whole CSI
/// sequences are dropped (`sanitize_user_text`), and submission trims.
/// Heeler strips invisible characters and appends a space when it sends.
/// Applying all of that to both sides lets an echo compare equal exactly,
/// so matching never needs a fuzzy rule. Pass the text as sent to herdr,
/// after the `/name` → `$name` conversion.
func codexEchoKey(_ text: String) -> String {
    let input = Array(text.unicodeScalars)
    var output = String.UnicodeScalarView()
    var index = 0
    while index < input.count {
        let scalar = input[index]
        index += 1
        switch scalar.value {
        case 0x1B:
            // `ESC [` starts a CSI sequence that runs through its final byte;
            // an unterminated one swallows the rest, as in the TUI.
            if index < input.count, input[index] == "[" {
                index += 1
                while index < input.count, !(0x40...0x7E).contains(input[index].value) {
                    index += 1
                }
                index += 1
            }
        case 0x0D:
            output.append("\n")
            if index < input.count, input[index] == "\n" {
                index += 1
            }
        case 0x0A, 0x09:
            output.append(scalar)
        case 0x00...0x1F, 0x7F...0x9F:
            break
        default:
            if !CodexPendingEcho.isInvisible(scalar) {
                output.append(scalar)
            }
        }
    }
    return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Where the transcript stood when a prompt was sent: the live rollout and
/// the offset just past its last processed line.
struct CodexEchoCursor: Equatable, Sendable {
    var rolloutID: String
    var offset: UInt64

    init(rolloutID: String, offset: UInt64) {
        self.rolloutID = rolloutID
        self.offset = offset
    }
}

/// A prompt Heeler sent that has not shown up in the transcript yet.
struct CodexPendingSend: Equatable, Sendable {
    /// The text as sent to herdr.
    var text: String
    var cursor: CodexEchoCursor

    init(text: String, cursor: CodexEchoCursor) {
        self.text = text
        self.cursor = cursor
    }
}

/// A recorded entry a pending send may turn out to be.
struct CodexEchoCandidate: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A user prompt, with the text as recorded and its `local_image`
        /// paths.
        case prompt(text: String, localImagePaths: [String])
        /// A compaction, which is what a sent `/compact` leaves: the TUI
        /// records no prompt for it.
        case compaction
    }

    var rolloutID: String
    var offset: UInt64
    var entryID: ChatEntryID
    var kind: Kind
}

/// Matches pending sends to the prompts Codex recorded
/// (docs/research/codex-rollout-format.md, "Prompt recording and echo
/// matching"). The rules are conservative because a wrong match hides a
/// prompt that was never delivered: keys must be equal, only entries
/// recorded after the send count, and matching is first in, first out and
/// one to one, so a prompt sent twice needs two recorded copies. Codex's own
/// message id is useless here: the TUI sets a fresh `client_id` that Heeler
/// cannot choose.
enum CodexPendingEcho {
    /// The command whose echo is a compaction rather than a prompt.
    static let compactCommand = "/compact"

    /// For each pending send, in order, the entry it matched, or nil.
    /// `candidates` must be in transcript order.
    static func match(pending: [CodexPendingSend], candidates: [CodexEchoCandidate]) -> [ChatEntryID?] {
        var claimed = Set<Int>()
        return pending.map { send in
            let key = codexEchoKey(send.text)
            let index = candidates.indices.first { index in
                let candidate = candidates[index]
                guard !claimed.contains(index), isAfter(candidate, send.cursor) else { return false }
                switch candidate.kind {
                case .compaction:
                    return key == compactCommand
                case .prompt(let text, _):
                    return key != compactCommand && codexEchoKey(text) == key
                }
            }
            guard let index else { return nil }
            claimed.insert(index)
            return candidates[index].entryID
        }
    }

    /// True when `candidate` was recorded after the cursor: later in the
    /// same rollout, or in another one (a revert continues in a new file,
    /// and only the live file offers candidates).
    private static func isAfter(_ candidate: CodexEchoCandidate, _ cursor: CodexEchoCursor) -> Bool {
        candidate.rolloutID != cursor.rolloutID || candidate.offset >= cursor.offset
    }

    /// Characters Heeler strips before sending: zero-width and bidi
    /// controls, word joiners, the byte order mark, variation selectors and
    /// tags.
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF,
            0xFE00...0xFE0F, 0xE0000...0xE007F, 0xE0100...0xE01EF:
            return true
        default:
            return false
        }
    }
}
