import Foundation

@testable import HerdrMobile

/// Scripted `DictationEngine` for store-level tests, mirroring
/// `ScriptedTransport`: the test drives the transcript stream by hand — emit
/// partials, emit or flush a final, fail the stream — with no Speech framework
/// anywhere (ADR 0003). The real engine cannot run in CI or the Simulator.
final actor ScriptedDictationEngine: DictationEngine {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var downloadCount = 0
    /// The language handed to the most recent `start(language:)`, so tests can
    /// assert the store forwards the persisted selection (#38).
    private(set) var lastStartLanguage: DictationLanguage?

    private var continuation: AsyncThrowingStream<DictationTranscript, any Error>.Continuation?
    /// If set, the next `start()` throws it instead of opening a stream.
    private var startError: (any Error)?
    /// If set, `stop()` yields this final transcript before ending the stream,
    /// standing in for the analyzer flushing its last result on finalize.
    private var finalOnStop: DictationTranscript?

    /// Scripted model status per language id, defaulting to `.notInstalled`.
    private var statuses: [DictationLanguage.ID: DictationModelStatus] = [:]
    /// The live download stream's continuation, driven by hand like the
    /// transcript stream so a test can watch progress deterministically.
    private var downloadContinuation: AsyncThrowingStream<Double, any Error>.Continuation?

    // MARK: Scripting

    /// Makes the next `start()` throw `error` (permission denied, model
    /// missing, unsupported locale) instead of opening a stream.
    func setStartError(_ error: (any Error)?) {
        startError = error
    }

    /// Scripts the model status `modelStatus(for:)` reports for a language.
    func setModelStatus(_ status: DictationModelStatus, for language: DictationLanguage) {
        statuses[language.id] = status
    }

    /// Pushes a progress fraction onto the live download stream; false if none
    /// is live.
    @discardableResult
    func emitDownloadProgress(_ fraction: Double) -> Bool {
        guard let downloadContinuation else { return false }
        downloadContinuation.yield(fraction)
        return true
    }

    /// Ends the live download stream cleanly, as a completed install would.
    func finishDownload() {
        downloadContinuation?.finish()
        downloadContinuation = nil
    }

    /// Fails the live download stream, as a failed install would.
    func failDownload(_ error: any Error) {
        downloadContinuation?.finish(throwing: error)
        downloadContinuation = nil
    }

    /// Whether a download stream is currently live.
    var hasLiveDownload: Bool {
        downloadContinuation != nil
    }

    /// Scripts the final transcript `stop()` flushes before finishing.
    func setFinalOnStop(_ transcript: DictationTranscript?) {
        finalOnStop = transcript
    }

    /// Pushes a volatile partial onto the live stream; false if none is live.
    @discardableResult
    func emitPartial(_ text: String) -> Bool {
        guard let continuation else { return false }
        continuation.yield(DictationTranscript(text: text, isFinal: false))
        return true
    }

    /// Pushes a final transcript onto the live stream without ending it.
    @discardableResult
    func emitFinal(_ text: String) -> Bool {
        guard let continuation else { return false }
        continuation.yield(DictationTranscript(text: text, isFinal: true))
        return true
    }

    /// Kills the live stream with `failure`, as a mid-recording engine failure
    /// would.
    func failStream(_ failure: any Error) {
        continuation?.finish(throwing: failure)
        continuation = nil
    }

    /// Whether a recording stream is currently live.
    var hasLiveStream: Bool {
        continuation != nil
    }

    // MARK: DictationEngine

    func modelStatus(for language: DictationLanguage) async -> DictationModelStatus {
        statuses[language.id] ?? .notInstalled
    }

    func downloadModel(for language: DictationLanguage) async
        -> AsyncThrowingStream<Double, any Error>
    {
        downloadCount += 1
        let (stream, continuation) = AsyncThrowingStream<Double, any Error>.makeStream()
        self.downloadContinuation = continuation
        return stream
    }

    func start(language: DictationLanguage) async throws
        -> AsyncThrowingStream<DictationTranscript, any Error>
    {
        startCount += 1
        lastStartLanguage = language
        if let startError {
            throw startError
        }
        let (stream, continuation) = AsyncThrowingStream<
            DictationTranscript, any Error
        >.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() async {
        stopCount += 1
        if let finalOnStop {
            continuation?.yield(finalOnStop)
        }
        continuation?.finish()
        continuation = nil
    }
}
