import Foundation
import SwiftUI
import Testing

@testable import Heeler

/// Chat on a native Windows core Host, from the Console down: the real Console,
/// session, link and Windows read's parser, with the core, the process table and SFTP
/// scripted. No PowerShell and no program runs: each program's Chat stays off until
/// its owner's check in `docs/guides/native-windows-testing.md` passes, so these turn
/// them on through the store's own list.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreWindowsChatTests {
    private static let powerShell = #"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe"#
    private static let exit = "; exit $LASTEXITCODE"
    private static let directory = #"C:\Users\me\proj"#
    private static let home = "/C:/Users/me"
    private static let shellPid = 7868
    private static let agentPid = 3792
    private static let agentStart = "134065000000000002"
    private static let session = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
    private static let bracketedPasteOn = "\u{1B}[?2004h"
    private static let readyScreen = "claude-01-ready"
    private static let dialogScreen = "claude-02-c1-bash-blocked"
    private static let candidates: Set<ChatProgram> = [.claude, .grok, .pi, .omp]

    private static func foreground(argv: [String]) -> JSONValue {
        .object([
            "pid": .number(Double(shellPid)), "name": .string("powershell.exe"),
            "argv": .array(argv.map(JSONValue.string)), "cwd": .string(directory),
        ])
    }

    private static func record(
        program: String = "claude", app: String = "claude-code", status: String = "idle",
        arguments: [String]? = nil, labels: [String: String] = [:]
    ) -> JSONValue {
        let arguments = arguments ?? ["-Command", "& '\(program)'" + exit]
        return .object([
            "address": .string("t1"), "cwd": .string(directory), "state": .string("live"),
            "argv": .array([.string("powershell.exe")]), "keep": .bool(false), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(Double(shellPid)),
            "foreground": foreground(argv: [powerShell] + arguments),
            "status": .object(["state": .string(status), "app": .string(app)]),
            "labels": .object(labels.mapValues(JSONValue.string)),
        ])
    }

    /// A captured paint in the form a Windows core's ends.
    private static func paint(_ stem: String, modes: String = bracketedPasteOn) throws -> Data {
        let captured = try ChatFixture.text("screens/core-paint/\(stem).paint")
        return Data(captured.replacingOccurrences(of: "\u{1B}[?9001l", with: modes + "\u{1B}[?9001h").utf8)
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

    private typealias Attached = (channel: UInt32, params: JSONValue, socket: FakeCoreSocket)

    @MainActor
    private struct Fixture {
        let scripted: ScriptedCoreHost
        let files = VirtualHostFiles(home: HerdrCoreWindowsChatTests.home)
        let console: ConsoleStore
        let host = Host(address: "win.example", username: "me", serverKind: .herdrCore)
        let clock = ManualClock()
        let agent: ConsoleAgent

        /// `offered` nil is the list the app ships.
        init(
            terminal: JSONValue = HerdrCoreWindowsChatTests.record(), image: String = "claude.exe",
            offered: Set<ChatProgram>? = HerdrCoreWindowsChatTests.candidates, screen: String = readyScreen,
            timing: AgentChatStore.Timing = AgentChatStore.Timing()
        ) async throws {
            let scripted = ScriptedCoreHost(
                windowsLocator: ScriptedCoreHost.windowsLocatorLines(),
                channel: .core(.init(id: "c1", terminals: [terminal])))
            self.scripted = scripted
            await scripted.helper.configure { $0.platform = .nativeWindows }
            await scripted.setHostFiles(files)
            await scripted.setAnswersLabels(true)
            await scripted.setAttachPaint(try HerdrCoreWindowsChatTests.paint(screen))
            let environment = ["HC_SCOPE": "scope", "USERPROFILE": #"C:\Users\me"#]
            await scripted.setWindowsProcesses([
                .init(
                    pid: shellPid, parent: 100, image: "powershell.exe", start: "134065000000000001",
                    environment: environment),
                .init(pid: agentPid, parent: shellPid, image: image, start: agentStart, environment: environment),
            ])
            let clock = clock
            let sleeping = BlockedCardClock(now: clock.clock.now, sleep: clock.parkedSleep(for:))
            let console = ConsoleStore(
                chatCache: VolatileChatTranscriptCache(),
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
                coreHostMemory: HerdrCoreHostMemory(
                    defaults: UserDefaults(suiteName: "core-windows-chat-\(UUID().uuidString)") ?? .standard),
                coreSendClock: sleeping,
                coreWindowsChatPrograms: offered ?? HostCapabilities.confirmedWindowsCoreChatPrograms,
                chatTiming: timing)
            self.console = console
            let host = host
            console.setHosts([host])
            await console.resume()
            try await until("the Agent") { [console] in !console.agents.isEmpty }
            agent = try #require(console.agents.first)
            await console.resolveHostPlatform(host.id)
            try await until("the Host's kind") { [console] in
                console.hostPlatforms[host.id] == .nativeWindows && console.hostCoreKernels[host.id] == "Windows"
            }
        }

        func finish() {
            console.setHosts([])
        }

        func chat(as program: ChatProgram = .claude) throws -> AgentChatStore {
            let chat = try #require(console.chatStore(for: agent, program: program))
            chat.show()
            return chat
        }

        /// A binder's, not the link's own check of the core's environment, the one read
        /// that asks by prefix.
        var processReads: Int {
            get async { await scripted.scripts.filter { $0.contains("$pre=''") }.count }
        }

        func entry(start: String = HerdrCoreWindowsChatTests.agentStart) async {
            let line = """
                {"pid":\(agentPid),"sessionId":"\(session)","cwd":"C:\\\\Users\\\\me\\\\proj","procStartFt":"\(start)"}
                """
            await files.write(Data(line.utf8), at: "\(home)/.claude/sessions/\(agentPid).json")
        }

        // MARK: Typing

        var policy: ComposerDeliveryPolicy {
            let console = console
            let hostID = host.id
            return .chat(
                rules: ChatSendRules(
                    program: .claude,
                    commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .claude)),
                activity: { .idle },
                readScreen: { try await console.readAgentScreen("t1", on: hostID) },
                pause: { _ in })
        }

        func viewer() async throws -> Attached {
            let scripted = scripted
            try await until("Chat's viewer") {
                await !scripted.attaches.filter { $0.params["resumed"] == .bool(true) }.isEmpty
            }
            return try #require(await scripted.attaches.first { $0.params["resumed"] == .bool(true) })
        }
    }

    // MARK: Which programs

    @Test func aHostOffersNoChatUntilAProgramIsMarkedPassed() {
        let shipped = HostCapabilities(serverKind: .herdrCore, platform: .nativeWindows, coreKernel: "Windows")
        #expect(!shipped.chat)
        for program in ChatProgram.allCases { #expect(!shipped.offersChat(for: program)) }

        for program in Self.candidates {
            let one = HostCapabilities(
                serverKind: .herdrCore, platform: .nativeWindows, coreKernel: "Windows",
                coreWindowsChatPrograms: [program])
            #expect(one.offersChat(for: program))
            for other in ChatProgram.allCases where other != program { #expect(!one.offersChat(for: other)) }
        }
    }

    @Test func codexAndOpenCodeStayOffEvenIfSomethingMarksThemPassed() {
        let all = HostCapabilities(
            serverKind: .herdrCore, platform: .nativeWindows, coreKernel: "Windows",
            coreWindowsChatPrograms: Set(ChatProgram.allCases))
        #expect(!all.offersChat(for: .codex))
        #expect(!all.offersChat(for: .opencode))
        #expect(all.offersChat(for: .claude))
    }

    @Test func aLinuxCoresListIsNotAWindowsCoresList() {
        let linux = HostCapabilities(
            serverKind: .herdrCore, platform: .posix, coreKernel: "Linux", coreChatPrograms: [.claude],
            coreWindowsChatPrograms: [.pi])
        #expect(linux.offersChat(for: .claude))
        #expect(!linux.offersChat(for: .pi))
    }

    @Test(arguments: ChatProgram.allCases)
    func everyAgentOnANativeWindowsHerdrTUIHostHasNoChat(program: ChatProgram) {
        let capabilities = HostCapabilities(
            serverKind: .herdrTUI, platform: .nativeWindows, coreWindowsChatPrograms: Set(ChatProgram.allCases))
        let agent = Agent(.fixture(paneID: "p1", kind: program.rawValue))
        #expect(
            AgentChatAvailability.program(
                for: agent, platform: .nativeWindows, opensOnWindows: capabilities.startsInWindowsDirectories) == nil)
    }

    @Test func theStoreOffersAProgramOnlyOnceItIsOnTheList() async throws {
        let shipped = try await Fixture(offered: nil)
        #expect(shipped.console.chatProgram(for: shipped.agent) == nil)
        shipped.finish()

        let elsewhere = try await Fixture(offered: [.pi])
        #expect(elsewhere.console.chatProgram(for: elsewhere.agent) == nil)
        elsewhere.finish()

        let passed = try await Fixture()
        #expect(passed.console.chatProgram(for: passed.agent) == .claude)
        passed.finish()
    }

    @Test(arguments: [("codex", "codex"), ("opencode", "opencode")])
    func theStoreOffersCodexAndOpenCodeNothing(program: String, app: String) async throws {
        let fixture = try await Fixture(
            terminal: Self.record(program: program, app: app), image: "\(program).exe",
            offered: Set(ChatProgram.allCases))
        #expect(fixture.agent.agent.kind == program)
        #expect(fixture.console.chatProgram(for: fixture.agent) == nil)
        fixture.finish()
    }

    // MARK: Claude Code

    @Test func claudeCodesChatFollowsItsTranscriptByTheRecordedPath() async throws {
        let fixture = try await Fixture()
        await fixture.entry()
        let path = "\(Self.home)/.claude/projects/C--Users-me-proj/\(Self.session).jsonl"
        await fixture.files.write(Data(try ChatFixture.text("claude/probe2-transcript.jsonl").utf8), at: path)

        let chat = try fixture.chat()

        try await Self.until("the Transcript") {
            if case .following(path) = chat.conversation.phase { return true }
            return false
        }
        // One check: one exec and one read of the entry, and no key file.
        #expect(await fixture.processReads == 1)
        let reads = await fixture.files.reads.map(\.path)
        #expect(reads.filter { $0.contains("/sessions/") } == ["\(Self.home)/.claude/sessions/\(Self.agentPid).json"])
        #expect(!reads.contains { $0.hasSuffix(".key") })
        #expect(await !fixture.scripted.log.contains("process-read"))
        fixture.finish()
    }

    @Test func aWindowsCannotTellOffersNoHelper() async throws {
        let fixture = try await Fixture()
        await fixture.entry(start: "134065000000000099")

        let chat = try fixture.chat()

        try await Self.until("the reason") {
            chat.conversation.phase == .unavailable(.cannotTellSessionOnWindows(.claude))
        }
        #expect(await fixture.processReads == 1)
        #expect(!chat.offersCandidates)
        fixture.finish()
    }

    // MARK: Pi and Oh My Pi

    private static func piLabel(start: String) throws -> String {
        let file = #"C:\Users\me\.pi\agent\sessions\--C--Users-me-proj--\2026-11-01_"# + session + ".jsonl"
        let fields: [String: JSONValue] = [
            "session": .string(session), "file": .string(file), "pid": .number(Double(agentPid)), "start": .string(start),
        ]
        return String(decoding: try JSONEncoder().encode(JSONValue.object(fields)), as: UTF8.self)
    }

    private static func piTranscript() throws -> Data {
        let data = try ChatFixture.data("pi/provider-retry.jsonl")
        let recorded = try #require(PiTranscriptLocator.sessionID(inHead: data))
        return Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: recorded, with: session).utf8)
    }

    @Test func pisChatFollowsTheFileItsMatchingLabelNames() async throws {
        let fixture = try await Fixture(
            terminal: Self.record(
                program: "pi", app: "pi", labels: ["heeler.session": try Self.piLabel(start: Self.agentStart)]),
            image: "node.exe")
        let path = "\(Self.home)/.pi/agent/sessions/--C--Users-me-proj--/2026-11-01_\(Self.session).jsonl"
        await fixture.files.write(try Self.piTranscript(), at: path)

        let chat = try fixture.chat(as: .pi)

        try await Self.until("the Transcript") {
            if case .following(path) = chat.conversation.phase { return true }
            return false
        }
        fixture.finish()
    }

    @Test func aLabelWhoseCreationTimeDiffersOffersTheExtensionAndIsCleared() async throws {
        let fixture = try await Fixture(
            terminal: Self.record(
                program: "pi", app: "pi", labels: ["heeler.session": try Self.piLabel(start: "134065000000000099")]),
            image: "pi.exe")

        let chat = try fixture.chat(as: .pi)

        try await Self.until("the reason") {
            chat.conversation.phase == .unavailable(.cannotTellSessionOnWindows(.pi))
        }
        #expect(ChatUnavailableReason.cannotTellSessionOnWindows(.pi).offersWindowsExtension)
        await fixture.scripted.waitForMethod("terminal.label")
        fixture.finish()
    }

    /// A send guard's verdict says what any check here says, whatever the Host: this
    /// Host has no Helper to install and no list to choose from.
    @Test func aDroppedPickSaysTheWindowsCannotTell() async throws {
        var timing = AgentChatStore.Timing()
        timing.pickGuardSettle = 0
        let fixture = try await Fixture(
            terminal: Self.record(
                program: "pi", app: "pi", labels: ["heeler.chat": try Self.piLabel(start: Self.agentStart)]),
            image: "pi.exe", timing: timing)
        let path = "\(Self.home)/.pi/agent/sessions/--C--Users-me-proj--/2026-11-01_\(Self.session).jsonl"
        await fixture.files.write(try Self.piTranscript(), at: path)
        let chat = try #require(fixture.console.chatStore(for: fixture.agent, program: .pi))
        try await Self.until("the picked conversation") {
            await chat.step()
            return chat.conversation.phase == .following(path: path)
        }
        let id = UUID()
        chat.updateSends([.init(id: id, text: "this never arrives", isDelivered: false, mayNotHaveGone: false)])
        chat.updateSends([.init(id: id, text: "this never arrives", isDelivered: true, mayNotHaveGone: false)])

        for (sequence, state, status) in [(5, "working", AgentStatus.working), (6, "idle", .idle)] {
            let line = JSONValue.object([
                "jsonrpc": .string("2.0"), "method": .string("event"),
                "params": .object([
                    "seq": .number(Double(sequence)), "type": .string("status"), "terminal": .string("t1"),
                    "data": .object([
                        "status": .object(["state": .string(state), "app": .string("pi")]),
                        "records": .object([:]), "reported": .bool(true),
                    ]),
                ]),
            ])
            try await fixture.scripted.deliverEvent(try JSONEncoder().encode(line))
            try await Self.until("the Agent's status") { [console = fixture.console] in
                console.agents.first?.agent.status == status
            }
        }
        await chat.step()

        #expect(chat.conversation.phase == .unavailable(.cannotTellSessionOnWindows(.pi)))
        #expect(!chat.offersCandidates)
        chat.end()
        fixture.finish()
    }

    // MARK: Reading the Transcript over real SFTP

    /// `ScriptedCoreHost` answers file calls itself, so this is what lets the real
    /// connection read a Transcript on Windows at all (ADR 0034). A Herdr TUI Host
    /// offers no Chat there.
    @Test func theRealTransportsChatFileGateOpensOnWindowsForACoreHostAlone() async throws {
        func transport(_ kind: ServerKind) -> HeelerSSHTransport {
            var settings = SSHTransportSettings(
                host: "win.example", port: 22, username: "me", credentials: .password("unused"),
                hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false },
                socket: .absolutePath("/never/opened"))
            settings.serverKind = kind
            return HeelerSSHTransport(
                connection: .neverConnectedForTesting(serverIdentification: "SSH-2.0-OpenSSH_for_Windows_9.5"),
                settings: settings, routeID: nil)
        }

        try await transport(.herdrCore).requireChatFileHost()
        await #expect(
            throws: TransportError.hostFeatureUnavailable(feature: "Chat is not yet supported on native Windows")
        ) {
            try await transport(.herdrTUI).requireChatFileHost()
        }
    }

    // MARK: Writing the extension

    private static let bundlePath = HerdrCoreWindowsExtensions.bundlePath

    @Test func writingTheExtensionGoesOnlyToEachProgramsOwnFolder() async throws {
        let fixture = try await Fixture(terminal: Self.record(program: "pi", app: "pi"), image: "pi.exe")
        for name in ["work", "default", "UPPER", "ok.name", ".hidden"] {
            await fixture.files.makeDirectory("\(Self.home)/.omp/profiles/\(name)")
        }
        await fixture.files.write(Data("x".utf8), at: "\(Self.home)/.omp/profiles/afile")
        let flow = fixture.console.windowsExtensionFlow(for: fixture.agent.id)

        await flow.load()

        let folders = [
            #"C:\Users\me\.pi\agent\extensions"#,
            #"C:\Users\me\.omp\agent\extensions"#,
            #"C:\Users\me\.omp\profiles\ok.name\agent\extensions"#,
            #"C:\Users\me\.omp\profiles\work\agent\extensions"#,
        ]
        #expect(flow.phase == .ready(folders: folders))
        #expect(await fixture.scripted.fileWrites.isEmpty)

        await flow.confirm()

        #expect(flow.phase == .written(folders: folders))
        let writes = await fixture.scripted.fileWrites
        #expect(writes.map(\.path) == folders.map { $0 + #"\heeler-session.js"# })
        let shipped = try #require(try HostHelperBundle.load().files[Self.bundlePath])
        for write in writes { #expect(write.contents == shipped) }
        fixture.finish()
    }

    @Test func aHostWithNoOhMyPiProfilesGetsTheTwoFolders() async throws {
        let fixture = try await Fixture(terminal: Self.record(program: "omp", app: "omp"), image: "omp.exe")
        let flow = fixture.console.windowsExtensionFlow(for: fixture.agent.id)
        await flow.load()
        #expect(
            flow.phase
                == .ready(folders: [#"C:\Users\me\.pi\agent\extensions"#, #"C:\Users\me\.omp\agent\extensions"#]))
        fixture.finish()
    }

    @Test func aDetailOnAnotherCoreWritesNothing() async throws {
        let fixture = try await Fixture(terminal: Self.record(program: "pi", app: "pi"), image: "pi.exe")
        let flow = fixture.console.windowsExtensionFlow(
            for: fixture.agent.id, keepingTo: TerminalCorePin(joined: "another"))

        await flow.load()
        guard case .failed = flow.phase else {
            Issue.record("Expected a refusal, got \(flow.phase)")
            fixture.finish()
            return
        }
        await flow.confirm()
        #expect(await fixture.scripted.fileWrites.isEmpty)
        fixture.finish()
    }

    @Test func aRefusedWriteStopsAndSaysSo() async throws {
        let fixture = try await Fixture(terminal: Self.record(program: "pi", app: "pi"), image: "pi.exe")
        await fixture.scripted.setFileWriteRefusal("internal")
        let flow = fixture.console.windowsExtensionFlow(for: fixture.agent.id)
        await flow.load()
        await flow.confirm()
        guard case .failed = flow.phase else {
            Issue.record("Expected a failure, got \(flow.phase)")
            fixture.finish()
            return
        }
        #expect(await fixture.scripted.fileWrites.count == 1)
        fixture.finish()
    }

    @Test func theOfferShowsOnlyForPiAndOhMyPi() {
        #expect(ChatUnavailableReason.cannotTellSessionOnWindows(.pi).offersWindowsExtension)
        #expect(ChatUnavailableReason.cannotTellSessionOnWindows(.omp).offersWindowsExtension)
        #expect(!ChatUnavailableReason.cannotTellSessionOnWindows(.claude).offersWindowsExtension)
        #expect(!ChatUnavailableReason.cannotTellSessionOnWindows(.grok).offersWindowsExtension)
        #expect(!ChatUnavailableReason.cannotTellSession(.pi).offersWindowsExtension)
    }

    @Test func theUnavailableStateShowsTheOfferAsRendered() async throws {
        let shown = try await labels(
            of: ChatUnavailableView(
                reason: .cannotTellSessionOnWindows(.pi), retry: {}, showAgentTerminal: {}, addExtension: {}),
            showing: "Add Heeler's Extension")
        #expect(shown.contains { $0.contains("Add Heeler's Extension") }, "\(shown)")
        #expect(!shown.contains { $0.localizedCaseInsensitiveContains("helper") }, "\(shown)")
    }

    private func labels<Content: View>(of view: Content, showing text: String) async throws -> [String] {
        let controller = UIHostingController(rootView: view)
        var found: [String] = []
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            let deadline = ContinuousClock.now + .seconds(5)
            repeat {
                found = AccessibilityProbe.labels(in: controller.view)
                if found.contains(where: { $0.contains(text) }) { return }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
        }
        return found
    }

    // MARK: Send, Stop and Blocked answers

    private static let pasteOfHello = "\u{1B}[200~hello \u{1B}[201~"

    @Test func chatsSendInTheHeelerFormPastesThenSubmits() async throws {
        let fixture = try await Fixture()
        let composer = fixture.console.composerStore(for: fixture.agent)
        composer.open()
        composer.replaceDraft(with: "hello")
        let policy = fixture.policy
        let sending = Task { await composer.send(policy: policy) }

        let viewer = try await fixture.viewer()
        await viewer.socket.waitForData(channel: viewer.channel, count: 1)
        await fixture.clock.untilParked(for: HerdrCoreComposerSend.sampleDelay)
        fixture.clock.advance(HerdrCoreComposerSend.sampleDelay)
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(with: Self.record())

        #expect(await sending.value == .submittedViaAttach)
        let written = await viewer.socket.dataWritten(channel: viewer.channel)
        #expect(written == [Self.pasteOfHello, "\r"])
        fixture.finish()
    }

    @Test(arguments: [
        ["-NoExit", "-Command", "& 'claude'"],
        ["-NoExit", "-Command", "& 'claude'; exit $LASTEXITCODE"],
    ])
    func chatsSendTypesNothingIntoAPowerShellThatCanOutliveItsProgram(arguments: [String]) async throws {
        let fixture = try await Fixture(terminal: Self.record(arguments: arguments))
        let composer = fixture.console.composerStore(for: fixture.agent)
        composer.open()
        composer.replaceDraft(with: "hello")

        let result = await composer.send(policy: fixture.policy)

        guard case .refused(.inputNotReady) = result else {
            Issue.record("Expected a refusal, got \(result)")
            fixture.finish()
            return
        }
        #expect(composer.draft == "hello")
        let viewers = await fixture.scripted.attaches.filter { $0.params["resumed"] == .bool(true) }
        for viewer in viewers { #expect(await viewer.socket.dataWritten(channel: viewer.channel).isEmpty) }
        fixture.finish()
    }

    @Test func chatsStopPressesEsc() async throws {
        let fixture = try await Fixture()
        let console = fixture.console
        let hostID = fixture.host.id
        let keys = ChatAgentKeysStore { try await console.sendAgentKeys($0, to: "t1", on: hostID) }
        let interrupt = console.chatStopPlan(for: fixture.agent, program: .claude).composerInterrupt(
            context: {
                ChatStopContext(screen: try await console.readAgentScreen("t1", on: hostID), activity: .working)
            },
            agentKeys: keys)

        #expect(await interrupt.perform() == .sent)

        let viewer = try await fixture.viewer()
        #expect(await viewer.socket.dataWritten(channel: viewer.channel) == ["\u{1B}"])
        fixture.finish()
    }

    @Test func aBlockedAnswerGoesOverItsDialog() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), screen: Self.dialogScreen)
        let chat = try fixture.chat()
        chat.blocked.update(activity: .blocked)
        await chat.blocked.refresh()
        guard case .card = chat.blocked.content else {
            Issue.record("Expected a card, got \(chat.blocked.content)")
            fixture.finish()
            return
        }

        let card = chat.blocked
        let answering = Task { await card.perform(.choose(ordinal: 1)) }
        let viewer = try await fixture.viewer()
        await viewer.socket.waitForData(channel: viewer.channel, count: 1)
        await fixture.scripted.setAttachPaint(try Self.paint(Self.readyScreen))
        await answering.value

        #expect(await viewer.socket.dataWritten(channel: viewer.channel) == ["1"])
        #expect(card.notice == nil)
        fixture.finish()
    }
}
