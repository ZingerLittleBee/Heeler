@preconcurrency import AVFoundation
import Foundation
import Speech

/// The production `DictationEngine`: on-device speech-to-text on the iOS 26
/// `SpeechAnalyzer` / `SpeechTranscriber` stack, driven by the language the
/// user selected in Settings (#38). It owns microphone capture
/// (`AVAudioEngine`), resolves and reports the on-device language model, and
/// streams partial→final transcripts. Model downloads are triggered explicitly
/// from Settings, so `start()` fails fast when the model is missing rather than
/// blocking a hold-to-talk on a multi-megabyte download.
///
/// This type cannot run in CI or the Simulator: `SpeechTranscriber` reports no
/// supported locales there, so `start()` throws `.localeUnsupported`. It is
/// exercised manually on device; stores test against a scripted engine
/// (ADR 0003).
actor SpeechDictationEngine: DictationEngine {
    private enum SessionPhase {
        case idle
        case starting
        case active
        case stopping
    }

    private let microphone: MicrophoneCapture

    private var phase: SessionPhase = .idle
    private var sessionID: DictationSessionID?
    private var stopRequestedDuringStart = false
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    init(microphone: MicrophoneCapture = MicrophoneCapture()) {
        self.microphone = microphone
    }

    func modelStatus(for language: DictationLanguage) async -> DictationModelStatus {
        guard let resolved = await Self.resolvedLocale(for: language) else {
            return .unsupported
        }
        return await Self.isInstalled(resolved) ? .installed : .notInstalled
    }

    nonisolated func downloadModel(for language: DictationLanguage) async
        -> AsyncThrowingStream<Double, any Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let resolved = await Self.resolvedLocale(for: language) else {
                        throw DictationEngineError.localeUnsupported
                    }
                    let transcriber = SpeechTranscriber(
                        locale: resolved,
                        transcriptionOptions: [],
                        reportingOptions: [.volatileResults, .fastResults],
                        attributeOptions: [])
                    guard
                        let request = try await AssetInventory.assetInstallationRequest(
                            supporting: [transcriber])
                    else {
                        // Nothing to install — the model is already present.
                        continuation.yield(1)
                        continuation.finish()
                        return
                    }
                    let observation = request.progress.observe(\.fractionCompleted) {
                        progress, _ in
                        continuation.yield(progress.fractionCompleted)
                    }
                    defer { observation.invalidate() }
                    try await request.downloadAndInstall()
                    continuation.yield(1)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as DictationEngineError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: DictationEngineError.modelUnavailable)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func start(sessionID: DictationSessionID, language: DictationLanguage) async throws
        -> AsyncThrowingStream<DictationTranscript, any Error>
    {
        guard self.sessionID == nil else {
            throw DictationEngineError.captureFailed("another dictation session is active")
        }
        self.sessionID = sessionID
        phase = .starting
        stopRequestedDuringStart = false

        var startupAnalyzer: SpeechAnalyzer?
        var transcriptContinuation: AsyncThrowingStream<
            DictationTranscript, any Error
        >.Continuation?

        do {
            try checkStartupStillRequested(sessionID: sessionID)
            guard await Self.ensureMicrophonePermission() else {
                throw DictationEngineError.microphonePermissionDenied
            }
            try checkStartupStillRequested(sessionID: sessionID)

            // Locale identity is unreliable across the Speech framework's own
            // canonicalization, so resolve through its equivalence lookup (ADR
            // 0003); a nil result means no on-device support (also the Simulator).
            guard let resolvedLocale = await Self.resolvedLocale(for: language) else {
                throw DictationEngineError.localeUnsupported
            }
            try checkStartupStillRequested(sessionID: sessionID)

            // Downloads happen from Settings, not mid-gesture: if the model is
            // not installed, fail fast and route the user to Settings.
            guard await Self.isInstalled(resolvedLocale) else {
                throw DictationEngineError.modelUnavailable
            }
            try checkStartupStillRequested(sessionID: sessionID)

            let transcriber = SpeechTranscriber(
                locale: resolvedLocale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [])
            self.transcriber = transcriber

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            startupAnalyzer = analyzer
            self.analyzer = analyzer

            guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber])
            else {
                throw DictationEngineError.captureFailed("no compatible audio format")
            }
            try checkStartupStillRequested(sessionID: sessionID)
            try await analyzer.prepareToAnalyze(in: targetFormat)
            try checkStartupStillRequested(sessionID: sessionID)

            let inputStream = AsyncStream<AnalyzerInput> { continuation in
                self.inputContinuation = continuation
            }
            try await analyzer.start(inputSequence: inputStream)
            try checkStartupStillRequested(sessionID: sessionID)

            let (transcripts, continuation) = AsyncThrowingStream<
                DictationTranscript, any Error
            >.makeStream()
            transcriptContinuation = continuation

            let inputContinuation = inputContinuation
            try microphone.start(into: targetFormat) { buffer in
                inputContinuation?.yield(AnalyzerInput(buffer: buffer))
            }
            // A stop can arrive at any earlier suspension point. This final
            // check prevents a microphone that started late from escaping.
            try checkStartupStillRequested(sessionID: sessionID)

            phase = .active
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        continuation.yield(
                            DictationTranscript(
                                text: String(result.text.characters), isFinal: result.isFinal))
                    }
                    await self?.finishActiveSession(
                        sessionID: sessionID, analyzer: analyzer)
                    continuation.finish()
                } catch {
                    await self?.finishActiveSession(
                        sessionID: sessionID, analyzer: analyzer)
                    continuation.finish(throwing: error)
                }
            }
            return transcripts
        } catch {
            transcriptContinuation?.finish(throwing: error)
            await rollBackStartup(sessionID: sessionID, analyzer: startupAnalyzer)
            throw error
        }
    }

    func stop(sessionID: DictationSessionID) async {
        guard self.sessionID == sessionID else { return }
        switch phase {
        case .idle:
            return
        case .starting:
            // Keep the startup claim until its task observes this request and
            // rolls back. A second caller cannot start against half-torn-down
            // Speech resources in the meantime.
            stopRequestedDuringStart = true
            microphone.stop()
            inputContinuation?.finish()
            inputContinuation = nil
            let analyzer = analyzer
            await analyzer?.cancelAndFinishNow()
        case .active:
            // Stop the mic first so no further audio queues, then finalize the
            // analyzer so it flushes the last result and ends the stream. The
            // stopping phase keeps this generation claimed across the await.
            phase = .stopping
            microphone.stop()
            inputContinuation?.finish()
            inputContinuation = nil
            let analyzer = analyzer
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            clearSession(sessionID: sessionID)
        case .stopping:
            return
        }
    }

    private func checkStartupStillRequested(sessionID: DictationSessionID) throws {
        if self.sessionID != sessionID || stopRequestedDuringStart {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func rollBackStartup(
        sessionID: DictationSessionID, analyzer: SpeechAnalyzer?
    ) async {
        guard self.sessionID == sessionID else { return }
        microphone.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        await analyzer?.cancelAndFinishNow()
        clearSession(sessionID: sessionID)
    }

    private func finishActiveSession(
        sessionID: DictationSessionID, analyzer: SpeechAnalyzer
    ) {
        guard
            self.sessionID == sessionID,
            phase == .active,
            self.analyzer === analyzer
        else { return }
        microphone.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        clearSession(sessionID: sessionID)
    }

    private func clearSession(sessionID: DictationSessionID) {
        guard self.sessionID == sessionID else { return }
        analyzer = nil
        transcriber = nil
        resultsTask = nil
        stopRequestedDuringStart = false
        phase = .idle
        self.sessionID = nil
    }

    /// Resolves a language to an on-device-supported locale via the Speech
    /// framework's equivalence lookup, or `nil` when there is no support (also
    /// the Simulator and CI). Locale identity is never compared directly.
    private static func resolvedLocale(for language: DictationLanguage) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: language.locale)
    }

    private static func isInstalled(_ locale: Locale) async -> Bool {
        let installed = await Set(
            SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        return installed.contains(locale.identifier(.bcp47))
    }

    private static func ensureMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}

/// The narrow AVFoundation boundary used by `MicrophoneCapture`. Tests replace
/// it with deterministic hardware while production owns the real audio engine
/// and shared audio session here.
protocol MicrophoneCaptureHardware: Sendable {
    func activateSession() throws
    func installTap(_ receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void)
    func prepareEngine()
    func startEngine() throws
    func removeTap()
    func stopEngine()
    func deactivateSession()
}

/// Owns microphone startup as one transaction. Once the tap has been installed,
/// every later failure removes it, stops the engine, and deactivates the audio
/// session before the error escapes, leaving the same instance safe to retry.
final class MicrophoneCapture: @unchecked Sendable {
    private let hardware: any MicrophoneCaptureHardware
    private var isTapInstalled = false

    init(hardware: any MicrophoneCaptureHardware = AVFoundationMicrophoneCaptureHardware()) {
        self.hardware = hardware
    }

    func start(
        into targetFormat: AVAudioFormat,
        receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        // Input formats may change with the audio route between sessions. A
        // converter is valid only for this tap's input/output format pair.
        let converter = BufferConverter()
        do {
            try hardware.activateSession()
            hardware.installTap { buffer in
                guard let converted = try? converter.convertBuffer(buffer, to: targetFormat) else {
                    return
                }
                receive(converted)
            }
            isTapInstalled = true
            hardware.prepareEngine()
            try hardware.startEngine()
        } catch {
            cleanUp()
            throw error
        }
    }

    func stop() {
        cleanUp()
    }

    private func cleanUp() {
        if isTapInstalled {
            hardware.removeTap()
            isTapInstalled = false
        }
        hardware.stopEngine()
        hardware.deactivateSession()
    }
}

private final class AVFoundationMicrophoneCaptureHardware: MicrophoneCaptureHardware,
    @unchecked Sendable
{
    private let audioEngine: AVAudioEngine
    private let audioSession: AVAudioSession

    init(
        audioEngine: AVAudioEngine = AVAudioEngine(),
        audioSession: AVAudioSession = .sharedInstance()
    ) {
        self.audioEngine = audioEngine
        self.audioSession = audioSession
    }

    func activateSession() throws {
        try audioSession.setCategory(.record, mode: .spokenAudio)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    func installTap(_ receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        audioEngine.inputNode.installTap(
            onBus: 0, bufferSize: 4096, format: inputFormat
        ) { buffer, _ in
            receive(buffer)
        }
    }

    func prepareEngine() {
        audioEngine.prepare()
    }

    func startEngine() throws {
        try audioEngine.start()
    }

    func removeTap() {
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    func stopEngine() {
        audioEngine.stop()
    }

    func deactivateSession() {
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Converts captured microphone buffers to the analyzer's requested format.
/// Adapted from Apple's SpeechAnalyzer sample; the tap thread is realtime, so
/// this is `@unchecked Sendable` and holds no actor state.
private final class BufferConverter: @unchecked Sendable {
    enum ConversionError: Error {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convertBuffer(
        _ buffer: AVAudioPCMBuffer, to format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        if converter == nil
            || converter?.inputFormat != inputFormat
            || converter?.outputFormat != format
        {
            converter = AVAudioConverter(from: inputFormat, to: format)
            // Sacrifice the first samples' quality to avoid timestamp drift.
            converter?.primeMethod = .none
        }
        guard let converter else { throw ConversionError.failedToCreateConverter }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat, frameCapacity: frameCapacity)
        else {
            throw ConversionError.failedToCreateConversionBuffer
        }

        // One-shot input block: hand over the buffer once, then report no more
        // data so the converter emits exactly this buffer's worth of output.
        let consumed = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        consumed.initialize(to: false)
        defer {
            consumed.deinitialize(count: 1)
            consumed.deallocate()
        }
        nonisolated(unsafe) let consumedFlag = consumed

        var nsError: NSError?
        let status = converter.convert(to: output, error: &nsError) { _, inputStatus in
            if consumedFlag.pointee {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumedFlag.pointee = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error else { throw ConversionError.conversionFailed(nsError) }
        return output
    }
}
