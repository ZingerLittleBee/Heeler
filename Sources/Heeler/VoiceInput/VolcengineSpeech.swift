import Foundation

/// Which Volcengine recognition a recording uses
/// (https://docs.volcengine.com/docs/6561/2687968). Both take the same
/// frames and answer with the whole text so far.
enum VolcengineRoute: Sendable {
    /// `bigmodel_nostream`: a finished recording, accuracy first, with up to
    /// 5000 hotwords.
    case batch
    /// `bigmodel_async`: text as it is heard. `enable_nonstream` has the
    /// batch model hear each sentence again once it ends, and settles it.
    /// Hotwords and context share about 100 tokens.
    case stream

    var path: String {
        switch self {
        case .batch: "bigmodel_nostream"
        case .stream: "bigmodel_async"
        }
    }

    /// A finished recording is WAV; the microphone's samples are raw PCM.
    var audioFormat: String {
        switch self {
        case .batch: "wav"
        case .stream: "pcm"
        }
    }

    /// The leading Keywords the route can take. The service accepts a
    /// longer list without complaint, but its terms then stop helping
    /// (tried 2026-11-24). Streaming's limit is in tokens; counting
    /// characters, which these terms rarely have fewer of, stays under it.
    func hotwords(from keywords: [String]) -> [String] {
        switch self {
        case .batch:
            return Array(keywords.prefix(5000))
        case .stream:
            var budget = 100
            return Array(
                keywords.prefix { word in
                    guard word.count <= budget else { return false }
                    budget -= word.count
                    return true
                })
        }
    }

    /// The first frame's JSON. Disfluency removal (`enable_ddc`) stays off:
    /// it may drop a negation from an instruction.
    func requestBody(keywords: [String]) throws -> Data {
        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "show_utterances": true,
            "result_type": "full",
        ]
        if self == .stream { request["enable_nonstream"] = true }
        let hotwords = hotwords(from: keywords)
        if !hotwords.isEmpty {
            let context = try JSONSerialization.data(
                withJSONObject: ["hotwords": hotwords.map { ["word": $0] }], options: [.sortedKeys])
            request["corpus"] = ["context": String(decoding: context, as: UTF8.self)]
        }
        let body: [String: Any] = [
            "audio": ["format": audioFormat, "codec": "raw", "rate": 16_000, "bits": 16, "channel": 1],
            "request": request,
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

/// Numbers audio into frames of 200 ms, the size the docs recommend, and
/// sends what is left over as the last frame.
struct VolcengineAudioFrames {
    /// 200 ms of 16 kHz 16-bit mono.
    static let frameSize = 6400
    /// The request took number 1.
    private var sequence: Int32 = 1
    private var pending = Data()

    /// Frames ready to send once `audio` is added.
    mutating func frames(adding audio: Data) -> [Data] {
        pending.append(audio)
        var frames: [Data] = []
        while pending.count >= Self.frameSize {
            sequence += 1
            frames.append(VolcengineFrame.audio(pending.prefix(Self.frameSize), sequence: sequence, isLast: false))
            pending = Data(pending.dropFirst(Self.frameSize))
        }
        return frames
    }

    /// The rest of the audio, possibly none, marked last.
    mutating func lastFrame() -> Data {
        sequence += 1
        defer { pending = Data() }
        return VolcengineFrame.audio(pending, sequence: sequence, isLast: true)
    }
}

/// Opening a recognition and reading its results, shared by both routes.
enum VolcengineConnection {
    /// Connects with the endpoint's key and resource, then sends the request.
    static func open(
        _ route: VolcengineRoute, endpoint: VoiceInputEndpoint, apiKey: String, keywords: [String],
        connect: @Sendable (URLRequest) async throws -> any VoiceWebSocket
    ) async throws -> any VoiceWebSocket {
        let socket = try await connect(try request(route, endpoint: endpoint, apiKey: apiKey))
        do {
            try await socket.send(VolcengineFrame.request(try route.requestBody(keywords: keywords)))
        } catch {
            socket.close()
            throw error
        }
        return socket
    }

    /// The handshake. The key is the console's API Key; without a request
    /// ID the service refuses the handshake.
    static func request(
        _ route: VolcengineRoute, endpoint: VoiceInputEndpoint, apiKey: String
    ) throws -> URLRequest {
        var components = URLComponents(
            url: endpoint.baseURL.appending(path: route.path), resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        guard let url = components?.url else { throw VoiceTranscriptionError.unreadableResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(endpoint.model, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        return request
    }

    /// Reads results until the last, passing each earlier one on.
    static func lastResult(
        on socket: any VoiceWebSocket,
        onResult: @Sendable (VolcengineResult) async -> Void = { _ in }
    ) async throws -> VolcengineResult {
        while true {
            switch try VolcengineFrame.message(from: try await socket.receive()) {
            case .result(let result, let isLast):
                if isLast { return result }
                await onResult(result)
            case .error(let code, let message):
                throw failure(code: code, message: message)
            }
        }
    }

    static func failure(code: Int, message: String) -> VoiceTranscriptionError {
        // 45000002: the audio was empty.
        if code == 45_000_002 { return .emptyTranscript }
        let detail = VoiceTranscriptionClient.errorMessage(in: Data(message.utf8))
            ?? String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        return .failed(code: code, message: detail.isEmpty ? nil : detail)
    }

    /// `operation`, given at most `limit`. Past it, or once the task is
    /// cancelled, the socket is closed, which ends a receive still waiting:
    /// a receive does not answer cancellation on its own.
    static func within<T: Sendable>(
        _ limit: Duration, closing socket: any VoiceWebSocket,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: T?.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: limit)
                    return nil
                }
                defer { group.cancelAll() }
                guard case .some(.some(let value)) = try await group.next() else {
                    socket.close()
                    throw VoiceTranscriptionError.timedOut
                }
                return value
            }
        } onCancel: {
            socket.close()
        }
    }

    static func transcript(_ result: VolcengineResult) throws -> String {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceTranscriptionError.emptyTranscript }
        return text
    }
}

/// A finished recording sent to `bigmodel_nostream` all at once; the
/// service does not need it paced like speech.
struct VolcengineBatchRecognizer: VoiceBatchRecognizer {
    /// Sending and hearing back, like an upload's limit.
    static let limit: Duration = .seconds(90)

    let endpoint: VoiceInputEndpoint
    let apiKey: String
    let keywords: [String]
    let connect: @Sendable (URLRequest) async throws -> any VoiceWebSocket

    func recognize(_ recording: VoiceRecording) async throws -> String {
        let socket = try await VolcengineConnection.open(
            .batch, endpoint: endpoint, apiKey: apiKey, keywords: keywords, connect: connect)
        defer { socket.close() }
        let audio = recording.audio
        let result = try await VolcengineConnection.within(Self.limit, closing: socket) {
            var frames = VolcengineAudioFrames()
            for frame in frames.frames(adding: audio) { try await socket.send(frame) }
            try await socket.send(frames.lastFrame())
            return try await VolcengineConnection.lastResult(on: socket)
        }
        return try VolcengineConnection.transcript(result)
    }
}

/// Speech sent to `bigmodel_async` as the microphone hears it, with each
/// result shown as it arrives. If the connection fails, the recording goes
/// on, and the session sends the whole of it to the batch route instead.
@MainActor
final class VolcengineStreamRecognizer: VoiceStreamRecognizer {
    /// After the last audio, the last result usually comes within half a
    /// second.
    static let settleLimit: Duration = .seconds(10)

    private let endpoint: VoiceInputEndpoint
    private let apiKey: String
    private let keywords: [String]
    private let connect: @Sendable (URLRequest) async throws -> any VoiceWebSocket
    private var socket: (any VoiceWebSocket)?
    private var audio: AsyncStream<Data>.Continuation?
    private var sending: Task<Void, any Error>?
    private var receiving: Task<VolcengineResult, any Error>?

    init(
        endpoint: VoiceInputEndpoint, apiKey: String, keywords: [String],
        connect: @escaping @Sendable (URLRequest) async throws -> any VoiceWebSocket
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.keywords = keywords
        self.connect = connect
    }

    /// Recording starts once the service has accepted the request, about
    /// 150 ms after the tap.
    func start(onText: @escaping @MainActor (VoiceHeard) -> Void) async throws -> VoiceAudioSink {
        let socket = try await VolcengineConnection.open(
            .stream, endpoint: endpoint, apiKey: apiKey, keywords: keywords, connect: connect)
        self.socket = socket
        receiving = Task.detached {
            try await VolcengineConnection.lastResult(on: socket) { result in
                await onText(result.heard)
            }
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        audio = continuation
        sending = Task.detached {
            var frames = VolcengineAudioFrames()
            for await samples in stream {
                for frame in frames.frames(adding: samples) { try await socket.send(frame) }
            }
            try await socket.send(frames.lastFrame())
        }
        return { buffer in
            if let samples = VoicePCM.data(of: buffer) { continuation.yield(samples) }
        }
    }

    func finish() async throws -> String {
        audio?.finish()
        audio = nil
        guard let socket, let sending, let receiving else { return "" }
        defer { cancel() }
        let result = try await VolcengineConnection.within(Self.settleLimit, closing: socket) {
            try await sending.value
            return try await receiving.value
        }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        audio?.finish()
        audio = nil
        sending?.cancel()
        sending = nil
        receiving?.cancel()
        receiving = nil
        socket?.close()
        socket = nil
    }
}
