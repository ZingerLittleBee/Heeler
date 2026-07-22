import Foundation

/// Identifies one owner's recording attempt across asynchronous startup and
/// teardown. A stop for an older screen must never affect a newer session on
/// the app-wide shared engine.
struct DictationSessionID: Hashable, Sendable {
    private let rawValue = UUID()
}

/// One transcription update from a `DictationEngine`. `text` is the best
/// transcription of the current utterance so far: the engine revises it as
/// more audio arrives (volatile partials), then emits a last value with
/// `isFinal` set once it stops revising. The store treats `text` as the whole
/// dictated span, not an increment — each update replaces the previous one.
struct DictationTranscript: Sendable, Equatable {
    var text: String
    var isFinal: Bool

    init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Why a dictation session could not start or continue. The concrete engine
/// produces these; the store maps them to user-facing text. A closed taxonomy
/// so the UI can route each cause to its own remedy (permission vs. model)
/// without string-matching.
enum DictationEngineError: Error, Sendable, Equatable {
    /// The user has not granted (or has revoked) microphone access.
    case microphonePermissionDenied
    /// The on-device language model for the locale is not installed and could
    /// not be downloaded.
    case modelUnavailable
    /// The Speech framework reports no on-device support for the locale. This
    /// is also what the Simulator and CI report for every locale.
    case localeUnsupported
    /// Audio capture or the analyzer failed to start or run.
    case captureFailed(String)
}

/// The seam between Dictation and the iOS Speech stack: it wraps microphone
/// capture, the `SpeechAnalyzer` / `SpeechTranscriber` pipeline, and on-device
/// model assurance behind one protocol. Stores and UI depend only on this,
/// never on Speech framework types — the same discipline the app keeps between
/// Transport and Citadel (ADR 0002, ADR 0003).
protocol DictationEngine: Sendable {
    /// Resolves whether `language` is supported on device and whether its model
    /// is installed, via the Speech framework's supported-locale equivalence
    /// lookup (never raw `Locale` comparison, ADR 0003). Used by Settings to
    /// show per-language readiness.
    func modelStatus(for language: DictationLanguage) async -> DictationModelStatus

    /// Downloads and installs `language`'s on-device model, yielding progress
    /// fractions in `0...1` and finishing once installed. The stream finishes
    /// throwing a `DictationEngineError` if the language is unsupported or the
    /// download fails. Triggered from Settings so a hold-to-talk never blocks
    /// on a multi-megabyte download.
    func downloadModel(for language: DictationLanguage) async
        -> AsyncThrowingStream<Double, any Error>

    /// Begins a recording session in `language` and returns a stream of
    /// partial→final transcripts. Ensures microphone permission and resolves
    /// the on-device model; throws a `DictationEngineError` before yielding if
    /// the session cannot start (permission denied, model not installed,
    /// unsupported locale). The stream finishes normally after the matching
    /// `stop(sessionID:)` flushes the final transcript, and finishes throwing
    /// if capture fails mid-recording.
    func start(sessionID: DictationSessionID, language: DictationLanguage) async throws
        -> AsyncThrowingStream<DictationTranscript, any Error>

    /// Stops capture and finalizes the matching utterance: the stream yields
    /// its final transcript, then finishes. A no-op when `sessionID` is stale
    /// or no matching session is active.
    func stop(sessionID: DictationSessionID) async
}
