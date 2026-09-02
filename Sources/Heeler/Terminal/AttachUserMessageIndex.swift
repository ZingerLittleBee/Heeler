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
/// Contract only. `refs #268`.
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

    /// Submitted messages, oldest first.
    private(set) var entries: [Entry] = []

    /// Bytes the app is about to write to the Attach PTY. Printable content
    /// accumulates; a carriage return or newline closes the pending line and
    /// appends an entry. Editing keys (backspace, cursor movement) and control
    /// sequences must not corrupt the accumulator.
    func observeOutgoing(_ data: Data) {
        // TODO(#268): implement in package msgnav-index.
    }

    /// A message delivered out of band — the Composer's `agent.prompt` path,
    /// which never crosses the PTY.
    func record(submitted text: String) {
        // TODO(#268): implement in package msgnav-index.
    }

    /// Drops everything. Called when the Attach session is replaced, because
    /// entries describe one session's scrollback and must not outlive it.
    func reset() {
        // TODO(#268): implement in package msgnav-index.
    }

    /// Whether `frameText` appears to contain any indexed message.
    ///
    /// This is the predicate `TerminalMessageJumpController` is constructed
    /// with. It normalises both sides before comparing, so a message the TUI
    /// soft-wrapped, indented, or drew inside a box still matches.
    func frameContainsMessage(_ frameText: String) -> Bool {
        // TODO(#268): implement in package msgnav-index.
        false
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
        // TODO(#268): implement in package msgnav-index.
        text
    }
}
