import Foundation

/// What the user has submitted to one Attach session, so a later frame can be
/// recognised as carrying it.
///
/// The conversation on iOS is a repainted terminal grid, not a message model
/// (ADR 0013). Nothing in the frames marks which rows the user authored: no
/// agent CLI emits OSC 133, and herdr's API exposes no transcript. The one
/// thing the app reliably knows is what it sent, so that is what the jump
/// control searches for.
///
/// Two submission paths feed this index, because Agent detail has two:
/// keystrokes crossing `TerminalInputController` (Direct Input, ADR 0016) and
/// Composer sends that leave over `agent.prompt` without touching the PTY.
/// `AgentComposerStore.messages` is not a substitute — it is in-memory, scoped
/// to the Composer, and empty in Direct Input mode.
///
/// Scope, deliberately: only messages submitted through *this* Attach session
/// are indexed. Messages sent from a desktop herdr, or before the app attached,
/// are not jump targets.
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

    /// Jump targets shorter than this match almost any frame (`y`, `ok`).
    static let minimumEntryCharacterCount = 8

    /// Oldest entries are dropped past this so a long session stays bounded.
    static let maximumEntryCount = 200

    /// TUIs may truncate or reflow a long message; matching the whole
    /// normalised entry would miss those frames. This many leading characters
    /// is still long enough to be a distinctive jump target.
    static let matchPrefixCharacterCount = 64

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
    /// content. The Esc quick key cancels only a Composer-inserted pending
    /// line; raw `0x1B` keeps CSI/SS3 split-tolerant scanning.
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

    /// Whether `frameText` appears to contain any indexed message.
    ///
    /// This is the predicate `TerminalMessageJumpController` is constructed
    /// with. It normalises both sides before comparing, so a message the TUI
    /// soft-wrapped, indented, or drew inside a box still matches.
    func frameContainsMessage(_ frameText: String) -> Bool {
        guard !entries.isEmpty else { return false }
        let frame = Self.normalize(frameText)
        guard !frame.isEmpty else { return false }
        return entries.contains { entry in
            let key = Self.matchKey(for: entry.normalizedText)
            return !key.isEmpty && frame.contains(key)
        }
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
        guard normalized.count >= Self.minimumEntryCharacterCount else { return }
        entries.append(
            Entry(id: UUID(), rawText: rawText, normalizedText: normalized))
        if entries.count > Self.maximumEntryCount {
            entries.removeFirst(entries.count - Self.maximumEntryCount)
        }
    }

    private static func matchKey(for normalizedText: String) -> String {
        if normalizedText.count <= matchPrefixCharacterCount {
            return normalizedText
        }
        return String(normalizedText.prefix(matchPrefixCharacterCount))
    }

    private static func stripLeadingDecorations(_ line: String) -> String {
        var text = line
        while true {
            text = text.trimmingCharacters(in: .whitespaces)
            guard let first = text.unicodeScalars.first,
                isLeadingDecoration(first)
            else { return text }
            text = String(text.unicodeScalars.dropFirst())
        }
    }

    /// Prompt / box glyphs actually observed in agent TUI captures, plus the
    /// surrounding Box Drawing and Block Elements ranges (`▎` is U+258E).
    private static func isLeadingDecoration(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x003E: true  // >
        case 0x203A: true  // ›
        case 0x276F: true  // ❯
        case 0x2500...0x259F: true  // Box Drawing + Block Elements
        default: false
        }
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
