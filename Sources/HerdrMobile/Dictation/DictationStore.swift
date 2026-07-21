import Foundation
import Observation

/// The Agent reply draft that dictation composes into. AgentInputStore is the
/// production conformer; keeping the seam this narrow is deliberate — the
/// dictation store may only compose into the draft the reply box already owns,
/// never reach into the send pipeline (the send path stays untouched, #36).
@MainActor
protocol ReplyDraft: AnyObject {
    var draft: String { get set }
    /// Caret position within `draft` as a character offset, mirrored from the
    /// reply box's text selection so dictation inserts at the cursor instead of
    /// overwriting (#37, User Story 6). `nil` means the caret is unknown (field
    /// unfocused), which composes at the end. The store writes it back so the
    /// caret follows the streaming transcript.
    var cursorOffset: Int? { get set }
}

extension AgentInputStore: ReplyDraft {}

/// Owns the hold-to-talk state machine for Dictation (#36) and writes
/// transcribed text into the reply draft — nothing else. It never sends: the
/// user reviews and sends the draft with the existing send button, so a
/// misrecognition can never reach a Blocked Agent's terminal.
///
/// The engine is a `DictationEngine` seam, so this store is exercised against a
/// scripted engine with no Speech framework anywhere (ADR 0003); the concrete
/// engine is verified manually on device.
///
/// ```
///                            ┌─ stopDictation() ─▶ finishing ─▶ idle
/// idle ─startDictation()─▶ recording                            ▲
///          ▲    │            ├─ cancelDictation() ──────────────┤
///          │    │            └─ engine error ──▶ failed(reason)
///          └────┴─ dismiss / next hold
/// ```
@MainActor
@Observable
final class DictationStore {
    enum State: Equatable {
        /// Not recording; the last session (if any) finished cleanly.
        case idle
        /// Capturing audio; partial transcripts are streaming into the draft.
        case recording
        /// The user released; waiting for the engine to flush the final
        /// transcript and end the stream.
        case finishing
        /// The session failed. Any partial text already composed into the draft
        /// is left in place (User Story 16); the reason routes the failure to
        /// its own remedy.
        case failed(Failure)
    }

    /// Why a session failed, split by where the failure is surfaced. A denied
    /// mic gets its own alert with a Settings shortcut (User Story 13); every
    /// other failure gets a line in the reply box's existing error row.
    enum Failure: Equatable {
        /// Microphone access is off — surfaced as an alert, not in the error
        /// row, and the mic button stays visible (User Stories 13, 14).
        case microphonePermissionDenied
        /// Any other failure, with a user-facing message for the error row
        /// (model missing → Settings, mid-recording capture failure, …).
        case message(String)
    }

    private(set) var state: State = .idle

    private let engine: any DictationEngine
    /// The reply draft to compose into; reached only through the protocol so
    /// the store touches only `draft` and its caret.
    private let draftTarget: any ReplyDraft
    /// Reads the language the user selected in Settings, snapshotted at
    /// touch-down so mid-session changes never swap engines under a live
    /// recording (#38). Replaces the tracer bullet's hardcoded `zh_CN`.
    private let currentLanguage: @MainActor () -> DictationLanguage

    /// The draft split at the caret as it stood when the session started: the
    /// dictated span is composed between these two, so text typed before *and
    /// after* the caret is preserved and dictation never overwrites it.
    private var basePrefix = ""
    private var baseSuffix = ""
    /// The latest transcript from the engine — the entire dictated span, which
    /// each update replaces.
    private var latestTranscript = ""
    /// The live session's consume task; non-nil exactly while a session is in
    /// flight. Doubles as the in-flight guard.
    private var sessionTask: Task<Void, Never>?
    /// Set by `cancelDictation()` so the consume loop stops touching the draft
    /// and the session ends at `idle` even if the engine still flushes a final.
    private var isCancelled = false
    /// The language snapshotted at touch-down and handed to the engine for this
    /// session.
    private var sessionLanguage: DictationLanguage = .default

    init(
        engine: any DictationEngine,
        draft: any ReplyDraft,
        language: @escaping @MainActor () -> DictationLanguage = { .default }
    ) {
        self.engine = engine
        self.draftTarget = draft
        self.currentLanguage = language
    }

    /// Whether the mic is live from the button's point of view: true while
    /// recording and while finalizing, so the button holds its active look
    /// until the final transcript lands.
    var isRecording: Bool {
        switch state {
        case .recording, .finishing: true
        case .idle, .failed: false
        }
    }

    /// True while the permission-denied alert should be presented. Distinct
    /// from the error row: a denied mic gets an alert with a Settings shortcut,
    /// never a line in the row (User Story 13).
    var showsPermissionAlert: Bool {
        state == .failed(.microphonePermissionDenied)
    }

    /// The message for the reply box's existing error row, or `nil` when there
    /// is nothing to show there. Permission denial is an alert, not a row line.
    var errorRowMessage: String? {
        if case .failed(.message(let text)) = state { return text }
        return nil
    }

    /// Button touch-down: begin a hold-to-talk session. Splits the current
    /// draft at the caret as the base and starts the engine. Ignored if a
    /// session is already in flight.
    func startDictation() {
        guard sessionTask == nil else { return }
        captureBase()
        latestTranscript = ""
        isCancelled = false
        // Snapshot the selected language now so a change in Settings mid-hold
        // never swaps the engine's locale under a live recording.
        sessionLanguage = currentLanguage()
        // Light the button immediately on touch-down; a first-use permission
        // or model-readiness check happens inside the engine's `start()`.
        state = .recording
        sessionTask = Task { await self.runSession() }
    }

    /// Button release: stop recording. Moves to `finishing` and asks the
    /// engine to flush its final transcript, which ends the stream. Ignored if
    /// no session is active.
    func stopDictation() {
        guard sessionTask != nil else { return }
        if state == .recording {
            state = .finishing
        }
        Task { await engine.stop() }
    }

    /// Slide-off cancel: discard everything this session streamed in and
    /// restore the draft (and caret) to exactly what it was before the hold,
    /// then wind the engine down. A botched take never pollutes the draft
    /// (User Story 5). Ignored if no session is active.
    func cancelDictation() {
        guard sessionTask != nil else { return }
        isCancelled = true
        draftTarget.draft = basePrefix + baseSuffix
        draftTarget.cursorOffset = basePrefix.count
        // Wind the engine down; any final it flushes is ignored by the loop.
        Task { await engine.stop() }
    }

    /// Dismiss the permission-denied alert and return to idle. The mic button
    /// stays visible regardless (User Story 14).
    func dismissPermissionAlert() {
        if state == .failed(.microphonePermissionDenied) {
            state = .idle
        }
    }

    /// Clears a lingering error-row message (e.g. a model-not-ready hint) so a
    /// later send failure isn't masked by it — the reply box calls this when
    /// the user attempts a send. The permission alert and any in-flight session
    /// are left untouched.
    func clearErrorRow() {
        if sessionTask == nil, case .failed(.message) = state {
            state = .idle
        }
    }

    private func captureBase() {
        let text = draftTarget.draft
        let offset = min(max(draftTarget.cursorOffset ?? text.count, 0), text.count)
        let caret = text.index(text.startIndex, offsetBy: offset)
        basePrefix = String(text[..<caret])
        baseSuffix = String(text[caret...])
    }

    private func runSession() async {
        do {
            let transcripts = try await engine.start(language: sessionLanguage)
            for try await transcript in transcripts {
                guard !isCancelled else { continue }
                latestTranscript = transcript.text
                applyToDraft()
            }
            endSession(.idle)
        } catch {
            // A cancel that races the stream still ends clean; otherwise keep
            // whatever partial already landed in the draft (User Story 16) and
            // report why it stopped.
            endSession(isCancelled ? .idle : .failed(Self.failure(for: error)))
        }
    }

    private func endSession(_ finalState: State) {
        sessionTask = nil
        isCancelled = false
        state = finalState
    }

    private func applyToDraft() {
        let composed = Self.compose(
            prefix: basePrefix, dictated: latestTranscript, suffix: baseSuffix)
        draftTarget.draft = composed
        // Keep the caret at the end of the dictated span so it follows the
        // streaming transcript and further typing lands after it.
        draftTarget.cursorOffset = composed.count - baseSuffix.count
    }

    /// Inserts the dictated span at the caret, between the pre-dictation prefix
    /// and suffix, adding a single space on either side only when that side
    /// abuts a non-space so words do not run together.
    static func compose(prefix: String, dictated: String, suffix: String) -> String {
        guard !dictated.isEmpty else { return prefix + suffix }
        var middle = dictated
        if let last = prefix.last, !last.isWhitespace {
            middle = " " + middle
        }
        if let first = suffix.first, !first.isWhitespace {
            middle += " "
        }
        return prefix + middle + suffix
    }

    private static func failure(for error: any Error) -> Failure {
        switch error {
        case DictationEngineError.microphonePermissionDenied:
            .microphonePermissionDenied
        case DictationEngineError.modelUnavailable:
            .message("The speech model isn't ready yet. Download it in Settings.")
        case DictationEngineError.localeUnsupported:
            .message("On-device dictation isn't available for this language.")
        case DictationEngineError.captureFailed(let detail):
            .message("Dictation stopped: \(detail)")
        default:
            .message("Dictation failed: \(error)")
        }
    }
}
