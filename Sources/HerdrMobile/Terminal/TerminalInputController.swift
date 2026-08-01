import Foundation
import Observation

/// The only application-level writer for Attach input. Keyboard input, terminal
/// controls, reviewed Paste, and Staged Image paths all cross this boundary so
/// pausing and session-generation checks apply consistently.
@MainActor
@Observable
final class TerminalInputController {
    struct SessionGeneration: Sendable, Hashable {
        fileprivate let value: UInt64
    }

    struct PasteReview: Sendable, Equatable {
        let lineCount: Int
        let characterCount: Int
        let preview: String
    }

    enum PasteRequestResult: Sendable, Equatable {
        case inserted
        case requiresReview(PasteReview)
        case rejected
        case blocked

        var requiresReview: Bool {
            if case .requiresReview = self { true } else { false }
        }
    }

    private(set) var liveGeneration: SessionGeneration?
    private(set) var isPaused = false
    private(set) var pendingPaste: PasteReview?
    private(set) var pasteErrorMessage: String?

    private var nextGeneration: UInt64 = 0
    private var writer: ((Data) -> Void)?
    private var scroller: ((Data, Int) -> Void)?
    private var pendingPasteText: String?
    /// Captured when the paste is requested rather than read again at confirm
    /// time: the review sheet is what the user is looking at, so the framing
    /// they agreed to is the framing that was true when they were shown it.
    private var pendingPasteIsBracketed = false

    @discardableResult
    func beginSession(
        writer: @escaping (Data) -> Void,
        scroller: ((Data, Int) -> Void)? = nil
    ) -> SessionGeneration {
        nextGeneration &+= 1
        let generation = SessionGeneration(value: nextGeneration)
        liveGeneration = generation
        self.writer = writer
        self.scroller = scroller
        return generation
    }

    func endSession(_ generation: SessionGeneration) {
        guard generation == liveGeneration else { return }
        liveGeneration = nil
        writer = nil
        scroller = nil
        cancelPaste()
    }

    func pause() {
        isPaused = true
        cancelPaste()
    }

    func resume() {
        isPaused = false
    }

    /// Sends ordinary terminal bytes if a live, unpaused Attach session exists.
    func send(_ data: Data) {
        guard !data.isEmpty, !isPaused else { return }
        writer?(data)
    }

    /// Touch scrolling is deliberately separate from reliable terminal input.
    /// The live session can coalesce and shed stale momentum without changing
    /// keyboard, Paste, Snippet, or staged-path delivery semantics.
    func scroll(_ sequence: Data, rows: Int) {
        guard !sequence.isEmpty, rows > 0, !isPaused else { return }
        scroller?(sequence, rows)
    }

    /// Inserts a staged path only into the session captured by an image
    /// operation. Path and separator remain distinct writes and no submit byte
    /// is ever synthesized.
    @discardableResult
    func insertPath(_ path: String, matching generation: SessionGeneration) -> Bool {
        guard generation == liveGeneration else { return false }
        return insertPathIntoCurrentSession(path)
    }

    /// Recovery action chosen by the user. It intentionally targets whichever
    /// Attach session is live now, rather than the operation's old generation.
    @discardableResult
    func insertPathIntoCurrentSession(_ path: String) -> Bool {
        guard !isPaused, writer != nil, Self.isValidAbsoluteHostPath(path) else {
            return false
        }
        writer?(Data(path.utf8))
        writer?(Data(" ".utf8))
        return true
    }

    /// Sends a Snippet's text. It never carries a submit byte of its own — a
    /// Snippet is stored with carriage returns already collapsed to line feeds
    /// (see `Snippet.make`) — and multiline text is framed as a paste so the
    /// remote application reads it as one block rather than a run of keys.
    ///
    /// Unlike Paste, there is no review step: the user wrote this text, named
    /// it, and can see it on the button they just tapped.
    @discardableResult
    func insertSnippet(_ text: String, bracketedPaste: Bool) -> Bool {
        guard !isPaused, writer != nil, !text.isEmpty,
            TerminalTextSafety.containsOnlySafeScalars(text)
        else { return false }
        writer?(
            TerminalBracketedPaste.encode(
                text, bracketed: bracketedPaste && TerminalTextSafety.isMultiline(text)))
        return true
    }

    @discardableResult
    func requestPaste(_ text: String, bracketedPaste: Bool = false) -> PasteRequestResult {
        pasteErrorMessage = nil
        guard !isPaused, writer != nil else { return .blocked }
        guard TerminalTextSafety.containsOnlySafeScalars(text) else {
            cancelPaste()
            pasteErrorMessage = "The clipboard contains unsafe terminal control characters."
            return .rejected
        }
        guard TerminalTextSafety.isMultiline(text) else {
            if !text.isEmpty {
                writer?(Data(text.utf8))
            }
            return .inserted
        }

        let review = PasteReview(
            lineCount: Self.lineCount(text),
            characterCount: text.count,
            preview: Self.preview(text))
        pendingPasteText = text
        pendingPasteIsBracketed = bracketedPaste
        pendingPaste = review
        return .requiresReview(review)
    }

    @discardableResult
    func confirmPaste() -> Bool {
        guard !isPaused, writer != nil, let text = pendingPasteText else {
            cancelPaste()
            return false
        }
        // Reviewed text is still multiline text: without framing its newlines
        // reach the pane as separate key events, which is the very thing the
        // review sheet leaves the user unable to prevent.
        writer?(TerminalBracketedPaste.encode(text, bracketed: pendingPasteIsBracketed))
        cancelPaste()
        return true
    }

    func cancelPaste() {
        pendingPasteText = nil
        pendingPasteIsBracketed = false
        pendingPaste = nil
    }

    func clearPasteError() {
        pasteErrorMessage = nil
    }

    private static func isValidAbsoluteHostPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
                && scalar.properties.generalCategory != .control
        }
    }

    private static func lineCount(_ text: String) -> Int {
        var count = 1
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            if scalar.value == 0x0A {
                if !previousWasCarriageReturn { count += 1 }
            } else if scalar.value == 0x0D {
                count += 1
            }
            previousWasCarriageReturn = scalar.value == 0x0D
        }
        return count
    }

    private static func preview(_ text: String) -> String {
        let limit = 2_000
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
