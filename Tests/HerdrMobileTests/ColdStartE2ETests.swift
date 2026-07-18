import CryptoKit
import Foundation
import Testing

@testable import HerdrMobile

// Cold start (#6): a stale socket (server stopped) triggers the wake command
// over a real exec channel, then the request retries against the socket. The
// wake command is injected at the environment boundary — a shell script
// standing in for `herdr remote-client-bridge` — because the test host has no
// controllable herdr binary; everything else is the real stack.
@Suite(
    "Cold start e2e",
    .enabled(
        if: LocalSSHTestEnvironment.isAvailable,
        "requires localhost sshd, socat, and an authorized Ed25519 test key"),
    .timeLimit(.minutes(1)))
struct ColdStartE2ETests {
    @Test func wakeStartsServerAndRetriedRequestSucceeds() async throws {
        // Server "stopped": stale socket at the configured path. The wake
        // script brings the fake server online at that path, exactly like
        // the bridge entry point ensures a live socket before returning.
        let stale = try StaleUnixSocket()
        defer { stale.remove() }
        let server = try FakeHerdrServer { request in
            [
                #"{"id":"\#(request.id)","result":{"type":"pong","version":"9.9.9-fake","protocol":16}}"#
            ]
        }
        defer { server.stop() }
        let wake = try WakeScript(commands: [
            "rm -f '\(stale.path)'",
            "ln -s '\(server.socketPath)' '\(stale.path)'",
        ])
        defer { wake.remove() }

        try await withTransport(socketPath: stale.path, wakeCommand: wake.command) { transport in
            let info = try await transport.ping()

            #expect(info == ServerInfo(version: "9.9.9-fake", protocolVersion: 16))
        }
        #expect(wake.invocationCount == 1)
        // Only the post-wake retry reaches the server; the refused first
        // attempt never got that far.
        #expect(server.receivedRequests.map(\.method) == ["ping"])
        #expect(server.connectionCount == 1)
    }

    @Test func ineffectiveWakeSurfacesServerNotRunningWithoutLooping() async throws {
        // Wake runs and exits 0 but brings nothing up (herdr broken on the
        // host): the retry hits the stale socket again and the user gets
        // `.serverNotRunning` — one wake, one retry, no silent loop.
        let stale = try StaleUnixSocket()
        defer { stale.remove() }
        let wake = try WakeScript(commands: ["true"])
        defer { wake.remove() }

        try await withTransport(socketPath: stale.path, wakeCommand: wake.command) { transport in
            await #expect(throws: TransportError.serverNotRunning(path: stale.path)) {
                try await transport.ping()
            }
        }
        #expect(wake.invocationCount == 1)
    }

    @Test func failingWakeCommandSurfacesServerNotRunning() async throws {
        // The wake command itself fails (herdr not on PATH): the user still
        // gets `.serverNotRunning`, not a channel error.
        let stale = try StaleUnixSocket()
        defer { stale.remove() }
        let bogusWake = "/tmp/herdr-no-wake-\(UUID().uuidString.prefix(8))"

        try await withTransport(socketPath: stale.path, wakeCommand: bogusWake) { transport in
            await #expect(throws: TransportError.serverNotRunning(path: stale.path)) {
                try await transport.ping()
            }
        }
    }

    @Test func hungWakeCommandSurfacesTimedOut() async throws {
        // The wake command starts but never exits (hung host): the request
        // must surface .timedOut at the deadline — not hang forever pinning
        // an exec slot — and end the wake channel by explicit close.
        let stale = try StaleUnixSocket()
        defer { stale.remove() }
        let wake = try WakeScript(commands: ["sleep 600"])
        defer { wake.remove() }

        try await withTransport(
            socketPath: stale.path, wakeCommand: wake.command, requestTimeout: .seconds(2)
        ) { transport in
            await #expect(throws: TransportError.timedOut) {
                try await transport.ping()
            }
        }
        #expect(wake.invocationCount == 1)
    }

    @Test func missingSocketDoesNotTriggerWake() async throws {
        // No socket file means herdr is not installed there (or the path is
        // wrong) — waking cannot help, so the wake must not run.
        let missingPath = "/tmp/herdr-missing-\(UUID().uuidString.prefix(8)).sock"
        let wake = try WakeScript(commands: ["true"])
        defer { wake.remove() }

        try await withTransport(socketPath: missingPath, wakeCommand: wake.command) { transport in
            await #expect(throws: TransportError.socketNotFound(path: missingPath)) {
                try await transport.ping()
            }
        }
        #expect(wake.invocationCount == 0)
    }

    /// Connects to localhost for real; the cold-start behavior under test
    /// happens on the first request, not at connect time.
    private func withTransport(
        socketPath: String,
        wakeCommand: String,
        requestTimeout: Duration = .seconds(15),
        body: (SSHTransport) async throws -> Void
    ) async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let transport = try await SSHTransport.connect(
            settings: environment.makeSettings(
                socket: .absolutePath(socketPath),
                wakeCommand: wakeCommand,
                requestTimeout: requestTimeout))
        do {
            try await body(transport)
        } catch {
            try? await transport.close()
            throw error
        }
        try await transport.close()
    }
}

/// A shell script substituted for `herdr remote-client-bridge` at the
/// environment boundary. Records every invocation in a marker file so tests
/// can assert the wake ran exactly as often as the bounded retry allows.
private struct WakeScript {
    let scriptPath: String
    let markerPath: String

    /// The value to inject as the transport's wake command.
    var command: String { "/bin/sh \(scriptPath)" }

    init(commands: [String]) throws {
        let token = UUID().uuidString.prefix(8)
        scriptPath = "/tmp/herdr-wake-\(token).sh"
        markerPath = "/tmp/herdr-wake-runs-\(token)"
        let lines = ["echo run >> '\(markerPath)'"] + commands
        try (lines.joined(separator: "\n") + "\n")
            .write(toFile: scriptPath, atomically: true, encoding: .utf8)
    }

    /// How many times the transport invoked the wake command. The simulator
    /// shares the host filesystem, so the marker written by the remote login
    /// shell is directly readable.
    var invocationCount: Int {
        guard let marker = try? String(contentsOfFile: markerPath, encoding: .utf8) else {
            return 0
        }
        return marker.split(separator: "\n").count
    }

    func remove() {
        unlink(scriptPath)
        unlink(markerPath)
    }
}

// The default wake command is the real herdr invocation from spec #16: the
// remote bridge's entry point ensures the server is running before bridging.
@Suite("Wake command default")
struct WakeCommandDefaultTests {
    @Test func defaultsToHerdrRemoteClientBridge() {
        let settings = SSHTransportSettings(
            host: "example.invalid",
            port: 22,
            username: "u",
            credentials: .ed25519(Curve25519.Signing.PrivateKey()),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false },
            socket: .defaultSession,
            socatPath: "/opt/homebrew/bin/socat")

        #expect(settings.wakeCommand == "herdr remote-client-bridge")
    }
}
