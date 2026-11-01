import Foundation
import Testing

@testable import Heeler

/// The terminal Composer's Stop on a core Host, through `ConsoleStore` and a
/// scripted core under a manual clock (ADR 0035): one `terminal.interrupt`, which
/// presses the Terminal's own stop key, then a read of its foreground. The records
/// and events follow what herdr-core 0.1.13 sends.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreComposerStopTests {
    private let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)

    private static let claude: JSONValue = .object([
        "pid": .number(40), "name": .string("claude"), "argv": .array([.string("claude")]),
        "cwd": .string("/work/app"),
    ])

    private static let shell: JSONValue = .object([
        "pid": .number(7), "name": .string("zsh"), "argv": .array([.string("/bin/zsh")]),
        "cwd": .string("/work/app"),
    ])

    private static func record(
        foreground: JSONValue = claude, state: String = "working", app: String = "claude-code",
        extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        .object(
            [
                "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
                "argv": .array([.string("/bin/zsh")]), "keep": .bool(true), "title": .string(""),
                "cols": .number(80), "rows": .number(24), "pid": .number(7),
                "labels": .object([:]), "foreground": foreground, "reported": .bool(true),
                "status": .object(["state": .string(state), "app": .string(app)]),
            ].merging(extra) { _, new in new })
    }

    /// The Terminal as a `terminal.get` finds it once the program has left.
    private static let recordOfAShell = record(foreground: shell)

    private static func foregroundEvent(sequence: Int, _ foreground: JSONValue) throws -> Data {
        try JSONEncoder().encode(
            JSONValue.object([
                "jsonrpc": .string("2.0"), "method": .string("event"),
                "params": .object([
                    "seq": .number(Double(sequence)), "type": .string("foreground"),
                    "terminal": .string("t1"), "data": foreground,
                ]),
            ]))
    }

    private struct Started {
        let store: ConsoleStore
        let transport: ScriptedCoreTransport
        let clock: ManualClock
        let agent: ConsoleAgent
    }

    private func start(_ terminal: JSONValue = record()) async throws -> Started {
        let transport = ScriptedCoreTransport(
            subscribeResults: [
                .object(["seq": .number(1), "terminals": .array([terminal]), "channel": .number(1)])
            ])
        let defaults = UserDefaults(suiteName: "core-stop-\(UUID().uuidString)") ?? .standard
        let clock = ManualClock()
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in HerdrCoreHostSession(connect: { transport }, keepalive: nil) },
            coreStopClock: BlockedCardClock(
                now: { ContinuousClock.now }, sleep: { try await clock.parkedSleep(for: $0) }),
            coreHostMemory: HerdrCoreHostMemory(defaults: defaults))
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Agent") { !store.agents.isEmpty }
        let agent = try #require(store.agents.first)
        // A detail's Composer is what asks a core Host's platform.
        _ = store.composerSession(for: agent)
        try await waitUntil("the Host's platform") { store.capabilities(for: host.id).composerStop }
        await transport.setTerminalRecords([.success(terminal)])
        return Started(store: store, transport: transport, clock: clock, agent: agent)
    }

    private func waitUntil(
        _ what: String, _ condition: @MainActor () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    /// The Composer's Stop, pressing Esc on this path being a failure of its own.
    private func coreStop(_ started: Started) throws -> AgentComposerInterrupt {
        try #require(
            started.store.terminalInterrupt(for: started.agent) {
                Issue.record("A core Stop pressed Esc itself")
                return .sent
            })
    }

    private func methods(_ transport: ScriptedCoreTransport) async -> [String] {
        await transport.stopCalls.map(\.method)
    }

    // MARK: A detail whose core is gone

    @Test func aDetailsStopSendsNothingOnceAnotherCoreServesTheAddress() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        let pin = started.store.composerSession(for: started.agent).corePin

        await started.transport.setCoreID("c2")
        await started.transport.endLink()
        try await waitUntil("the new core's Agent") {
            started.store.hostCores[host.id] == "c2" && !started.store.agents.isEmpty
        }
        let stop = try #require(
            started.store.terminalInterrupt(for: started.agent, keepingTo: pin) {
                Issue.record("A core Stop pressed Esc itself")
                return .sent
            })

        #expect(await stop.perform() == .failed(HerdrCoreComposerStop.coreGone))
        #expect(await methods(started.transport).isEmpty)
        #expect(await started.transport.mutations.isEmpty)
    }

    // MARK: The steps

    @Test func stopSendsOneInterruptWithTheShortTimeoutThenReadsTheForeground() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }

        #expect(try await coreStop(started).perform() == .sent)

        let calls = await started.transport.stopCalls
        #expect(calls.map(\.method) == ["terminal.interrupt", "terminal.get"])
        #expect(calls.first?.params == .object(["terminal": .string("t1"), "timeout": .number(2)]))
        #expect(calls.last?.params == .object(["terminal": .string("t1")]))
        #expect(await started.transport.mutations == ["terminal.interrupt"])
    }

    /// `stopped` came for Pi, which stayed, and for Codex, which exited, so no
    /// answer is taken for what became of the program.
    @Test(arguments: ["stopped", "exited", "still_working", "unknown"])
    func everyAnswerLeadsToTheRead(outcome: String) async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        await started.transport.setInterruptAnswer(
            .success(.object(["outcome": .string(outcome), "key": .string("ctrl+c")])))

        #expect(try await coreStop(started).perform() == .sent)

        #expect(await methods(started.transport) == ["terminal.interrupt", "terminal.get"])
    }

    /// The core's own timeout passed and its answer has not come: expected, as a
    /// held key or a slow link can do that. Nothing goes out again, and an answer
    /// that comes later changes nothing.
    @Test func anInterruptThatOutlastsItsTimeoutLeadsToTheReadAndIsNeverResent() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        await started.transport.holdInterrupts()
        let interrupt = try coreStop(started)

        let outcome = Task { await interrupt.perform() }
        try await waitUntil("the interrupt") { await methods(started.transport) == ["terminal.interrupt"] }
        await started.clock.untilParked(1)

        started.clock.advance(.seconds(3) - .milliseconds(1))
        await Task.yield()
        #expect(await methods(started.transport) == ["terminal.interrupt"])

        started.clock.advance(.milliseconds(1))
        #expect(await outcome.value == .sent)
        #expect(await methods(started.transport) == ["terminal.interrupt", "terminal.get"])

        await started.transport.releaseInterrupts()
        await started.transport.setTerminalRecords([.success(Self.record())])
        #expect(await methods(started.transport) == ["terminal.interrupt", "terminal.get"])
        #expect(await started.transport.mutations == ["terminal.interrupt"])
    }

    // MARK: Failures

    /// The link went with the interrupt on it: the key may or may not have gone,
    /// and nothing is left to read over.
    @Test func aLinkLostDuringTheInterruptReadsAsOutcomeUnknown() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        await started.transport.setInterruptAnswer(.failure(TransportError.coreMutationOutcomeUnknown))

        let outcome = try await coreStop(started).perform()

        #expect(outcome == .failed(HerdrCoreComposerStop.outcomeUnknown))
        #expect(await methods(started.transport) == ["terminal.interrupt"])
    }

    /// A link that dies without an EOF, as on a network change: the interrupt went
    /// to the writer, and neither it nor the read that follows hears back. Nothing
    /// says the key went.
    @Test func anInterruptAndAReadThatBothGetNoAnswerReadAsOutcomeUnknown() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        await started.transport.holdInterrupts()
        await started.transport.holdTerminalReads()
        let interrupt = try coreStop(started)

        let outcome = Task { await interrupt.perform() }
        await started.clock.untilParked(for: .seconds(3))
        started.clock.advance(.seconds(3))
        try await waitUntil("the read") {
            await methods(started.transport) == ["terminal.interrupt", "terminal.get"]
        }
        await started.clock.untilParked(for: HerdrCoreComposerStop.readTimeout)
        started.clock.advance(HerdrCoreComposerStop.readTimeout)

        #expect(await outcome.value == .failed(HerdrCoreComposerStop.outcomeUnknown))
        #expect(await started.transport.mutations == ["terminal.interrupt"])
        await started.transport.releaseTerminalReads()
        await started.transport.releaseInterrupts()
    }

    /// The deadline's cancel drops an interrupt still queued behind other writes, so
    /// no key was pressed. A read would prove nothing about a key that never went.
    @Test func anInterruptStillQueuedAtItsDeadlineSaysItWasNotSent() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        await started.transport.holdInterrupts(.inTheOutbox)
        let interrupt = try coreStop(started)

        let outcome = Task { await interrupt.perform() }
        await started.clock.untilParked(for: .seconds(3))
        started.clock.advance(.seconds(3))

        #expect(await outcome.value == .failed(HerdrCoreComposerStop.notTakenInTime))
        #expect(await methods(started.transport) == ["terminal.interrupt"])
        await started.transport.releaseInterrupts()
    }

    /// Still waiting for a link, which a cancel cannot end. The call can no longer
    /// write, so Stop says so without waiting for that link.
    @Test func anInterruptStillWaitingForALinkAtItsDeadlineSaysItWasNotSent() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        await started.transport.holdInterrupts(.awaitingALink)
        let interrupt = try coreStop(started)

        let outcome = Task { await interrupt.perform() }
        await started.clock.untilParked(for: .seconds(3))
        started.clock.advance(.seconds(3))
        await started.clock.untilParked(for: HerdrCoreComposerStop.cancelWait)
        started.clock.advance(HerdrCoreComposerStop.cancelWait)

        #expect(await outcome.value == .failed(HerdrCoreComposerStop.notTakenInTime))
        #expect(await methods(started.transport) == ["terminal.interrupt"])
        await started.transport.releaseInterrupts()
    }

    @Test func aRefusedInterruptSaysWhyAndReadsNothing() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        await started.transport.setInterruptAnswer(
            .failure(HerdrAPIError(code: "not_found", message: "terminal removed")))

        let outcome = try await coreStop(started).perform()

        #expect(outcome == .failed("The Host refused Stop: terminal removed"))
        #expect(await methods(started.transport) == ["terminal.interrupt"])
    }

    @Test func anInterruptThatNeverLeftSaysSo() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        await started.transport.setInterruptAnswer(.failure(TransportError.channelFailed(detail: "gone")))

        let outcome = try await coreStop(started).perform()

        #expect(outcome == .failed(HerdrCoreComposerStop.notSent))
        #expect(await methods(started.transport) == ["terminal.interrupt"])
    }

    @Test func aReadWithNoAnswerSaysStopWentAndNotWhatBecameOfTheProgram() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        await started.transport.holdTerminalReads()
        let interrupt = try coreStop(started)

        let outcome = Task { await interrupt.perform() }
        try await waitUntil("the read") {
            await methods(started.transport) == ["terminal.interrupt", "terminal.get"]
        }
        await started.clock.untilParked(for: HerdrCoreComposerStop.readTimeout)
        started.clock.advance(HerdrCoreComposerStop.readTimeout)

        #expect(await outcome.value == .failed(HerdrCoreComposerStop.readFailed))
        await started.transport.releaseTerminalReads()
    }

    /// The core forgot the Terminal while it was stopping: no program runs there.
    @Test func aTerminalTheCoreNoLongerKnowsCountsAsRead() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        await started.transport.setTerminalRecords([
            .failure(HerdrAPIError(code: "not_found", message: "terminal removed"))
        ])

        #expect(try await coreStop(started).perform() == .sent)
    }

    // MARK: What the read shows

    /// Codex exits at the key. The read says so before the next foreground event
    /// does, and the shell left behind gets no Stop.
    @Test func aReadThatFindsAShellEndsTheAgent() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        await started.transport.setTerminalRecords([.success(Self.recordOfAShell)])
        let interrupt = try coreStop(started)

        #expect(await interrupt.perform() == .sent)

        #expect(started.store.agents.isEmpty)
        #expect(started.store.terminalInterrupt(for: started.agent) { .sent } == nil)
    }

    /// Pi keeps running at the key. The read leaves it the Agent.
    @Test func aReadThatFindsTheProgramLeavesTheAgent() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }

        #expect(try await coreStop(started).perform() == .sent)

        #expect(started.store.agents.map(\.agent.paneID) == ["t1"])
        #expect(started.store.terminalInterrupt(for: started.agent) { .sent } != nil)
    }

    /// Nothing orders a reply against an event on the link, so a foreground event
    /// that lands during the read is at least as new as what the read found.
    @Test func aForegroundEventDuringTheReadWinsOverIt() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        await started.transport.holdTerminalReads()
        let interrupt = try coreStop(started)

        let outcome = Task { await interrupt.perform() }
        try await waitUntil("the read") {
            await methods(started.transport) == ["terminal.interrupt", "terminal.get"]
        }
        await started.transport.deliver(try Self.foregroundEvent(sequence: 2, Self.shell))
        try await waitUntil("the event") { started.store.agents.isEmpty }
        await started.transport.releaseTerminalReads()

        #expect(await outcome.value == .sent)
        #expect(started.store.agents.isEmpty)
    }

    // MARK: When it is offered

    @Test func theCapabilityIsOnForACoreHostOnceItsPlatformIsKnown() {
        #expect(HostCapabilities(serverKind: .herdrCore, platform: .posix).composerStop)
        #expect(HostCapabilities(serverKind: .herdrCore, platform: .nativeWindows).composerStop)
        #expect(!HostCapabilities(serverKind: .herdrCore).composerStop)
        #expect(!HostCapabilities(serverKind: .unconfirmed, platform: .posix).composerStop)
        #expect(HostCapabilities(serverKind: .herdrTUI).composerStop)
        #expect(HostCapabilities(serverKind: .herdrTUI, platform: .nativeWindows).composerStop)
    }

    /// A Terminal that has ever reported keeps Esc as its interrupt key after its
    /// Agent exits, so Stop must not outlast the Agent, even for a detail still on it.
    @Test func noStopOnceAShellHoldsTheForeground() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        #expect(started.store.terminalInterrupt(for: started.agent) { .sent } != nil)

        await started.transport.deliver(try Self.foregroundEvent(sequence: 2, Self.shell))
        try await waitUntil("the shell") { started.store.agents.isEmpty }

        #expect(started.store.terminalInterrupt(for: started.agent) { .sent } == nil)
    }

    /// Esc does not stop Grok Build's turns, and Esc is the key a core would press.
    @Test func aGrokBuildAgentKeepsSend() async throws {
        let started = try await start(
            Self.record(
                foreground: .object([
                    "pid": .number(40), "name": .string("grok"), "argv": .array([.string("grok")]),
                    "cwd": .string("/work/app"),
                ]),
                app: "grok-build"))
        defer { started.store.setHosts([]) }
        #expect(started.agent.agent.kind == "grok")
        #expect(started.agent.agent.status == .working)

        let interrupt = started.store.terminalInterrupt(for: started.agent) {
            Issue.record("A Grok Build Stop pressed Esc")
            return .sent
        }

        #expect(interrupt == nil)
        #expect(
            AgentComposerPrimaryControl(status: .working, draft: "", canStop: interrupt != nil) == .send)
        #expect(await started.transport.stopCalls.isEmpty)
    }

    /// The record names the Template's stop key, and the core presses it. Heeler's
    /// request is the same as for any other Terminal.
    @Test func aTemplatesTerminalSendsTheSameInterruptAndNoKeyOfItsOwn() async throws {
        let started = try await start(
            Self.record(
                extra: [
                    "template": .string("night-shift"), "submit": .string("ctrl+s"),
                    "stop": .string("ctrl+g"),
                ]))
        defer { started.store.setHosts([]) }

        #expect(try await coreStop(started).perform() == .sent)

        let calls = await started.transport.stopCalls
        #expect(calls.map(\.method) == ["terminal.interrupt", "terminal.get"])
        #expect(calls.first?.params == .object(["terminal": .string("t1"), "timeout": .number(2)]))
        #expect(await started.transport.mutations == ["terminal.interrupt"])
    }

    // MARK: The wait after it

    /// A program still Working after the core's watch gets the store's window,
    /// which adds up to Esc's, and the notice does not name a key.
    @Test func aProgramStillWorkingIsWhatTheNoticeSays() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        let interrupt = try coreStop(started)
        let windows = SleepRecorder()
        let store = AgentComposerStopStore(sleep: { await windows.record($0) })

        await store.stop(waiting: interrupt.wait, using: interrupt.perform)?.value

        #expect(await windows.durations == [.seconds(1)])
        #expect(store.notice == "Stop went, but the Agent still shows Working.")
        #expect(interrupt.accessibilityHint == AgentComposerInterrupt.coreHint)
    }

    @Test func anUnknownOutcomeIsTheNoticeAndStopWorksAgain() async throws {
        let started = try await start()
        defer { started.store.setHosts([]) }
        await started.transport.setInterruptAnswer(.failure(TransportError.coreMutationOutcomeUnknown))
        let interrupt = try coreStop(started)
        let store = AgentComposerStopStore(sleep: { _ in })

        await store.stop(waiting: interrupt.wait, using: interrupt.perform)?.value

        #expect(store.notice == HerdrCoreComposerStop.outcomeUnknown)
        #expect(!store.isStopping)
        #expect(await methods(started.transport) == ["terminal.interrupt"])
    }
}

/// The same Stop over a real link and a fake socket: what the link does with a
/// mutation is what tells a timeout from a lost link.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreComposerStopLinkTests {
    private let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)

    private static let agent: JSONValue = .object([
        "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
        "argv": .array([.string("claude")]), "keep": .bool(false), "title": .string(""),
        "cols": .number(80), "rows": .number(24), "pid": .number(7),
        "foreground": .object([
            "pid": .number(40), "name": .string("claude"), "argv": .array([.string("claude")]),
            "cwd": .string("/work/app"),
        ]),
        "status": .object(["state": .string("working"), "app": .string("claude-code")]),
        "labels": .object([:]),
    ])

    private func started() async throws -> (ConsoleStore, ScriptedCoreHost, ManualClock, AgentComposerInterrupt) {
        let scripted = ScriptedCoreHost(channel: .core(.init(id: "c1", terminals: [Self.agent])))
        let defaults = UserDefaults(suiteName: "core-stop-link-\(UUID().uuidString)") ?? .standard
        let clock = ManualClock()
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in
                HerdrCoreHostSession(
                    connect: {
                        await scripted.setConnected(true)
                        return scripted.transport()
                    },
                    keepalive: nil)
            },
            coreStopClock: BlockedCardClock(
                now: { ContinuousClock.now }, sleep: { try await clock.parkedSleep(for: $0) }),
            coreHostMemory: HerdrCoreHostMemory(defaults: defaults))
        store.setHosts([host])
        await store.resume()
        for _ in 0..<500 where store.agents.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let agent = try #require(store.agents.first)
        _ = store.composerSession(for: agent)
        for _ in 0..<500 where !store.capabilities(for: host.id).composerStop {
            try await Task.sleep(for: .milliseconds(10))
        }
        let interrupt = try #require(store.terminalInterrupt(for: agent) { .sent })
        return (store, scripted, clock, interrupt)
    }

    @Test func aLinkLostDuringTheInterruptReadsAsOutcomeUnknown() async throws {
        let (store, scripted, _, interrupt) = try await started()
        defer { store.setHosts([]) }

        let outcome = Task { await interrupt.perform() }
        await scripted.waitForMethod("terminal.interrupt")
        await scripted.socket?.deliverEndOfFile()

        #expect(await outcome.value == .failed(HerdrCoreComposerStop.outcomeUnknown))
        #expect(await scripted.interrupts.count == 1)
    }

    /// The deadline abandons the call and leaves the link up for the read. The
    /// core's late answer is dropped, and the key is pressed once.
    @Test func anInterruptPastItsDeadlineKeepsTheLinkForTheRead() async throws {
        let (store, scripted, clock, interrupt) = try await started()
        defer { store.setHosts([]) }

        let outcome = Task { await interrupt.perform() }
        await scripted.waitForMethod("terminal.interrupt")
        await clock.untilParked(1)
        clock.advance(.seconds(3))
        await scripted.waitForMethod("terminal.get")
        await scripted.answerInterrupts(outcome: "unknown")
        await scripted.answerTerminalReads(with: Self.agent)

        #expect(await outcome.value == .sent)
        #expect(await scripted.interrupts.count == 1)
        #expect(await scripted.interrupts.first?["timeout"] == .number(2))
        #expect(await scripted.sockets.count == 1)
    }

    /// The link dies with no EOF, past the deadline: nothing answers either call.
    @Test func aSilentLinkReadsAsOutcomeUnknown() async throws {
        let (store, scripted, clock, interrupt) = try await started()
        defer { store.setHosts([]) }

        let outcome = Task { await interrupt.perform() }
        await scripted.waitForMethod("terminal.interrupt")
        await clock.untilParked(for: .seconds(3))
        clock.advance(.seconds(3))
        await scripted.waitForMethod("terminal.get")
        await clock.untilParked(for: HerdrCoreComposerStop.readTimeout)
        clock.advance(HerdrCoreComposerStop.readTimeout)

        #expect(await outcome.value == .failed(HerdrCoreComposerStop.outcomeUnknown))
        #expect(await scripted.interrupts.count == 1)
    }

    /// The EOF comes after the deadline, while the read is out.
    @Test func aLinkLostPastTheInterruptsDeadlineReadsAsOutcomeUnknown() async throws {
        let (store, scripted, clock, interrupt) = try await started()
        defer { store.setHosts([]) }

        let outcome = Task { await interrupt.perform() }
        await scripted.waitForMethod("terminal.interrupt")
        await clock.untilParked(for: .seconds(3))
        clock.advance(.seconds(3))
        await scripted.waitForMethod("terminal.get")
        await scripted.socket?.deliverEndOfFile()

        #expect(await outcome.value == .failed(HerdrCoreComposerStop.outcomeUnknown))
        #expect(await scripted.interrupts.count == 1)
    }

    /// A writer stuck on the first Stop's bytes leaves the second in the outbox. The
    /// deadline drops it, and only the first reaches the core once writes resume.
    @Test func anInterruptStillInTheOutboxAtItsDeadlineNeverReachesTheCore() async throws {
        let (store, scripted, clock, interrupt) = try await started()
        defer { store.setHosts([]) }
        let socket = try #require(await scripted.socket)
        await socket.holdWrites()

        let first = Task { await interrupt.perform() }
        await socket.waitForHeldWrite()
        let second = Task { await interrupt.perform() }
        try await Task.sleep(for: .milliseconds(50))
        await clock.untilParked(2)
        clock.advance(.seconds(3))

        #expect(await second.value == .failed(HerdrCoreComposerStop.notTakenInTime))
        await socket.releaseWrites()
        await scripted.waitForMethod("terminal.get")
        await scripted.answerTerminalReads(with: Self.agent)
        #expect(await first.value == .sent)
        #expect(await scripted.interrupts.count == 1)
    }

    /// The link ended and the next is slow to establish. Stop gives up on it, and the
    /// key is not pressed late on the link that opens after.
    @Test func anInterruptStillWaitingForALinkNeverReachesTheCore() async throws {
        let (store, scripted, clock, interrupt) = try await started()
        defer { store.setHosts([]) }
        await scripted.holdHellos()
        await scripted.socket?.deliverEndOfFile()
        for _ in 0..<500 where await scripted.sockets.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        let outcome = Task { await interrupt.perform() }
        await clock.untilParked(for: .seconds(3))
        clock.advance(.seconds(3))
        await clock.untilParked(for: HerdrCoreComposerStop.cancelWait)
        clock.advance(HerdrCoreComposerStop.cancelWait)

        #expect(await outcome.value == .failed(HerdrCoreComposerStop.notTakenInTime))
        await scripted.releaseHellos()
        await scripted.waitForMethod("events.subscribe", count: 2)
        #expect(await scripted.interrupts.isEmpty)
    }

    /// A viewer's bytes are Heeler's own keys: Stop writes none on the attach.
    @Test func anAnsweredInterruptWritesNothingElseOnTheLink() async throws {
        let (store, scripted, _, interrupt) = try await started()
        defer { store.setHosts([]) }

        let outcome = Task { await interrupt.perform() }
        await scripted.waitForMethod("terminal.interrupt")
        await scripted.answerInterrupts()
        await scripted.waitForMethod("terminal.get")
        await scripted.answerTerminalReads(with: Self.agent)

        #expect(await outcome.value == .sent)
        let methods = await scripted.methods
        #expect(!methods.contains("terminal.send"))
        #expect(!methods.contains("terminal.keys"))
        #expect(!methods.contains("terminal.attach"))
    }
}
