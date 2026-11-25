import Foundation

/// How a service turns speech into text. Each service lists the ways it
/// offers, its default first (`VoiceInputService.recognitionModes`); where
/// it offers more than one, the user picks in Settings.
enum VoiceRecognitionMode: String, Codable, Sendable {
    /// Text arrives while the user speaks and shows in the recorder
    /// (ADR 0043) until the draft takes it.
    case stream
    /// The finished recording is sent, and its text comes back once.
    case batch
}

/// Turns one finished recording into text.
protocol VoiceBatchRecognizer: Sendable {
    func recognize(_ recording: VoiceRecording) async throws -> String
}

/// Turns speech into text as it is heard.
@MainActor
protocol VoiceStreamRecognizer: AnyObject {
    /// Gets ready to listen and returns where the recorder sends audio.
    /// `onText` gets everything heard so far each time it changes.
    func start(onText: @escaping @MainActor (VoiceHeard) -> Void) async throws -> VoiceAudioSink
    /// Settles the rest of what was heard and returns the whole text.
    func finish() async throws -> String
    /// Stops at once and drops what was not settled.
    func cancel()
}

/// Builds the recognizer for a recording from the saved settings. The
/// transports are replaced in tests; which recognizer a service gets is
/// decided here alone.
struct VoiceRecognizers {
    /// One multipart upload (`VoiceTranscriptionClient`).
    var upload: @Sendable (VoiceTranscriptionRequest) async throws -> String
    /// Opens a WebSocket, for Volcengine.
    var connect: @Sendable (URLRequest) async throws -> any VoiceWebSocket
    /// The device's own recognizer for a language and Keywords; nil where
    /// the system has none.
    var onDevice: @MainActor (_ language: String, _ keywords: [String]) -> (any VoiceStreamRecognizer)?
    /// Downloads the device's model for a language, reporting progress
    /// from 0 to 1.
    var installOnDeviceModel: @MainActor (
        _ language: String, _ progress: @escaping @MainActor (Double) -> Void
    ) async throws -> Void

    @MainActor
    static func system() -> VoiceRecognizers {
        let client = VoiceTranscriptionClient()
        return VoiceRecognizers(
            upload: { try await client.transcribe($0) },
            connect: { try await URLSessionVoiceWebSocket.connect($0) },
            onDevice: { language, keywords in
                if #available(iOS 26.0, *) {
                    DeviceVoiceTranscriber(language: language, keywords: keywords)
                } else {
                    nil
                }
            },
            installOnDeviceModel: { language, progress in
                guard #available(iOS 26.0, *) else { throw DeviceVoiceTranscriberError.unavailable }
                try await DeviceVoiceTranscriber.downloadModel(for: language, progress: progress)
            })
    }

    /// The recognizer for a finished recording; nil when the saved service
    /// takes none, or has no key or agreement.
    @MainActor
    func batch(for settings: VoiceInputSettings) -> (any VoiceBatchRecognizer)? {
        guard settings.service?.recognitionModes.contains(.batch) == true,
            let endpoint = settings.endpoint, settings.hasConsent(for: endpoint),
            let apiKey = settings.apiKey(for: endpoint)
        else { return nil }
        switch endpoint.wire {
        case .upload:
            return VoiceUploadRecognizer(
                upload: upload, endpoint: endpoint, apiKey: apiKey,
                options: settings.options(for: endpoint), keywords: settings.keywords, prompt: settings.prompt)
        case .volcengine:
            return VolcengineBatchRecognizer(
                endpoint: endpoint, apiKey: apiKey, keywords: settings.keywords, connect: connect)
        }
    }

    /// The recognizer that listens as the user speaks.
    @MainActor
    func stream(for settings: VoiceInputSettings) throws -> any VoiceStreamRecognizer {
        if settings.service == .onDevice {
            guard let recognizer = onDevice(settings.onDeviceLanguage, settings.keywords) else {
                throw DeviceVoiceTranscriberError.unavailable
            }
            return recognizer
        }
        guard settings.service?.recognitionModes.contains(.stream) == true,
            let endpoint = settings.endpoint, settings.hasConsent(for: endpoint),
            let apiKey = settings.apiKey(for: endpoint), case .volcengine = endpoint.wire
        else {
            throw VoiceTranscriptionError.invalidSettings(
                String(localized: "Set up Voice Input to transcribe this recording."))
        }
        return VolcengineStreamRecognizer(
            endpoint: endpoint, apiKey: apiKey, keywords: settings.keywords, connect: connect)
    }
}

/// A finished recording uploaded in one multipart request.
struct VoiceUploadRecognizer: VoiceBatchRecognizer {
    let upload: @Sendable (VoiceTranscriptionRequest) async throws -> String
    let endpoint: VoiceInputEndpoint
    let apiKey: String
    let options: VoiceInputRequestOptions
    let keywords: [String]
    let prompt: String

    func recognize(_ recording: VoiceRecording) async throws -> String {
        try await upload(
            VoiceTranscriptionRequest(
                endpoint: endpoint, apiKey: apiKey, audio: recording.audio, options: options,
                keywords: keywords, prompt: prompt))
    }
}
