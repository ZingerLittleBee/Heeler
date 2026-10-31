import Foundation
import Testing

@testable import Heeler

/// Composer Send on a core Host (ADR 0035), from the Composer down: the real
/// Console, Attach store, Host session and link, with the core scripted and time
/// on a manual clock. What is asserted is what reaches the core.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreComposerSendTests {
    private static let paste = "\u{1B}[200~hello\u{1B}[201~"
    private static let enter = "\r"
    private static let ctrlC = "\u{3}"
    private static let bracketedPasteOn = "\u{1B}[?2004h"
    private static let kittyAllKeys = "\u{1B}[>8u"

    private static func foreground(pid: Int = 40, argv: [String] = ["claude"]) -> JSONValue {
        .object([
            "pid": .number(Double(pid)), "name": .string(argv.first ?? ""),
            "argv": .array(argv.map(JSONValue.string)), "cwd": .string("/work/app"),
        ])
    }

    private static func record(
        foreground: JSONValue? = Self.foreground(), status: String = "idle", submit: String? = nil,
        argv: [String] = ["claude"]
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array(argv.map(JSONValue.string)), "keep": .bool(false), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(7),
            "status": .object(["state": .string(status), "app": .string("claude-code")]),
            "labels": .object([:]),
        ]
        fields["foreground"] = foreground
        fields["submit"] = submit.map(JSONValue.string)
        return .object(fields)
    }

    private final class SessionBox: @unchecked Sendable {
        var session: HerdrCoreHostSession?
    }

    @MainActor
    private struct Fixture {
        let scripted: ScriptedCoreHost
        let console: ConsoleStore
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)
        let clock = ManualClock()
        let composer: AgentComposerStore
        let attach: AgentAttachStore
        private let box: SessionBox

        init(terminal: JSONValue = HerdrCoreComposerSendTests.record(), bindsAttach: Bool = true) async throws {
            let scripted = ScriptedCoreHost(channel: .core(.init(id: "c1", terminals: [terminal])))
            self.scripted = scripted
            let box = SessionBox()
            self.box = box
            let clock = clock
            let console = ConsoleStore(
                makeSession: { _, subscriptions in
                    EventsSession(
                        subscriptions: subscriptions,
                        connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                        keepalive: nil)
                },
                makeCoreSession: { _ in
                    let session = HerdrCoreHostSession(
                        connect: {
                            await scripted.setConnected(true)
                            return scripted.transport()
                        },
                        keepalive: nil)
                    box.session = session
                    return session
                },
                coreHostMemory: HerdrCoreHostMemory(
                    defaults: UserDefaults(suiteName: "core-send-\(UUID().uuidString)") ?? .standard),
                coreSendClock: BlockedCardClock(now: clock.clock.now, sleep: clock.parkedSleep(for:)))
            self.console = console
            console.setHosts([host])
            await console.resume()
            try await until("the Agent") { [console] in !console.agents.isEmpty }
            let agent = try #require(console.agents.first)
            composer = console.composerStore(for: agent)
            composer.open()
            attach = AgentAttachStore(
                target: agent.agent.paneID, paneTitle: "", transportGeneration: nil, isOnStage: { true },
                runTerminal: console.terminalRunner(for: host.id), closePane: {})
            if bindsAttach { composer.bindCoreAttach(attach) }
        }

        func finish() async {
            await attach.leave().value
            console.setHosts([])
        }

        /// A round trip on the link, so what it was given before has been heard.
        func settle() async throws {
            let session = try #require(box.session)
            _ = try await session.withTransport { try await $0.serverStatus() }
        }

        /// The Attach, once the core answered it and its output set `modes`.
        @discardableResult
        func live(
            modes: String = HerdrCoreComposerSendTests.bracketedPasteOn
        ) async throws -> (channel: UInt32, socket: FakeCoreSocket) {
            attach.viewDidResize(cols: 80, rows: 24)
            await scripted.waitForMethod("terminal.attach")
            let opened = try #require(await scripted.attaches.last)
            try await opened.socket.deliver(
                HerdrCoreFrame(channel: opened.channel, kind: .data, payload: Data((modes + "x").utf8)))
            try await until("the Attach's output") { [attach] in attach.input.readySession != nil }
            return (opened.channel, opened.socket)
        }

        /// Starts a Send and returns once its paste has reached the core.
        func sendPastingHello(
            on attached: (channel: UInt32, socket: FakeCoreSocket), writtenBefore: Int = 0
        ) async -> Task<AgentComposerStore.SendResult, Never> {
            composer.replaceDraft(with: "hello")
            let composer = composer
            let sending = Task { await composer.send() }
            await attached.socket.waitForData(channel: attached.channel, count: writtenBefore + 1)
            return sending
        }

        /// Takes the sample delay's 550 ms, with nothing else having happened.
        func passSampleDelay() async {
            await clock.untilParked(for: HerdrCoreComposerSend.sampleDelay)
            clock.advance(HerdrCoreComposerSend.sampleDelay)
        }

        func deliverForeground(_ data: JSONValue, sequence: Int = 101) async throws {
            try await deliverEvent("foreground", data: data, sequence: sequence)
        }

        func deliverEvent(_ type: String, data: JSONValue, sequence: Int = 101) async throws {
            let line = try JSONEncoder().encode(
                JSONValue.object([
                    "jsonrpc": .string("2.0"), "method": .string("event"),
                    "params": .object([
                        "seq": .number(Double(sequence)), "type": .string(type), "terminal": .string("t1"),
                        "data": data,
                    ]),
                ]))
            let events = try #require(await scripted.sockets.first)
            try await scripted.deliverEvent(line, on: events)
        }
    }

    private static func until(
        _ what: String, _ condition: @MainActor () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private static func noAuthoredInputRPC(_ scripted: ScriptedCoreHost) async -> Bool {
        let methods = await scripted.methods
        return !methods.contains("terminal.send") && !methods.contains("terminal.keys")
    }

    // MARK: The passing path

    @Test func aSendPastesReadsAfterTheSampleDelayAndSubmitsOnTheSameProgram() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()

        let sending = await fixture.sendPastingHello(on: attached)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        #expect(await !fixture.scripted.methods.contains("terminal.get"))

        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])

        await fixture.scripted.answerTerminalReads(with: Self.record())
        #expect(await sending.value == .submittedViaAttach)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, Self.enter])
        #expect(fixture.composer.draft.isEmpty)
        #expect(fixture.composer.notice == nil)
        #expect(fixture.composer.messages.last?.state == .delivered(.acknowledged))
        #expect(await Self.noAuthoredInputRPC(fixture.scripted))
        await fixture.finish()
    }

    @Test func aProgramThatAskedForEveryKeyGetsItsEnterInThatForm() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live(modes: Self.bracketedPasteOn + Self.kittyAllKeys)

        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(with: Self.record())

        #expect(await sending.value == .submittedViaAttach)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, "\u{1B}[13u"])
        await fixture.finish()
    }

    @Test func aTemplatesSubmitKeyIsWhatItPresses() async throws {
        let terminal = Self.record(submit: "ctrl+s")
        let fixture = try await Fixture(terminal: terminal)
        let attached = try await fixture.live()

        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(with: terminal)

        #expect(await sending.value == .submittedViaAttach)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, "\u{13}"])
        await fixture.finish()
    }

    /// The event is the fresh sample, so no read is needed, and the submit still
    /// waits out the full delay.
    @Test func aForegroundEventBeforeTheDelaySparesTheReadAndDoesNotHurryTheSubmit() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)

        await fixture.clock.untilParked(for: HerdrCoreComposerSend.sampleDelay)
        try await fixture.deliverForeground(Self.foreground())
        // The status behind it shows both events have been folded.
        try await fixture.deliverEvent(
            "status",
            data: .object([
                "status": .object(["state": .string("working"), "app": .string("claude-code")]),
                "reported": .bool(true),
            ]),
            sequence: 102)
        try await Self.until("the events to fold") { fixture.console.agents.first?.agent.status == .working }
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])

        fixture.clock.advance(HerdrCoreComposerSend.sampleDelay)
        await attached.socket.waitForData(channel: attached.channel, count: 2)
        #expect(await sending.value == .submittedViaAttach)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, Self.enter])
        #expect(await !fixture.scripted.methods.contains("terminal.get"))
        await fixture.finish()
    }

    // MARK: What stops a submit

    /// A different pid, the same program.
    @Test func anotherPidRunningTheSameProgramGetsNothing() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(with: Self.record(foreground: Self.foreground(pid: 41)))

        guard case .refused(.notSubmitted(let reason)) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(reason.contains("may still be in the terminal"))
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        #expect(fixture.composer.draft == "hello")
        #expect(fixture.composer.notice?.refusal.message == reason)
        await fixture.finish()
    }

    /// The desktop app's wrapper: the shell execs itself under the Agent's pid,
    /// so only the program says the Agent left. Under bash one Ctrl+C drops the
    /// paste.
    @Test func theSamePidNowRunningBashGetsOneCtrlCAndTheTextIsGone() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(
            with: Self.record(foreground: Self.foreground(argv: ["bash", "-i"])))

        guard case .refused(.notSubmitted(let reason)) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(reason.contains("no longer in the terminal"))
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, Self.ctrlC])
        #expect(fixture.composer.draft == "hello")
        await fixture.finish()
    }

    /// A shell's foreground event ends the wait at once, with no read and no
    /// delay. Fish and dash read as bash does.
    @Test(arguments: ["fish", "dash"])
    func aShellsEventStopsTheSendAtOnce(shell: String) async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        try await fixture.deliverForeground(Self.foreground(pid: 50, argv: [shell, "-i"]))

        guard case .refused(.notSubmitted(let reason)) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(reason.contains("no longer in the terminal"))
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, Self.ctrlC])
        #expect(await !fixture.scripted.methods.contains("terminal.get"))
        await fixture.finish()
    }

    /// Until the owner's account check: the conservative part is the notice, not
    /// skipping Ctrl+C. Any shell nobody has observed says the same.
    @Test(arguments: ["zsh", "-zsh", "ksh", "sh"])
    func underAShellNotObservedToDropThePasteTheNoticeSaysItMayRemain(shell: String) async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        try await fixture.deliverForeground(Self.foreground(pid: 50, argv: [shell]))

        guard case .refused(.notSubmitted(let reason)) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(reason.contains("may still be in the terminal"))
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, Self.ctrlC])
        #expect(fixture.composer.draft == "hello")
        await fixture.finish()
    }

    /// An Agent that died never popped its keyboard flags, and a shell does not
    /// read a Ctrl+C written for them.
    @Test func aCtrlCForAShellIsTheByteWhateverKeyboardFlagsWereLeftBehind() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live(modes: Self.bracketedPasteOn + Self.kittyAllKeys)
        let sending = await fixture.sendPastingHello(on: attached)
        try await fixture.deliverForeground(Self.foreground(pid: 50, argv: ["bash", "-i"]))

        guard case .refused(.notSubmitted) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, Self.ctrlC])
        await fixture.finish()
    }

    /// Ctrl+C is for a shell's line editor: another program would take it as an
    /// interrupt of its own.
    @Test func anotherProgramGetsNoCtrlC() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        try await fixture.deliverForeground(Self.foreground(pid: 50, argv: ["vim", "notes.txt"]))

        guard case .refused(.notSubmitted(let reason)) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(reason.contains("may still be in the terminal"))
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        await fixture.finish()
    }

    /// A cleared foreground names nothing, so nothing says a shell holds it.
    @Test func aClearedForegroundStopsTheSendWithoutACtrlC() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        try await fixture.deliverForeground(.null)

        guard case .refused(.notSubmitted(let reason)) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(reason.contains("may still be in the terminal"))
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        await fixture.finish()
    }

    @Test func aProgramThatEndedGetsNothingMore() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        try await fixture.deliverEvent(
            "finished", data: .object(["reason": .string("exited"), "exit_code": .number(0)]))

        guard case .refused(.notSubmitted) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        #expect(fixture.composer.draft == "hello")
        await fixture.finish()
    }

    /// The read's answer is late, past the limit: the Agent still holds the
    /// terminal, so no shell has anything to drop and the text stays in its input.
    @Test func twoSecondsPassingLeavesTheTextUnsubmittedInTheAgentsInput() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        fixture.clock.advance(HerdrCoreComposerSend.submitWindow - HerdrCoreComposerSend.sampleDelay)
        await fixture.scripted.answerTerminalReads(with: Self.record())

        guard case .refused(.notSubmitted(let reason)) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(reason.contains("stayed in the Agent's input unsubmitted"))
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        #expect(fixture.composer.draft == "hello")
        await fixture.finish()
    }

    /// Just inside the limit still submits.
    @Test func anAnswerJustInsideTheLimitSubmits() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        fixture.clock.advance(
            HerdrCoreComposerSend.submitWindow - HerdrCoreComposerSend.sampleDelay - .milliseconds(1))
        await fixture.scripted.answerTerminalReads(with: Self.record())

        #expect(await sending.value == .submittedViaAttach)
        await fixture.finish()
    }

    // MARK: Refusing before anything is written

    @Test func bracketedPasteOffWritesNothingAndKeepsTheDraft() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live(modes: "")

        fixture.composer.replaceDraft(with: "hello")
        let result = await fixture.composer.send()

        #expect(result == .refused(.programNotAcceptingPaste))
        #expect(fixture.composer.draft == "hello")
        #expect(fixture.composer.messages.isEmpty)
        #expect(fixture.composer.notice?.refusal.message.contains("not accepting a paste") == true)
        #expect(await attached.socket.dataWritten(channel: attached.channel).isEmpty)
        await fixture.finish()
    }

    @Test func aShellHoldingTheTerminalBeforeTheSendGetsNothing() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        try await fixture.deliverForeground(Self.foreground(pid: 50, argv: ["bash", "-i"]))
        try await Self.until("the Agent to leave") { fixture.console.agents.isEmpty }

        fixture.composer.replaceDraft(with: "hello")
        let result = await fixture.composer.send()

        guard case .refused(.inputNotReady) = result else {
            Issue.record("Expected a refusal, got \(result)")
            return
        }
        #expect(fixture.composer.draft == "hello")
        #expect(await attached.socket.dataWritten(channel: attached.channel).isEmpty)
        await fixture.finish()
    }

    @Test func aRecordWithNoSampleYetIsReadOnceBeforeThePaste() async throws {
        let fixture = try await Fixture(terminal: Self.record(foreground: nil))
        let attached = try await fixture.live()

        fixture.composer.replaceDraft(with: "hello")
        let composer = fixture.composer
        let sending = Task { await composer.send() }
        await fixture.scripted.waitForMethod("terminal.get")
        #expect(await attached.socket.dataWritten(channel: attached.channel).isEmpty)
        await fixture.scripted.answerTerminalReads(with: Self.record())
        await attached.socket.waitForData(channel: attached.channel, count: 1)

        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get", count: 2)
        await fixture.scripted.answerTerminalReads(with: Self.record())
        #expect(await sending.value == .submittedViaAttach)
        await fixture.finish()
    }

    @Test func aTextWithAControlByteIsNeverPasted() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()

        fixture.composer.replaceDraft(with: "a\u{1B}[201~b")
        let result = await fixture.composer.send()

        #expect(result == .failed)
        #expect(await attached.socket.dataWritten(channel: attached.channel).isEmpty)
        await fixture.finish()
    }

    @Test func aTemplateKeyHeelerCannotPressGetsNoPaste() async throws {
        let fixture = try await Fixture(terminal: Self.record(submit: "hyper+x"))
        let attached = try await fixture.live()

        fixture.composer.replaceDraft(with: "hello")
        guard case .refused(.inputNotReady) = await fixture.composer.send() else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(await attached.socket.dataWritten(channel: attached.channel).isEmpty)
        await fixture.finish()
    }

    // MARK: A live Attach

    /// The wait is bounded and nothing was written, so Retry may send it.
    @Test func noLiveAttachInTimeFailsWithNothingSentAndRetrySends() async throws {
        let fixture = try await Fixture()
        await fixture.scripted.holdAttachReplies()
        fixture.attach.viewDidResize(cols: 80, rows: 24)
        fixture.composer.replaceDraft(with: "hello")
        let composer = fixture.composer
        let sending = Task { await composer.send() }

        await fixture.clock.untilParked(for: HerdrCoreComposerSend.liveAttachTimeout)
        fixture.clock.advance(HerdrCoreComposerSend.liveAttachTimeout)
        #expect(await sending.value == .failed)
        let failed = try #require(composer.messages.last)
        guard case .failed = failed.state else {
            Issue.record("Expected a failed message")
            return
        }

        await fixture.scripted.waitForMethod("terminal.attach")
        await fixture.scripted.releaseAttachReplies()
        let attached = try #require(await fixture.scripted.attaches.last)
        try await attached.socket.deliver(
            HerdrCoreFrame(channel: attached.channel, kind: .data, payload: Data((Self.bracketedPasteOn + "x").utf8)))
        try await Self.until("the Attach's output") { fixture.attach.input.readySession != nil }

        let retrying = Task { await composer.retry(failed.id) }
        await attached.socket.waitForData(channel: attached.channel, count: 1)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(with: Self.record())
        #expect(await retrying.value == .submittedViaAttach)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, Self.enter])
        await fixture.finish()
    }

    /// An Attach that ended is opened again, and the Send goes through it.
    @Test func aSendOpensAnAttachThatEnded() async throws {
        let fixture = try await Fixture()
        let first = try await fixture.live()
        try await first.socket.deliver(HerdrCoreFrame(channel: first.channel, kind: .close))
        try await Self.until("the Attach to end") {
            if case .ended = fixture.attach.terminal.status { return true }
            return false
        }

        fixture.composer.replaceDraft(with: "hello")
        let composer = fixture.composer
        let sending = Task { await composer.send() }
        await fixture.scripted.waitForMethod("terminal.attach", count: 2)
        let second = try #require(await fixture.scripted.attaches.last)
        try await second.socket.deliver(
            HerdrCoreFrame(channel: second.channel, kind: .data, payload: Data((Self.bracketedPasteOn + "x").utf8)))

        await second.socket.waitForData(channel: second.channel, count: 1)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(with: Self.record())
        #expect(await sending.value == .submittedViaAttach)
        #expect(await second.socket.dataWritten(channel: second.channel) == [Self.paste, Self.enter])
        await fixture.finish()
    }

    @Test func aComposerWithNoAttachFailsWithNothingSent() async throws {
        let fixture = try await Fixture(bindsAttach: false)
        fixture.composer.replaceDraft(with: "hello")
        #expect(await fixture.composer.send() == .failed)
        #expect(await fixture.scripted.attaches.isEmpty)
        await fixture.finish()
    }

    // MARK: Blocked

    /// As on Herdr TUI: the tools keyboard submits or cancels.
    @Test func aBlockedAgentGetsThePasteAndNoSubmit() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"))
        let attached = try await fixture.live()

        let sending = await fixture.sendPastingHello(on: attached)

        #expect(await sending.value == .deliveredViaAttach)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        #expect(await !fixture.scripted.methods.contains("terminal.get"))
        #expect(fixture.composer.messages.last?.state == .delivered(.acknowledged))
        await fixture.finish()
    }

    /// Enter would answer the dialog that came up meanwhile.
    @Test func anAgentThatBecameBlockedDuringTheCheckGetsNoSubmit() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(with: Self.record(status: "blocked"))

        #expect(await sending.value == .deliveredViaAttach)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        await fixture.finish()
    }

    // MARK: A step with no answer

    private static func expectUnknownAndNoRetry(_ fixture: Fixture) async throws {
        let message = try #require(fixture.composer.messages.last)
        #expect(message.state == .outcomeUnknown)
        #expect(fixture.composer.draft.isEmpty)
        #expect(await fixture.composer.retry(message.id) == .ignored)
        #expect(fixture.composer.messages.last?.state == .outcomeUnknown)
    }

    @Test func aPasteWithNoAnswerIsNeverSentAgain() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        await attached.socket.holdWrites()

        fixture.composer.replaceDraft(with: "hello")
        let composer = fixture.composer
        let sending = Task { await composer.send() }
        await fixture.clock.untilParked(for: HerdrCoreComposerSend.stepTimeout)
        await attached.socket.waitForHeldWrite()
        fixture.clock.advance(HerdrCoreComposerSend.stepTimeout)

        #expect(await sending.value == .outcomeUnknown)
        try await Self.expectUnknownAndNoRetry(fixture)

        // The held paste still reaches the core once, as a held one can.
        await attached.socket.releaseWrites()
        await attached.socket.waitForData(channel: attached.channel, count: 1)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        await fixture.finish()
    }

    @Test func aReadWithNoAnswerSubmitsNothingAndIsNeverSentAgain() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.clock.untilParked(for: HerdrCoreComposerSend.stepTimeout)
        fixture.clock.advance(HerdrCoreComposerSend.stepTimeout)

        #expect(await sending.value == .outcomeUnknown)
        try await Self.expectUnknownAndNoRetry(fixture)

        // An answer after that changes nothing.
        await fixture.scripted.answerTerminalReads(with: Self.record())
        try await fixture.settle()
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        await fixture.finish()
    }

    @Test func aSubmitWithNoAnswerIsNeverSentAgain() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await attached.socket.holdWrites()
        await fixture.scripted.answerTerminalReads(with: Self.record())

        await attached.socket.waitForHeldWrite()
        await fixture.clock.untilParked(for: HerdrCoreComposerSend.stepTimeout)
        fixture.clock.advance(HerdrCoreComposerSend.stepTimeout)
        #expect(await sending.value == .outcomeUnknown)
        try await Self.expectUnknownAndNoRetry(fixture)

        await attached.socket.releaseWrites()
        await attached.socket.waitForData(channel: attached.channel, count: 2)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, Self.enter])
        await fixture.finish()
    }

    @Test func aCtrlCWithNoAnswerIsNeverSentAgain() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        await attached.socket.holdWrites()
        try await fixture.deliverForeground(Self.foreground(pid: 50, argv: ["bash", "-i"]))

        await attached.socket.waitForHeldWrite()
        await fixture.clock.untilParked(for: HerdrCoreComposerSend.stepTimeout)
        fixture.clock.advance(HerdrCoreComposerSend.stepTimeout)
        #expect(await sending.value == .outcomeUnknown)
        try await Self.expectUnknownAndNoRetry(fixture)

        await attached.socket.releaseWrites()
        await attached.socket.waitForData(channel: attached.channel, count: 2)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, Self.ctrlC])
        await fixture.finish()
    }

    /// The link went with the read, so what happened to the paste is not known.
    @Test func aLinkThatDropsDuringTheReadLeavesTheOutcomeUnknown() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await attached.socket.deliverEndOfFile()

        #expect(await sending.value == .outcomeUnknown)
        try await Self.expectUnknownAndNoRetry(fixture)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        await fixture.finish()
    }

    @Test func anUnansweredMessageComesBackOnlyWhenTheUserAsks() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.clock.untilParked(for: HerdrCoreComposerSend.stepTimeout)
        fixture.clock.advance(HerdrCoreComposerSend.stepTimeout)
        #expect(await sending.value == .outcomeUnknown)

        let message = try #require(fixture.composer.messages.last)
        fixture.composer.withdrawToDraft(message.id)
        #expect(fixture.composer.draft == "hello")
        #expect(fixture.composer.messages.isEmpty)
        await fixture.finish()
    }

    // MARK: Two Sends

    /// Two pastes under one submit would submit both as one message.
    @Test func aSecondSendWaitsForTheFirstToFinish() async throws {
        let fixture = try await Fixture()
        let attached = try await fixture.live()
        let first = await fixture.sendPastingHello(on: attached)

        fixture.composer.replaceDraft(with: "again")
        let composer = fixture.composer
        let second = Task { await composer.send() }
        try await Self.until("the second echo") { composer.messages.count == 2 }
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])

        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(with: Self.record())
        #expect(await first.value == .submittedViaAttach)

        await attached.socket.waitForData(channel: attached.channel, count: 3)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get", count: 2)
        await fixture.scripted.answerTerminalReads(with: Self.record())
        #expect(await second.value == .submittedViaAttach)
        #expect(
            await attached.socket.dataWritten(channel: attached.channel) == [
                Self.paste, Self.enter, "\u{1B}[200~again\u{1B}[201~", Self.enter,
            ])
        await fixture.finish()
    }
}
