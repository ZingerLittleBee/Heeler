import CLibSSH2
import Darwin
import Foundation
import Testing

@testable import HeelerSSH

/// The diagnostics line is the only record of *why* a coarse `SSHError` was
/// thrown, so each contract here is about the line, not the error: which
/// phase it names, which libssh2 code, and that an uninstalled sink costs
/// nothing and receives nothing.
@Suite("SSH failure diagnostics", .serialized)
struct SSHDiagnosticsTests {
    @Test("a handshake cut off mid key exchange names the phase and the libssh2 code")
    func handshakeCutoffNamesPhaseAndCode() async throws {
        let server = try HandshakeCutoffServer.start()
        let recorder = DiagnosticsRecorder()
        let token = SSHDiagnostics.addSink(recorder.record)
        defer { SSHDiagnostics.removeSink(token) }

        await #expect(throws: SSHError.connectionFailed) {
            _ = try await SSHConnection.connect(
                to: SSHEndpoint(host: "127.0.0.1", port: server.port),
                timeout: .seconds(5))
        }
        try await server.waitForCompletion()

        let lines = recorder.lines(mentioning: server.port)
        #expect(lines.count == 1)
        #expect(
            lines.first?.hasPrefix(
                "handshake with 127.0.0.1:\(server.port) failed: "
                    + "LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE (\(LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE))")
                == true)
    }

    @Test("a handshake that never receives a banner names the phase that timed out")
    func handshakeTimeoutNamesPhase() async throws {
        let listener = try SilentListener.start()
        defer { listener.stop() }
        let recorder = DiagnosticsRecorder()
        let token = SSHDiagnostics.addSink(recorder.record)
        defer { SSHDiagnostics.removeSink(token) }

        await #expect(throws: SSHError.timedOut) {
            _ = try await SSHConnection.connect(
                to: SSHEndpoint(host: "127.0.0.1", port: listener.port),
                timeout: .milliseconds(500))
        }

        let lines = recorder.lines(mentioning: listener.port)
        #expect(lines.count == 1)
        #expect(
            lines.first?.hasPrefix("handshake with 127.0.0.1:\(listener.port) timed out [") == true,
            Comment(rawValue: "recorded: \(lines)"))
        #expect(lines.first?.contains("last_wait=socket read") == true)

        // Exercise the readiness timer itself, then let its caller overwrite
        // the context as a cleanup/drain would. The failure must already have
        // been recorded before that caller resumes.
        let quietListener = try SilentListener.start()
        defer { quietListener.stop() }
        let budget = Duration.milliseconds(50)
        let context = SSHDiagnosticOperation(
            phase: "readiness on 127.0.0.1:\(quietListener.port)",
            budget: budget)
        await SSHDiagnosticOperation.$current.withValue(context) {
            context.recordWait("socket read")
            // Pump idle polls and candidate retries consume their deadline;
            // they must neither log an operation failure nor consume dedup.
            await #expect(throws: SSHError.timedOut) {
                try await SocketReadiness.wait(
                    descriptor: quietListener.descriptor,
                    directions: .read,
                    until: ContinuousClock.now.advanced(by: budget))
            }
            #expect(recorder.lines(mentioning: quietListener.port).isEmpty)
            await #expect(throws: SSHError.timedOut) {
                do {
                    try await SocketReadiness.wait(
                        descriptor: quietListener.descriptor,
                        directions: .read,
                        until: ContinuousClock.now.advanced(by: budget),
                        onTimeout: context.noteTimeout)
                } catch {
                    #expect(recorder.lines(mentioning: quietListener.port).count == 1)
                    context.step = "cleanup"
                    context.recordResult(0)
                    context.recordWait("cleanup wait")
                    context.noteTimeout()
                    throw error
                }
            }
        }
        let readinessLines = recorder.lines(mentioning: quietListener.port)
        #expect(readinessLines.count == 1)
        #expect(readinessLines.first?.contains("last_wait=socket read") == true)
        #expect(readinessLines.first?.contains("cleanup") == false)
    }

    @Test("a removed sink receives nothing and no line is formatted without one")
    func removedSinkReceivesNothing() async throws {
        let server = try HandshakeCutoffServer.start()
        let recorder = DiagnosticsRecorder()
        let token = SSHDiagnostics.addSink(recorder.record)
        SSHDiagnostics.removeSink(token)
        let formatted = FormatCounter()

        await #expect(throws: SSHError.connectionFailed) {
            _ = try await SSHConnection.connect(
                to: SSHEndpoint(host: "127.0.0.1", port: server.port),
                timeout: .seconds(5))
        }
        try await server.waitForCompletion()
        // Direct check of the laziness contract: the message closure is not
        // evaluated when nothing is listening.
        SSHDiagnostics.note(formatted.count())

        #expect(recorder.lines(mentioning: server.port).isEmpty)
        #expect(formatted.value == 0 || SSHDiagnostics.isEnabled)
    }
}

final class DiagnosticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func record(_ line: String) {
        lock.withLock { stored.append(line) }
    }

    /// Sinks are process-global, so a parallel suite's failure can land here
    /// too. Only lines naming this test's own port count.
    func lines(mentioning port: UInt16) -> [String] {
        lock.withLock { stored.filter { $0.contains("127.0.0.1:\(port)") } }
    }

    func lines(startingWith prefix: String) -> [String] {
        lock.withLock { stored.filter { $0.hasPrefix(prefix) } }
    }
}

private final class FormatCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int { lock.withLock { stored } }

    func count() -> String {
        lock.withLock { stored += 1 }
        return "formatted"
    }
}

/// Listens without ever accepting. The kernel completes the TCP handshake
/// from the backlog, so the client's banner is sent and its wait for the
/// server banner runs until the caller's deadline.
private struct SilentListener {
    let port: UInt16
    let descriptor: Int32

    static func start() throws -> SilentListener {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SilentListenerError.socketFailed }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            Darwin.close(listener)
            throw SilentListenerError.socketFailed
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            Darwin.close(listener)
            throw SilentListenerError.socketFailed
        }
        var localAddress = sockaddr_in()
        var localAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &localAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &localAddressLength)
            }
        }
        guard named == 0 else {
            Darwin.close(listener)
            throw SilentListenerError.socketFailed
        }
        return SilentListener(port: UInt16(bigEndian: localAddress.sin_port), descriptor: listener)
    }

    func stop() {
        Darwin.close(descriptor)
    }
}

private enum SilentListenerError: Error {
    case socketFailed
}
