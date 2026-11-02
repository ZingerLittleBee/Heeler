import Foundation
import Testing

@testable import Heeler

/// The Composer's Send and Stop on a native Windows core Host (ADR 0035), from the
/// Composer down: the real Console, Attach store, Host session and link, with the
/// core scripted, time on a manual clock, and the foreground and paint replayed from
/// the capture in `herdr-core-frames-windows-v1.json`. No PowerShell runs here: the
/// owner's steps are section 9 of `docs/guides/native-windows-testing.md`.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreWindowsComposerTests {
    private static let paste = "\u{1B}[200~hello\u{1B}[201~"
    private static let enter = "\r"
    private static let ctrlC = "\u{3}"
    private static let bracketedPasteOn = "\u{1B}[?2004h"
    private static let kittyAllKeys = "\u{1B}[>8u"
    /// How the captured Windows first paint ends.
    private static let paintEnd = "\u{1B}[?9001h"

    private static let powerShell = #"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe"#
    private static let exit = "; exit $LASTEXITCODE"

    // MARK: The capture

    private static func capturedEvent(_ name: String) -> String {
        HerdrCoreVectorFile.windows.events.first { $0.name == name }?.line ?? ""
    }

    /// The `foreground` the capture's event carries.
    private static func capturedForeground(_ name: String) throws -> JSONValue {
        let line = try JSONDecoder().decode(JSONValue.self, from: Data(capturedEvent(name).utf8))
        guard case .object(let fields) = line, case .object(let params)? = fields["params"], let data = params["data"]
        else {
            throw TransportError.herdrCoreTerminalGone
        }
        return data
    }

    /// The captured Terminal's address and its foreground's pid.
    private static let address = "t1t"
    private static let pid = 17624

    private static func foreground(pid: Int = Self.pid, argv: [String]) -> JSONValue {
        .object([
            "pid": .number(Double(pid)), "name": .string("powershell.exe"),
            "argv": .array(argv.map(JSONValue.string)), "cwd": .string(#"C:\Users\user\heeler586"#),
        ])
    }

    /// A Terminal as a `terminal.get` shows it. A captured program reporting a status
    /// is an Agent, whichever program it is.
    private static func record(
        foreground: JSONValue?, address: String = Self.address, status: String = "idle",
        app: String = "custom", state: String = "live"
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "address": .string(address), "cwd": .string(#"C:\Users\user\heeler586"#), "state": .string(state),
            "argv": .array([.string("powershell.exe")]), "keep": .bool(false), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(Double(pid)),
            "status": .object(["state": .string(status), "app": .string(app)]),
            "labels": .object([:]),
        ]
        fields["foreground"] = foreground
        return .object(fields)
    }

    /// The Terminal the capture's Heeler-form events are about.
    private static func heelerForm(status: String = "idle") throws -> JSONValue {
        record(foreground: try capturedForeground("foreground-heeler-form"), status: status)
    }

    private static func heelerFormClaude(status: String = "idle") -> JSONValue {
        record(
            foreground: foreground(argv: [powerShell, "-Command", "& 'claude'" + exit]), status: status,
            app: "claude-code")
    }

    // MARK: The fixture

    @MainActor
    private struct Fixture {
        let scripted: ScriptedCoreHost
        let console: ConsoleStore
        let host = Host(address: "win.example", username: "me", serverKind: .herdrCore)
        let clock = ManualClock()
        let composer: AgentComposerStore
        let attach: AgentAttachStore
        let agent: ConsoleAgent

        init(terminal: JSONValue) async throws {
            let scripted = ScriptedCoreHost(
                windowsLocator: ScriptedCoreHost.windowsLocatorLines(),
                channel: .core(.init(id: "c1", terminals: [terminal])))
            self.scripted = scripted
            await scripted.helper.configure { $0.platform = .nativeWindows }
            let clock = clock
            let sleeping = BlockedCardClock(now: clock.clock.now, sleep: clock.parkedSleep(for:))
            let console = ConsoleStore(
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
                coreStopClock: sleeping,
                coreHostMemory: HerdrCoreHostMemory(
                    defaults: UserDefaults(suiteName: "core-windows-composer-\(UUID().uuidString)") ?? .standard),
                coreSendClock: sleeping)
            self.console = console
            let host = host
            console.setHosts([host])
            await console.resume()
            try await HerdrCoreWindowsComposerTests.until("the Agent") { [console] in !console.agents.isEmpty }
            let agent = try #require(console.agents.first)
            self.agent = agent
            composer = console.composerStore(for: agent)
            composer.open()
            attach = AgentAttachStore(
                target: agent.agent.paneID, paneTitle: "", transportGeneration: nil, isOnStage: { true },
                runTerminal: console.terminalRunner(for: host.id), closePane: {})
            try await HerdrCoreWindowsComposerTests.until("the Host's platform") { [console] in
                console.capabilities(for: host.id).composerSend
            }
        }

        func finish() async {
            await attach.leave().value
            console.setHosts([])
        }

        var policy: ComposerDeliveryPolicy {
            var policy = ComposerDeliveryPolicy.terminal
            policy.coreAttach = attach
            return policy
        }

        /// The Attach, once the core answered it and `paint` went through.
        @discardableResult
        func live(
            paint: Data = Data(
                (HerdrCoreWindowsComposerTests.bracketedPasteOn + "x" + HerdrCoreWindowsComposerTests.paintEnd).utf8)
        ) async throws -> (channel: UInt32, socket: FakeCoreSocket) {
            attach.viewDidResize(cols: 80, rows: 24)
            await scripted.waitForMethod("terminal.attach")
            let opened = try #require(await scripted.attaches.last)
            try await opened.socket.deliver(HerdrCoreFrame(channel: opened.channel, kind: .data, payload: paint))
            let input = attach.input
            try await HerdrCoreWindowsComposerTests.until("the Attach's paint") { input.paintedSession != nil }
            return (opened.channel, opened.socket)
        }

        func sendPastingHello(
            on attached: (channel: UInt32, socket: FakeCoreSocket)
        ) async -> Task<AgentComposerStore.SendResult, Never> {
            composer.replaceDraft(with: "hello")
            let composer = composer
            let policy = policy
            let sending = Task { await composer.send(policy: policy) }
            await attached.socket.waitForData(channel: attached.channel, count: 1)
            return sending
        }

        func passSampleDelay() async {
            await clock.untilParked(for: HerdrCoreComposerSend.sampleDelay)
            clock.advance(HerdrCoreComposerSend.sampleDelay)
        }

        /// A capture's line, exactly as the core wrote it.
        func deliverCaptured(_ name: String) async throws {
            let events = try #require(await scripted.sockets.first)
            try await scripted.deliverEvent(Data(HerdrCoreWindowsComposerTests.capturedEvent(name).utf8), on: events)
        }

        func deliverForeground(_ data: JSONValue, sequence: Int = 500) async throws {
            let line = try JSONEncoder().encode(
                JSONValue.object([
                    "jsonrpc": .string("2.0"), "method": .string("event"),
                    "params": .object([
                        "seq": .number(Double(sequence)), "type": .string("foreground"),
                        "terminal": .string(HerdrCoreWindowsComposerTests.address), "data": data,
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

    private static func notSubmitted(
        _ result: AgentComposerStore.SendResult, sourceLocation: SourceLocation = #_sourceLocation
    ) -> String? {
        guard case .refused(.notSubmitted(let reason)) = result else {
            Issue.record("Expected nothing submitted, got \(result)", sourceLocation: sourceLocation)
            return nil
        }
        return reason
    }

    // MARK: Send into a live Agent

    @Test func aSendPastesThenPressesEnterInThatOrderInsideTheLimit() async throws {
        let fixture = try await Fixture(terminal: try Self.heelerForm())
        let attached = try await fixture.live()

        let sending = await fixture.sendPastingHello(on: attached)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        fixture.clock.advance(
            HerdrCoreComposerSend.submitWindow - HerdrCoreComposerSend.sampleDelay - .milliseconds(1))
        await fixture.scripted.answerTerminalReads(with: try Self.heelerForm())

        #expect(await sending.value == .submittedViaAttach)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, Self.enter])
        #expect(fixture.composer.draft.isEmpty)
        let methods = await fixture.scripted.methods
        #expect(!methods.contains("terminal.send") && !methods.contains("terminal.keys"))
        await fixture.finish()
    }

    /// The capture's event is the first and only one a PowerShell Terminal sends:
    /// it may have been sampled before the paste, so only the read lets Enter go.
    @Test func theCapturedForegroundEventSparesNoRead() async throws {
        let fixture = try await Fixture(terminal: try Self.heelerForm())
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)

        await fixture.clock.untilParked(for: HerdrCoreComposerSend.sampleDelay)
        try await fixture.deliverCaptured("foreground-heeler-form")
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        #expect(await !fixture.scripted.methods.contains("terminal.get"))

        fixture.clock.advance(HerdrCoreComposerSend.sampleDelay)
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(with: try Self.heelerForm())

        #expect(await sending.value == .submittedViaAttach)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, Self.enter])
        await fixture.finish()
    }

    @Test func aProgramThatSetKittyFlagEightGetsItsEnterInThatForm() async throws {
        let fixture = try await Fixture(terminal: Self.heelerFormClaude())
        let attached = try await fixture.live(
            paint: Data((Self.bracketedPasteOn + Self.kittyAllKeys + "x" + Self.paintEnd).utf8))

        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(with: Self.heelerFormClaude())

        #expect(await sending.value == .submittedViaAttach)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, "\u{1B}[13u"])
        await fixture.finish()
    }

    // MARK: An Agent that exits between paste and check

    /// Heeler's form: the program's end ends PowerShell and the Terminal, so there is
    /// no shell to press Ctrl+C for, and the text went with them.
    @Test func aFinishedEventEndsTheSendWithNothingMore() async throws {
        let fixture = try await Fixture(terminal: try Self.heelerForm())
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)

        try await fixture.deliverCaptured("finished-heeler-form")

        let reason = Self.notSubmitted(await sending.value)
        #expect(reason?.contains("ended before the message was submitted") == true)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        #expect(fixture.composer.draft == "hello")
        #expect(fixture.composer.notice?.refusal.message == reason)
        await fixture.finish()
    }

    /// Read past the end, a finished Terminal answers with its record or a refusal.
    @Test(arguments: ["finished", "not_found"])
    func aReadTheCoreRefusesEndsTheSendWithNothingMore(kind: String) async throws {
        let fixture = try await Fixture(terminal: try Self.heelerForm())
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.refuseTerminalReads(kind: kind)

        let reason = Self.notSubmitted(await sending.value)
        #expect(reason?.contains("ended before the message was submitted") == true)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        #expect(fixture.composer.draft == "hello")
        await fixture.finish()
    }

    /// Windows PowerShell 5.1 dropped such a paste on one 0x03, with one PSReadLine on
    /// one machine (herdr compatibility), so the notice does not promise it elsewhere.
    @Test func powerShellBackInTheForegroundGetsOneCtrlCAndTheTextMayRemain() async throws {
        let fixture = try await Fixture(terminal: Self.heelerFormClaude())
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(
            with: Self.record(foreground: Self.foreground(argv: [Self.powerShell]), app: "claude-code"))

        let reason = Self.notSubmitted(await sending.value)
        #expect(reason?.contains("may still be in the terminal") == true)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, Self.ctrlC])
        #expect(fixture.composer.draft == "hello")
        await fixture.finish()
    }

    /// Nobody has seen what PowerShell 7 does with it, so the notice says it may
    /// remain. The byte is 0x03 whatever flags a program that died left behind.
    @Test func anEventShowingPwshBackGetsOneCtrlCAndTheTextMayRemain() async throws {
        let fixture = try await Fixture(terminal: Self.heelerFormClaude())
        let attached = try await fixture.live(
            paint: Data((Self.bracketedPasteOn + Self.kittyAllKeys + "x" + Self.paintEnd).utf8))
        let sending = await fixture.sendPastingHello(on: attached)

        try await fixture.deliverForeground(
            Self.foreground(argv: [#"C:\Program Files\PowerShell\7\pwsh.exe"#, "-NoLogo"]))

        let reason = Self.notSubmitted(await sending.value)
        #expect(reason?.contains("may still be in the terminal") == true)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste, Self.ctrlC])
        #expect(fixture.composer.draft == "hello")
        await fixture.finish()
    }

    // MARK: A shell that outlives its program

    /// The foreground of each stays the same after the program exits (ADR 0032), so
    /// the check would pass and Enter would run the draft at the prompt. Nothing goes.
    @Test(arguments: [
        ["-NoExit", "-Command", "& 'claude'"],
        ["-noexit", "-Command", "& 'claude'"],
        ["-NoE", "-Command", "& 'claude'"],
        ["/NoExit", "-Command", "& 'claude'"],
        ["-NoExit", "-Command", "& 'claude'; exit $LASTEXITCODE"],
        ["-Command", "& 'claude'; Read-Host; exit $LASTEXITCODE"],
        ["-NoLogo", "-Command", "& 'claude'; exit $LASTEXITCODE"],
        ["-Command", "& 'cmd' '/k' 'claude'; exit $LASTEXITCODE"],
        ["-Command", #"& 'C:\WINDOWS\system32\cmd.exe' '/k' 'claude'; exit $LASTEXITCODE"#],
        ["-Command", "& 'powershell.exe' '-NoExit' '-Command' 'claude'; exit $LASTEXITCODE"],
        ["-Command", "& 'pwsh' '-NoExit' 'claude'; exit $LASTEXITCODE"],
        ["-Command", "& 'bash' '-i'; exit $LASTEXITCODE"],
    ])
    func aPowerShellThatCanOutliveItsProgramGetsNothing(arguments: [String]) async throws {
        let terminal = Self.record(foreground: Self.foreground(argv: [Self.powerShell] + arguments))
        let fixture = try await Fixture(terminal: terminal)
        let attached = try await fixture.live()

        fixture.composer.replaceDraft(with: "hello")
        let result = await fixture.composer.send(policy: fixture.policy)

        guard case .refused(.inputNotReady(let reason)) = result else {
            Issue.record("Expected a refusal, got \(result)")
            await fixture.finish()
            return
        }
        #expect(reason.contains("keeps a shell open after the Agent exits"))
        #expect(fixture.composer.draft == "hello")
        #expect(fixture.composer.messages.isEmpty)
        #expect(await attached.socket.dataWritten(channel: attached.channel).isEmpty)
        await fixture.finish()
    }

    /// The form the capture recorded for the desktop app, while the Agent is Blocked too.
    @Test(arguments: ["idle", "blocked"])
    func theCapturedDesktopFormGetsNothing(status: String) async throws {
        let terminal = Self.record(
            foreground: try Self.capturedForeground("foreground-desktop-form"), address: "t1v", status: status)
        let fixture = try await Fixture(terminal: terminal)
        let attached = try await fixture.live()

        fixture.composer.replaceDraft(with: "hello")
        guard case .refused(.inputNotReady) = await fixture.composer.send(policy: fixture.policy) else {
            Issue.record("Expected a refusal")
            await fixture.finish()
            return
        }
        #expect(fixture.composer.draft == "hello")
        #expect(await attached.socket.dataWritten(channel: attached.channel).isEmpty)
        await fixture.finish()
    }

    @Test func aShellLeftRunningUnderCmdGetsNothing() async throws {
        let terminal = Self.record(
            foreground: Self.foreground(argv: [#"C:\WINDOWS\system32\cmd.exe"#, "/k", "claude"]), app: "claude-code")
        let fixture = try await Fixture(terminal: terminal)
        let attached = try await fixture.live()

        fixture.composer.replaceDraft(with: "hello")
        guard case .refused(.inputNotReady) = await fixture.composer.send(policy: fixture.policy) else {
            Issue.record("Expected a refusal")
            await fixture.finish()
            return
        }
        #expect(await attached.socket.dataWritten(channel: attached.channel).isEmpty)
        await fixture.finish()
    }

    /// A program that is the Terminal's first process leaves no shell behind, as a
    /// Template's does.
    @Test func aProgramRunWithoutAShellSubmits() async throws {
        let terminal = Self.record(
            foreground: Self.foreground(argv: [#"C:\Users\user\.local\bin\claude.exe"#]), app: "claude-code")
        let fixture = try await Fixture(terminal: terminal)
        let attached = try await fixture.live()

        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(with: terminal)

        #expect(await sending.value == .submittedViaAttach)
        await fixture.finish()
    }

    // MARK: What stops a submit

    @Test func twoSecondsPassingSubmitsNothingAndSaysTheTextStayed() async throws {
        let fixture = try await Fixture(terminal: try Self.heelerForm())
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        fixture.clock.advance(HerdrCoreComposerSend.submitWindow - HerdrCoreComposerSend.sampleDelay)
        await fixture.scripted.answerTerminalReads(with: try Self.heelerForm())

        let reason = Self.notSubmitted(await sending.value)
        #expect(reason?.contains("stayed in the Agent's input unsubmitted") == true)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        #expect(fixture.composer.draft == "hello")
        await fixture.finish()
    }

    /// The capture's first paint turns the mode off and nothing sets it again.
    @Test func theCapturedPaintLeavesBracketedPasteOffSoNothingGoes() async throws {
        let fixture = try await Fixture(terminal: try Self.heelerForm())
        let frame = try #require(HerdrCoreVectorFile.windows.frames.first { $0.name == "data-attach-first-paint" })
        var decoder = HerdrCoreFrameDecoder()
        decoder.append(HerdrCoreVectorFile.bytes(hex: frame.bytes))
        let attached = try await fixture.live(paint: try #require(try decoder.next()).payload)

        fixture.composer.replaceDraft(with: "hello")
        let result = await fixture.composer.send(policy: fixture.policy)

        #expect(result == .refused(.programNotAcceptingPaste))
        #expect(fixture.composer.draft == "hello")
        #expect(fixture.composer.notice?.refusal.message.contains("not accepting a paste") == true)
        #expect(await attached.socket.dataWritten(channel: attached.channel).isEmpty)
        await fixture.finish()
    }

    @Test func aBlockedAgentGetsThePasteAndNoSubmit() async throws {
        let fixture = try await Fixture(terminal: try Self.heelerForm(status: "blocked"))
        let attached = try await fixture.live()

        let sending = await fixture.sendPastingHello(on: attached)

        #expect(await sending.value == .deliveredViaAttach)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        #expect(await !fixture.scripted.methods.contains("terminal.get"))
        await fixture.finish()
    }

    @Test func aStepWithNoAnswerIsUnknownAndRetryIsRefused() async throws {
        let fixture = try await Fixture(terminal: try Self.heelerForm())
        let attached = try await fixture.live()
        let sending = await fixture.sendPastingHello(on: attached)
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.clock.untilParked(for: HerdrCoreComposerSend.stepTimeout)
        fixture.clock.advance(HerdrCoreComposerSend.stepTimeout)

        #expect(await sending.value == .outcomeUnknown)
        let message = try #require(fixture.composer.messages.last)
        #expect(message.state == .outcomeUnknown)
        #expect(await fixture.composer.retry(message.id, policy: fixture.policy) == .ignored)
        #expect(await attached.socket.dataWritten(channel: attached.channel) == [Self.paste])
        await fixture.scripted.answerTerminalReads(with: try Self.heelerForm())
        await fixture.finish()
    }

    // MARK: Stop

    private static func coreStop(_ fixture: Fixture, agent: ConsoleAgent) throws -> AgentComposerInterrupt {
        try #require(
            fixture.console.terminalInterrupt(for: agent) {
                Issue.record("A core Stop pressed Esc itself")
                return .sent
            })
    }

    @Test func stopSendsOneInterruptWithItsShortTimeoutThenReadsTheForeground() async throws {
        let fixture = try await Fixture(terminal: Self.heelerFormClaude(status: "working"))
        let stop = try Self.coreStop(fixture, agent: fixture.agent)

        let stopping = Task { await stop.perform() }
        await fixture.scripted.waitForMethod("terminal.interrupt")
        #expect(await !fixture.scripted.methods.contains("terminal.get"))
        await fixture.scripted.answerInterrupts()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(with: Self.heelerFormClaude(status: "working"))

        #expect(await stopping.value == .sent)
        #expect(
            await fixture.scripted.interrupts
                == [.object(["terminal": .string(Self.address), "timeout": .number(2)])])
        await fixture.finish()
    }

    /// PowerShell's foreground never changes, so a Terminal that finished at the key
    /// says so only in the read's record, and the Agent leaves with no event.
    @Test func aTerminalThatFinishedAtTheKeyLeavesTheListOnTheRead() async throws {
        let fixture = try await Fixture(terminal: Self.heelerFormClaude(status: "working"))
        let stop = try Self.coreStop(fixture, agent: fixture.agent)

        let stopping = Task { await stop.perform() }
        await fixture.scripted.waitForMethod("terminal.interrupt")
        await fixture.scripted.answerInterrupts()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(
            with: Self.record(
                foreground: Self.foreground(argv: [Self.powerShell, "-Command", "& 'claude'" + Self.exit]),
                status: "working", app: "claude-code", state: "finished"))

        #expect(await stopping.value == .sent)
        #expect(fixture.console.agents.isEmpty)
        await fixture.finish()
    }

    /// A program that keeps running at the key stays the Agent.
    @Test func aTerminalStillLiveAfterTheKeyStaysListed() async throws {
        let fixture = try await Fixture(terminal: Self.heelerFormClaude(status: "working"))
        let stop = try Self.coreStop(fixture, agent: fixture.agent)

        let stopping = Task { await stop.perform() }
        await fixture.scripted.waitForMethod("terminal.interrupt")
        await fixture.scripted.answerInterrupts()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(with: Self.heelerFormClaude(status: "working"))

        #expect(await stopping.value == .sent)
        #expect(fixture.console.agents.map(\.agent.paneID) == [Self.address])
        await fixture.finish()
    }

    /// Esc does not stop Grok Build's turns, here as anywhere.
    @Test func aGrokBuildAgentKeepsSend() async throws {
        let terminal = Self.record(
            foreground: Self.foreground(argv: [Self.powerShell, "-Command", "& 'grok'" + Self.exit]), status: "working",
            app: "grok-build")
        let fixture = try await Fixture(terminal: terminal)
        #expect(fixture.agent.agent.kind == "grok")

        let stop = fixture.console.terminalInterrupt(for: fixture.agent) {
            Issue.record("A Grok Build Stop pressed Esc")
            return .sent
        }

        #expect(stop == nil)
        #expect(await fixture.scripted.interrupts.isEmpty)
        await fixture.finish()
    }

    // MARK: When they are offered

    @Test func aWindowsCoreHostOffersSendAndStopOnceItsPlatformIsKnown() {
        for offers in [
            HostCapabilities(serverKind: .herdrCore, platform: .nativeWindows),
            HostCapabilities(serverKind: .herdrCore, coreKernel: HerdrCoreLocator.windowsKernel),
        ] {
            #expect(offers.composerSend)
            #expect(offers.composerStop)
        }
        #expect(!HostCapabilities(serverKind: .herdrCore).composerSend)
        #expect(!HostCapabilities(serverKind: .herdrCore).composerStop)
    }

    @Test func aWindowsHerdrTUIHostAndAnUnconfirmedOneAreUnchanged() {
        let tui = HostCapabilities(serverKind: .herdrTUI, platform: .nativeWindows)
        #expect(tui == HostCapabilities(serverKind: .herdrTUI))
        #expect(tui.composerSend)
        #expect(tui.composerStop)
        let unconfirmed = HostCapabilities(serverKind: .unconfirmed, platform: .nativeWindows)
        #expect(!unconfirmed.composerSend)
        #expect(!unconfirmed.composerStop)
    }
}
