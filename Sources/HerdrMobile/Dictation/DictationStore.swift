import Foundation
import Observation

/// The Agent reply draft that dictation composes into. AgentInputStore is the
/// production conformer; keeping the seam this narrow is deliberate — the
/// dictation store may only append into the draft the reply box already owns,
/// never reach into the send pipeline (the send path stays untouched, #36).
@MainActor
protocol ReplyDraft: AnyObject {
    var draft: String { get set }
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
/// idle ──startDictation()──▶ recording ──stopDictation()──▶ finishing ──▶ idle
///                               │                                          ▲
///                               └────────── engine error ──────────────▶ failed
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
        /// The session failed; the message is user-facing. Any partial text
        /// already streamed into the draft is left in place (User Story 16).
        case failed(String)
    }

    private(set) var state: State = .idle

    private let engine: any DictationEngine
    /// The reply draft to compose into; unowned-by-value via the protocol so
    /// the store touches only `draft`.
    private let draftTarget: any ReplyDraft

    /// The draft text as it stood when the current session started. Dictated
    /// text is composed onto this base, so typing done before dictation is
    /// preserved and dictation never overwrites it.
    private var baseText = ""
    /// The latest transcript from the engine — the entire dictated span, which
    /// each update replaces.
    private var latestTranscript = ""
    /// The live session's consume task; non-nil exactly while a session is in
    /// flight. Doubles as the in-flight guard.
    private var sessionTask: Task<Void, Never>?

    init(engine: any DictationEngine, draft: any ReplyDraft) {
        self.engine = engine
        self.draftTarget = draft
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

    /// Button touch-down: begin a hold-to-talk session. Captures the current
    /// draft as the base and starts the engine. Ignored if a session is
    /// already in flight.
    func startDictation() {
        guard sessionTask == nil else { return }
        baseText = draftTarget.draft
        latestTranscript = ""
        // Light the button immediately on touch-down; a first-use permission
        // or model-download hop happens inside the engine's `start()`.
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

    private func runSession() async {
        do {
            let transcripts = try await engine.start()
            for try await transcript in transcripts {
                latestTranscript = transcript.text
                applyToDraft()
            }
            endSession(.idle)
        } catch {
            // Keep whatever partial already landed in the draft (User Story
            // 16); only report why it stopped.
            endSession(.failed(Self.message(for: error)))
        }
    }

    private func endSession(_ finalState: State) {
        sessionTask = nil
        state = finalState
    }

    private func applyToDraft() {
        draftTarget.draft = Self.compose(base: baseText, dictated: latestTranscript)
    }

    /// Appends the dictated span onto the pre-dictation draft, inserting a
    /// single space only when the base ends in a non-space so words do not run
    /// together. Cursor-aware insertion is a later slice (#37); this appends at
    /// the end, which is where a phone caret sits after typing.
    static func compose(base: String, dictated: String) -> String {
        guard !dictated.isEmpty else { return base }
        guard let last = base.last else { return dictated }
        return last.isWhitespace ? base + dictated : base + " " + dictated
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case DictationEngineError.microphonePermissionDenied:
            "Microphone access is off. Turn it on in Settings to dictate."
        case DictationEngineError.modelUnavailable:
            "The speech model isn't ready yet."
        case DictationEngineError.localeUnsupported:
            "On-device dictation isn't available for this language."
        case DictationEngineError.captureFailed(let detail):
            "Dictation stopped: \(detail)"
        default:
            "Dictation failed: \(error)"
        }
    }
}
