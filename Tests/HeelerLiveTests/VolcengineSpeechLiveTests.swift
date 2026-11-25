@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import Heeler

/// Volcengine's speech recognition with a real key, over the app's own
/// WebSocket. `HEELER_VOLCENGINE_LIVE_KEY` is an API Key from the
/// Volcengine console with Doubao streaming speech recognition 2.0;
/// `HEELER_VOLCENGINE_LIVE_AUDIO` is a 16 kHz mono 16-bit WAV of speech on
/// this Mac, for example from `say -o speech.aiff` and
/// `afconvert -f WAVE -d LEI16@16000 -c 1 speech.aiff speech.wav`. Each test
/// sends that recording once and is billed by its length.
///
/// ```sh
/// xcrun simctl spawn <UDID> launchctl setenv HEELER_VOLCENGINE_LIVE_KEY "<key>"
/// xcrun simctl spawn <UDID> launchctl setenv HEELER_VOLCENGINE_LIVE_AUDIO "<wav path>"
/// make test-app SCHEME=HeelerLiveTests \
///   SIM_DESTINATION='platform=iOS Simulator,id=<UDID>' \
///   TEST_SELECTOR='HeelerLiveTests/VolcengineSpeechLiveTests'
/// xcrun simctl spawn <UDID> launchctl unsetenv HEELER_VOLCENGINE_LIVE_KEY
/// xcrun simctl spawn <UDID> launchctl unsetenv HEELER_VOLCENGINE_LIVE_AUDIO
/// ```
@Suite("Volcengine speech with a real key", .serialized, .timeLimit(.minutes(1)))
struct VolcengineSpeechLiveTests {
    private struct Setup {
        let endpoint: VoiceInputEndpoint
        let key: String
        let recording: VoiceRecording
    }

    private func setup() throws -> Setup {
        let environment = ProcessInfo.processInfo.environment
        let key = try #require(
            environment["HEELER_VOLCENGINE_LIVE_KEY"].flatMap { $0.isEmpty ? nil : $0 },
            "HEELER_VOLCENGINE_LIVE_KEY names no key")
        let path = try #require(
            environment["HEELER_VOLCENGINE_LIVE_AUDIO"].flatMap { $0.isEmpty ? nil : $0 },
            "HEELER_VOLCENGINE_LIVE_AUDIO names no recording")
        let audio = try Data(contentsOf: URL(filePath: path))
        return Setup(
            endpoint: try #require(VoiceInputEndpoint.preset(.volcengine)), key: key,
            recording: VoiceRecording(audio: audio, duration: Double(audio.count - 44) / 32_000))
    }

    private func connect(_ request: URLRequest) async throws -> any VoiceWebSocket {
        try await URLSessionVoiceWebSocket.connect(request)
    }

    @Test func aFinishedRecordingComesBackAsText() async throws {
        let setup = try setup()
        let recognizer = VolcengineBatchRecognizer(
            endpoint: setup.endpoint, apiKey: setup.key, keywords: ["tmux"], connect: connect)
        let text = try await recognizer.recognize(setup.recording)
        print("Volcengine batch: \(text)")
        #expect(!text.isEmpty)
    }

    @MainActor
    @Test func speechStreamedAsHeardSettlesIntoText() async throws {
        let setup = try setup()
        let recognizer = VolcengineStreamRecognizer(
            endpoint: setup.endpoint, apiKey: setup.key, keywords: ["tmux"], connect: connect)
        var heard: [VoiceHeard] = []
        let sink = try await recognizer.start { heard.append($0) }
        let format = try #require(VoicePCM.format)
        let samples = setup.recording.audio.dropFirst(44)
        // 200 ms at a time, at the pace of speech, as the microphone hands it over.
        for start in stride(from: samples.startIndex, to: samples.endIndex, by: 6400) {
            let chunk = samples[start..<min(start + 6400, samples.endIndex)]
            let frames = AVAudioFrameCount(chunk.count / 2)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let channel = try #require(buffer.int16ChannelData?[0])
            chunk.withUnsafeBytes { bytes in
                UnsafeMutableRawPointer(channel).copyMemory(from: bytes.baseAddress!, byteCount: chunk.count)
            }
            sink(buffer)
            try await Task.sleep(for: .milliseconds(200))
        }
        let text = try await recognizer.finish()
        print("Volcengine stream: \(text), after \(heard.count) partial results")
        #expect(!text.isEmpty)
        #expect(heard.contains { !$0.text.isEmpty }, "text arrived while the speech was still coming")
    }

    @Test func aWrongKeyIsRefusedAtTheHandshake() async throws {
        let setup = try setup()
        let recognizer = VolcengineBatchRecognizer(
            endpoint: setup.endpoint, apiKey: UUID().uuidString, keywords: [], connect: connect)
        await #expect(throws: VoiceTranscriptionError.unauthorized(nil)) {
            try await recognizer.recognize(setup.recording)
        }
    }
}
