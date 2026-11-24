@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import Heeler

@Suite("Volcengine speech")
struct VolcengineSpeechTests {
    private func endpoint() throws -> VoiceInputEndpoint {
        try #require(VoiceInputEndpoint.preset(.volcengine))
    }

    private func bytes(_ value: Int32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Frames

    @Test func everyClientFrameIsNumberedAndTheLastAudioNegatesItsNumber() {
        let request = VolcengineFrame.request(Data("{}".utf8))
        #expect([UInt8](request) == [0x11, 0x11, 0x10, 0x00] + bytes(1) + bytes(2) + [0x7B, 0x7D])

        var frames = VolcengineAudioFrames()
        let sent = frames.frames(adding: Data(repeating: 7, count: VolcengineAudioFrames.frameSize * 2 + 100))
        #expect(sent.count == 2, "whole 200 ms frames go at once; the rest waits")
        #expect([UInt8](sent[0].prefix(12)) == [0x11, 0x21, 0x00, 0x00] + bytes(2) + bytes(6400))
        #expect([UInt8](sent[1].prefix(8)) == [0x11, 0x21, 0x00, 0x00] + bytes(3))

        let last = frames.lastFrame()
        #expect([UInt8](last.prefix(12)) == [0x11, 0x23, 0x00, 0x00] + bytes(-4) + bytes(100))
        #expect(last.count == 12 + 100)
    }

    @Test func resultsErrorsAndTheAcknowledgementDecode() throws {
        let partial = try VolcengineFrame.message(
            from: VolcengineServerFrame.result("先把", utterances: [("先把", false)], sequence: 2))
        #expect(
            partial
                == .result(
                    VolcengineResult(text: "先把", utterances: [.init(text: "先把", definite: false)]),
                    isLast: false))

        let last = try VolcengineFrame.message(from: VolcengineServerFrame.result("好。", sequence: 9, isLast: true))
        #expect(last == .result(VolcengineResult(text: "好。", utterances: []), isLast: true))

        let acknowledgement = try VolcengineFrame.message(from: VolcengineServerFrame.acknowledgement)
        #expect(acknowledgement == .result(VolcengineResult(text: "", utterances: []), isLast: false))

        let error = try VolcengineFrame.message(
            from: VolcengineServerFrame.error(code: 45_000_001, message: "invalid request"))
        #expect(error == .error(code: 45_000_001, message: "invalid request"))

        #expect(throws: VoiceTranscriptionError.unreadableResponse) {
            try VolcengineFrame.message(from: Data([0x11, 0x90, 0x10]))
        }
        #expect(throws: VoiceTranscriptionError.unreadableResponse, "a gzip answer is not expected") {
            try VolcengineFrame.message(from: Data([0x11, 0x90, 0x11, 0x00, 0, 0, 0, 0]))
        }
    }

    @Test func settledSentencesComeFirstAndTheRestIsStillBeingRevised() {
        let result = VolcengineResult(
            text: "先把分支同步一下。然后 run",
            utterances: [.init(text: "先把分支同步一下。", definite: true), .init(text: "然后 run", definite: false)])
        #expect(result.heard == VoiceHeard(settled: "先把分支同步一下。", revising: "然后 run"))
    }

    // MARK: Request

    @Test func theStreamRequestsSecondPassRecognitionAndCarriesHotwords() throws {
        let body = try json(VolcengineRoute.stream.requestBody(keywords: ["tmux", "Heeler"]))
        let audio = try #require(body["audio"] as? [String: Any])
        #expect(audio["format"] as? String == "pcm")
        #expect(audio["rate"] as? Int == 16_000)
        let request = try #require(body["request"] as? [String: Any])
        #expect(request["model_name"] as? String == "bigmodel")
        #expect(request["enable_nonstream"] as? Bool == true)
        #expect(request["show_utterances"] as? Bool == true)
        #expect(request["enable_ddc"] == nil, "disfluency removal can drop a negation")
        let corpus = try #require(request["corpus"] as? [String: Any])
        let context = try json(Data(try #require(corpus["context"] as? String).utf8))
        #expect(context["hotwords"] as? [[String: String]] == [["word": "tmux"], ["word": "Heeler"]])
    }

    @Test func aFinishedRecordingIsSentAsWAVWithoutHotwordsWhenThereAreNone() throws {
        let body = try json(VolcengineRoute.batch.requestBody(keywords: []))
        #expect((body["audio"] as? [String: Any])?["format"] as? String == "wav")
        let request = try #require(body["request"] as? [String: Any])
        #expect(request["enable_nonstream"] == nil)
        #expect(request["corpus"] == nil)
    }

    @Test func streamingKeepsTheLeadingKeywordsWithinItsBudget() {
        let long = String(repeating: "a", count: 60)
        let words = [long, String(repeating: "b", count: 50), "tmux"]
        #expect(VolcengineRoute.stream.hotwords(from: words) == [long])
        #expect(VolcengineRoute.batch.hotwords(from: words) == words)
        #expect(VolcengineRoute.batch.hotwords(from: Array(repeating: "x", count: 6000)).count == 5000)
    }

    @Test func theHandshakeNamesTheKeyResourceAndRequest() throws {
        let request = try VolcengineConnection.request(.batch, endpoint: endpoint(), apiKey: "volc-key")
        #expect(request.url?.absoluteString == "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "volc-key")
        #expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.seedasr.sauc.duration")
        #expect(UUID(uuidString: request.value(forHTTPHeaderField: "X-Api-Request-Id") ?? "") != nil)
        let stream = try VolcengineConnection.request(.stream, endpoint: endpoint(), apiKey: "volc-key")
        #expect(stream.url?.path() == "/api/v3/sauc/bigmodel_async")
    }

    // MARK: Batch

    @Test func aFinishedRecordingIsSentAtOnceAndTheLastResultIsItsText() async throws {
        let socket = FakeVoiceWebSocket(answering: [
            VolcengineServerFrame.acknowledgement,
            VolcengineServerFrame.result("", sequence: 2),
            VolcengineServerFrame.result(" 运行 make test。 ", sequence: 3, isLast: true),
        ])
        let connector = FakeVoiceWebSocketConnector([socket])
        let recognizer = VolcengineBatchRecognizer(
            endpoint: try endpoint(), apiKey: "volc-key", keywords: ["tmux"], connect: connector.connect)
        let audio = Data(repeating: 1, count: VolcengineAudioFrames.frameSize + 44)

        let text = try await recognizer.recognize(VoiceRecording(audio: audio, duration: 0.2))
        #expect(text == "运行 make test。")
        let sent = socket.sent
        #expect(sent.count == 3, "request, one whole frame, then the rest as the last")
        #expect(sent.first?.prefix(2) == Data([0x11, 0x11]))
        #expect(sent.last?.prefix(2) == Data([0x11, 0x23]))
        #expect(socket.isClosed)
        #expect(connector.requests.first?.url?.lastPathComponent == "bigmodel_nostream")
    }

    @Test func anErrorFrameNamesItsCodeAndEmptyAudioHeardNothing() async throws {
        let failing = FakeVoiceWebSocket(answering: [
            VolcengineServerFrame.error(code: 45_000_001, message: #"{"error":"invalid audio format"}"#)
        ])
        let empty = FakeVoiceWebSocket(answering: [VolcengineServerFrame.error(code: 45_000_002, message: "empty")])
        let connector = FakeVoiceWebSocketConnector([failing, empty])
        let recognizer = VolcengineBatchRecognizer(
            endpoint: try endpoint(), apiKey: "volc-key", keywords: [], connect: connector.connect)
        let recording = VoiceRecording(audio: Data(repeating: 0, count: 100), duration: 1)

        await #expect(throws: VoiceTranscriptionError.failed(code: 45_000_001, message: "invalid audio format")) {
            try await recognizer.recognize(recording)
        }
        await #expect(throws: VoiceTranscriptionError.emptyTranscript) {
            try await recognizer.recognize(recording)
        }
    }

    // MARK: Stream

    @MainActor
    @Test func streamedTextShowsAsItArrivesAndTheLastResultSettlesIt() async throws {
        let socket = FakeVoiceWebSocket(
            answering: [
                VolcengineServerFrame.acknowledgement,
                VolcengineServerFrame.result("先把", utterances: [("先把", false)], sequence: 1),
            ],
            answerLast: .success(
                VolcengineServerFrame.result(
                    "先把分支同步一下。", utterances: [("先把分支同步一下。", true)], sequence: 2, isLast: true)))
        let connector = FakeVoiceWebSocketConnector([socket])
        let recognizer = VolcengineStreamRecognizer(
            endpoint: try endpoint(), apiKey: "volc-key", keywords: [], connect: connector.connect)
        var heard: [VoiceHeard] = []

        let sink = try await recognizer.start { heard.append($0) }
        #expect(connector.requests.first?.url?.lastPathComponent == "bigmodel_async")
        sink(try pcmBuffer(frames: 3200))
        try await waitUntil { heard.last == VoiceHeard(settled: "", revising: "先把") }

        let text = try await recognizer.finish()
        #expect(text == "先把分支同步一下。")
        let sent = socket.sent
        #expect(sent.count == 3, "request, the 200 ms the microphone heard, then the last frame")
        #expect([UInt8](sent[1].prefix(12)) == [0x11, 0x21, 0x00, 0x00] + bytes(2) + bytes(6400))
        #expect([UInt8](sent[2].prefix(8)) == [0x11, 0x23, 0x00, 0x00] + bytes(-3))
        #expect(socket.isClosed)
    }

    @MainActor
    @Test func aStreamThatLosesItsConnectionFailsToFinish() async throws {
        let socket = FakeVoiceWebSocket(
            answering: [VolcengineServerFrame.acknowledgement],
            answerLast: .failure(VoiceTranscriptionError.network("lost")))
        let recognizer = VolcengineStreamRecognizer(
            endpoint: try endpoint(), apiKey: "volc-key", keywords: [],
            connect: FakeVoiceWebSocketConnector([socket]).connect)

        _ = try await recognizer.start { _ in }
        await #expect(throws: VoiceTranscriptionError.network("lost")) {
            try await recognizer.finish()
        }
        #expect(socket.isClosed)
    }

    private func pcmBuffer(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try #require(VoicePCM.format)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        return buffer
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        var budget = PollBudget(.seconds(2))
        while budget.hasTimeLeft {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
            budget.charge()
        }
        #expect(await condition())
    }
}
