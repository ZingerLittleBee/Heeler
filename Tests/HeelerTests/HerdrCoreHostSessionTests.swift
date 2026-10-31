import Foundation
import Testing

@testable import Heeler

/// The session over the real framed transport and link, with the SSH connection
/// and the core scripted and time on a manual clock.
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreHostSessionTests {
    /// Reads the session's updates one at a time, and keeps the ones it passed over.
    private final class Reader: @unchecked Sendable {
        private var iterator: AsyncStream<HerdrCoreHostSessionUpdate>.Iterator

        init(_ session: HerdrCoreHostSession) {
            iterator = session.updates.makeAsyncIterator()
        }

        func next() async -> HerdrCoreHostSessionUpdate? {
            await iterator.next()
        }

        /// The next status.
        func nextStatus() async -> EventsSessionStatus? {
            while let update = await next() {
                if case .status(let status) = update { return status }
            }
            return nil
        }

        /// The next snapshot, passing over anything else.
        func nextSnapshot() async -> (snapshot: HerdrCoreSnapshot, coreID: String)? {
            while let update = await next() {
                if case .snapshot(let snapshot, let coreID) = update { return (snapshot, coreID) }
            }
            return nil
        }
    }

    private let clock = ManualClock()

    private func session(
        on host: ScriptedCoreHost,
        keepalive: KeepalivePolicy? = nil,
        dials: Dials = Dials()
    ) -> HerdrCoreHostSession {
        HerdrCoreHostSession(
            connect: {
                dials.count()
                await host.setConnected(true)
                return host.transport()
            },
            keepalive: keepalive,
            sleep: clock.parkedSleep(for:))
    }

    private final class Dials: @unchecked Sendable {
        private let lock = NSLock()
        private var counted = 0
        var value: Int { lock.withLock { counted } }
        func count() { lock.withLock { counted += 1 } }
    }

    private static func sizeLine(sequence: Int, terminal: String = "t1") -> Data {
        Data(
            #"{"jsonrpc":"2.0","method":"event","params":{"seq":\#(sequence),"type":"size","terminal":"\#(terminal)","data":{"cols":90,"rows":30}}}"#
                .utf8)
    }

    private static func record(_ address: String) -> JSONValue {
        .object(["address": .string(address), "cwd": .string("/work"), "state": .string("live"), "pid": .number(7)])
    }

    @Test func aLinkThatEndsWhileSSHStaysUpReopensOnTheSameConnectionWithAFreshCursorAndSnapshot() async throws {
        let host = ScriptedCoreHost(
            channel: .core(.init(id: "c1", sequence: 40, terminals: [Self.record("t1")])))
        let dials = Dials()
        let session = session(on: host, dials: dials)
        let reader = Reader(session)
        await session.resume()

        let first = try #require(await reader.nextSnapshot())
        #expect(first.snapshot.sequence == 40)
        #expect(first.coreID == "c1")
        let firstSocket = try #require(await host.socket)
        try await host.deliverEvent(Self.sizeLine(sequence: 41))
        #expect(await reader.next() == .event(.size(terminal: "t1", columns: 90, rows: 30)))

        // The core restarted: its sequence starts over, and the same events
        // numbers below the old cursor must still arrive.
        await host.setChannel(.core(.init(id: "c1", sequence: 2, terminals: [Self.record("t2")])))
        await firstSocket.deliverEndOfFile()

        let second = try #require(await reader.nextSnapshot())
        #expect(second.snapshot.sequence == 2)
        #expect(second.snapshot.terminals.map(\.address) == ["t2"])
        try await host.deliverEvent(Self.sizeLine(sequence: 3, terminal: "t2"))
        #expect(await reader.next() == .event(.size(terminal: "t2", columns: 90, rows: 30)))

        #expect(dials.value == 1)
        #expect(await host.log.filter { $0 == "close" }.isEmpty)
        #expect(await host.sockets.count == 2)
        await session.end()
    }

    @Test func aLinkReopeningStaysConnected() async throws {
        let host = ScriptedCoreHost(channel: .core(.init()))
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()
        #expect(await reader.nextStatus() == .connecting)
        #expect(await reader.nextStatus() == .connected)
        _ = try #require(await reader.nextSnapshot())

        let firstSocket = try #require(await host.socket)
        await firstSocket.deliverEndOfFile()

        // Nothing but a snapshot comes next: no status at all.
        let next = await reader.next()
        guard case .snapshot = next else {
            Issue.record("expected a snapshot, got \(String(describing: next))")
            return
        }
        await session.end()
    }

    @Test func aLinkWhoseHeartbeatsStopIsLostUnderTheKeepalivePolicy() async throws {
        let host = ScriptedCoreHost(channel: .core(.init()))
        let dials = Dials()
        let session = session(
            on: host,
            keepalive: KeepalivePolicy(interval: .seconds(30)),
            dials: dials)
        let reader = Reader(session)
        await session.resume()
        _ = try #require(await reader.nextSnapshot())

        // One interval with only a heartbeat stays connected.
        await clock.untilParked(1)
        try await host.deliverEvent(Data(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":9}}"#.utf8))
        while await !session.hasTrafficSinceLastKeepalive { await Task.yield() }
        clock.advance(.seconds(30))
        // Connected's round trip, the environment check's pid, and this one.
        await host.waitForMethod("server.status", count: 3)

        // The next interval passes with nothing on the channel.
        await clock.untilParked(1)
        clock.advance(.seconds(30))
        guard case .reconnecting(_, _, let failure) = await reader.nextStatus() else {
            Issue.record("expected reconnecting")
            await session.end()
            return
        }
        #expect(failure == .timedOut)

        await clock.untilParked(1)
        clock.advance(.seconds(1))
        _ = try #require(await reader.nextSnapshot())
        // A silent link is not trusted: the connection under it is redialled.
        #expect(dials.value == 2)
        await session.end()
    }

    @Test func aRefusedChannelWithTheSocketFilePresentIsPolledForAboutFiveSecondsBeforeNotRunning() async throws {
        let host = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(socketFile: true), channel: .refused)
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()

        #expect(await reader.nextStatus() == .connecting)
        for elapsed in 0..<10 {
            await clock.untilParked(1)
            #expect(await host.log.filter { $0.hasPrefix("open") }.count == elapsed + 1)
            clock.advance(.milliseconds(500))
        }
        guard case .reconnecting(let attempt, let delay, let failure) = await reader.nextStatus() else {
            Issue.record("expected reconnecting")
            await session.end()
            return
        }
        #expect(attempt == 1)
        #expect(delay == .seconds(1))
        #expect(failure == .herdrCoreNotRunning(socketPath: ScriptedCoreHost.socketPath, socketFilePresent: true))
        // The poll retried the socket; only the first try ran the locator.
        #expect(await host.log.filter { $0 == "locator" }.count == 1)
        await session.end()
    }

    @Test func aCoreBackWithinTheHolderWindowNeverReadsNotRunning() async throws {
        let host = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(socketFile: true), channel: .refused)
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()
        #expect(await reader.nextStatus() == .connecting)

        await clock.untilParked(1)
        await host.setChannel(.core(.init(id: "c1", sequence: 1)))
        clock.advance(.milliseconds(500))
        #expect(await reader.nextStatus() == .connected)
        await session.end()
    }

    @Test func aMissingSocketFileReadsNotRunningAtOnceAndRetriesWithBackoff() async throws {
        let host = ScriptedCoreHost(channel: .refused)
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()
        #expect(await reader.nextStatus() == .connecting)

        for (attempt, delay) in [(1, Duration.seconds(1)), (2, .seconds(2)), (3, .seconds(4))] {
            let status = await reader.nextStatus()
            #expect(
                status
                    == .reconnecting(
                        attempt: attempt, delay: delay,
                        failure: .herdrCoreNotRunning(
                            socketPath: ScriptedCoreHost.socketPath, socketFilePresent: false)))
            await clock.untilParked(1)
            // It comes back when the user starts it.
            if attempt == 3 { await host.setChannel(.core(.init())) }
            clock.advance(delay)
        }
        #expect(await reader.nextStatus() == .connected)
        await session.end()
    }

    @Test func updateRequiredIsNeverRetried() async throws {
        let host = ScriptedCoreHost(channel: .answersHello(ScriptedCoreHost.helloReply(features: ["framed"])))
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()
        #expect(await reader.nextStatus() == .connecting)
        let status = await reader.nextStatus()
        #expect(status == .failed(.herdrCoreUpdateRequired(command: "\(ScriptedCoreHost.installedPath) update")))
        // No time passing brings another try.
        clock.advance(.seconds(120))
        await session.end()
        #expect(await reader.nextStatus() == .ended)
        #expect(await host.log.filter { $0.hasPrefix("open") }.count == 1)
    }

    @Test func aMutationDispatchedBeforeTheLinkEndedReportsOutcomeUnknownAndIsNeverReplayed() async throws {
        let host = ScriptedCoreHost(channel: .core(.init()))
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()
        _ = try #require(await reader.nextSnapshot())
        let firstSocket = try #require(await host.socket)

        let mutation = Task {
            try await session.withTransport { transport in
                try await transport.call("terminal.kill", params: .object([:]), isMutation: true)
            }
        }
        await host.waitForMethod("terminal.kill")
        await firstSocket.deliverEndOfFile()

        await #expect(throws: TransportError.coreMutationOutcomeUnknown) {
            _ = try await mutation.value
        }
        _ = try #require(await reader.nextSnapshot())
        // The new link took a new snapshot and nothing else.
        #expect(await host.methods.filter { $0 == "terminal.kill" }.count == 1)
        await session.end()
    }

    @Test func aRecentReadIsPassive() async throws {
        let host = ScriptedCoreHost(channel: .core(.init()))
        let transport = host.transport()
        _ = try await transport.hello()
        let read = try await transport.readTerminal("t1")
        #expect(read.how == "screen")
        let socket = try #require(await host.socket)
        let params = await requestParams("terminal.read", on: socket)
        #expect(params?["lines"] == .number(0))
        #expect(params?["terminal"] == .string("t1"))
        try await transport.close()
    }

    @Test func aRecentReadRefusesAnotherMachinesTerminal() async throws {
        let host = ScriptedCoreHost(channel: .core(.init()))
        let transport = host.transport()
        _ = try await transport.hello()
        await #expect(throws: TransportError.self) {
            _ = try await transport.readTerminal("peer/t1")
        }
        #expect(await host.methods.isEmpty)
        try await transport.close()
    }

    private func requestParams(_ method: String, on socket: FakeCoreSocket) async -> JSONValue? {
        await socket.frames(channel: 0, kind: .data).lazy
            .compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0.payload) }
            .first { $0["method"]?.stringValue == method }?["params"]
    }

    /// The boundary of ADR 0031: however long it keeps trying, it only looks.
    @Test func repeatedReconnectsToAStoppedCoreOnlyRunTheLocatorAndOpenChannels() async throws {
        let host = ScriptedCoreHost(channel: .refused)
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()
        #expect(await reader.nextStatus() == .connecting)
        var delays: [Duration] = []
        for _ in 0..<6 {
            guard case .reconnecting(_, let delay, _) = await reader.nextStatus() else {
                Issue.record("expected reconnecting")
                break
            }
            delays.append(delay)
            await clock.untilParked(1)
            clock.advance(delay)
        }
        await session.end()

        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)])
        let log = await host.log
        #expect(log.allSatisfy { $0 == "locator" || $0 == "open \(ScriptedCoreHost.socketPath)" || $0 == "close" })
        #expect(log.filter { $0 == "locator" }.count >= 6)

        let scripts = await host.scripts
        #expect(!scripts.isEmpty)
        for script in scripts {
            // The one thing a script executes of what it finds is `--version`.
            let executions = script.components(separatedBy: #"$("$1""#).dropFirst()
            #expect(executions.count == 1)
            #expect(executions.allSatisfy { $0.hasPrefix(" --version") })
            // `hc ` appears once, as version text it accepts, never as a command.
            #expect(script.components(separatedBy: "hc ").count == 2)
            #expect(script.contains("'hc '[0-9]*"))
        }
    }

    // MARK: Terminals

    private func untilATerminalWaits(on session: HerdrCoreHostSession) async {
        while await session.terminalTransportWaiterCount == 0 { await Task.yield() }
    }

    @Test func aTerminalAskedForBeforeTheLinkIsUpWaitsAndThenUsesThatLink() async throws {
        let host = ScriptedCoreHost(channel: .core(.init(id: "c1")))
        let session = session(on: host)
        let asked = Task {
            try await session.withTerminalTransport { _, generation in generation }
        }
        await untilATerminalWaits(on: session)
        await session.resume()
        #expect(try await asked.value == 0)
        await session.end()
        #expect(await host.log.filter { $0.hasPrefix("open ") }.count == 1)
    }

    @Test func aTerminalWaitingOnAHostThatStopsGetsWhatStoppedIt() async throws {
        let host = ScriptedCoreHost(
            channel: .answersHello(ScriptedCoreHost.helloReply(errorKind: "unsupported_generation")))
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()
        while let status = await reader.nextStatus() {
            if case .failed = status { break }
        }
        await #expect(
            throws: TransportError.herdrCoreUpdateRequired(
                command: "\(ScriptedCoreHost.installedPath) update")
        ) {
            try await session.withTerminalTransport { _, _ in }
        }
        await session.end()
    }

    @Test func aTerminalThatAskedWhileSuspendedGetsWhatStoppedTheNextActivation() async throws {
        let host = ScriptedCoreHost(
            channel: .answersHello(ScriptedCoreHost.helloReply(errorKind: "unsupported_generation")))
        let session = session(on: host)
        let waiting = Task { try await session.withTerminalTransport { _, _ in } }
        await untilATerminalWaits(on: session)
        await session.resume()
        await #expect(
            throws: TransportError.herdrCoreUpdateRequired(
                command: "\(ScriptedCoreHost.installedPath) update")
        ) {
            try await waiting.value
        }
        await session.end()
    }

    @Test func aLocatorCutShortRetriesInsteadOfStoppingTheHost() async throws {
        let host = ScriptedCoreHost(channel: .core(.init(id: "c1")))
        await host.answerNextLocator(GitExecResult(stdout: Data(), stderr: Data(), exitStatus: 143))
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()
        #expect(await reader.nextStatus() == .connecting)
        guard case .reconnecting(let attempt, let delay, _) = await reader.nextStatus() else {
            Issue.record("expected reconnecting")
            await session.end()
            return
        }
        #expect(attempt == 1)
        await clock.untilParked(1)
        clock.advance(delay)
        #expect(await reader.nextStatus() == .connected)
        await session.end()
    }

    @Test func anUnknownEventKindNeedsNoNewSnapshot() async throws {
        let host = ScriptedCoreHost(channel: .core(.init(id: "c1", sequence: 1)))
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()
        _ = try #require(await reader.nextSnapshot())

        let future = #"{"jsonrpc":"2.0","method":"event","params":{"seq":2,"type":"machine","data":{}}}"#
        let terminal = #"{"jsonrpc":"2.0","method":"event","params":{"seq":3,"type":"future","terminal":"t1","data":{}}}"#
        try await host.deliverEvent(Data(future.utf8))
        try await host.deliverEvent(Data(terminal.utf8))
        // The next event in order proves the unknown ones went by.
        try await host.deliverEvent(Self.sizeLine(sequence: 4))
        #expect(await reader.next() == .event(.size(terminal: "t1", columns: 90, rows: 30)))
        #expect(await host.methods.filter { $0 == "events.subscribe" }.count == 1)
        await session.end()
    }

    @Test func aTerminalWaitingWhenTheSessionSuspendsReadsAsALostConnection() async throws {
        let host = ScriptedCoreHost(channel: .refused)
        let session = session(on: host)
        let reader = Reader(session)
        await session.resume()
        while let status = await reader.nextStatus() {
            if case .reconnecting = status { break }
        }
        let waiting = Task { try await session.withTerminalTransport { _, _ in } }
        await untilATerminalWaits(on: session)
        await session.suspend()
        await #expect(throws: TransportError.cancelled) { try await waiting.value }
        await session.end()
    }

    @Test func aTerminalAskedForAfterTheEndIsCancelled() async throws {
        let host = ScriptedCoreHost(channel: .core(.init(id: "c1")))
        let session = session(on: host)
        await session.resume()
        await session.end()
        await #expect(throws: TransportError.cancelled) {
            try await session.withTerminalTransport { _, _ in }
        }
    }

    @Test func aCancelledTerminalStopsWaiting() async throws {
        let host = ScriptedCoreHost(channel: .refused)
        let session = session(on: host)
        let waiting = Task { try await session.withTerminalTransport { _, _ in } }
        await untilATerminalWaits(on: session)
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        await session.end()
    }
}
