import Foundation
import Testing

@testable import Heeler

/// Explicit opt-in only: the whole Rex dial over real SSH. libssh2 opens a
/// direct-streamlocal channel through a disposable sshd on this Mac to a Rex
/// server that already runs here, and Heeler's control link says hello over
/// it. It never runs in the HeelerTests target or in CI, and fails rather
/// than skips when selected without its configuration.
///
/// The tests call only `server.status`, `session.attach_all` and
/// `session.list`, drop and resume the control client, and close it with a
/// close frame. They create no session and change nothing on the server.
/// They print counts only.
///
/// The sshd allows stream-local forwarding on one port and forbids it on a
/// second. Give its configuration, base64 JSON with `host`, `port`,
/// `refusingPort`, `username`, `deviceKeySeed`, `socketPath` and
/// `missingSocketPath`, to the Simulator's launchd environment, run the suite,
/// then unset it:
///
/// ```sh
/// xcrun simctl spawn <UDID> launchctl setenv HEELER_REX_LIVE_SSH "<base64 JSON>"
/// make test-app SCHEME=HeelerLiveTests \
///   SIM_DESTINATION='platform=iOS Simulator,id=<UDID>' \
///   TEST_SELECTOR='HeelerLiveTests/RexSSHLiveTests'
/// xcrun simctl spawn <UDID> launchctl unsetenv HEELER_REX_LIVE_SSH
/// ```
@Suite("Rex over SSH to a running server", .serialized, .timeLimit(.minutes(2)))
struct RexSSHLiveTests {
    private struct Configuration: Decodable {
        let host: String
        let port: Int
        let refusingPort: Int
        let username: String
        let deviceKeySeed: String
        let socketPath: String
        let missingSocketPath: String
    }

    private struct Sessions: Decodable {
        struct Entry: Decodable {
            let session_id: String
        }

        let sessions: [Entry]
    }

    private struct Status: Decodable {
        let session_count: Int?
    }

    private func configuration() throws -> Configuration {
        let encoded = try #require(
            ProcessInfo.processInfo.environment["HEELER_REX_LIVE_SSH"].flatMap { $0.isEmpty ? nil : $0 },
            "HEELER_REX_LIVE_SSH names no sshd")
        let data = try #require(Data(base64Encoded: encoded), "HEELER_REX_LIVE_SSH is not base64")
        return try JSONDecoder().decode(Configuration.self, from: data)
    }

    private func settings(_ configuration: Configuration, port: Int? = nil, socketPath: String?) throws
        -> SSHTransportSettings
    {
        var settings = SSHTransportSettings(
            host: configuration.host,
            port: port ?? configuration.port,
            username: configuration.username,
            credentials: .ed25519(try RealSSHFixture.deviceKey(seed: configuration.deviceKeySeed)),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            socket: .absolutePath("/nonexistent/herdr.sock"),
            jump: nil)
        settings.serverKind = .rex
        settings.rexSocket = socketPath.flatMap { RexSocket(path: $0) }
        return settings
    }

    private func failure(_ settings: SSHTransportSettings) async -> (any Error)? {
        do {
            let transport = try await SSHTransportConnector().connectRex(settings: settings)
            await transport.close()
            return nil
        } catch {
            return error
        }
    }

    @Test func readsTheServerOverAForwardedSocket() async throws {
        let configuration = try configuration()
        #expect(configuration.socketPath.contains(" "), "The socket path has no space to quote")
        let transport = try await SSHTransportConnector().connectRex(
            settings: try settings(configuration, socketPath: configuration.socketPath))
        let control = await transport.control
        #expect(control.apiRevision == 12)
        #expect(transport.foundSocket == nil)

        let status = try await control.call("server.status").result(Status.self)
        let attached = try await control.call("session.attach_all", payload: ["event_scope": "session"])
            .result(Sessions.self)
        let listed = try await control.call("session.list").result(Sessions.self)
        print(
            "Rex over SSH: status counts \(status.session_count ?? -1) sessions, attach_all \(attached.sessions.count), list \(listed.sessions.count)"
        )
        #expect(attached.sessions.count == listed.sessions.count)

        // A data link's channel reaches the same socket under an attach slot.
        let data = try await transport.openDataChannel()
        try await data.close(timeout: .seconds(2))

        let resumed = try await transport.reconnectControl()
        print("Rex over SSH: resumed \(resumed.resumed), same client \(resumed.clientID == control.clientID)")
        #expect(resumed.resumed)
        #expect(resumed.clientID == control.clientID)
        _ = try await resumed.call("session.list")
        await transport.close()
        let ending = await resumed.endingReason
        #expect(ending == .closedHere)
    }

    /// A Host that stores no socket finds it with the probe over the same SSH
    /// connection, then says hello to it.
    @Test func aHostWithoutASocketLooksItUp() async throws {
        let configuration = try configuration()
        let transport = try await SSHTransportConnector().connectRex(
            settings: try settings(configuration, socketPath: nil))
        #expect(transport.foundSocket?.path == configuration.socketPath)
        #expect(await transport.control.apiRevision == 12)
        await transport.close()
    }

    @Test func aMissingSocketReadsAsNotRunning() async throws {
        let configuration = try configuration()
        let error = await failure(try settings(configuration, socketPath: configuration.missingSocketPath))
        #expect(error as? TransportError == .rexServerNotRunning(socketPath: configuration.missingSocketPath))
    }

    /// The second port's sshd forbids stream-local forwarding while Rex
    /// listens, which the socket check tells from a stopped server.
    @Test func anSSHServerThatForbidsForwardingIsNamed() async throws {
        let configuration = try configuration()
        let error = await failure(
            try settings(configuration, port: configuration.refusingPort, socketPath: configuration.socketPath))
        #expect(error as? TransportError == .rexForwardingRefused(socketPath: configuration.socketPath))
    }
}
