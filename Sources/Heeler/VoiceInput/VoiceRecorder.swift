@preconcurrency import AVFoundation
import Foundation
import OSLog
import Synchronization

/// One finished recording: 16 kHz mono 16-bit WAV, held in memory until its
/// text lands or the user dismisses it. It is never written to a file.
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
            String(localized: "The microphone is in use or unavailable.")
        case .recordingFailed:
            String(localized: "The recording could not be saved.")
        }
    }
}

/// Receives the microphone as it is heard, in `VoicePCM.format`, on the
/// audio engine's tap thread.
typealias VoiceAudioSink = @Sendable (AVAudioPCMBuffer) -> Void

/// The microphone, so `VoiceInputSession` is tested without one. The audio
/// session belongs to the process, so there is one recorder for the app.
@MainActor
protocol VoiceRecorder: AnyObject {
    /// Asks the first time; afterwards reports the user's choice.
    func requestPermission() async -> Bool
    /// Ends on its own at `maxDuration`, calling `onEnded`. With
    /// `builtInMicrophone`, records from the device's own microphone whatever
    /// else is connected. `onAudio` hears the recording as it is made.
    func start(maxDuration: TimeInterval, builtInMicrophone: Bool, onAudio: VoiceAudioSink?) throws
    /// Ends the recording and hands back what it heard.
    func stop() throws -> VoiceRecording
    /// Ends the recording and throws it away.
    func cancel()
    /// How loud the microphone is right now, from 0 for silence to 1; 0
    /// when nothing is recording.
    func level() -> Double
    /// The system ended or paused the recording: the time limit, a call, or
    /// a change of audio hardware. `stop()` still returns what was heard
    /// before it.
    var onEnded: (@MainActor () -> Void)? { get set }
}

/// The one format Voice Input records: 16 kHz mono 16-bit linear PCM.
/// Speech services take it as WAV without a decoder, it keeps two minutes
/// under 4 MB, and it is the format Apple's dictation model asks for.
enum VoicePCM {
    static let sampleRate: Double = 16_000

    static var format: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
    }

    /// `pcm` behind a WAV header.
    static func wav(_ pcm: Data) -> Data {
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytesPerSecond = UInt32(sampleRate) * 2
        append("RIFF")
        append(UInt32(36 + pcm.count))
        append("WAVE")
        append("fmt ")
        append(UInt32(16))
        append(UInt16(1))  // linear PCM
        append(UInt16(1))  // mono
        append(UInt32(sampleRate))
        append(bytesPerSecond)
        append(UInt16(2))  // bytes per frame
        append(UInt16(16))  // bits per sample
        append("data")
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}

/// Converts buffers to one format, keeping the resampler's state across the
/// buffers of one recording. Used from one thread at a time.
final class VoicePCMConverter: @unchecked Sendable {
    let output: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to output: AVAudioFormat) {
        self.output = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == output { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
            // The first samples' quality for no timestamp drift.
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
            return nil
        }
        // Hands the buffer over once, so the converter emits exactly its
        // worth of output.
        var isConsumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if isConsumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            isConsumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0 else { return nil }
        return converted
    }
}

/// `AVAudioEngine`'s input tap, converted to `VoicePCM.format`. The recording
/// is kept in memory for upload, and each stretch is handed to `onAudio` as it
/// arrives, so the same capture serves a speech service and the device's own
/// recognition.
///
/// The session mixes with other audio and keeps its output where it is: music
/// on a Bluetooth speaker or headphones keeps playing there, and the device's
/// speaker stays the output rather than the receiver. A Bluetooth microphone
/// records only where it keeps full bandwidth: AirPods with high-quality
/// recording on iOS 26 and later. Any other one would use the call profile,
/// narrowband and heavily filtered, which also takes a speaker off music, so
/// the device's own microphone, or a wired one, records instead.
@MainActor
final class SystemVoiceRecorder: VoiceRecorder {
    private static let log = Logger(subsystem: "dev.bybee.heeler", category: "VoiceInput")

    var onEnded: (@MainActor () -> Void)?

    private var engine: AVAudioEngine?
    private var tap: VoiceCaptureTap?
    private var observers: [NSObjectProtocol] = []

    init() {}

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

    func start(maxDuration: TimeInterval, builtInMicrophone: Bool, onAudio: VoiceAudioSink?) throws {
        cancel()
        guard let format = VoicePCM.format else { throw VoiceRecorderError.microphoneUnavailable }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord, mode: .default,
                options: Self.categoryOptions(builtInMicrophone: builtInMicrophone))
            // A preference outlives the session, so it is cleared when off.
            try? session.setPreferredInput(
                builtInMicrophone
                    ? session.availableInputs?.first { $0.portType == .builtInMic } : nil)
            // The tap that stops a recording lands while the session still
            // records, and iOS mutes haptics then unless this is on.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
        } catch {
            deactivate()
            throw VoiceRecorderError.microphoneUnavailable
        }
        Self.logInput(of: session)
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            deactivate()
            throw VoiceRecorderError.microphoneUnavailable
        }
        let tap = VoiceCaptureTap(
            format: format, maxFrames: Int(maxDuration * VoicePCM.sampleRate), onAudio: onAudio,
            onLimit: { [weak self] in Task { @MainActor in self?.systemEnded() } })
        // Sendable, so it does not inherit the main actor: the engine calls
        // it on its own thread.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
            tap.receive(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            deactivate()
            throw VoiceRecorderError.microphoneUnavailable
        }
        self.engine = engine
        self.tap = tap
        observe(engine)
    }

    func stop() throws -> VoiceRecording {
        guard let tap else { throw VoiceRecorderError.recordingFailed }
        end()
        let (pcm, frames) = tap.finish()
        guard frames > 0 else { throw VoiceRecorderError.recordingFailed }
        return VoiceRecording(audio: VoicePCM.wav(pcm), duration: Double(frames) / VoicePCM.sampleRate)
    }

    func cancel() {
        guard engine != nil else { return }
        end()
    }

    func level() -> Double {
        tap?.level ?? 0
    }

    /// Average power on a 0...1 scale: a quiet room near -50 dB reads as
    /// silence and speech close to the phone, around -10 dB, fills it.
    nonisolated static func level(decibels: Float) -> Double {
        let quiet: Float = -50
        let loud: Float = -10
        return Double(min(1, max(0, (decibels - quiet) / (loud - quiet))))
    }

    /// Mixes with other audio, keeps Bluetooth and speaker output, and
    /// without the call profile's fallback never offers a Bluetooth
    /// microphone that cannot record in full bandwidth.
    nonisolated static func categoryOptions(builtInMicrophone: Bool) -> AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]
        if !builtInMicrophone, #available(iOS 26.0, *) {
            options.insert(.bluetoothHighQualityRecording)
        }
        return options
    }

    /// The input a recording uses, by kind only: a port's name can be the
    /// owner's.
    private static func logInput(of session: AVAudioSession) {
        guard let input = session.currentRoute.inputs.first else { return }
        var highQuality = false
        if #available(iOS 26.0, *) {
            highQuality = input.bluetoothMicrophoneExtension?.highQualityRecording.isEnabled ?? false
        }
        let output = session.currentRoute.outputs.first?.portType.rawValue ?? "none"
        log.info(
            "Recording from \(input.portType.rawValue, privacy: .public) at \(session.sampleRate, privacy: .public) Hz, high quality \(highQuality, privacy: .public), output \(output, privacy: .public)"
        )
    }

    private func systemEnded() {
        guard engine != nil else { return }
        onEnded?()
    }

    private func end() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        tap = nil
        deactivate()
    }

    /// A call or Siri interrupts the session; a change of audio hardware
    /// stops the engine. Either way the recording ends with what was heard.
    private func observe(_ engine: AVAudioEngine) {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let began =
                    (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
                guard began else { return }
                MainActor.assumeIsolated { self?.systemEnded() }
            })
        observers.append(
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemEnded() }
            })
    }

    private func deactivate() {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// What the input tap hears, on the engine's tap thread: converted, kept up
/// to the recording's limit, measured for the level bar, and handed on.
private final class VoiceCaptureTap: Sendable {
    private struct Recorded {
        var pcm = Data()
        var frames = 0
        var level = 0.0
        var isFull = false
    }

    private let converter: VoicePCMConverter
    private let maxFrames: Int
    private let onAudio: VoiceAudioSink?
    private let onLimit: @Sendable () -> Void
    private let recorded = Mutex(Recorded())

    init(
        format: AVAudioFormat, maxFrames: Int, onAudio: VoiceAudioSink?,
        onLimit: @escaping @Sendable () -> Void
    ) {
        converter = VoicePCMConverter(to: format)
        self.maxFrames = maxFrames
        self.onAudio = onAudio
        self.onLimit = onLimit
    }

    var level: Double { recorded.withLock { $0.level } }

    func finish() -> (pcm: Data, frames: Int) {
        recorded.withLock { ($0.pcm, $0.frames) }
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer), let channel = converted.int16ChannelData?[0]
        else { return }
        let count = Int(converted.frameLength)
        let level = Self.level(of: channel, count: count)
        let (taken, reachedLimit) = recorded.withLock { recorded -> (Int, Bool) in
            guard !recorded.isFull else { return (0, false) }
            let taken = min(count, maxFrames - recorded.frames)
            recorded.pcm.append(Data(bytes: channel, count: taken * 2))
            recorded.frames += taken
            recorded.level = level
            recorded.isFull = recorded.frames >= maxFrames
            return (taken, recorded.isFull)
        }
        guard taken > 0 else { return }
        if taken < count { converted.frameLength = AVAudioFrameCount(taken) }
        onAudio?(converted)
        if reachedLimit { onLimit() }
    }

    private static func level(of samples: UnsafePointer<Int16>, count: Int) -> Double {
        guard count > 0 else { return 0 }
        var sum = 0.0
        for index in 0..<count {
            let sample = Double(samples[index]) / 32_768
            sum += sample * sample
        }
        let rms = (sum / Double(count)).squareRoot()
        return SystemVoiceRecorder.level(decibels: rms > 0 ? Float(20 * log10(rms)) : -160)
    }
}
