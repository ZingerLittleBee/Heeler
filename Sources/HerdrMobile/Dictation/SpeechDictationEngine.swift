@preconcurrency import AVFoundation
import Foundation
import Speech

/// The production `DictationEngine`: on-device speech-to-text on the iOS 26
/// `SpeechAnalyzer` / `SpeechTranscriber` stack, hardcoded to Simplified
/// Chinese for the tracer bullet (#36). It owns microphone capture
/// (`AVAudioEngine`), ensures the language-model asset is installed on first
/// use, and streams partial→final transcripts.
///
/// This type cannot run in CI or the Simulator: `SpeechTranscriber` reports no
/// supported locales there, so `start()` throws `.localeUnsupported`. It is
/// exercised manually on device; stores test against a scripted engine
/// (ADR 0003).
actor SpeechDictationEngine: DictationEngine {
    private let locale: Locale
    private let audioEngine = AVAudioEngine()
    private let converter = BufferConverter()

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    init(locale: Locale = Locale(identifier: "zh_CN")) {
        self.locale = locale
    }

    func start() async throws -> AsyncThrowingStream<DictationTranscript, any Error> {
        guard await Self.ensureMicrophonePermission() else {
            throw DictationEngineError.microphonePermissionDenied
        }

        // Locale identity is unreliable across the Speech framework's own
        // canonicalization, so resolve through its equivalence lookup (ADR
        // 0003); a nil result means no on-device support (also the Simulator).
        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else {
            throw DictationEngineError.localeUnsupported
        }

        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [])
        self.transcriber = transcriber

        try await ensureModelInstalled(for: transcriber, locale: resolvedLocale)

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

    private func ensureModelInstalled(
        for transcriber: SpeechTranscriber, locale: Locale
    ) async throws {
        let installed = await Set(SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        if installed.contains(locale.identifier(.bcp47)) { return }

        do {
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber])
            {
                try await request.downloadAndInstall()
            }
        } catch {
            throw DictationEngineError.modelUnavailable
        }
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
