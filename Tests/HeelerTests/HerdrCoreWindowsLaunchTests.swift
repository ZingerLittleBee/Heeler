import Foundation
import Testing

@testable import Heeler

/// New Agent, New Terminal and New Workspace on a native Windows core Host,
/// through `ConsoleStore` and the real `HerdrCoreSSHTransport`, with the exec and
/// the core scripted. No PowerShell ran any of this: the forms are the ones
/// recorded in ADR 0032 and the herdr compatibility notes.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreWindowsLaunchTests {
    private static let uuid = #/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/#
    private static let openCodeID = #/^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$/#
    private static let spaceID = #/^sp[0-9a-f]{32}$/#
    private static let tabID = #/^tb[0-9a-f]{32}$/#
    private static let exit = "; exit $LASTEXITCODE"
    private static let derivedDirectory = #"C:\Users\me\src\api"#
    private static let spaceDirectory = #"D:\work\web"#
    private static let powerShellPath = #"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe"#

    private let host = Host(address: "win.example", username: "me", serverKind: .herdrCore)

    private static func record(
        _ address: String, cwd: String, labels: [String: String] = [:],
        argv: [String] = [#"C:\Windows\System32\cmd.exe"#], keep: Bool = false
    ) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string(cwd), "state": .string("live"),
            "argv": .array(argv.map(JSONValue.string)), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(7), "keep": .bool(keep),
            "labels": .object(labels.mapValues(JSONValue.string)),
        ])
    }

    private static func eventLine(sequence: Int, type: String, terminal: String, data: JSONValue) throws -> Data {
        try JSONEncoder().encode(
            JSONValue.object([
                "jsonrpc": .string("2.0"), "method": .string("event"),
                "params": .object([
                    "seq": .number(Double(sequence)), "type": .string(type),
                    "terminal": .string(terminal), "data": data,
                ]),
            ]))
    }

    /// One Terminal in a derived Workspace and one labeled into a space no document
    /// lists. The core answers each `terminal.run` with `t101` at the asked directory.
    @MainActor
    private final class Fixture {
        let scripted: ScriptedCoreHost
        let store: ConsoleStore
        let host: Host

        init(host: Host) async throws {
            self.host = host
            let scripted = ScriptedCoreHost(
                windowsLocator: ScriptedCoreHost.windowsLocatorLines(),
                channel: .core(
                    .init(terminals: [
                        HerdrCoreWindowsLaunchTests.record("t1", cwd: HerdrCoreWindowsLaunchTests.derivedDirectory),
                        HerdrCoreWindowsLaunchTests.record(
                            "t2", cwd: HerdrCoreWindowsLaunchTests.spaceDirectory,
                            labels: ["herdr.space": "s1", "herdr.tab": "tb1"]),
                    ])))
            self.scripted = scripted
            store = ConsoleStore(
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
                        }, keepalive: nil)
                },
                coreHostMemory: HerdrCoreHostMemory(
                    defaults: UserDefaults(suiteName: "core-windows-launch-\(UUID().uuidString)") ?? .standard))
            store.setHosts([host])
            await store.resume()
            try await until("the first snapshot") { !self.store.hostsAwaitingSnapshot.contains(host.id) }
            try await until("the kernel") {
                self.store.hostCoreKernels[host.id] == HerdrCoreLocator.windowsKernel
            }
        }

        func until(
            _ what: String, _ condition: @MainActor () async -> Bool,
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            var budget = PollBudget(.seconds(5))
            while budget.hasTimeLeft {
                if await condition() { return }
                try await Task.sleep(for: .milliseconds(10))
                budget.charge()
            }
            Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
        }

        var derived: String { HerdrCoreOrganization.workspaceID(directory: HerdrCoreWindowsLaunchTests.derivedDirectory) }

        /// Answers the next `terminal.run` as a core does, with the launch's own words.
        func answerRun(argv: [String], cwd: String, labels: [String: String] = [:]) async {
            await scripted.setRunReply(
                HerdrCoreWindowsLaunchTests.record("t101", cwd: cwd, labels: labels, argv: argv, keep: true))
        }

        /// The params of the one launch it runs. The core answers with the launch's form.
        func launch(
            _ kind: SupportedAgentKind, arguments: [String] = [], workspaceID: String? = nil
        ) async throws -> JSONValue {
            await answerRun(
                argv: HerdrCoreWindowsLaunchTests.launchForm(kind.executable),
                cwd: HerdrCoreWindowsLaunchTests.derivedDirectory)
            _ = try await store.startAgent(
                AgentLaunchRequest(
                    kind: kind.rawValue, name: kind.rawValue, arguments: arguments,
                    workspaceID: workspaceID ?? derived),
                on: host.id)
            return try #require(await scripted.runs.last)
        }

        func startAgentForm() -> StartAgentStore {
            let store = store
            return StartAgentStore(
                hosts: [host],
                workspaces: { store.workspaces(for: $0) },
                existingAgentNames: { store.takenAgentNames(on: $0) },
                discoverAgentKinds: { try await store.availableAgentKinds(on: $0) },
                discoverTemplates: { try await store.availableTemplates(on: $0) },
                startTemplate: { try await store.startTemplate($0, on: $1) },
                remoteHome: { try await store.remoteHomeDirectory(on: $0) },
                start: { params, destination, hostID in
                    switch destination {
                    case .existingWorkspace: try await store.startAgent(params, on: hostID)
                    case .newWorktree(let worktree):
                        try await store.startAgentInNewWorktree(params, worktree: worktree, on: hostID)
                    case .newWorkspace(let workspace):
                        try await store.startAgentInNewWorkspace(params, workspace: workspace, on: hostID)
                    }
                },
                awaitAgentVisible: { await store.waitForAgent($0, timeout: .seconds(2)) },
                isAgentListed: { id in store.agents.contains { $0.id == id } },
                programExit: { store.programExit(of: $0) },
                recents: RecentLaunchStore(
                    defaults: UserDefaults(suiteName: "windows-launch-\(UUID())") ?? .standard),
                offersDesktopAppNames: { store.capabilities(for: $0).namesNewWorkspaces },
                offersConnectedWorktrees: { store.capabilities(for: $0).worktrees })
        }

        func finish() async {
            store.setHosts([])
            await store.suspend()
        }
    }

    private static func launchForm(_ program: String) -> [String] {
        ["powershell.exe", "-Command", "& '\(program)'\(exit)"]
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap(\.stringValue)
    }

    private static func stringFields(_ value: JSONValue?) -> [String: String] {
        guard case .object(let fields)? = value else { return [:] }
        return fields.compactMapValues(\.stringValue)
    }

    // MARK: The launch form

    /// The expected lines are written out by hand, as PowerShell's grammar reads them.
    @Test(arguments: [
        (["fix it"], "& 'omp' 'fix it'"),
        (["it's"], "& 'omp' 'it''s'"),
        (["修复 bug", "é"], "& 'omp' '修复 bug' 'é'"),
        (["\u{2018}a\u{2019}"], "& 'omp' '\u{2018}\u{2018}a\u{2019}\u{2019}'"),
        (["$HOME", "`id`", "a;b", "\"q\""], "& 'omp' '$HOME' '`id`' 'a;b' '\"q\"'"),
        ([], "& 'omp'"),
    ])
    func aWindowsLaunchIsThePowerShellFormWithEachWordQuoted(arguments: [String], line: String) async throws {
        let fixture = try await Fixture(host: host)

        let params = try await fixture.launch(.omp, arguments: arguments)

        #expect(Self.strings(params["argv"]) == ["powershell.exe", "-Command", line + Self.exit])
        #expect(params["keep"] == .bool(true))
        #expect(params["name"]?.stringValue == "omp")
        await fixture.finish()
    }

    @Test(arguments: [
        (SupportedAgentKind.claude, "--session-id", ["CLAUDE_CODE_CHILD_SESSION": "", "CLAUDE_CODE_SKIP_PROMPT_HISTORY": ""]),
        (SupportedAgentKind.pi, "--session-id", [:]),
        (SupportedAgentKind.grok, "-s", ["TMUX": "", "STY": "", "ZELLIJ": ""]),
    ])
    func aWindowsLaunchCarriesTheSessionFlagBlanksAndHintOfTheUnixOne(
        kind: SupportedAgentKind, flag: String, blanks: [String: String]
    ) async throws {
        let fixture = try await Fixture(host: host)

        let params = try await fixture.launch(kind)

        let line = try #require(Self.strings(params["argv"]).last)
        let match = try #require(line.wholeMatch(of: #/& '(?<program>[^']+)' '(?<flag>[^']+)' '(?<id>[^']+)'; exit \$LASTEXITCODE/#))
        #expect(match.output.program == kind.executable)
        #expect(match.output.flag == flag)
        #expect(String(match.output.id).wholeMatch(of: Self.uuid) != nil)
        #expect(Self.stringFields(params["env"]) == blanks)
        #expect(Self.stringFields(params["env"])["PATH"] == nil)
        #expect(Self.stringFields(params["labels"]) == [HerdrCoreLaunch.sessionHintLabel: String(match.output.id)])
        await fixture.finish()
    }

    @Test func codexRunsEmbeddedWithNoVariablesAndNoPath() async throws {
        let fixture = try await Fixture(host: host)

        let params = try await fixture.launch(.codex)

        #expect(
            Self.strings(params["argv"])
                == ["powershell.exe", "-Command", "& 'codex' '--no-daemon'" + Self.exit])
        #expect(params["env"] == nil)
        await fixture.finish()
    }

    /// The Windows probe reports no login shell, and no process read works there.
    @Test func theShellComesWithoutAProcessRead() async throws {
        let fixture = try await Fixture(host: host)

        _ = try await fixture.launch(.omp)

        #expect(await !fixture.scripted.log.contains("process-read"))
        await fixture.finish()
    }

    // MARK: Where it lands

    @Test func aLaunchInADesktopSpaceCarriesItsSpaceAndANewTab() async throws {
        let fixture = try await Fixture(host: host)

        let first = try await fixture.launch(.omp, workspaceID: "space-s1")
        let second = try await fixture.launch(.omp, workspaceID: "space-s1")

        let labels = Self.stringFields(first["labels"])
        #expect(labels["herdr.space"] == "s1")
        let tab = try #require(labels["herdr.tab"])
        #expect(tab.wholeMatch(of: Self.tabID) != nil)
        #expect(Self.stringFields(second["labels"])["herdr.tab"] != tab)
        #expect(first["cwd"]?.stringValue == Self.spaceDirectory)
        await fixture.finish()
    }

    @Test func aLaunchInADerivedWorkspaceHasNoDesktopLabelsAndStartsInItsWindowsKeyDirectory() async throws {
        let fixture = try await Fixture(host: host)

        let params = try await fixture.launch(.omp)

        #expect(params["cwd"]?.stringValue == Self.derivedDirectory)
        #expect(params["labels"] == nil)
        await fixture.finish()
    }

    // MARK: The foreground

    /// Where a foreground event says the program is, which tells that it has landed.
    private static let sampledDirectory = #"C:\Users\me\src\api\sampled"#

    /// One event for the Terminal's whole life, with PowerShell's pid, its absolute
    /// path and the launch's arguments, never the child (herdr compatibility).
    private static func recordedForeground(_ line: String) -> JSONValue {
        .object([
            "pid": .number(7), "name": .string("powershell.exe"),
            "argv": .array([.string(powerShellPath), .string("-Command"), .string(line)]),
            "cwd": .string(sampledDirectory),
        ])
    }

    @Test(arguments: [
        (SupportedAgentKind.claude, "claude"), (.codex, "codex"), (.cursor, "cursor"), (.grok, "grok"),
    ])
    func theRecordedForegroundShowsTheAgentOfItsKindUntilTheTerminalFinishes(
        kind: SupportedAgentKind, shown: String
    ) async throws {
        let fixture = try await Fixture(host: host)
        let params = try await fixture.launch(kind, arguments: ["it's 修复"])
        let line = try #require(Self.strings(params["argv"]).last)
        // With no sample yet the launch stands in.
        try await fixture.until("the Agent from its launch") {
            fixture.store.agents.contains { $0.agent.paneID == "t101" }
        }

        try await fixture.scripted.deliverEvent(
            Self.eventLine(
                sequence: 1, type: "foreground", terminal: "t101", data: Self.recordedForeground(line)))
        try await fixture.until("the Agent from its foreground") {
            fixture.store.agents.first { $0.agent.paneID == "t101" }?.agent.foregroundCwd == Self.sampledDirectory
        }
        let agent = try #require(fixture.store.agents.first { $0.agent.paneID == "t101" })
        #expect(agent.agent.kind == shown)

        try await fixture.scripted.deliverEvent(
            Self.eventLine(
                sequence: 2, type: "finished", terminal: "t101",
                data: .object([
                    "exit_code": .number(2), "finished_ms": .number(5), "reason": .string("exited"),
                    "signal": .null,
                ])))
        try await fixture.until("the Terminal to end") {
            !fixture.store.terminals.contains { $0.paneID == "t101" }
        }
        #expect(!fixture.store.agents.contains { $0.agent.paneID == "t101" })
        await fixture.finish()
    }

    /// A New Terminal's PowerShell is a shell, and no Agent.
    @Test func aPowerShellPromptInTheForegroundIsNoAgent() async throws {
        let fixture = try await Fixture(host: host)
        await fixture.answerRun(argv: ["powershell.exe"], cwd: Self.derivedDirectory)
        _ = try await fixture.store.createShellTerminal(
            ShellTerminalCreationRequest(workspaceID: fixture.derived, cwd: Self.derivedDirectory), on: host.id)

        try await fixture.scripted.deliverEvent(
            Self.eventLine(
                sequence: 1, type: "foreground", terminal: "t101",
                data: .object([
                    "pid": .number(7), "name": .string("powershell.exe"),
                    "argv": .array([.string(Self.powerShellPath)]), "cwd": .string(Self.sampledDirectory),
                ])))
        try await fixture.until("the foreground") {
            fixture.store.terminals.first { $0.paneID == "t101" }?.pane.foregroundCwd == Self.sampledDirectory
        }

        #expect(!fixture.store.agents.contains { $0.agent.paneID == "t101" })
        await fixture.finish()
    }

    // MARK: New Terminal

    @Test func aNewTerminalBesideOneOpensKeptInItsWindowsDirectoryWithNoProgram() async throws {
        let fixture = try await Fixture(host: host)
        await fixture.answerRun(argv: [#"C:\Windows\System32\cmd.exe"#], cwd: Self.derivedDirectory)
        let request = try #require(
            fixture.store.capabilities(for: host.id)
                .newTerminalRequest(workspaceID: fixture.derived, cwd: Self.derivedDirectory))

        let identity = try await fixture.store.createShellTerminal(request, on: host.id)

        let params = try #require(await fixture.scripted.runs.last)
        #expect(params["argv"] == nil)
        #expect(params["keep"] == .bool(true))
        #expect(params["cwd"]?.stringValue == Self.derivedDirectory)
        #expect(params["labels"] == nil)
        #expect(identity.terminalID == "t101")
        await fixture.finish()
    }

    @Test func aNewTerminalInADesktopSpaceCarriesItsSpaceAndANewTab() async throws {
        let fixture = try await Fixture(host: host)
        await fixture.answerRun(argv: [#"C:\Windows\System32\cmd.exe"#], cwd: Self.spaceDirectory)

        _ = try await fixture.store.createShellTerminal(
            ShellTerminalCreationRequest(workspaceID: "space-s1", cwd: Self.spaceDirectory), on: host.id)

        let params = try #require(await fixture.scripted.runs.last)
        let labels = Self.stringFields(params["labels"])
        #expect(labels["herdr.space"] == "s1")
        #expect(labels["herdr.tab"]?.wholeMatch(of: Self.tabID) != nil)
        await fixture.finish()
    }

    /// Open Terminal from an Agent, and the row's own New Terminal, read the same path.
    @Test func anAgentsWindowsDirectoryIsWhereItsOpenTerminalStarts() async throws {
        let fixture = try await Fixture(host: host)

        _ = try await fixture.launch(.claude)
        try await fixture.until("the Agent") {
            fixture.store.agents.contains { $0.agent.paneID == "t101" }
        }

        let agent = try #require(fixture.store.agents.first { $0.agent.paneID == "t101" })
        #expect(
            agent.shellTerminalCreationRequest
                == ShellTerminalCreationRequest(workspaceID: fixture.derived, cwd: Self.derivedDirectory))
        await fixture.finish()
    }

    /// The Terminals tab's card takes its New Terminal from the same directory.
    @Test func aWorkspaceCardsNewTerminalStartsInItsWindowsDirectory() async throws {
        let fixture = try await Fixture(host: host)
        let list = TerminalListPresentationStore(
            defaults: UserDefaults(suiteName: "windows-list-\(UUID())") ?? .standard)

        let projection = list.projection(hosts: [host], console: fixture.store)

        let card = try #require(projection.workspaces().first { $0.workspaceID == fixture.derived })
        #expect(card.directory == Self.derivedDirectory)
        await fixture.finish()
    }

    // MARK: Discovery

    /// The profile a launch's `-Command` loads has to run here too, or the two find
    /// different programs. The command fits `cmd.exe`'s line under the default shell.
    @Test func discoveryRunsThroughPowerShellWithItsProfileAndFeedsTheLaunch() async throws {
        let fixture = try await Fixture(host: host)
        await fixture.scripted.setWindowsAgentDiscovery(
            programs: ["cursor-agent", "opencode", "claude"], version: "opencode v2.2.2")
        let form = fixture.startAgentForm()

        await form.discoverAgents()

        #expect(form.agentDiscoveryState == .loaded)
        #expect(form.availableAgentKinds == [.claude, .cursor, .opencode])
        let command = try #require(await fixture.scripted.windowsDiscoveryCommands.first)
        #expect(command.hasPrefix("powershell.exe -NoLogo -NonInteractive -EncodedCommand "))
        #expect(command.utf8.count < 8191)
        let script = try ScriptedCoreHost.decodedDiscovery(command)
        #expect(script.contains("Get-Command"))
        #expect(script.contains("'opencode' --version"))
        for kind in SupportedAgentKind.allCases { #expect(script.contains("'\(kind.executable)'")) }

        form.selectedAgentKind = .opencode
        await fixture.answerRun(argv: Self.launchForm("opencode"), cwd: Self.derivedDirectory)
        await form.submit()

        let line = try #require(Self.strings(await fixture.scripted.runs.last?["argv"]).last)
        let id = try #require(line.wholeMatch(of: #/& 'opencode' '-s' '(?<id>[^']+)'; exit \$LASTEXITCODE/#)?.output.id)
        #expect(String(id).wholeMatch(of: Self.openCodeID) != nil)
        await fixture.finish()
    }

    /// An exec can refuse to run a program a Terminal runs (herdr compatibility), so a
    /// version that did not come is no word on whether OpenCode is there.
    @Test func anOpenCodeTheExecCannotRunIsStillListedAndStartsWithoutItsID() async throws {
        let fixture = try await Fixture(host: host)
        await fixture.scripted.setWindowsAgentDiscovery(programs: ["opencode"], version: "")
        let form = fixture.startAgentForm()

        await form.discoverAgents()

        #expect(form.availableAgentKinds == [.opencode])
        await fixture.answerRun(argv: Self.launchForm("opencode"), cwd: Self.derivedDirectory)
        await form.submit()

        #expect(
            Self.strings(await fixture.scripted.runs.last?["argv"])
                == ["powershell.exe", "-Command", "& 'opencode'" + Self.exit])
        await fixture.finish()
    }

    @Test func aProfileThatPrintsDoesNotReachTheAnswer() async throws {
        let fixture = try await Fixture(host: host)
        await fixture.scripted.setWindowsAgentDiscovery(
            programs: ["codex"], version: "", banner: "Loading profile...\r\nagent claude\r\n")

        let kinds = try await fixture.store.availableAgentKinds(on: host.id)

        #expect(kinds == [.codex])
        await fixture.finish()
    }

    @Test func aDiscoveryCutShortSaysSo() async throws {
        let fixture = try await Fixture(host: host)
        await fixture.scripted.setWindowsDiscoveryAnswer(
            GitExecResult(stdout: Data("Loading profile...\r\n".utf8), stderr: Data(), exitStatus: 0))

        await #expect(throws: TransportError.self) {
            try await fixture.store.availableAgentKinds(on: host.id)
        }
        await fixture.finish()
    }

    // MARK: New Workspace

    @Test func newWorkspaceCreatesADesktopSpaceAtThePickedWindowsDirectoryWithNoNameField() async throws {
        let fixture = try await Fixture(host: host)
        await fixture.scripted.setWindowsAgentDiscovery(programs: ["codex"], version: "")
        // Even an app that answers: Rename and a typed name stay off on Windows.
        await fixture.scripted.setHerdrAppAnswer(
            .success(GitExecResult(stdout: Data(), stderr: Data(), exitStatus: 0)))
        let form = fixture.startAgentForm()
        await form.discoverAgents()
        let picked = #"C:\Users\me\new project"#

        form.applyBrowsedDirectory(picked)
        #expect(form.launchTarget == .newWorkspace)
        #expect(!form.offersWorkspaceName)
        #expect(!form.offersWorkspaceAndTabNames)
        #expect(!form.offersWorktree)
        let labels = ["herdr.space": "sp0", "herdr.tab": "tb0"]
        await fixture.answerRun(argv: Self.launchForm("codex"), cwd: picked, labels: labels)
        await form.submit()

        let params = try #require(await fixture.scripted.runs.last)
        #expect(params["cwd"]?.stringValue == picked)
        let sent = Self.stringFields(params["labels"])
        #expect(sent["herdr.space"]?.wholeMatch(of: Self.spaceID) != nil)
        #expect(sent["herdr.tab"]?.wholeMatch(of: Self.tabID) != nil)
        #expect(await fixture.scripted.methods.contains("doc.set") == false)

        let offers = fixture.store.capabilities(for: host.id)
        #expect(!offers.renameWorkspace(id: "space-s1"))
        #expect(!offers.namesNewWorkspaces)
        #expect(await !fixture.scripted.log.contains("herdr-app"))
        await fixture.finish()
    }

    @Test func newTerminalOffersNoNameFieldThereEither() async throws {
        let fixture = try await Fixture(host: host)
        let store = fixture.store
        let form = NewTerminalStore(
            hosts: [host], workspaces: { store.workspaces(for: $0) }, directory: { _, _ in nil },
            remoteHome: { try await store.remoteHomeDirectory(on: $0) },
            create: { _, _ in ShellTerminalIdentity(paneID: "", tabID: "", terminalID: "") },
            awaitTerminal: { _, _ in nil },
            offersDesktopAppNames: { store.capabilities(for: $0).namesNewWorkspaces })

        #expect(!form.offersWorkspaceAndTabNames)
        #expect(!form.offersWorkspaceName)
        await fixture.finish()
    }

    /// Chat's home read refuses native Windows, and the probe has already said.
    @Test func aNewWorkspaceWithNoDirectoryStartsInTheHomeTheProbeFound() async throws {
        let fixture = try await Fixture(host: host)
        await fixture.scripted.setWindowsAgentDiscovery(programs: ["codex"], version: "")
        let form = fixture.startAgentForm()
        await form.discoverAgents()
        form.selectNewWorkspace()
        await fixture.answerRun(argv: Self.launchForm("codex"), cwd: #"C:\Users\me"#)

        await form.submit()

        #expect(await fixture.scripted.runs.last?["cwd"]?.stringValue == #"C:\Users\me"#)
        #expect(try await fixture.store.remoteHomeDirectory(on: host.id) == #"C:\Users\me"#)
        await fixture.finish()
    }

    /// A Herdr TUI Host on Windows keeps its own answers.
    @Test func aHerdrTUIHostOnWindowsStillOpensNoTerminalAtAWindowsPath() {
        let offers = HostCapabilities(serverKind: .herdrTUI, platform: .nativeWindows)
        #expect(offers.newTerminalRequest(workspaceID: "w", cwd: #"C:\work"#) == nil)
        #expect(!offers.startsIn(#"C:\work"#))
    }

    @Test func aWindowsCoreHostRefusesADirectoryThatIsNotAPath() {
        let offers = HostCapabilities(serverKind: .herdrCore, platform: .nativeWindows)
        #expect(offers.newTerminalRequest(workspaceID: "w", cwd: "relative") == nil)
        #expect(offers.newTerminalRequest(workspaceID: "w", cwd: "") == nil)
        #expect(offers.newTerminalRequest(workspaceID: "w", cwd: #"C:\work"#) != nil)
    }
}
