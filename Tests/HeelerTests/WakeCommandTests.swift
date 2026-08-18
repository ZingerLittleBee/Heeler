import CryptoKit
import Foundation
import Testing

@testable import Heeler

// The default wake command is the real herdr invocation from spec #16: the
// remote bridge's entry point ensures the server is running before bridging.
@Suite("Wake command")
struct WakeCommandTests {
    @Test func defaultsToHerdrRemoteClientBridge() {
        let settings = SSHTransportSettings(
            host: "example.invalid",
            port: 22,
            username: "u",
            credentials: .ed25519(Curve25519.Signing.PrivateKey()),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false },
            socket: .defaultSession)

        #expect(settings.wakeCommand == "herdr remote-client-bridge")
    }

    @Test func scopesNamedSessionWakeCommandToSessionState() throws {
        let command = try HeelerSSHTransport.wakeExecCommand(
            wakeCommand: "herdr remote-client-bridge",
            socketPath: "/home/u/.config/herdr/sessions/testloop/herdr.sock",
            socketLocation: .namedSession("testloop"))

        #expect(
            command == "LC_ALL=C /bin/sh -c 'export HERDR_SOCKET_PATH=\"$1\"; "
                + "export HERDR_SESSION=\"$2\"; PATH=\"/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:$PATH\" LC_ALL=C herdr remote-client-bridge < /dev/null' wake "
                + "'/home/u/.config/herdr/sessions/testloop/herdr.sock' testloop")
    }

    @Test func defaultSessionWakeCommandDoesNotOverrideSessionState() throws {
        let command = try HeelerSSHTransport.wakeExecCommand(
            wakeCommand: "/opt/herdr-wake --foreground",
            socketPath: "/home/u/.config/herdr/herdr.sock",
            socketLocation: .defaultSession)

        #expect(
            command == "LC_ALL=C /bin/sh -c 'export HERDR_SOCKET_PATH=\"$1\"; "
                + "PATH=\"/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:$PATH\" LC_ALL=C /opt/herdr-wake --foreground < /dev/null' wake "
                + "'/home/u/.config/herdr/herdr.sock'")
    }

    @Test func absolutePathWakeCommandDoesNotOverrideSessionState() throws {
        let command = try HeelerSSHTransport.wakeExecCommand(
            wakeCommand: "/opt/herdr-wake --foreground",
            socketPath: "/home/u/My Config/herdr.sock",
            socketLocation: .absolutePath("/home/u/My Config/herdr.sock"))

        #expect(
            command == "LC_ALL=C /bin/sh -c 'export HERDR_SOCKET_PATH=\"$1\"; "
                + "PATH=\"/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:$PATH\" LC_ALL=C /opt/herdr-wake --foreground < /dev/null' wake "
                + "'/home/u/My Config/herdr.sock'")
    }

    @Test func refusesInvalidNamedSession() {
        #expect(throws: TransportError.self) {
            _ = try HeelerSSHTransport.wakeExecCommand(
                wakeCommand: "herdr remote-client-bridge",
                socketPath: "/home/u/.config/herdr/sessions/work session/herdr.sock",
                socketLocation: .namedSession("work session"))
        }
    }

    @Test func refusesUnquotableSocketPath() {
        #expect(throws: TransportError.self) {
            _ = try HeelerSSHTransport.wakeExecCommand(
                wakeCommand: "herdr remote-client-bridge",
                socketPath: "/tmp/it's-a.sock",
                socketLocation: .absolutePath("/tmp/it's-a.sock"))
        }
    }
}

// Connect failures that need no live sshd.
@Suite("SSH connect failure taxonomy")
struct SSHConnectFailureTests {
    @Test func unreachableHostMapsToSSHUnreachable() async throws {
        // Nothing listens on port 1 (privileged, unused): connection refused.
        let settings = SSHTransportSettings(
            host: "127.0.0.1",
            port: 1,
            username: "nobody",
            credentials: .password("irrelevant"),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            socket: .defaultSession)

        do {
            let transport = try await HeelerSSHTransport.connect(settings: settings)
            try await transport.close()
            Issue.record("connect succeeded against a dead port")
        } catch let error as TransportError {
            guard case .sshUnreachable = error else {
                Issue.record("expected sshUnreachable, got \(error)")
                return
            }
        }
    }
}
