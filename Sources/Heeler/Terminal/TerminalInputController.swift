import Foundation
import Observation

/// The only application-level writer for Attach input. Keyboard input, terminal
/// controls, reviewed Paste, and Snippets all cross this boundary so session
/// ownership applies consistently.
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
    private(set) var pendingPaste: PasteReview?
    private(set) var pasteErrorMessage: String?

    /// Submitted messages for this Attach session. Reset whenever the live
    /// writer is replaced, so entries cannot outlive the session they describe.
    let userMessageIndex = AttachUserMessageIndex()

    private var nextGeneration: UInt64 = 0
    private var writer: ((Data) -> Void)?
    private var acknowledgedWriter: (@Sendable (Data) async throws -> Void)?
    private var scroller: ((Data, Int) -> Void)?
    private var pendingPasteText: String?
    /// Captured when the paste is requested rather than read again at confirm
    /// time: the review sheet is what the user is looking at, so the framing
    /// they agreed to is the framing that was true when they were shown it.
    private var pendingPasteIsBracketed = false
    /// A channel can own a writer before the Attach client is ready for input.
    private var readyGeneration: SessionGeneration?
    private var heldInsertion = ""
    @ObservationIgnored private var readyWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var canConfirmPaste: Bool {
        writer != nil && pendingPasteText != nil
    }

    /// The session, once its Attach has produced output and can take input.
    var readySession: SessionGeneration? {
        readyGeneration == liveGeneration ? readyGeneration : nil
    }

    @discardableResult
    func beginSession(
        writer: @escaping (Data) -> Void,
        scroller: ((Data, Int) -> Void)? = nil,
        acknowledgedWriter: (@Sendable (Data) async throws -> Void)? = nil
    ) -> SessionGeneration {
        nextGeneration &+= 1
        let generation = SessionGeneration(value: nextGeneration)
        liveGeneration = generation
        readyGeneration = nil
        userMessageIndex.reset()
        self.writer = writer
        self.acknowledgedWriter = acknowledgedWriter
        self.scroller = scroller
        return generation
    }

    func endSession(_ generation: SessionGeneration, preservingPendingPaste: Bool = false) {
        guard generation == liveGeneration else { return }
        liveGeneration = nil
        readyGeneration = nil
        writer = nil
        acknowledgedWriter = nil
        scroller = nil
        userMessageIndex.reset()
        if !preservingPendingPaste {
            cancelPaste()
        }
    }

    /// Synchronously removes the predecessor Attach's input capabilities when
    /// replacement is scheduled. A reviewed Paste belongs to the surrounding
    /// interaction, so it remains pending for the replacement session.
    func detachSessionForReplacement() {
        liveGeneration = nil
        readyGeneration = nil
        writer = nil
        acknowledgedWriter = nil
        scroller = nil
        userMessageIndex.reset()
    }

    /// Returns once a session is ready, or the caller is cancelled.
    func untilSessionIsReady() async {
        guard readySession == nil else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    readyWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.readyWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    /// Writes `data` on `generation`'s session and returns once it has left.
    /// Throws `TerminalAttachInputError.sessionEnded` when that session is gone
    /// and nothing was written, or what the session's write threw. `source`
    /// indexes the bytes as typing; a caller that records its own message omits it.
    func writeAcknowledged(
        _ data: Data, generation: SessionGeneration, indexedAs source: AttachUserMessageIndex.OutgoingSource? = nil
    ) async throws {
        guard generation == liveGeneration, let acknowledgedWriter else {
            throw TerminalAttachInputError.sessionEnded
        }
        if let source { userMessageIndex.observeOutgoing(data, source: source) }
        try await acknowledgedWriter(data)
    }

    /// Sends ordinary terminal bytes if a live Attach session exists.
    /// Returns whether the bytes reached a live writer. Empty payloads and a
    /// missing session are no-ops and return false.
    @discardableResult
    func send(_ data: Data) -> Bool {
        guard let writer, !data.isEmpty else { return false }
        write(data, using: writer, source: .keystroke)
        return true
    }

    /// Inserts Composer text into the live Attach PTY without submitting.
    /// Indexed as a composer insertion: embedded newlines are content, and a
    /// later Escape key cancels this pending line.
    @discardableResult
    func insertComposerDraft(_ text: String) -> Bool {
        guard let writer, !text.isEmpty else { return false }
        write(Data(text.utf8), using: writer, source: .composerInsert)
        return true
    }

    /// The Esc quick key. Distinct from a raw `0x1B` that may start CSI/SS3.
    @discardableResult
    func sendEscapeKey() -> Bool {
        guard let writer else { return false }
        write(Data([0x1B]), using: writer, source: .escapeKey)
        return true
    }

    /// Touch scrolling is deliberately separate from reliable terminal input.
    /// The live session can coalesce and shed stale momentum without changing
    /// keyboard, Paste, or Snippet delivery semantics.
    func scroll(_ sequence: Data, rows: Int) {
        guard !sequence.isEmpty, rows > 0 else { return }
        scroller?(sequence, rows)
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
        guard let writer, !text.isEmpty,
            TerminalTextSafety.containsOnlySafeScalars(text)
        else { return false }
        write(
            TerminalBracketedPaste.encode(
                text, bracketed: bracketedPaste && TerminalTextSafety.isMultiline(text)),
            using: writer,
            source: .snippet)
        return true
    }

    /// Changes returns to a rebuilding Attach. Keep its single-line reference
    /// until the client produces output, then use the same writer as Snippets.
    /// Ordinary Snippets still require a writer and never enter this holding path.
    @discardableResult
    func insertReferenceWhenLive(_ text: String) -> Bool {
        guard !text.isEmpty,
            text.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
                    && !CharacterSet.newlines.contains($0)
            })
        else { return false }
        if let readyGeneration, readyGeneration == liveGeneration {
            return insertSnippet(text, bracketedPaste: false)
        }
        heldInsertion += text
        return true
    }

    func sessionDidBecomeLive(_ generation: SessionGeneration) {
        guard generation == liveGeneration else { return }
        readyGeneration = generation
        let text = heldInsertion
        heldInsertion = ""
        if !text.isEmpty { insertSnippet(text, bracketedPaste: false) }
        let waiters = readyWaiters.values
        readyWaiters = [:]
        for waiter in waiters { waiter.resume() }
    }

    /// Only a departure discards text; ending or replacing a pipeline keeps it.
    func discardHeldInsertion() {
        heldInsertion = ""
    }

    @discardableResult
    func requestPaste(_ text: String, bracketedPaste: Bool = false) -> PasteRequestResult {
        pasteErrorMessage = nil
        guard writer != nil else { return .blocked }
        guard TerminalTextSafety.containsOnlySafeScalars(text) else {
            cancelPaste()
            pasteErrorMessage = "The clipboard contains unsafe terminal control characters."
            return .rejected
        }
        guard TerminalTextSafety.isMultiline(text) else {
            if !text.isEmpty, let writer {
                write(Data(text.utf8), using: writer, source: .paste)
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
        guard canConfirmPaste, let writer, let text = pendingPasteText else { return false }
        // Reviewed text is still multiline text: without framing its newlines
        // reach the pane as separate key events, which is the very thing the
        // review sheet leaves the user unable to prevent.
        write(
            TerminalBracketedPaste.encode(text, bracketed: pendingPasteIsBracketed),
            using: writer,
            source: .paste)
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

    /// Records a Composer `agent.prompt` delivery against `generation`.
    /// Drops the write if that session is no longer live, so a reconnect
    /// cannot inherit a predecessor's jump target.
    func recordSubmitted(_ text: String, generation: SessionGeneration) {
        guard generation == liveGeneration else { return }
        userMessageIndex.record(submitted: text)
    }

    private func write(
        _ data: Data,
        using writer: (Data) -> Void,
        source: AttachUserMessageIndex.OutgoingSource
    ) {
        userMessageIndex.observeOutgoing(data, source: source)
        writer(data)
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
