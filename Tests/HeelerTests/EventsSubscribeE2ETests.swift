import Foundation
import Testing

@testable import Heeler

// The dedicated events.subscribe channel (#4) over the real stack: Citadel ->
// localhost sshd -> real socat -> fake herdr scripting ack-then-event-lines.
// Reconnect/keepalive/background handling is #18, not here.
@Suite(
    "Events subscribe e2e",
    .enabled(
        if: LocalSSHTestEnvironment.isAvailable,
        "requires localhost sshd, socat, and an authorized Ed25519 test key"),
    .timeLimit(.minutes(1)))
struct EventsSubscribeE2ETests {
    private static func ack(_ id: String) -> String {
        #"{"id":"\#(id)","result":{"type":"subscription_started"}}"#
    }

    @Test func ackThenEventLinesArriveCanonicallyAndPromptly() async throws {
        // Wire event lines are snake_case; the consumer must see the
        // canonical dotted kinds. The second event is written 400ms after
        // the first, proving live streaming (no buffering until close).
        try await withTransport { request in
            .streamThenHold([
                .write(Self.ack(request.id)),
                .write(#"{"event":"pane_created","data":{"pane_id":"w1:p1","workspace_id":"w1"}}"#),
                .pause(.milliseconds(400)),
                .write(
                    #"{"event":"pane_agent_status_changed","data":{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"blocked"}}"#
                ),
            ])
        } body: { transport, server in
            let stream = try await transport.subscribeToEvents([
                .global(.paneCreated),
                .pane(.agentStatusChanged, paneID: "w1:p1"),
            ])
            var iterator = stream.events.makeAsyncIterator()

            let first = try await iterator.next()
            #expect(first?.kind == GlobalEventKind.paneCreated.kind)
            #expect(first?.data["pane_id"] == .string("w1:p1"))

            let second = try await iterator.next()
            #expect(second?.kind == PaneEventKind.agentStatusChanged.kind)
            #expect(second?.data["agent_status"] == .string("blocked"))

            // One long-lived connection carried the ack and both events.
            #expect(server.connectionCount == 1)
            await stream.end()
        }
    }

    @Test func subscriptionParamsUseDottedKindsAndPaneIDs() async throws {
        try await withTransport { request in
            .streamThenHold([.write(Self.ack(request.id))])
        } body: { transport, server in
            let stream = try await transport.subscribeToEvents([
                .global(.paneCreated),
                .pane(.agentStatusChanged, paneID: "w1:p1"),
            ])

            #expect(server.receivedRequests.map(\.method) == ["events.subscribe"])
            #expect(
                server.receivedRequests.first?.params
                    == #"{"subscriptions":[{"type":"pane.created"},{"pane_id":"w1:p1","type":"pane.agent_status_changed"}]}"#
            )
            await stream.end()
        }
    }

    @Test func endClosesTheChannelWithoutHangingAndFreesTheHost() async throws {
        // The spike gotcha: a live exec channel ignores task cancellation,
        // so end() must close the channel explicitly (socat exits on stdin
        // EOF) — observed server-side as the connection dying — and a new
        // subscription must be possible afterwards.
        try await withTransport { request in
            .streamThenHold([.write(Self.ack(request.id))])
        } body: { transport, server in
            let stream = try await transport.subscribeToEvents([.global(.paneCreated)])
            await stream.end()

            #expect(await server.wait(for: { $0.closedConnectionCount == 1 }))
            var iterator = stream.events.makeAsyncIterator()
            #expect(try await iterator.next() == nil)

            let second = try await transport.subscribeToEvents([.global(.paneCreated)])
            await second.end()
            #expect(await server.wait(for: { $0.closedConnectionCount == 2 }))
        }
    }

    @Test func unknownKindsAndJunkLinesDoNotKillTheStream() async throws {
        // herdr's API has no stability guarantee: an unknown event kind is
        // surfaced under its wire name, junk lines are dropped, and known
        // events keep flowing.
        try await withTransport { request in
            .streamThenHold([
                .write(Self.ack(request.id)),
                .write(#"{"event":"pane_haunted","data":{"spooky":true}}"#),
                .write("not json at all"),
                .write(#"{"event":"pane_created","data":{"pane_id":"w1:p2"}}"#),
            ])
        } body: { transport, _ in
            let stream = try await transport.subscribeToEvents([.global(.paneCreated)])
            var iterator = stream.events.makeAsyncIterator()

            let first = try await iterator.next()
            #expect(first?.kind.name == "pane_haunted")
            #expect(first?.data["spooky"] == .bool(true))

            let second = try await iterator.next()
            #expect(second?.kind == GlobalEventKind.paneCreated.kind)
            await stream.end()
        }
    }

    @Test func remoteCloseSurfacesAsErrorAndFreesTheHost() async throws {
        // The server writing then closing (network blip, herdr restart) must
        // finish the stream with an error — the #18 reconnect trigger — and
        // leave the Host free for a new subscription.
        try await withTransport { request in
            [
                Self.ack(request.id),
                #"{"event":"pane_created","data":{"pane_id":"w1:p1"}}"#,
            ]
        } body: { transport, _ in
            let stream = try await transport.subscribeToEvents([.global(.paneCreated)])
            var iterator = stream.events.makeAsyncIterator()

            let first = try await iterator.next()
            #expect(first?.kind == GlobalEventKind.paneCreated.kind)
            // The exact detail depends on how the close races the read loop
            // (clean EOF vs Citadel's "Already closed"); the taxonomy case
            // is the contract.
            do {
                _ = try await iterator.next()
                Issue.record("stream should have failed on remote close")
            } catch TransportError.channelFailed {}

            let second = try await transport.subscribeToEvents([.global(.paneCreated)])
            await second.end()
        }
    }

    @Test func subscribeErrorEnvelopeThrowsHerdrAPIError() async throws {
        try await withTransport { request in
            [#"{"id":"\#(request.id)","error":{"code":"invalid_request","message":"nope"}}"#]
        } body: { transport, _ in
            await #expect(throws: HerdrAPIError(code: "invalid_request", message: "nope")) {
                _ = try await transport.subscribeToEvents([.global(.paneCreated)])
            }
        }
    }

    @Test func hungServerSubscribeTimesOutAndClosesTheChannel() async throws {
        // No ack ever comes: the subscribe must fail at the deadline and end
        // its channel by explicit close, never hang.
        try await withTransport(requestTimeout: .seconds(2)) { _ in
            nil
        } body: { transport, server in
            await #expect(throws: TransportError.timedOut) {
                _ = try await transport.subscribeToEvents([.global(.paneCreated)])
            }
            #expect(await server.wait(for: { $0.closedConnectionCount == 1 }))
        }
    }

    @Test func secondSubscribeWhileOneIsLiveIsRefused() async throws {
        // One dedicated events channel per Host, by design (ADR 0002
        // MaxSessions headroom).
        try await withTransport { request in
            .streamThenHold([.write(Self.ack(request.id))])
        } body: { transport, _ in
            let stream = try await transport.subscribeToEvents([.global(.paneCreated)])
            await #expect(throws: TransportError.eventsChannelAlreadyOpen) {
                _ = try await transport.subscribeToEvents([.global(.paneCreated)])
            }
            await stream.end()
        }
    }

    @Test func missingSocketMapsToSocketNotFound() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let missingPath = "/tmp/herdr-missing-\(UUID().uuidString.prefix(8)).sock"
        let transport = try await SSHTransport.connect(
            settings: environment.makeSettings(
                socket: .absolutePath(missingPath), wakeCommand: "false"))
        await #expect(throws: TransportError.socketNotFound(path: missingPath)) {
            _ = try await transport.subscribeToEvents([.global(.paneCreated)])
        }
        try await transport.close()
    }

    @Test func eventsChannelIsExemptFromTheExecSlotQueue() async throws {
        // The queue bounds RPC exec channels at 8 precisely so the events
        // channel can hold its own session slot. With the events channel
        // live, a full queue-width of hanging RPCs must still all reach the
        // server: 9 concurrent connections, not 8.
        try await withTransport(requestTimeout: .seconds(3)) { request in
            switch request.method {
            case "events.subscribe": .streamThenHold([.write(Self.ack(request.id))])
            default: nil
            }
        } body: { transport, server in
            let stream = try await transport.subscribeToEvents([.global(.paneCreated)])

            await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask { _ = try await transport.listAgents() }
                }
                _ = await server.wait(for: { $0.connectionCount == 9 })
                while let result = await group.nextResult() {
                    if case .success = result {
                        Issue.record("hung agent.list unexpectedly succeeded")
                    }
                }
            }
            #expect(server.connectionCount == 9)
            await stream.end()
        }
    }

    /// Boots a fake herdr server plus a real SSH connection to localhost and
    /// tears both down afterwards. The wake command is stubbed to a no-op so
    /// no test path can ever poke the machine's real herdr server.
    private func withTransport(
        requestTimeout: Duration = .seconds(15),
        script: @escaping FakeHerdrServer.Script,
        body: (SSHTransport, FakeHerdrServer) async throws -> Void
    ) async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let server = try FakeHerdrServer(script: script)
        let transport: SSHTransport
        do {
            transport = try await SSHTransport.connect(
                settings: environment.makeSettings(
                    socket: .absolutePath(server.socketPath),
                    wakeCommand: "false",
                    requestTimeout: requestTimeout))
        } catch {
            server.stop()
            throw error
        }
        do {
            try await body(transport, server)
        } catch {
            try? await transport.close()
            server.stop()
            throw error
        }
        try await transport.close()
        server.stop()
    }
}
