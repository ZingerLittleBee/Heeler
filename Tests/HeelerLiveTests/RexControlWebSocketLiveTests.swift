import Foundation
import Testing

@testable import Heeler

/// Explicit opt-in only: the app's WebSocket client against a Rex server that
/// already runs on this Mac, over its local Unix socket. It never runs in the
/// HeelerTests target or in CI, and fails rather than skips when selected
/// without its configuration.
///
/// The first test connects once to `/api/control`, sends a hello for API
/// revision 12, checks the welcome, calls the read-only `server.status`, and
/// closes with 1000. The second does the same through `RexControlLink`, adds
/// `session.attach_all` and `session.list`, keeps the link idle across a few
/// of its own pings, drops the connection, resumes the client on a new one,
/// and closes it with a close frame. They create no session and change
/// nothing on the server. They print counts only, never what the server
/// returns: the welcome carries a reconnect token, the status carries local
/// paths, and sessions carry their labels.
///
/// Give the socket path that `rex server status` prints on its endpoint line
/// to the Simulator's launchd environment, run the suite, then unset it:
///
/// ```sh
/// xcrun simctl spawn <UDID> launchctl setenv HEELER_REX_LIVE_SOCKET "<socket path>"
/// make test-app SCHEME=HeelerLiveTests \
///   SIM_DESTINATION='platform=iOS Simulator,id=<UDID>' \
///   TEST_SELECTOR='HeelerLiveTests/RexControlWebSocketLiveTests'
/// xcrun simctl spawn <UDID> launchctl unsetenv HEELER_REX_LIVE_SOCKET
/// ```
@Suite("Rex control connection over a local socket", .serialized, .timeLimit(.minutes(1)))
struct RexControlWebSocketLiveTests {
    @Test func helloStatusAndCloseOnALocalRexServer() async throws {
        let socketPath = try #require(
            ProcessInfo.processInfo.environment["HEELER_REX_LIVE_SOCKET"].flatMap { $0.isEmpty ? nil : $0 },
            "HEELER_REX_LIVE_SOCKET names no Rex socket")
        let link = try await WebSocketLink.connect(
            over: try UnixDomainSocketChannel(path: socketPath), path: "/api/control",
            subprotocol: "rex.control.v1")

        try await link.send(
            text: #"{"type":"hello","api_revision":12,"api_min_revision":12,"client":{"kind":"other","name":"heeler-tests"}}"#)
        let welcome = try await Self.object(link.receive())
        #expect(welcome["type"] as? String == "welcome")
        #expect(welcome["protocol"] as? String == "rex.control.v1")
        #expect(welcome["api_revision"] as? Int == 12)
        let limits = try #require(welcome["limits"] as? [String: Any])
        #expect((limits["max_message_bytes"] as? Int ?? 0) >= 65536)

        try await link.send(text: #"{"type":"request","id":"status-1","method":"server.status"}"#)
        var response: [String: Any]?
        for _ in 0..<32 {
            let message = try await Self.object(link.receive())
            // Events may come first; only this request's response counts.
            if message["type"] as? String == "response", message["id"] as? String == "status-1" {
                response = message
                break
            }
        }
        let status = try #require(response, "No response to server.status")
        #expect(status["error"] == nil, "server.status failed with code \(Self.errorCode(status) ?? "none")")
        #expect(status["payload"] is [String: Any])

        let answer = await link.close(.normalClosure)
        #expect(answer?.code == .normalClosure, "The close answer was \(String(describing: answer?.code.rawValue))")
        #expect(await !link.isOpen)
    }

    private struct Status: Decodable {
        let session_count: Int?
    }

    private struct Sessions: Decodable {
        struct Entry: Decodable {
            let session_id: String
        }

        let sessions: [Entry]
    }

    @Test func readsTheServerThroughTheControlLinkAndResumes() async throws {
        let socketPath = try #require(
            ProcessInfo.processInfo.environment["HEELER_REX_LIVE_SOCKET"].flatMap { $0.isEmpty ? nil : $0 },
            "HEELER_REX_LIVE_SOCKET names no Rex socket")
        var options = RexControlLink.Options()
        // Pings every second, so idling for a few proves Rex answers them.
        options.keepalive = .init(interval: .seconds(1), pongDeadline: .seconds(2))
        let link = try await RexControlLink.open(over: try UnixDomainSocketChannel(path: socketPath), options: options)
        #expect(RexControlProtocol.apiRevisions.contains(link.apiRevision))
        #expect(!link.resumed)
        #expect(link.maxMessageBytes >= 65536)

        let status = try await link.call("server.status")
        let attached = try await link.call("session.attach_all", payload: ["event_scope": "session"])
        let listed = try await link.call("session.list")
        let sessionCount = try status.result(Status.self).session_count
        let attachedCount = try attached.result(Sessions.self).sessions.count
        let listedCount = try listed.result(Sessions.self).sessions.count
        print("Rex control link: status counts \(sessionCount ?? -1) sessions, attach_all \(attachedCount), list \(listedCount); seq \(attached.seq), \(listed.seq)")
        #expect(attachedCount == listedCount)

        try await Task.sleep(for: .seconds(4))
        let idleEnding = await link.endingReason
        #expect(idleEnding == nil, "The link ended while idle: \(String(describing: idleEnding))")
        _ = try await link.call("server.status")

        await link.disconnect()
        let resumed = try await RexControlLink.open(
            over: try UnixDomainSocketChannel(path: socketPath), resuming: link, options: options)
        print("Rex control link: resumed \(resumed.resumed), same client \(resumed.clientID == link.clientID)")
        #expect(resumed.resumed)
        #expect(resumed.clientID == link.clientID)
        _ = try await resumed.call("session.list")
        await resumed.close()
        let ending = await resumed.endingReason
        #expect(ending == .closedHere)
    }

    private static func object(_ message: WebSocketMessage) throws -> [String: Any] {
        guard case .text(let text) = message else {
            Issue.record("The control connection sent a binary message")
            return [:]
        }
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private static func errorCode(_ response: [String: Any]) -> String? {
        (response["error"] as? [String: Any])?["code"] as? String
    }
}
