import Foundation
import Synchronization
import Testing

@testable import Heeler

// The events reconnect state machine (#18) over the real stack: Citadel ->
// localhost sshd -> real socat -> fake herdr. The fake server drops channels
// mid-stream, refuses subscribes, and hangs pings; the session must recover
// on its own with observable status transitions and bounded backoff.
@Suite(
    "Events session e2e",
    .enabled(
        if: LocalSSHTestEnvironment.isAvailable,
        "requires localhost sshd, socat, and an authorized Ed25519 test key"),
    .timeLimit(.minutes(1)))
struct EventsSessionE2ETests {
    @Test func remoteDropReconnectsAutomaticallyAndEventsFlowAgain() async throws {
        // The core #18 scenario: the server drops the channel mid-stream
        // (network blip, herdr restart); events must flow again without user
        // action, over the same SSH connection (channel-level failure only),
        // with the staleness window visible as a .reconnecting transition.
        let subscribeCount = Mutex(0)
        try await withSession { request in
            switch request.method {
            case "ping":
                return [Self.pingResult(request.id)]
            case "events.subscribe":
                let n = subscribeCount.withLock { count in
                    count += 1
                    return count
                }
                if n == 1 {
                    // Ack + one event, then close: the mid-stream drop.
                    return .lines([
                        Self.ack(request.id),
                        #"{"event":"pane_created","data":{"pane_id":"w1:p1"}}"#,
                    ])
                }
                return .streamThenHold([
                    .write(Self.ack(request.id)),
                    .write(#"{"event":"pane_created","data":{"pane_id":"w1:p2"}}"#),
                ])
            default:
                return nil
            }
        } body: { session, server, factory in
            await session.resume()
            var iterator = session.updates.makeAsyncIterator()

            #expect(await iterator.next() == .status(.connected))
            guard case .event(let first) = await iterator.next() else {
                Issue.record("expected the first event")
                return
            }
            #expect(first.data["pane_id"] == .string("w1:p1"))

            guard case .status(.reconnecting(let attempt, let delay, let failure)) =
                await iterator.next()
            else {
                Issue.record("expected a .reconnecting transition after the drop")
                return
            }
            #expect(attempt == 1)
            #expect(delay == .milliseconds(50))
            guard case .channelFailed = failure else {
                Issue.record("expected channelFailed, got \(failure)")
                return
            }

            #expect(await iterator.next() == .status(.connected))
            guard case .event(let second) = await iterator.next() else {
                Issue.record("expected the post-reconnect event")
                return
            }
            #expect(second.data["pane_id"] == .string("w1:p2"))

            // Channel-level failure: the SSH layer was reused, not re-dialed,
            // and the fresh connection path was pinged exactly once.
            #expect(factory.connectCount == 1)
            #expect(
                server.receivedRequests.map(\.method)
                    == ["ping", "events.subscribe", "events.subscribe"])
        }
    }

    @Test func backoffIsBoundedAndChannelRetriesReuseTheSSHLayer() async throws {
        // Four straight subscribe failures: delays must grow exponentially
        // and clamp at the cap, and each retry goes through the one-channel
        // state machine on the same SSH connection.
        let subscribeCount = Mutex(0)
        let reconnect = ReconnectPolicy(
            initialDelay: .milliseconds(20), multiplier: 2, maxDelay: .milliseconds(50))
        try await withSession(reconnect: reconnect) { request in
            switch request.method {
            case "ping":
                return [Self.pingResult(request.id)]
            case "events.subscribe":
                let n = subscribeCount.withLock { count in
                    count += 1
                    return count
                }
                // Close without an ack four times, then accept.
                return n <= 4 ? .lines([]) : .streamThenHold([.write(Self.ack(request.id))])
            default:
                return nil
            }
        } body: { session, _, factory in
            await session.resume()

            var delays: [Duration] = []
            for await update in session.updates {
                if case .status(.reconnecting(let attempt, let delay, _)) = update {
                    #expect(attempt == delays.count + 1)
                    delays.append(delay)
                }
                if update == .status(.connected) { break }
            }

            #expect(
                delays == [
                    .milliseconds(20), .milliseconds(40), .milliseconds(50), .milliseconds(50),
                ])
            #expect(factory.connectCount == 1)
        }
    }

    @Test func deadSSHConnectionIsReplacedOnReconnect() async throws {
        // Not just the channel: the SSH connection itself dies mid-stream.
        // The session must notice the layer that failed and re-establish SSH
        // (fresh dial + ping) before re-subscribing.
        try await withSession { request in
            switch request.method {
            case "ping":
                return [Self.pingResult(request.id)]
            case "events.subscribe":
                return .streamThenHold([.write(Self.ack(request.id))])
            default:
                return nil
            }
        } body: { session, server, factory in
            await session.resume()
            var iterator = session.updates.makeAsyncIterator()
            #expect(await iterator.next() == .status(.connected))
            #expect(await session.transportGeneration == 0)

            // Kill the SSH connection out from under the session, as a
            // network death would.
            try await factory.transports[0].close()

            guard case .status(.reconnecting) = await iterator.next() else {
                Issue.record("expected a .reconnecting transition after SSH death")
                return
            }
            #expect(await iterator.next() == .status(.connected))
            #expect(await session.transportGeneration == 1)

            #expect(factory.connectCount == 2)
            #expect(await !factory.transports[0].isConnected)
            #expect(await factory.transports[1].isConnected)
            // The replacement connection path was pinged before subscribing.
            #expect(
                server.receivedRequests.map(\.method)
                    == ["ping", "events.subscribe", "ping", "events.subscribe"])
        }
    }

    @Test func suspendTearsDownDeliberatelyAndResumeResignalsSnapshot() async throws {
        // iOS suspends sockets in the background: suspend() must tear the
        // channel and the SSH connection down deliberately and stop all
        // reconnect activity; resume() re-establishes and re-emits
        // .connected — the consumer's signal to re-snapshot via agent.list.
        let subscribeCount = Mutex(0)
        try await withSession { request in
            switch request.method {
            case "ping":
                return [Self.pingResult(request.id)]
            case "events.subscribe":
                let n = subscribeCount.withLock { count in
                    count += 1
                    return count
                }
                return .streamThenHold([
                    .write(Self.ack(request.id)),
                    .write(#"{"event":"pane_created","data":{"pane_id":"w1:p\#(n)"}}"#),
                ])
            default:
                return nil
            }
        } body: { session, server, factory in
            await session.resume()
            var iterator = session.updates.makeAsyncIterator()
            #expect(await iterator.next() == .status(.connected))
            guard case .event = await iterator.next() else {
                Issue.record("expected the first event")
                return
            }

            await session.suspend()
            #expect(await iterator.next() == .status(.suspended))
            // Everything is down: channel closed server-side, SSH layer gone.
            #expect(await server.wait(for: { $0.closedConnectionCount == $0.connectionCount }))
            #expect(await !factory.transports[0].isConnected)

            // Suspended means quiet: no reconnect attempts while backgrounded.
            let connections = server.connectionCount
            try await Task.sleep(for: .milliseconds(300))
            #expect(server.connectionCount == connections)

            await session.resume()
            #expect(await iterator.next() == .status(.connected))
            guard case .event(let event) = await iterator.next() else {
                Issue.record("expected an event after resume")
                return
            }
            #expect(event.data["pane_id"] == .string("w1:p2"))
            #expect(factory.connectCount == 2)

            await session.end()
            #expect(await iterator.next() == .status(.ended))
            #expect(await iterator.next() == nil)

            // Terminal and idempotent: nothing revives an ended session.
            await session.resume()
            await session.suspend()
            try await Task.sleep(for: .milliseconds(100))
            #expect(factory.connectCount == 2)
        }
    }

    @Test func keepalivePingsFlowWhileIdleAndAPingTimeoutForcesReconnect() async throws {
        // Citadel exposes no SSH-level keepalive, so the session pings over
        // the RPC path while connected. An answered keepalive proves the
        // idle stream generates liveness traffic; a hung one must be treated
        // as a dead connection: explicit teardown, fresh SSH dial, resubscribe.
        let pingCount = Mutex(0)
        try await withSession(
            keepalive: KeepalivePolicy(interval: .milliseconds(150)),
            requestTimeout: .seconds(1)
        ) { request in
            switch request.method {
            case "ping":
                let n = pingCount.withLock { count in
                    count += 1
                    return count
                }
                // Ping 1 is the connect path, ping 2 the first keepalive;
                // hang the second keepalive to simulate a dead connection.
                return n == 3 ? nil : [Self.pingResult(request.id)]
            case "events.subscribe":
                return .streamThenHold([.write(Self.ack(request.id))])
            default:
                return nil
            }
        } body: { session, server, factory in
            await session.resume()
            var iterator = session.updates.makeAsyncIterator()
            #expect(await iterator.next() == .status(.connected))

            guard case .status(.reconnecting(_, _, let failure)) = await iterator.next() else {
                Issue.record("expected a .reconnecting transition after the hung ping")
                return
            }
            #expect(failure == .timedOut)
            #expect(await iterator.next() == .status(.connected))

            // A keepalive timeout distrusts the whole connection: fresh dial.
            #expect(factory.connectCount == 2)
            // Connect ping, answered keepalive, hung keepalive, reconnect ping.
            #expect(server.receivedRequests.filter { $0.method == "ping" }.count >= 4)
        }
    }

    @Test func keepaliveSkipsPingsWhileEventsProveTheConnectionAlive() async throws {
        // Real traffic already does the keepalive ping's two jobs (liveness
        // proof, NAT-mapping refresh), so a stream actively delivering
        // events must not also pay a ping per interval; once the stream
        // goes quiet, the pings resume.
        try await withSession(
            keepalive: KeepalivePolicy(interval: .milliseconds(300))
        ) { request in
            switch request.method {
            case "ping":
                return [Self.pingResult(request.id)]
            case "events.subscribe":
                var steps: [FakeHerdrServer.Response.Step] = [.write(Self.ack(request.id))]
                for n in 1...10 {
                    steps.append(.pause(.milliseconds(50)))
                    steps.append(
                        .write(#"{"event":"pane_created","data":{"pane_id":"w1:p\#(n)"}}"#))
                }
                return .streamThenHold(steps)
            default:
                return nil
            }
        } body: { session, server, _ in
            await session.resume()
            var iterator = session.updates.makeAsyncIterator()
            #expect(await iterator.next() == .status(.connected))
            for _ in 1...10 {
                guard case .event = await iterator.next() else {
                    Issue.record("expected an event")
                    return
                }
            }
            // ~500ms of continuous events straddled at least one keepalive
            // wakeup; fresh activity suppressed its ping, so the only ping
            // on record is the connect path's.
            #expect(server.receivedRequests.filter { $0.method == "ping" }.count == 1)
            // The stream is quiet now: the next wakeup finds the connection
            // idle and pings again.
            #expect(
                await server.wait { server in
                    server.receivedRequests.filter { $0.method == "ping" }.count >= 2
                })
        }
    }

    @Test func resumeRacingIntoSuspendTeardownWaitsForTeardownToFinish() async throws {
        // Quick background→foreground bounce: resume() lands while
        // suspend()'s teardown is still mid-flight. The session must
        // serialize lifecycle transitions itself — the teardown completes
        // fully (channel ended, run loop exited, transport closed) before
        // the new activation dials; the app layer never has to serialize
        // its own calls. Deterministic interleaving: the transport's
        // close() is gated by the test, so suspend() is provably parked
        // inside its teardown when resume() is issued.
        let closeEntered = AsyncGate()
        let closeRelease = AsyncGate()
        try await withSession(wrap: {
            GatedCloseTransport(inner: $0, closeEntered: closeEntered, closeRelease: closeRelease)
        }) { request in
            switch request.method {
            case "ping":
                return [Self.pingResult(request.id)]
            case "events.subscribe":
                return .streamThenHold([.write(Self.ack(request.id))])
            default:
                return nil
            }
        } body: { session, _, factory in
            await session.resume()
            var iterator = session.updates.makeAsyncIterator()
            #expect(await iterator.next() == .status(.connected))

            let suspending = Task { await session.suspend() }
            await closeEntered.waitUntilOpen()
            let resuming = Task { await session.resume() }
            // The bounce must not jump the queue: no new SSH dial while the
            // teardown is parked at the gated close.
            try await Task.sleep(for: .milliseconds(200))
            #expect(factory.connectCount == 1)

            closeRelease.open()
            await suspending.value
            await resuming.value

            #expect(await iterator.next() == .status(.suspended))
            #expect(await iterator.next() == .status(.connected))
            #expect(factory.connectCount == 2)
            #expect(await !factory.transports[0].isConnected)
            #expect(await factory.transports[1].isConnected)

            // The run loop reference survived the bounce: end() still tears
            // the second transport down — nothing leaks.
            await session.end()
            #expect(await iterator.next() == .status(.ended))
            #expect(await iterator.next() == nil)
            #expect(await !factory.transports[1].isConnected)
        }
    }

    private static func pingResult(_ id: String) -> String {
        #"{"id":"\#(id)","result":{"type":"pong","version":"9.9.9-fake","protocol":17}}"#
    }

    private static func ack(_ id: String) -> String {
        #"{"id":"\#(id)","result":{"type":"subscription_started"}}"#
    }

    /// Connect closure for an EventsSession that counts SSH dials and keeps
    /// every transport it created, so tests can kill or inspect the live
    /// one. `wrap` lets a test decorate the transport the session sees
    /// (e.g. gate its close) while the raw SSHTransport stays inspectable.
    private final class TransportFactory: Sendable {
        private let settings: SSHTransportSettings
        private let wrap: @Sendable (SSHTransport) -> any Transport
        private let created = Mutex<[SSHTransport]>([])

        init(
            settings: SSHTransportSettings,
            wrap: @escaping @Sendable (SSHTransport) -> any Transport = { $0 }
        ) {
            self.settings = settings
            self.wrap = wrap
        }

        var connectCount: Int { created.withLock { $0.count } }
        var transports: [SSHTransport] { created.withLock { $0 } }

        @Sendable func connect() async throws -> any Transport {
            let transport = try await SSHTransport.connect(settings: settings)
            created.withLock { $0.append(transport) }
            return wrap(transport)
        }
    }

    /// One-shot async gate for deterministic interleavings: `open()` lets
    /// every subsequent (or currently parked) `waitUntilOpen()` through.
    private final class AsyncGate: Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        }

        func open() {
            continuation.finish()
        }

        func waitUntilOpen() async {
            for await _ in stream {}
        }
    }

    /// Delegates to a real SSHTransport but parks `close()` on test-held
    /// gates, pinning a session teardown mid-flight deterministically.
    private final class GatedCloseTransport: Transport {
        private let inner: SSHTransport
        private let closeEntered: AsyncGate
        private let closeRelease: AsyncGate

        init(inner: SSHTransport, closeEntered: AsyncGate, closeRelease: AsyncGate) {
            self.inner = inner
            self.closeEntered = closeEntered
            self.closeRelease = closeRelease
        }

        var isConnected: Bool {
            get async { await inner.isConnected }
        }

        func ping() async throws -> ServerInfo {
            try await inner.ping()
        }

        func listAgents() async throws -> [Agent] {
            try await inner.listAgents()
        }

        func sessionSnapshot() async throws -> SessionSnapshot {
            try await inner.sessionSnapshot()
        }

        func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
            try await inner.readPane(params)
        }

        func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws
            -> HerdrEventStream
        {
            try await inner.subscribeToEvents(subscriptions)
        }

        func attachTerminal(_ request: TerminalAttachRequest) async throws
            -> TerminalAttachSession
        {
            try await inner.attachTerminal(request)
        }

        func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
            try await inner.startAgent(request)
        }

        func startAgentInNewWorktree(
            _ request: AgentLaunchRequest, worktree: WorktreeSpec
        ) async throws -> Agent {
            try await inner.startAgentInNewWorktree(request, worktree: worktree)
        }

        func closePane(_ params: PaneTarget) async throws {
            try await inner.closePane(params)
        }

        func renameAgent(_ params: AgentRenameParams) async throws {
            try await inner.renameAgent(params)
        }

        func renameWorkspace(_ params: WorkspaceRenameParams) async throws {
            try await inner.renameWorkspace(params)
        }

        func close() async throws {
            closeEntered.open()
            await closeRelease.waitUntilOpen()
            try await inner.close()
        }
    }

    /// Boots a fake herdr server and an EventsSession dialing localhost over
    /// real SSH, and tears both down afterwards. Fast test backoff by
    /// default; keepalive off unless a test turns it on.
    private func withSession(
        reconnect: ReconnectPolicy = ReconnectPolicy(
            initialDelay: .milliseconds(50), multiplier: 2, maxDelay: .milliseconds(200)),
        keepalive: KeepalivePolicy? = nil,
        requestTimeout: Duration = .seconds(15),
        wrap: @escaping @Sendable (SSHTransport) -> any Transport = { $0 },
        script: @escaping FakeHerdrServer.Script,
        body: (EventsSession, FakeHerdrServer, TransportFactory) async throws -> Void
    ) async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let server = try FakeHerdrServer(script: script)
        let factory = TransportFactory(
            settings: environment.makeSettings(
                socket: .absolutePath(server.socketPath),
                wakeCommand: "false",
                requestTimeout: requestTimeout),
            wrap: wrap)
        let session = EventsSession(
            subscriptions: [.global(.paneCreated)],
            connect: factory.connect,
            reconnectPolicy: reconnect,
            keepalive: keepalive)
        do {
            try await body(session, server, factory)
        } catch {
            await session.end()
            server.stop()
            throw error
        }
        await session.end()
        server.stop()
    }
}
