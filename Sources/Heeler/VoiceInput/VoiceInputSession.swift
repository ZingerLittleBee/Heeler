import Foundation
import Observation

/// Why a recording produced no text, and what the Composer offers next.
struct VoiceInputFailure: Equatable, Sendable {
    let message: String
    /// The recording is kept, so it can be sent again.
    var canRetry = false
    /// The fix is in Voice Input's settings.
    var opensVoiceInputSettings = false
    /// The fix is the system's microphone switch for Heeler.
    var opensMicrophoneSettings = false

    static let microphoneDenied = VoiceInputFailure(
        message: "Heeler can't use the microphone. Turn it on in Settings.",
        opensMicrophoneSettings: true)
    static let tooShort = VoiceInputFailure(message: "The recording was too short.")
    static let notSetUp = VoiceInputFailure(
        message: "Set up Voice Input to transcribe this recording.",
        canRetry: true, opensVoiceInputSettings: true)

    init(
        message: String, canRetry: Bool = false, opensVoiceInputSettings: Bool = false,
        opensMicrophoneSettings: Bool = false
    ) {
        self.message = message
        self.canRetry = canRetry
        self.opensVoiceInputSettings = opensVoiceInputSettings
        self.opensMicrophoneSettings = opensMicrophoneSettings
    }

    init(_ error: VoiceTranscriptionError) {
        self.init(
            message: error.message, canRetry: error != .emptyTranscript,
            opensVoiceInputSettings: error.suggestsSettings)
    }
}

/// Voice Input in one Composer: the phase its controls show, and the
/// recording kept for Retry. Its text goes into the draft of the Composer
/// it started in, and nowhere else; the store does the insertion.
@MainActor
@Observable
final class ComposerVoiceInput {
    enum Phase: Equatable {
        case idle
        /// Asking for the microphone.
        case starting
        case recording(since: Date)
        /// Uploading, or holding text until the input method's composition
        /// ends.
        case transcribing
        case failed(VoiceInputFailure)
    }

    fileprivate(set) var phase: Phase = .idle
    /// The microphone's recent loudness, oldest first, one sample per
    /// `VoiceInputSession.levelInterval`. It stays through transcribing, so
    /// the bar keeps showing what was heard, and clears when the next
    /// recording starts.
    fileprivate(set) var levels: [Double] = []
    /// Send waits a moment after text lands: the text can turn Stop into
    /// Send under a finger that meant Stop.
    private(set) var isHoldingSend = false
    /// The store's cue that `takeTranscript()` has text.
    @ObservationIgnored var onTranscript: (@MainActor () -> Void)?
    @ObservationIgnored fileprivate weak var session: VoiceInputSession?
    @ObservationIgnored fileprivate var recording: VoiceRecording?
    @ObservationIgnored fileprivate var task: Task<Void, Never>?
    @ObservationIgnored fileprivate var levelTask: Task<Void, Never>?
    @ObservationIgnored fileprivate var generation = 0
    @ObservationIgnored private var transcript: String?
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

    /// Recording or waiting on its text.
    var isBusy: Bool {
        switch phase {
        case .starting, .recording, .transcribing: true
        case .idle, .failed: false
        }
    }

    var blocksSend: Bool { isBusy || isHoldingSend }

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
    func takeTranscript() -> String? {
        guard let transcript else { return nil }
        self.transcript = nil
        phase = .idle
        holdSend()
        return transcript
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
        transcript = nil
        self.phase = phase
        return generation
    }

    fileprivate func fail(_ failure: VoiceInputFailure) {
        task = nil
        stopSamplingLevels()
        phase = .failed(failure)
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
        transcript = text
        onTranscript?()
    }

    fileprivate func reset() {
        generation += 1
        task?.cancel()
        task = nil
        stopSamplingLevels()
        transcript = nil
        recording = nil
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
    @ObservationIgnored private let primaryLanguage: @MainActor () -> String
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
            transcribe: { try await client.transcribe($0) })
    }

    init(
        settings: VoiceInputSettings,
        recorder: any VoiceRecorder,
        transcribe: @escaping @Sendable (VoiceTranscriptionRequest) async throws -> String,
        primaryLanguage: @escaping @MainActor () -> String = { VoiceInputLanguage.primary() },
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.settings = settings
        self.recorder = recorder
        self.transcribe = transcribe
        self.primaryLanguage = primaryLanguage
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
        case .starting, .transcribing:
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
        let generation = input.begin(.starting)
        input.task = Task { [weak self, weak input] in
            guard let self else { return }
            let granted = await recorder.requestPermission()
            guard let input, input.generation == generation else { return }
            beginRecording(input, granted: granted)
        }
        return .handled
    }

    /// Ends the recording and sends it.
    func stop(_ input: ComposerVoiceInput) {
        guard case .recording = input.phase, recordingInput === input else { return }
        recordingInput = nil
        let recording: VoiceRecording
        do {
            recording = try recorder.stop()
        } catch {
            input.fail(
                VoiceInputFailure(
                    message: (error as? VoiceRecorderError ?? .recordingFailed).message))
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
        case .starting: cancel(input)
        case .recording: stop(input)
        case .idle, .transcribing, .failed: break
        }
    }

    private func beginRecording(_ input: ComposerVoiceInput, granted: Bool) {
        input.task = nil
        guard granted else {
            input.fail(.microphoneDenied)
            return
        }
        // Another Composer may have taken the microphone during the request.
        if let other = recordingInput, other !== input { stop(other) }
        do {
            try recorder.start(maxDuration: Self.maximumDuration)
        } catch {
            input.fail(
                VoiceInputFailure(
                    message: (error as? VoiceRecorderError ?? .microphoneUnavailable).message))
            return
        }
        recordingInput = input
        input.phase = .recording(since: now())
        sampleLevels(of: input)
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
            primaryLanguage: primaryLanguage())
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
