import Foundation

/// What the user has submitted to one Attach session, so a later frame can be
/// recognised as carrying it.
///
/// The conversation on iOS is a repainted terminal grid, not a message model
/// (ADR 0013). Nothing in the frames marks which rows the user authored: no
/// agent CLI emits OSC 133, and herdr's API exposes no transcript. So the jump
/// control works from what the grid does show — the prompt glyph a TUI draws
/// on the user's own turns — backed by what the app itself sent.
///
/// Two submission paths feed this index, because Agent detail has two:
/// keystrokes crossing `TerminalInputController` (Direct Input, ADR 0016) and
/// Composer sends that leave over `agent.prompt` without touching the PTY.
/// `AgentComposerStore.messages` is not a substitute — it is in-memory, scoped
/// to the Composer, and empty in Direct Input mode.
///
/// Jump targets come from two sources, unioned:
///
/// 1. **Prompt lines seen in a frame.** Every agent TUI Heeler attaches to
///    draws the user's own turns behind a prompt glyph (`>`, `›`, `❯`). A line
///    carrying one is a user message wherever it came from — a desktop herdr,
///    another device, or before the app attached — so scrolling back through
///    history makes that history jumpable. This is the primary source.
/// 2. **Messages this session submitted.** Kept for TUIs that draw no prompt
///    glyph, where source 1 finds nothing.
///
/// Both sources answer ``visibleMessageKeys(_:)`` with *stable identities*
/// rather than a yes/no match, because the jump loop walks by noticing that a
/// message it had not seen has come into view. An identity must therefore not
/// change as a message scrolls in a row at a time: a prompt line's key is
/// derived from that one line, never from how much of the message is on screen.
///
/// Known limits, all of which cost jump-target accuracy rather than correctness
/// elsewhere. A wrong or missing target means a jump scrolls to the top and
/// reports that it found nothing.
///
/// - Direct Input Shift-Enter is a keystroke LF (`AgentQuickKey.shiftEnter`),
///   and a keystroke LF closes the pending line, so one multiline Direct Input
///   message is indexed as its LF-delimited fragments. Making it otherwise would
///   mean guessing intent from a byte that carries none.
/// - While a Composer insert is pending, a write ending on an unresolved `ESC`
///   is read as the Escape *key* and cancels that draft. A CSI or SS3 sequence
///   split exactly at its introducer would therefore be misread during that
///   window. This is the deliberate trade for cancelling a hardware-keyboard
///   Escape, which arrives through Ghostty as anonymous `.keystroke` bytes and
///   is otherwise indistinguishable; no current key producer splits a sequence
///   that way. Pending text from any other source keeps full split tolerance.
/// - A prompt glyph is a heuristic, narrowed by two rules taken from live
///   captures: the glyph must be followed by a space, and it must sit within
///   ``maximumPromptIndent`` columns. Together those reject a `>_ OpenAI
///   Codex` banner and an indented `> /tmp/out.txt` shell redirection. What
///   survives is a flush-left quoted block in agent prose, which costs one
///   surplus press on the walk.
///
/// `refs #268`.
@MainActor
final class AttachUserMessageIndex {
    /// One submitted message, oldest first in `entries`.
    struct Entry: Identifiable, Equatable {
        let id: UUID
        /// Exactly what the user submitted, for display and diagnostics.
        let rawText: String
        /// `rawText` under `normalize(_:)`, precomputed for matching.
        let normalizedText: String
    }

    /// Minimum ``weight(of:)`` for a message to be a jump target.
    ///
    /// The gate exists because a very short message is a bad target: `y`,
    /// `ok`, `继续` recur, and since keys are the message's own text, two
    /// identical short messages collide into one target.
    static let minimumEntryWeight = 8

    /// How much a character contributes to the length gate. A CJK ideograph,
    /// kana, or hangul syllable is a word, not a letter, so counting
    /// characters flatly excluded ordinary Chinese prompts — `安装到我手机上`
    /// is seven characters and was silently not a jump target. `refs #268`.
    static func weight(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            total + (isIdeographic(scalar) ? 2 : 1)
        }
    }

    private static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF: true  // Hiragana + Katakana
        case 0x3400...0x4DBF: true  // CJK Unified Extension A
        case 0x4E00...0x9FFF: true  // CJK Unified
        case 0xAC00...0xD7AF: true  // Hangul Syllables
        case 0xF900...0xFAFF: true  // CJK Compatibility Ideographs
        case 0x20000...0x3FFFF: true  // CJK Unified Extensions B and beyond
        default: false
        }
    }

    /// Oldest entries are dropped past this so a long session stays bounded.
    static let maximumEntryCount = 200

    /// TUIs may truncate or reflow a long message; matching the whole
    /// normalised entry would miss those frames. This many leading characters
    /// is still long enough to be a distinctive jump target.
    static let matchPrefixCharacterCount = 64

    /// Head length used when matching a submitted message against a *single*
    /// rendered line. It must be short enough to fit on one line of a phone-
    /// width terminal: the whole-frame join cannot be relied on, because TUIs
    /// right-align gutter content (timestamps, token counts) into the same row
    /// as the message's first line, which lands in the middle of the joined
    /// text and breaks a longer contiguous match. Measured against a live Grok
    /// TUI at 40 columns, where a 64-character head never matched. `refs #268`.
    static let lineMatchPrefixCharacterCount = 24

    /// Where a PTY write originated. LF and Escape mean different things
    /// depending on the source, not on the byte alone.
    enum OutgoingSource: Sendable, Equatable {
        /// Direct Input and tools-keyboard `send`. LF submits; Escape is skipped.
        case keystroke
        /// Blocked Composer insert. LF is content; Escape cancels this pending line.
        case composerInsert
        /// Snippet body. LF is content; Escape is skipped.
        case snippet
        /// Reviewed or single-line paste. Newlines are content; Escape is skipped.
        case paste
        /// The Esc quick key. Cancels a Composer-inserted pending line and
        /// does not start CSI/SS3 lookahead.
        case escapeKey
    }

    /// Submitted messages, oldest first.
    private(set) var entries: [Entry] = []

    private var pendingText = ""
    private var pendingSource: OutgoingSource = .keystroke
    private var utf8Remainder: [UInt8] = []
    private var scanState = ScanState.text

    private enum ScanState {
        case text
        /// Saw ESC (`0x1B`); waiting to learn whether a CSI or SS3 follows.
        case escape
        /// CSI: ESC `[` or C1 `0x9B`, skipped until a final byte `0x40...0x7E`.
        case csi
        /// SS3: ESC `O` or C1 `0x8F`, skipped for one payload byte.
        case ss3
    }

    /// Bytes the app is about to write to the Attach PTY. Printable content
    /// accumulates; a keystroke carriage return or line feed closes the
    /// pending line. Newlines inside a Composer insert, Snippet, or Paste are
    /// content. The Esc quick key cancels a Composer-inserted pending line.
    /// A keystroke write that ends on an unresolved ESC does the same when
    /// that pending line is a Composer insert (hardware Esc); keystroke
    /// pending keeps CSI/SS3 split-tolerant scanning.
    func observeOutgoing(_ data: Data, source: OutgoingSource = .keystroke) {
        if source == .escapeKey {
            if pendingSource == .composerInsert {
                cancelPending()
            }
            scanState = .text
            return
        }

        var bytes: [UInt8]
        if utf8Remainder.isEmpty {
            bytes = Array(data)
        } else {
            bytes = utf8Remainder
            bytes.append(contentsOf: data)
            utf8Remainder.removeAll(keepingCapacity: true)
        }

        var offset = 0
        while offset < bytes.count {
            switch scanState {
            case .escape:
                switch bytes[offset] {
                case 0x5B:
                    scanState = .csi
                    offset += 1
                case 0x4F:
                    scanState = .ss3
                    offset += 1
                default:
                    // Raw ESC that is not CSI/SS3. Skip it; do not infer the
                    // Esc key. Cancellation is `.escapeKey` provenance.
                    scanState = .text
                }
                continue

            case .csi:
                let byte = bytes[offset]
                offset += 1
                if (0x40...0x7E).contains(byte) {
                    scanState = .text
                } else if byte == 0x1B {
                    scanState = .escape
                }
                continue

            case .ss3:
                offset += 1
                scanState = .text
                continue

            case .text:
                break
            }

            let byte = bytes[offset]
            if byte == 0x1B {
                scanState = .escape
                offset += 1
                continue
            }
            if byte == 0x9B {
                scanState = .csi
                offset += 1
                continue
            }
            if byte == 0x8F {
                scanState = .ss3
                offset += 1
                continue
            }
            if byte == 0x0D {
                if Self.newlineIsContent(source) {
                    if !pendingText.isEmpty {
                        appendPending("\r", source: source)
                    }
                } else {
                    closePendingLine()
                }
                offset += 1
                continue
            }
            if byte == 0x0A {
                if Self.newlineIsContent(source) {
                    if !pendingText.isEmpty {
                        appendPending("\n", source: source)
                    }
                } else {
                    closePendingLine()
                }
                offset += 1
                continue
            }
            if byte == 0x08 || byte == 0x7F {
                if !pendingText.isEmpty {
                    pendingText.removeLast()
                    if pendingText.isEmpty {
                        pendingSource = .keystroke
                    }
                }
                offset += 1
                continue
            }
            if byte < 0x20 {
                offset += 1
                continue
            }
            if byte < 0x80 {
                appendPending(Character(Unicode.Scalar(byte)), source: source)
                offset += 1
                continue
            }

            switch Self.utf8Step(bytes, at: offset) {
            case .incomplete:
                utf8Remainder = Array(bytes[offset...])
                return
            case .invalid:
                offset += 1
            case .scalar(let scalar, let width):
                appendPending(Character(scalar), source: source)
                offset += width
            }
        }
        // Hardware Esc arrives as a keystroke write of `0x1B`. If the pending
        // line is a Composer insert, that is cancel, not CSI lookahead.
        if scanState == .escape, pendingSource == .composerInsert {
            cancelPending()
            scanState = .text
        }
    }

    /// A message delivered out of band — the Composer's `agent.prompt` path,
    /// which never crosses the PTY.
    func record(submitted text: String) {
        appendEntry(rawText: text)
    }

    /// Drops everything. Called when the Attach session is replaced, because
    /// entries describe one session's scrollback and must not outlive it.
    func reset() {
        entries.removeAll(keepingCapacity: false)
        pendingText = ""
        pendingSource = .keystroke
        utf8Remainder.removeAll(keepingCapacity: false)
        scanState = .text
    }

    /// Stable identities of every user message visible in `frameText`.
    ///
    /// This is what `TerminalMessageJumpController` is constructed with: it
    /// walks until a key it has not seen appears, so the keys must identify a
    /// message, not a frame. A prompt line's key comes from that line alone,
    /// so it is the same whether one row of the message is on screen or all of
    /// them; a submitted entry's key is its identity, independent of which of
    /// its rows the frame happens to show.
    func visibleMessageKeys(_ frameText: String) -> Set<String> {
        let lines = frameText.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).map { Self.strip(String($0)) }
        guard !lines.isEmpty else { return [] }

        var keys = Set<String>()
        for line in lines {
            if let key = Self.promptLineKey(line) {
                keys.insert(key)
            }
        }

        guard !entries.isEmpty else { return keys }
        let joined = lines.map(\.text).joined(separator: " ")
        let frame = joined.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let normalizedLines = lines.map {
            $0.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        for entry in entries {
            let head = Self.head(
                of: entry.normalizedText, length: Self.matchPrefixCharacterCount)
            if !head.isEmpty, frame.contains(head) {
                keys.insert("sent:\(entry.id.uuidString)")
                continue
            }
            let lineHead = Self.head(
                of: entry.normalizedText, length: Self.lineMatchPrefixCharacterCount)
            if !lineHead.isEmpty, normalizedLines.contains(where: { $0.contains(lineHead) }) {
                keys.insert("sent:\(entry.id.uuidString)")
            }
        }
        return keys
    }

    /// Whether `frameText` appears to contain any user message.
    func frameContainsMessage(_ frameText: String) -> Bool {
        !visibleMessageKeys(frameText).isEmpty
    }

    /// Collapses a terminal frame or a submitted line to a comparable form:
    /// per line, drop leading box and prompt glyphs and surrounding
    /// whitespace; join the lines with a single space; collapse every
    /// whitespace run to one space; trim.
    ///
    /// Joining across lines is what makes a soft-wrapped message match. The
    /// per-line glyph strip is what makes a message inside a TUI's bordered
    /// input box match.
    static func normalize(_ text: String) -> String {
        let strippedLines = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).map { stripLeadingDecorations(String($0)) }
        let joined = strippedLines.joined(separator: " ")
        return joined.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func closePendingLine() {
        let raw = pendingText
        pendingText = ""
        pendingSource = .keystroke
        appendEntry(rawText: raw)
    }

    private func cancelPending() {
        pendingText = ""
        pendingSource = .keystroke
        utf8Remainder.removeAll(keepingCapacity: false)
    }

    private func appendPending(_ character: Character, source: OutgoingSource) {
        if pendingText.isEmpty || source == .composerInsert {
            pendingSource = source
        }
        pendingText.append(character)
    }

    private static func newlineIsContent(_ source: OutgoingSource) -> Bool {
        switch source {
        case .keystroke, .escapeKey: false
        case .composerInsert, .snippet, .paste: true
        }
    }

    private func appendEntry(rawText: String) {
        let normalized = Self.normalize(rawText)
        guard Self.weight(of: normalized) >= Self.minimumEntryWeight else { return }
        entries.append(
            Entry(id: UUID(), rawText: rawText, normalizedText: normalized))
        if entries.count > Self.maximumEntryCount {
            entries.removeFirst(entries.count - Self.maximumEntryCount)
        }
    }

    private static func head(of normalizedText: String, length: Int) -> String {
        if normalizedText.count <= length { return normalizedText }
        return String(normalizedText.prefix(length))
    }

    /// Columns of leading whitespace a prompt glyph may sit behind. Measured
    /// on live panes: claude and codex draw the user's turn in column 0, while
    /// their tool output is indented to column 5 and deeper. A box-drawing
    /// glyph is not whitespace, so a bordered input box still qualifies.
    static let maximumPromptIndent = 2

    /// One frame line with its leading decorations removed, remembering
    /// whether a prompt glyph was among them and how far the line was indented
    /// before any of them.
    private struct StrippedLine {
        var text: String
        var hasPromptGlyph: Bool
        var indent: Int
    }

    /// Identity for a line that opens a user message, or nil when the line is
    /// not one.
    ///
    /// Only the text before the line's first double space contributes. TUIs
    /// right-align gutter content into the message's own row (a send time, a
    /// token count), and some of it is relative and repaints — a key that
    /// included it would change under the jump loop and read as a different
    /// message. Everything the user typed is a single-spaced run, so cutting
    /// at the gutter keeps the part that identifies the message.
    private static func promptLineKey(_ line: StrippedLine) -> String? {
        guard line.hasPromptGlyph, line.indent <= maximumPromptIndent else {
            return nil
        }
        let body = line.text.components(separatedBy: "  ").first ?? line.text
        let collapsed = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard weight(of: collapsed) >= minimumEntryWeight else { return nil }
        return "line:\(collapsed)"
    }

    private static func stripLeadingDecorations(_ line: String) -> String {
        strip(line).text
    }

    private static func strip(_ line: String) -> StrippedLine {
        var text = line
        var sawPrompt = false
        let indent = line.unicodeScalars.prefix {
            CharacterSet.whitespaces.contains($0)
        }.count
        while true {
            text = text.trimmingCharacters(in: .whitespaces)
            guard let first = text.unicodeScalars.first else {
                return StrippedLine(
                    text: text, hasPromptGlyph: sawPrompt, indent: indent)
            }
            if isPromptGlyph(first) {
                // A prompt glyph is separated from what the user typed. Without
                // this, a banner like `>_ OpenAI Codex (v0.152.0)` reads as a
                // user message and becomes a stop on the walk.
                let rest = text.unicodeScalars.dropFirst()
                guard rest.first.map({ CharacterSet.whitespaces.contains($0) }) ?? true
                else {
                    return StrippedLine(
                        text: text, hasPromptGlyph: sawPrompt, indent: indent)
                }
                sawPrompt = true
            } else if !isBoxGlyph(first) {
                return StrippedLine(
                    text: text, hasPromptGlyph: sawPrompt, indent: indent)
            }
            text = String(text.unicodeScalars.dropFirst())
        }
    }

    /// Prompt glyphs actually observed in agent TUI captures: claude `>`,
    /// codex `›`, grok `❯`.
    private static func isPromptGlyph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x003E, 0x203A, 0x276F: true
        default: false
        }
    }

    /// Box Drawing and Block Elements, which TUIs draw around an input box
    /// (`▎` is U+258E).
    private static func isBoxGlyph(_ scalar: Unicode.Scalar) -> Bool {
        (0x2500...0x259F).contains(scalar.value)
    }

    private enum UTF8Step {
        case scalar(Unicode.Scalar, width: Int)
        case incomplete
        case invalid
    }

    private static func utf8Step(_ bytes: [UInt8], at offset: Int) -> UTF8Step {
        let lead = bytes[offset]
        let available = bytes.count - offset
        let width: Int
        switch lead {
        case 0xC2...0xDF:
            width = 2
        case 0xE0...0xEF:
            width = 3
        case 0xF0...0xF4:
            width = 4
        default:
            return .invalid
        }
        if available < width {
            return .incomplete
        }
        let slice = Data(bytes[offset..<(offset + width)])
        guard let decoded = String(data: slice, encoding: .utf8),
            let scalar = decoded.unicodeScalars.first,
            decoded.unicodeScalars.count == 1
        else {
            return .invalid
        }
        return .scalar(scalar, width: width)
    }
}
