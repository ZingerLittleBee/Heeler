@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// Why the device's own recognition could not start.
enum LiveVoiceTranscriberError: Error, Equatable, Sendable {
    /// Before iOS 26, or no dictation model for this device.
    case unavailable
    case languageUnsupported
    /// The language's model is not on the device yet.
    case modelNotInstalled
    case downloadFailed
    case failed

    var failure: VoiceInputFailure {
        switch self {
        case .unavailable:
            VoiceInputFailure(
                message: String(localized: "This device can't transcribe speech on its own."),
                detail: String(localized: "Choose a speech service in Voice Input settings."),
                symbol: "iphone.slash", opensVoiceInputSettings: true)
        case .languageUnsupported:
            VoiceInputFailure(
                message: String(localized: "This device can't transcribe the chosen language."),
                detail: String(localized: "Choose another language or a speech service in Voice Input settings."),
                symbol: "globe", opensVoiceInputSettings: true)
        case .modelNotInstalled:
            VoiceInputFailure(
                message: String(localized: "This language's speech model is needed."),
                detail: String(localized: "Download it once to transcribe on this device, without a network."),
                symbol: "arrow.down.circle", downloadsModel: true)
        case .downloadFailed:
            VoiceInputFailure(
                message: String(localized: "The speech model could not be downloaded."),
                detail: String(localized: "Check the network and try again."),
                symbol: "arrow.down.circle", downloadsModel: true)
        case .failed:
            VoiceInputFailure(message: String(localized: "Speech recognition could not start."))
        }
    }
}

/// Speech turned into text on this device as it is heard (ADR 0043).
@MainActor
protocol LiveVoiceTranscriber: AnyObject {
    /// Loads `locale`'s model, biased toward `keywords`, and returns where
    /// the recorder sends audio. `onText` gets everything heard so far each
    /// time it changes.
    func start(
        locale: String, keywords: [String], onText: @escaping @MainActor (VoiceHeard) -> Void
    ) async throws -> VoiceAudioSink
    /// Settles the rest of what was heard and returns the whole text.
    func finish() async throws -> String
    /// Stops at once and drops what was not settled.
    func cancel()
    /// Downloads `locale`'s model, reporting progress from 0 to 1.
    func downloadModel(locale: String, progress: @escaping @MainActor (Double) -> Void) async throws
}

/// Whether a language's on-device model is ready.
enum VoiceInputModelStatus: Equatable, Sendable {
    case unsupported
    case notInstalled
    case installed
}

/// `DictationTranscriber`, the model behind the keyboard's dictation, with
/// its short-dictation preset: punctuation, and words that are revised as
/// more is heard. One language per recording; English words inside Chinese
/// speech come through, and Keywords bias it toward the user's terms.
@available(iOS 26.0, *)
@MainActor
final class DeviceVoiceTranscriber: LiveVoiceTranscriber {
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<String, any Error>?

    init() {}

    func start(
        locale identifier: String, keywords: [String], onText: @escaping @MainActor (VoiceHeard) -> Void
    ) async throws -> VoiceAudioSink {
        let module = try await Self.module(for: identifier)
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw LiveVoiceTranscriberError.modelNotInstalled
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw LiveVoiceTranscriberError.failed
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        if !keywords.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = keywords
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        self.input = input
        results = Task { @MainActor in
            var heard = VoiceHeard()
            for try await result in module.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    heard.settled += text
                    heard.revising = ""
                } else {
                    heard.revising = text
                }
                onText(heard)
            }
            return heard.text
        }
        let converter = VoicePCMConverter(to: format)
        return { buffer in
            guard let converted = converter.convert(buffer) else { return }
            input.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finish() async throws -> String {
        input?.finish()
        input = nil
        guard let analyzer, let results else { return "" }
        self.analyzer = nil
        self.results = nil
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await results.value
    }

    func cancel() {
        input?.finish()
        input = nil
        results?.cancel()
        results = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
    }

    func downloadModel(locale: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        try await Self.downloadModel(for: locale, progress: progress)
    }

    /// The languages this device can transcribe, as BCP 47 identifiers.
    static func supportedLanguages() async -> [String] {
        await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
    }

    /// The supported language nearest `identifier`, as listed by
    /// `supportedLanguages()`.
    static func supportedLanguage(equivalentTo identifier: String) async -> String? {
        await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))?
            .identifier(.bcp47)
    }

    static func modelStatus(for identifier: String) async -> VoiceInputModelStatus {
        guard let module = try? await module(for: identifier) else { return .unsupported }
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .installed
        case .supported, .downloading: return .notInstalled
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Downloads `identifier`'s model, reporting progress from 0 to 1.
    static func downloadModel(
        for identifier: String, progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let module = try await module(for: identifier)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            return
        }
        let reporter = Task { @MainActor in
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { reporter.cancel() }
        try await request.downloadAndInstall()
    }

    /// The transcriber for the supported locale nearest `identifier`.
    private static func module(for identifier: String) async throws -> DictationTranscriber {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
        else { throw LiveVoiceTranscriberError.languageUnsupported }
        return DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
    }
}
