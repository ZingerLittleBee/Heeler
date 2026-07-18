import Foundation
import Testing

@testable import HerdrMobile

// Environmental failure modes reproduced physically over the real stack:
// real sshd, real login shell, real socat (or its real absence). Each must
// map to its distinct taxonomy case — the same observable shapes the #3
// spike verified against herdr 0.7.4.
@Suite(
    "Transport failure modes e2e",
    .enabled(
        if: LocalSSHTestEnvironment.isAvailable,
        "requires localhost sshd, socat, and an authorized Ed25519 test key"))
struct TransportFailureModesE2ETests {
    @Test func missingSocketPathMapsToSocketNotFound() async throws {
        // socat exits with stderr `E connect(...): No such file or directory`.
        let missingPath = "/tmp/herdr-missing-\(UUID().uuidString.prefix(8)).sock"

        try await withFailingTransport(socketPath: missingPath) { transport in
            await #expect(throws: TransportError.socketNotFound(path: missingPath)) {
                try await transport.ping()
            }
        }
    }

    @Test func staleSocketMapsToServerNotRunning() async throws {
        // socat exits with stderr `E connect(...): Connection refused`.
        let stale = try StaleUnixSocket()
        defer { stale.remove() }

        try await withFailingTransport(socketPath: stale.path) { transport in
            await #expect(throws: TransportError.serverNotRunning(path: stale.path)) {
                try await transport.ping()
            }
        }
    }

    @Test func absentSocatBinaryMapsToSocatMissing() async throws {
        // The login shell cannot launch socat; its stderr names the missing
        // path (fish: "Unknown command", bash/zsh: "No such file or
        // directory") and the channel fails.
        let bogusSocat = "/tmp/herdr-no-socat-\(UUID().uuidString.prefix(8))"

        try await withFailingTransport(
            socketPath: "/tmp/herdr-irrelevant.sock", socatPath: bogusSocat
        ) { transport in
            await #expect(throws: TransportError.socatMissing(path: bogusSocat)) {
                try await transport.ping()
            }
        }
    }

    /// Connects to localhost for real and hands the transport to `body`;
    /// the failure under test happens on first request, not at connect time.
    private func withFailingTransport(
        socketPath: String,
        socatPath: String? = nil,
        body: (SSHTransport) async throws -> Void
    ) async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let transport = try await SSHTransport.connect(
            settings: SSHTransportSettings(
                host: environment.host,
                port: environment.port,
                username: environment.username,
                privateKey: environment.privateKey,
                socketPath: socketPath,
                socatPath: socatPath ?? environment.socatPath))
        do {
            try await body(transport)
        } catch {
            try? await transport.close()
            throw error
        }
        try await transport.close()
    }
}
