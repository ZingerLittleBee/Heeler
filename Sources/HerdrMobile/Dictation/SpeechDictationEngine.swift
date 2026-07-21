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
    private let audioEngine = AVAudioEngine()
    private let converter = BufferConverter()

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

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

    func start(language: DictationLanguage) async throws
        -> AsyncThrowingStream<DictationTranscript, any Error>
    {
        guard await Self.ensureMicrophonePermission() else {
            throw DictationEngineError.microphonePermissionDenied
        }

        // Locale identity is unreliable across the Speech framework's own
        // canonicalization, so resolve through its equivalence lookup (ADR
        // 0003); a nil result means no on-device support (also the Simulator).
        guard let resolvedLocale = await Self.resolvedLocale(for: language) else {
            throw DictationEngineError.localeUnsupported
        }

        // Downloads happen from Settings, not mid-gesture: if the model is not
        // installed, fail fast and let the store route the user to Settings.
        guard await Self.isInstalled(resolvedLocale) else {
            throw DictationEngineError.modelUnavailable
        }

        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [])
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber])
        else {
            throw DictationEngineError.captureFailed("no compatible audio format")
        }
        try await analyzer.prepareToAnalyze(in: targetFormat)

        let inputStream = AsyncStream<AnalyzerInput> { continuation in
            self.inputContinuation = continuation
        }
        try await analyzer.start(inputSequence: inputStream)

        let (transcripts, continuation) = AsyncThrowingStream<
            DictationTranscript, any Error
        >.makeStream()

        // Bridge the transcriber's results onto our transcript stream, then
        // tear the audio session down once results end.
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    continuation.yield(
                        DictationTranscript(
                            text: String(result.text.characters), isFinal: result.isFinal))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            await self?.deactivateAudioSession()
        }

        try startCapturingAudio(into: targetFormat)
        return transcripts
    }

    func stop() async {
        // Stop the mic first so no further audio queues, then finalize the
        // analyzer so it flushes the last (final) result and ends the results
        // stream — which finishes the transcript stream.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        transcriber = nil
        resultsTask = nil
    }

    private func startCapturingAudio(into targetFormat: AVAudioFormat) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        // Capture at the hardware format and convert to the analyzer's format
        // per buffer; the tap runs on a realtime audio thread, so it captures
        // only Sendable values (never the actor).
        let converter = self.converter
        let continuation = inputContinuation
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, _ in
            guard let converted = try? converter.convertBuffer(buffer, to: targetFormat) else {
                return
            }
            continuation?.yield(AnalyzerInput(buffer: converted))
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
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

        if converter == nil || converter?.outputFormat != format {
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
