import Foundation
import Synchronization

@testable import Heeler

/// A WebSocket whose server is the test: it records what the client sends,
/// answers from a queue, and can answer the last audio frame on its own.
final class FakeVoiceWebSocket: VoiceWebSocket {
    private struct State {
        var sent: [Data] = []
        var inbox: [Result<Data, any Error>] = []
        var waiting: CheckedContinuation<Data, any Error>?
        var isClosed = false
    }

    private let state = Mutex(State())
    /// What the server answers once the client's last audio frame arrives.
    private let answerLast: Result<Data, any Error>?

    init(answering inbox: [Data] = [], answerLast: Result<Data, any Error>? = nil) {
        self.answerLast = answerLast
        state.withLock { $0.inbox = inbox.map { .success($0) } }
    }

    var sent: [Data] { state.withLock { $0.sent } }
    var isClosed: Bool { state.withLock { $0.isClosed } }

    /// Queues a message, or hands it to a receive already waiting.
    func deliver(_ message: Result<Data, any Error>) {
        let waiting = state.withLock { state -> CheckedContinuation<Data, any Error>? in
            guard let waiting = state.waiting else {
                state.inbox.append(message)
                return nil
            }
            state.waiting = nil
            return waiting
        }
        waiting?.resume(with: message)
    }

    func send(_ message: Data) async throws {
        let closed = state.withLock { state in
            if !state.isClosed { state.sent.append(message) }
            return state.isClosed
        }
        if closed { throw VoiceTranscriptionError.network("closed") }
        if let answerLast, message.count >= 2, message[message.startIndex + 1] == 0x23 {
            deliver(answerLast)
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> Result<Data, any Error>? in
                if !state.inbox.isEmpty { return state.inbox.removeFirst() }
                if state.isClosed { return .failure(VoiceTranscriptionError.network("closed")) }
                state.waiting = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func close() {
        let waiting = state.withLock { state -> CheckedContinuation<Data, any Error>? in
            state.isClosed = true
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume(throwing: VoiceTranscriptionError.network("closed"))
    }
}

/// Hands out scripted sockets in order and records each handshake.
final class FakeVoiceWebSocketConnector: Sendable {
    private let sockets: Mutex<[FakeVoiceWebSocket]>
    private let handshakes = Mutex<[URLRequest]>([])

    init(_ sockets: [FakeVoiceWebSocket]) {
        self.sockets = Mutex(sockets)
    }

    var requests: [URLRequest] { handshakes.withLock { $0 } }

    func connect(_ request: URLRequest) async throws -> any VoiceWebSocket {
        handshakes.withLock { $0.append(request) }
        guard let socket = sockets.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
            throw VoiceTranscriptionError.network("no socket scripted")
        }
        return socket
    }
}

/// Frames a Volcengine server sends.
enum VolcengineServerFrame {
    static func result(
        _ text: String, utterances: [(String, Bool)] = [], sequence: Int32, isLast: Bool = false
    ) -> Data {
        let body: [String: Any] = [
            "result": [
                "text": text,
                "utterances": utterances.map { ["text": $0.0, "definite": $0.1] },
            ]
        ]
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return frame(type: 0x9, flags: isLast ? 0b0011 : 0b0001, fields: [UInt32(bitPattern: sequence)], payload: json)
    }

    /// The acknowledgement of the request: no sequence, no result.
    static let acknowledgement = frame(type: 0x9, flags: 0, fields: [], payload: Data("{}".utf8))

    static func error(code: UInt32, message: String) -> Data {
        frame(type: 0xF, flags: 0, fields: [code], payload: Data(message.utf8))
    }

    private static func frame(type: UInt8, flags: UInt8, fields: [UInt32], payload: Data) -> Data {
        var data = Data([0x11, type << 4 | flags, 0x10, 0x00])
        for field in fields + [UInt32(payload.count)] {
            withUnsafeBytes(of: field.bigEndian) { data.append(contentsOf: $0) }
        }
        data.append(payload)
        return data
    }
}
