import Foundation
import Observation

/// Why a recording produced no text, and what the Composer offers next.
struct VoiceInputFailure: Equatable, Sendable {
    let message: String
    /// More about the cause, where the On Device recorder has room for it.
    var detail: String?
    /// The SF Symbol the On Device recorder shows beside the message.
    var symbol = "exclamationmark.triangle"
    /// The recording is kept, so it can be sent again.
    var canRetry = false
    /// The fix is in Voice Input's settings.
    var opensVoiceInputSettings = false
    /// The fix is the system's microphone switch for Heeler.
    var opensMicrophoneSettings = false
    /// The fix is downloading the device's speech model.
    var downloadsModel = false
    /// Nothing was heard, so speaking again may work.
    var restarts = false

    static let microphoneDenied = VoiceInputFailure(
        message: String(localized: "Heeler can't use the microphone. Turn it on in Settings."),
        symbol: "mic.slash", opensMicrophoneSettings: true)
    static let tooShort = VoiceInputFailure(message: String(localized: "The recording was too short."))
    static let notSetUp = VoiceInputFailure(
        message: String(localized: "Set up Voice Input to transcribe this recording."),
        canRetry: true, opensVoiceInputSettings: true)
    static let noSpeech = VoiceInputFailure(
        message: String(localized: "No speech was recognized."),
        detail: String(localized: "Hold the phone a little closer and try again."),
        symbol: "mic", restarts: true)

    init(
        message: String, detail: String? = nil, symbol: String = "exclamationmark.triangle",
        canRetry: Bool = false, opensVoiceInputSettings: Bool = false,
        opensMicrophoneSettings: Bool = false, downloadsModel: Bool = false, restarts: Bool = false
    ) {
        self.message = message
        self.detail = detail
        self.symbol = symbol
        self.canRetry = canRetry
        self.opensVoiceInputSettings = opensVoiceInputSettings
        self.opensMicrophoneSettings = opensMicrophoneSettings
        self.downloadsModel = downloadsModel
        self.restarts = restarts
    }

    init(_ error: VoiceTranscriptionError) {
        self.init(
            message: error.message, canRetry: error != .emptyTranscript,
            opensVoiceInputSettings: error.suggestsSettings)
    }
}

/// What the device has heard so far: words it has settled, then words it
/// may still revise.
struct VoiceHeard: Equatable, Sendable {
    var settled = ""
    var revising = ""

    var text: String { settled + revising }
}

/// A recording's text on its way into the draft, and whether the user asked
/// for the draft to be sent once it lands.
struct VoiceDraftText: Equatable, Sendable {
    let text: String
    let sends: Bool
}

/// Voice Input in one Composer: the phase its controls show, and the
/// recording kept for Retry. Its text goes into the draft of the Composer
/// it started in, and nowhere else; the store does the insertion.
@MainActor
@Observable
final class ComposerVoiceInput {
    enum Phase: Equatable {
        case idle
        /// Asking for the microphone, or loading the device's model.
        case starting
        case recording(since: Date)
        /// Uploading, settling the device's last words, or holding text
        /// until the input method's composition ends.
        case transcribing
        /// Fetching the device's speech model before recording again.
        case downloadingModel(progress: Double)
        case failed(VoiceInputFailure)
    }

    fileprivate(set) var phase: Phase = .idle
    /// The microphone's recent loudness, oldest first, one sample per
    /// `VoiceInputSession.levelInterval`. It stays through transcribing, so
    /// the bar keeps showing what was heard, and clears when the next
    /// recording starts.
    fileprivate(set) var levels: [Double] = []
    /// This recording is transcribed on the device, and the recorder takes
    /// the input's place (ADR 0043).
    fileprivate(set) var isOnDevice = false
    /// What the device has heard so far.
    fileprivate(set) var heard = VoiceHeard()
    /// The draft is sent as soon as this recording's text lands.
    fileprivate(set) var sendsWhenSettled = false
    /// Send waits a moment after text lands: the text can turn Stop into
    /// Send under a finger that meant Stop.
    private(set) var isHoldingSend = false
    /// The store's cue that `takeDraftText()` has text.
    @ObservationIgnored var onTranscript: (@MainActor () -> Void)?
    @ObservationIgnored fileprivate weak var session: VoiceInputSession?
    @ObservationIgnored fileprivate var recording: VoiceRecording?
    @ObservationIgnored fileprivate var transcriber: (any LiveVoiceTranscriber)?
    @ObservationIgnored fileprivate var task: Task<Void, Never>?
    @ObservationIgnored fileprivate var levelTask: Task<Void, Never>?
    @ObservationIgnored fileprivate var generation = 0
    @ObservationIgnored private var pending: VoiceDraftText?
    @ObservationIgnored private var holdGeneration = 0
    @ObservationIgnored private let sendHold: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    init(
        sendHold: Duration = .seconds(1),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.sendHold = sendHold
        self.sleep = sleep
    }

    /// Recording, waiting on its text, or fetching the model for it.
    var isBusy: Bool {
        switch phase {
        case .starting, .recording, .transcribing, .downloadingModel: true
        case .idle, .failed: false
        }
    }

    var blocksSend: Bool { isBusy || isHoldingSend }

    /// The On Device recorder holds the input's place: from the first tap
    /// until the text lands, and while a failure or a download waits.
    var showsRecorder: Bool { isOnDevice && phase != .idle }

    /// Recording mode, which the Composer's border marks.
    var isInRecordingMode: Bool {
        guard isOnDevice else { return false }
        switch phase {
        case .starting, .recording, .transcribing: return true
        case .idle, .downloadingModel, .failed: return false
        }
    }

    var isRecording: Bool {
        if case .recording = phase { true } else { false }
    }

    /// How long the recording on its way to the speech service runs.
    var recordedDuration: TimeInterval? { recording?.duration }

    /// Enough samples to fill the widest Composer.
    static let levelCapacity = 160

    var failure: VoiceInputFailure? {
        if case .failed(let failure) = phase { failure } else { nil }
    }

    /// Hands over text waiting for the draft, ending this recording.
    func takeDraftText() -> VoiceDraftText? {
        guard let pending else { return nil }
        self.pending = nil
        phase = .idle
        heard = VoiceHeard()
        // Sending right away is what the user asked for; there is no
        // Stop-under-the-finger to guard against.
        if !pending.text.isEmpty, !pending.sends { holdSend() }
        return pending
    }

    /// Drops the recording and any text still on its way: the recording
    /// bar's Cancel, Direct Input, the Blocked Card, or the last detail
    /// leaving.
    func cancel() {
        if let session {
            session.cancel(self)
        } else {
            reset()
        }
    }

    /// The Composer left the screen: a recording ends and is transcribed
    /// into this draft; a microphone request still waiting is dropped.
    func composerDidLeaveScreen() {
        session?.composerDidLeaveScreen(self)
    }

    /// Clears a failure and its recording.
    func dismissFailure() {
        guard case .failed = phase else { return }
        reset()
    }

    fileprivate func begin(_ phase: Phase) -> Int {
        generation += 1
        task?.cancel()
        task = nil
        stopSamplingLevels()
        pending = nil
        self.phase = phase
        return generation
    }

    fileprivate func fail(_ failure: VoiceInputFailure) {
        task = nil
        transcriber = nil
        sendsWhenSettled = false
        stopSamplingLevels()
        phase = .failed(failure)
    }

    fileprivate func show(_ heard: VoiceHeard) {
        self.heard = heard
    }

    fileprivate func record(level: Double) {
        levels.append(level)
        if levels.count > Self.levelCapacity {
            levels.removeFirst(levels.count - Self.levelCapacity)
        }
    }

    fileprivate func stopSamplingLevels() {
        levelTask?.cancel()
        levelTask = nil
    }

    fileprivate func deliver(_ text: String) {
        task = nil
        recording = nil
        transcriber = nil
        pending = VoiceDraftText(text: text, sends: sendsWhenSettled)
        sendsWhenSettled = false
        onTranscript?()
    }

    fileprivate func reset() {
        generation += 1
        task?.cancel()
        task = nil
        transcriber?.cancel()
        transcriber = nil
        stopSamplingLevels()
        recording = nil
        pending = nil
        heard = VoiceHeard()
        sendsWhenSettled = false
        phase = .idle
    }

    private func holdSend() {
        holdGeneration += 1
        let holdGeneration = holdGeneration
        isHoldingSend = true
        let sleep = sleep
        let hold = sendHold
        Task { [weak self] in
            try? await sleep(hold)
            guard let self, self.holdGeneration == holdGeneration else { return }
            isHoldingSend = false
        }
    }
}

/// The app's one microphone owner: the audio session belongs to the process,
/// so one recording runs at a time across windows. Each recording belongs to
/// the `ComposerVoiceInput` it started in; starting another stops it first,
/// and its text still goes to its own Composer.
@MainActor
@Observable
final class VoiceInputSession {
    /// About two minutes of speech; the WAV stays under 4 MB.
    static let maximumDuration: TimeInterval = 120
    static let minimumDuration: TimeInterval = 0.5
    /// How often the bar's waveform takes the microphone's level.
    static let levelInterval: Duration = .milliseconds(70)

    let settings: VoiceInputSettings
    @ObservationIgnored private let recorder: any VoiceRecorder
    @ObservationIgnored private let transcribe: @Sendable (VoiceTranscriptionRequest) async throws -> String
    /// The device's own recognition, nil where the system has none.
    @ObservationIgnored private let makeLiveTranscriber: @MainActor () -> (any LiveVoiceTranscriber)?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// The input whose recording holds the microphone.
    @ObservationIgnored private weak var recordingInput: ComposerVoiceInput?

    enum MicResult: Equatable {
        case handled
        /// No service, key, or agreement yet; nothing was recorded.
        case needsSetup
    }

    convenience init(settings: VoiceInputSettings) {
        let client = VoiceTranscriptionClient()
        self.init(
            settings: settings, recorder: SystemVoiceRecorder(),
            transcribe: { try await client.transcribe($0) },
            makeLiveTranscriber: {
                if #available(iOS 26.0, *) { DeviceVoiceTranscriber() } else { nil }
            })
    }

    init(
        settings: VoiceInputSettings,
        recorder: any VoiceRecorder,
        transcribe: @escaping @Sendable (VoiceTranscriptionRequest) async throws -> String,
        makeLiveTranscriber: @escaping @MainActor () -> (any LiveVoiceTranscriber)? = { nil },
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.settings = settings
        self.recorder = recorder
        self.transcribe = transcribe
        self.makeLiveTranscriber = makeLiveTranscriber
        self.now = now
        self.sleep = sleep
        recorder.onEnded = { [weak self] in self?.stopRecording() }
    }

    /// The mic button: starts from rest or after a failure and stops a
    /// recording. While the microphone is asked for or the text is on its
    /// way it does nothing, so a second tap meant for Stop cannot drop what
    /// was just said; the recording bar's Cancel does that.
    @discardableResult
    func toggle(_ input: ComposerVoiceInput) -> MicResult {
        switch input.phase {
        case .idle, .failed:
            return start(input)
        case .recording:
            stop(input)
        case .starting, .transcribing, .downloadingModel:
            break
        }
        return .handled
    }

    @discardableResult
    func start(_ input: ComposerVoiceInput) -> MicResult {
        guard settings.isReady else { return .needsSetup }
        if let other = recordingInput, other !== input { stop(other) }
        input.session = self
        input.recording = nil
        input.levels = []
        input.heard = VoiceHeard()
        input.sendsWhenSettled = false
        let onDevice = settings.service == .onDevice
        input.isOnDevice = onDevice
        let generation = input.begin(.starting)
        input.task = Task { [weak self, weak input] in
            guard let self else { return }
            let granted = await recorder.requestPermission()
            guard let input, input.generation == generation else { return }
            guard granted else {
                input.fail(.microphoneDenied)
                return
            }
            var onAudio: VoiceAudioSink?
            if onDevice {
                guard let sink = await startTranscriber(for: input, generation: generation) else { return }
                onAudio = sink
            }
            beginRecording(input, onAudio: onAudio)
        }
        return .handled
    }

    /// Ends the recording and turns it into text; with `sending`, the draft
    /// is sent once the text lands. Before recording has begun, nothing has
    /// been heard, so the start is dropped.
    func stop(_ input: ComposerVoiceInput, sending: Bool = false) {
        if case .starting = input.phase {
            cancel(input)
            return
        }
        guard case .recording = input.phase, recordingInput === input else { return }
        recordingInput = nil
        let recording: VoiceRecording
        do {
            recording = try recorder.stop()
        } catch {
            input.transcriber?.cancel()
            input.fail(
                VoiceInputFailure(
                    message: (error as? VoiceRecorderError ?? .recordingFailed).message))
            return
        }
        if let transcriber = input.transcriber {
            input.sendsWhenSettled = sending
            settle(transcriber, recording: recording, for: input)
            return
        }
        guard recording.duration >= Self.minimumDuration else {
            input.fail(.tooShort)
            return
        }
        upload(recording, for: input)
    }

    /// Sends a kept recording again.
    func retry(_ input: ComposerVoiceInput) {
        guard case .failed(let failure) = input.phase, failure.canRetry,
            let recording = input.recording
        else { return }
        upload(recording, for: input)
    }

    /// Fetches the device's speech model for the chosen language, then
    /// starts recording.
    func downloadModel(_ input: ComposerVoiceInput) {
        guard case .failed(let failure) = input.phase, failure.downloadsModel else { return }
        guard let transcriber = makeLiveTranscriber() else {
            input.fail(LiveVoiceTranscriberError.unavailable.failure)
            return
        }
        let generation = input.begin(.downloadingModel(progress: 0))
        let language = settings.onDeviceLanguage
        input.task = Task { [weak self, weak input] in
            do {
                try await transcriber.downloadModel(locale: language) { [weak input] progress in
                    guard let input, input.generation == generation else { return }
                    input.phase = .downloadingModel(progress: progress)
                }
            } catch {
                guard let input, input.generation == generation else { return }
                input.fail(LiveVoiceTranscriberError.downloadFailed.failure)
                return
            }
            guard let self, let input, input.generation == generation else { return }
            start(input)
        }
    }

    func cancel(_ input: ComposerVoiceInput) {
        if recordingInput === input {
            recordingInput = nil
            recorder.cancel()
        }
        input.reset()
    }

    /// The app went to the background, or the system ended the recording:
    /// what was heard is sent.
    func stopRecording() {
        if let recordingInput { stop(recordingInput) }
    }

    fileprivate func composerDidLeaveScreen(_ input: ComposerVoiceInput) {
        switch input.phase {
        case .starting, .downloadingModel: cancel(input)
        case .recording: stop(input)
        case .idle, .transcribing, .failed: break
        }
    }

    /// Loads the device's model; nil when the recording failed or was
    /// dropped meanwhile.
    private func startTranscriber(
        for input: ComposerVoiceInput, generation: Int
    ) async -> VoiceAudioSink? {
        guard let transcriber = makeLiveTranscriber() else {
            input.fail(LiveVoiceTranscriberError.unavailable.failure)
            return nil
        }
        input.transcriber = transcriber
        let sink: VoiceAudioSink
        do {
            sink = try await transcriber.start(
                locale: settings.onDeviceLanguage, keywords: settings.keywords
            ) { [weak input, weak transcriber] heard in
                guard let input, let transcriber, input.transcriber === transcriber else { return }
                input.show(heard)
            }
        } catch {
            transcriber.cancel()
            guard input.generation == generation else { return nil }
            input.fail((error as? LiveVoiceTranscriberError ?? .failed).failure)
            return nil
        }
        guard input.generation == generation else {
            transcriber.cancel()
            return nil
        }
        return sink
    }

    private func beginRecording(_ input: ComposerVoiceInput, onAudio: VoiceAudioSink?) {
        input.task = nil
        // Another Composer may have taken the microphone during the request.
        if let other = recordingInput, other !== input { stop(other) }
        do {
            try recorder.start(
                maxDuration: Self.maximumDuration,
                builtInMicrophone: settings.alwaysUsesBuiltInMicrophone,
                onAudio: onAudio)
        } catch {
            input.transcriber?.cancel()
            input.fail(
                VoiceInputFailure(
                    message: (error as? VoiceRecorderError ?? .microphoneUnavailable).message))
            return
        }
        recordingInput = input
        input.phase = .recording(since: now())
        sampleLevels(of: input)
    }

    /// The device settles its last words. If settling fails, what was
    /// already heard lands instead; a recording that heard nothing lands
    /// nothing, though a requested send still goes.
    private func settle(
        _ transcriber: any LiveVoiceTranscriber, recording: VoiceRecording,
        for input: ComposerVoiceInput
    ) {
        input.recording = recording
        let generation = input.begin(.transcribing)
        input.task = Task { [weak input] in
            let text = try? await transcriber.finish()
            guard let input, input.generation == generation else { return }
            let heard = text.flatMap { $0.isEmpty ? nil : $0 } ?? input.heard.text
            if heard.isEmpty, !input.sendsWhenSettled {
                input.fail(.noSpeech)
            } else {
                input.deliver(heard)
            }
        }
    }

    private func sampleLevels(of input: ComposerVoiceInput) {
        let sleep = sleep
        input.levelTask = Task { [weak self, weak input] in
            while true {
                do { try await sleep(Self.levelInterval) } catch { return }
                guard let self, let input, recordingInput === input, input.isRecording else { return }
                input.record(level: recorder.level())
            }
        }
    }

    private func upload(_ recording: VoiceRecording, for input: ComposerVoiceInput) {
        input.recording = recording
        guard let endpoint = settings.endpoint, settings.hasConsent(for: endpoint),
            let apiKey = settings.apiKey(for: endpoint)
        else {
            input.fail(.notSetUp)
            return
        }
        let generation = input.begin(.transcribing)
        let request = VoiceTranscriptionRequest(
            endpoint: endpoint, apiKey: apiKey, audio: recording.audio,
            options: settings.options(for: endpoint), keywords: settings.keywords,
            prompt: settings.prompt)
        let transcribe = transcribe
        input.task = Task { [weak input] in
            let result: Result<String, any Error>
            do {
                result = .success(try await transcribe(request))
            } catch {
                result = .failure(error)
            }
            guard let input, input.generation == generation else { return }
            switch result {
            case .success(let text):
                input.deliver(text)
            case .failure(let error as VoiceTranscriptionError):
                input.fail(VoiceInputFailure(error))
            case .failure(is CancellationError):
                input.reset()
            case .failure:
                input.fail(VoiceInputFailure(.network("")))
            }
        }
    }
}

/// Spaces around dictated text that lands between words. Han, kana, Hangul,
/// and full-width forms take none, as those languages are typed.
enum VoiceInputSpacing {
    static func fitted(_ text: String, after before: Character?, before after: Character?) -> String {
        guard let first = text.first, let last = text.last else { return text }
        var fitted = text
        if let before, joinsWithSpace(before, first) { fitted = " " + fitted }
        if let after, joinsWithSpace(last, after) { fitted += " " }
        return fitted
    }

    private static func joinsWithSpace(_ left: Character, _ right: Character) -> Bool {
        guard !isWide(left), !isWide(right) else { return false }
        let leftEndsWord = left.isLetter || left.isNumber || ".,;:!?".contains(left)
        let rightStartsWord = right.isLetter || right.isNumber
        return leftEndsWord && rightStartsWord
    }

    private static func isWide(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x11FF, 0x2E80...0x303F, 0x3040...0x30FF, 0x3100...0x31FF,
                0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF,
                0xFF00...0xFFEF, 0x20000...0x2FA1F:
                true
            default:
                false
            }
        }
    }
}
