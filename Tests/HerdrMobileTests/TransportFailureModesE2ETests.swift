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
        // socat exits with stderr `E connect(...): Connection refused`, and
        // an ineffective wake leaves the configured server stopped.
        let stale = try StaleUnixSocket()
        defer { stale.remove() }

        try await withFailingTransport(
            socketPath: stale.path, wakeCommand: "false"
        ) { transport in
            await #expect(throws: TransportError.serverNotRunning(path: stale.path)) {
                try await transport.ping()
            }
        }
    }

    @Test func absentSocatBinaryMapsToSocatMissing() async throws {
        // Discovery finds nothing: the preferred path does not exist, and PATH
        // is not searched. Restricting the policy is what makes the absence
        // reproducible — this machine does have a socat on PATH, which
        // automatic discovery would (correctly) find.
        let bogusSocat = "/tmp/herdr-no-socat-\(UUID().uuidString.prefix(8))"

        try await withFailingTransport(
            socketPath: "/tmp/herdr-irrelevant.sock", socatPath: bogusSocat,
            socatDiscovery: .configuredPathOnly
        ) { transport in
            await #expect(throws: TransportError.socatMissing(path: bogusSocat)) {
                try await transport.ping()
            }
        }
    }

    @Test func unquotableSocatPathMapsToSocatMissing() async throws {
        // A path the conservative shell-quoting subset refuses is never
        // interpolated into the probe; it simply fails `[ -x ]` like any other
        // dead path, so the outcome stays a classified socatMissing.
        let hostile = "/tmp/herdr-'quote-\(UUID().uuidString.prefix(8))"

        try await withFailingTransport(
            socketPath: "/tmp/herdr-irrelevant.sock", socatPath: hostile,
            socatDiscovery: .configuredPathOnly
        ) { transport in
            await #expect(throws: TransportError.socatMissing(path: hostile)) {
                try await transport.ping()
            }
        }
    }

    /// Connects to localhost for real and hands the transport to `body`;
    /// the failure under test happens on first request, not at connect time.
    private func withFailingTransport(
        socketPath: String,
        socatPath: String? = nil,
        socatDiscovery: SocatDiscovery? = nil,
        wakeCommand: String? = nil,
        body: (SSHTransport) async throws -> Void
    ) async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let transport = try await SSHTransport.connect(
            settings: environment.makeSettings(
                socket: .absolutePath(socketPath), socatPath: socatPath,
                socatDiscovery: socatDiscovery,
                wakeCommand: wakeCommand))
        do {
            try await body(transport)
        } catch {
            try? await transport.close()
            throw error
        }
        try await transport.close()
    }
}
