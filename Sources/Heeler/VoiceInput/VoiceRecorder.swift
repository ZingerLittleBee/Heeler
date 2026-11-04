@preconcurrency import AVFoundation
import Foundation

/// One finished recording: 16 kHz mono 16-bit WAV, held in memory until its
/// text lands or the user dismisses it. The file it was written to is
/// already gone.
struct VoiceRecording: Equatable, Sendable {
    let audio: Data
    let duration: TimeInterval
}

enum VoiceRecorderError: Error, Equatable, Sendable {
    case microphoneUnavailable
    case recordingFailed

    var message: String {
        switch self {
        case .microphoneUnavailable:
            "The microphone is in use or unavailable."
        case .recordingFailed:
            "The recording could not be saved."
        }
    }
}

/// The microphone, so `VoiceInputSession` is tested without one. The audio
/// session belongs to the process, so there is one recorder for the app.
@MainActor
protocol VoiceRecorder: AnyObject {
    /// Asks the first time; afterwards reports the user's choice.
    func requestPermission() async -> Bool
    /// Ends on its own at `maxDuration`, calling `onEnded`.
    func start(maxDuration: TimeInterval) throws
    /// Ends the recording and hands back what it heard.
    func stop() throws -> VoiceRecording
    /// Ends the recording and throws it away.
    func cancel()
    /// How loud the microphone is right now, from 0 for silence to 1; 0
    /// when nothing is recording.
    func level() -> Double
    /// The system ended or paused the recording: the time limit, a call, or
    /// a lost route. `stop()` still returns what was heard before it.
    var onEnded: (@MainActor () -> Void)? { get set }
}

/// `AVAudioRecorder` writing linear PCM WAV to a protected temporary file.
/// Speech services take WAV without a decoder, and 16 kHz mono 16-bit keeps
/// two minutes under 4 MB.
@MainActor
final class SystemVoiceRecorder: VoiceRecorder {
    var onEnded: (@MainActor () -> Void)?

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private let delegate = RecorderDelegate()
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?

    init() {
        delegate.onFinish = { [weak self] in self?.systemEnded() }
    }

    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    func start(maxDuration: TimeInterval) throws {
        cancel()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
            // The tap that stops a recording lands while the session still
            // records, and iOS mutes haptics then unless this is on.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
        } catch {
            deactivate()
            throw VoiceRecorderError.microphoneUnavailable
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "voice-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            deactivate()
            throw VoiceRecorderError.microphoneUnavailable
        }
        recorder.delegate = delegate
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: maxDuration) else {
            recorder.deleteRecording()
            deactivate()
            throw VoiceRecorderError.microphoneUnavailable
        }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        self.recorder = recorder
        fileURL = url
        observeSession()
    }

    func stop() throws -> VoiceRecording {
        guard let recorder, let fileURL else { throw VoiceRecorderError.recordingFailed }
        let duration = recorder.currentTime
        self.recorder = nil
        self.fileURL = nil
        recorder.delegate = nil
        recorder.stop()
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            deactivate()
        }
        guard let audio = try? Data(contentsOf: fileURL), !audio.isEmpty else {
            throw VoiceRecorderError.recordingFailed
        }
        // `currentTime` reads zero once the recorder ends on its own; the
        // file's length then gives the duration.
        let measured = duration > 0 ? duration : Self.duration(ofWAV: audio)
        return VoiceRecording(audio: audio, duration: measured)
    }

    func cancel() {
        guard let recorder else { return }
        self.recorder = nil
        fileURL = nil
        recorder.delegate = nil
        recorder.stop()
        recorder.deleteRecording()
        deactivate()
    }

    func level() -> Double {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        return Self.level(decibels: recorder.averagePower(forChannel: 0))
    }

    /// Average power on a 0...1 scale: a quiet room near -50 dB reads as
    /// silence and speech close to the phone, around -10 dB, fills it.
    static func level(decibels: Float) -> Double {
        let quiet: Float = -50
        let loud: Float = -10
        return Double(min(1, max(0, (decibels - quiet) / (loud - quiet))))
    }

    /// Seconds of 16 kHz mono 16-bit audio after the header's `data` chunk.
    static func duration(ofWAV data: Data) -> TimeInterval {
        let marker = Data("data".utf8)
        guard let range = data.range(of: marker), range.upperBound + 4 <= data.count else {
            return 0
        }
        let bytes = data.count - (range.upperBound + 4)
        return TimeInterval(max(0, bytes)) / 32_000
    }

    private func systemEnded() {
        guard recorder != nil else { return }
        onEnded?()
    }

    private func observeSession() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let began =
                (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            guard began else { return }
            MainActor.assumeIsolated { self?.systemEnded() }
        }
        routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason =
                (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.systemEnded() }
        }
    }

    private func deactivate() {
        let center = NotificationCenter.default
        if let interruptionObserver { center.removeObserver(interruptionObserver) }
        if let routeObserver { center.removeObserver(routeObserver) }
        interruptionObserver = nil
        routeObserver = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// `AVAudioRecorderDelegate` calls arrive off the main actor.
private final class RecorderDelegate: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
    /// Set once in `SystemVoiceRecorder.init`, before any recording.
    nonisolated(unsafe) var onFinish: (@MainActor () -> Void)?

    func audioRecorderDidFinishRecording(_: AVAudioRecorder, successfully _: Bool) {
        let onFinish = onFinish
        Task { @MainActor in onFinish?() }
    }

    func audioRecorderEncodeErrorDidOccur(_: AVAudioRecorder, error _: (any Error)?) {
        let onFinish = onFinish
        Task { @MainActor in onFinish?() }
    }
}
