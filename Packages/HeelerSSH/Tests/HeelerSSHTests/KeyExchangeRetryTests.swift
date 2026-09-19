import Foundation
import Testing

@testable import HeelerSSH

/// The pinned libssh2 mis-encodes a hybrid ML-KEM shared secret whose leading
/// byte is zero, so roughly one handshake in 256 fails with
/// LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE against a peer that is doing nothing
/// wrong (#332). `SSHConnection` answers that with one redial, which is sound
/// only because each handshake draws a fresh secret.
///
/// This suite owns the redial's bounds. The other half of the contract, that a
/// failure reached outside key exchange is reported as it happened rather than
/// dialled again, is covered by `SSHDiagnosticsTests.handshakeTimeoutNamesPhase`:
/// its banner timeout records exactly one line.
@Suite("Key exchange redial", .serialized)
struct KeyExchangeRetryTests {
    @Test("a key exchange failure is redialled once and then reported")
    func keyExchangeFailureIsRedialledOnce() async throws {
        // The peer serves exactly as many cut-off connections as the client is
        // allowed to attempt, so the count is asserted from both ends: if the
        // client stopped after one attempt the server is still waiting to
        // accept and `waitForCompletion` fails, and if it attempted a third the
        // connection is refused and the recorded code changes.
        let server = try HandshakeCutoffServer.start(
            cutoffs: SSHConnection.handshakeAttemptLimit)
        let recorder = DiagnosticsRecorder()
        let token = SSHDiagnostics.addSink(recorder.record)
        defer { SSHDiagnostics.removeSink(token) }

        await #expect(throws: SSHError.connectionFailed) {
            _ = try await SSHConnection.connect(
                to: SSHEndpoint(host: "127.0.0.1", port: server.port),
                timeout: .seconds(10))
        }
        try await server.waitForCompletion()

        let lines = recorder.lines(mentioning: server.port)
        #expect(
            lines.filter { $0.contains("LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE") }.count
                == SSHConnection.handshakeAttemptLimit,
            Comment(rawValue: "recorded: \(lines)"))
        #expect(
            lines.filter { $0.hasSuffix("failed in key exchange, redialling") }.count
                == SSHConnection.handshakeAttemptLimit - 1,
            Comment(rawValue: "recorded: \(lines)"))
    }

    @Test("a redial cannot outlive the caller's timeout")
    func redialSharesTheCallerDeadline() async throws {
        let server = try HandshakeCutoffServer.start(
            cutoffs: SSHConnection.handshakeAttemptLimit)
        let started = ContinuousClock.now

        await #expect(throws: (any Error).self) {
            _ = try await SSHConnection.connect(
                to: SSHEndpoint(host: "127.0.0.1", port: server.port),
                timeout: .seconds(2))
        }

        // Two attempts against one budget, not one budget each: a redial that
        // restarted the clock would let a two-second connect run for four.
        #expect(ContinuousClock.now - started < .seconds(3))
        try? await server.waitForCompletion()
    }
}
