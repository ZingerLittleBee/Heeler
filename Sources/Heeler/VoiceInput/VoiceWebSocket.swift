import Foundation
import Synchronization

/// One open WebSocket, so a streaming service's exchange is tested without
/// a server.
protocol VoiceWebSocket: Sendable {
    func send(_ message: Data) async throws
    /// The next binary message.
    func receive() async throws -> Data
    /// Ends the connection; a receive still waiting then fails.
    func close()
}

/// A WebSocket over an ephemeral URLSession of its own: no cookies, cache,
/// or credential storage. A refused handshake is reported like an HTTP
/// answer, and a redirect is refused rather than followed, as for uploads
/// (ADR 0036).
final class URLSessionVoiceWebSocket: VoiceWebSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    private init(session: URLSession, task: URLSessionWebSocketTask) {
        self.session = session
        self.task = task
    }

    /// The session holds its delegate until it is invalidated.
    deinit { close() }

    /// Returns once the handshake has succeeded.
    static func connect(_ request: URLRequest) async throws -> URLSessionVoiceWebSocket {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let handshake = VoiceWebSocketHandshake()
        let session = URLSession(configuration: configuration, delegate: handshake, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        let socket = URLSessionVoiceWebSocket(session: session, task: task)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    handshake.wait(continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            socket.close()
            throw Self.failure(error)
        }
        return socket
    }

    func send(_ message: Data) async throws {
        do { try await task.send(.data(message)) } catch { throw Self.failure(error) }
    }

    func receive() async throws -> Data {
        let message: URLSessionWebSocketTask.Message
        do { message = try await task.receive() } catch { throw Self.failure(error) }
        switch message {
        case .data(let data): return data
        case .string: throw VoiceTranscriptionError.unreadableResponse
        @unknown default: throw VoiceTranscriptionError.unreadableResponse
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private static func failure(_ error: any Error) -> any Error {
        switch error {
        case let error as VoiceTranscriptionError: error
        case let error as URLError where error.code == .cancelled: CancellationError()
        case let error as URLError where error.code == .timedOut: VoiceTranscriptionError.timedOut
        case let error as URLError: VoiceTranscriptionError.network(error.localizedDescription)
        default: error
        }
    }
}

/// Resumes `connect` once: when the socket opens, or when the handshake
/// fails, with the refusing response's status where there is one.
private final class VoiceWebSocketHandshake: NSObject, URLSessionWebSocketDelegate, Sendable {
    private let continuation = Mutex<CheckedContinuation<Void, any Error>?>(nil)

    func wait(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation.withLock { $0 = continuation }
    }

    private func resume(_ result: Result<Void, any Error>) {
        continuation.withLock { continuation in
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    func urlSession(
        _: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol _: String?
    ) {
        resume(.success(()))
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            resume(.failure(VoiceTranscriptionClient.failure(of: response, body: Data())))
        } else {
            resume(.failure(error ?? URLError(.networkConnectionLost)))
        }
    }

    /// Declining hands back the 3xx response, which `didCompleteWithError`
    /// reports as a refused redirect.
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
