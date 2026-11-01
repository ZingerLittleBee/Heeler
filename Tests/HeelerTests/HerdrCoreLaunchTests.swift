import Foundation
import Testing
import os

@testable import Heeler

/// New Agent and New Terminal on a core Host, through `ConsoleStore` and the
/// form stores over the scripted core transport: the exact `terminal.run`
/// request, where it lands, and discovery through the interactive shell.
/// `scripts/test-herdr-core-shell-launch.py` runs the argv and the discovery
/// script through real shells.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreLaunchTests {
    private static let zsh = "/usr/bin/zsh"
    private static let fish = "/usr/bin/fish"
    private static let posixBody = "exec \"$@\""
    private static let fishBody = "exec $argv[2..]"
    private static let uuid = #/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/#
    private static let openCodeID = #/^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$/#

    private let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)

    private static func record(
        _ address: String, cwd: String = "/work/app", labels: [String: String] = [:],
        keep: Bool = false, name: String? = nil
    ) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string(cwd), "state": .string("live"),
            "name": name.map(JSONValue.string) ?? .null,
            "argv": .array([.string("/bin/zsh")]), "cols": .number(80), "rows": .number(24),
            "pid": .number(7), "keep": .bool(keep), "labels": .object(labels.mapValues(JSONValue.string)),
        ])
    }

    private static func subscribeResult(_ terminals: [JSONValue]) -> JSONValue {
        .object(["seq": .number(1), "terminals": .array(terminals), "channel": .number(1)])
    }

    private static func event(sequence: Int, type: String, terminal: String, data: JSONValue) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(Double(sequence)), "type": .string(type),
                "terminal": .string(terminal), "data": data,
            ]),
        ]))) ?? Data()
    }

    private static let desktopSpace = CoreDesktopJSON.document([
        CoreDesktopJSON.space(
            "s1", name: "Alpha", folder: "/work/alpha", tabs: [CoreDesktopJSON.tab("tb1", name: "main")])
    ])

    /// A core with one Terminal launched in `/work/app`, one labeled into a
    /// desktop space, and the shell the locator reports.
    @MainActor
    private final class Fixture {
        let transport: ScriptedCoreTransport
        let services: ScriptedCoreServices
        let store: ConsoleStore
        let host: Host

        init(
            host: Host, shell: String? = HerdrCoreLaunchTests.zsh,
            terminals: [JSONValue] = [
                HerdrCoreLaunchTests.record("t1"),
                HerdrCoreLaunchTests.record("t2", cwd: "/work/alpha/sub", labels: ["herdr.space": "s1", "herdr.tab": "tb1"]),
            ],
            listings: [String: RemoteDirectoryListing] = [:]
        ) async throws {
            self.host = host
            let services = ScriptedCoreServices(home: "/home/dev", listings: listings)
            let transport = ScriptedCoreTransport(
                subscribeResults: [HerdrCoreLaunchTests.subscribeResult(terminals)], services: services)
            await transport.setShell(shell)
            await transport.setDocument(HerdrCoreLaunchTests.desktopSpace, version: 1)
            self.services = services
            self.transport = transport
            store = ConsoleStore(
                makeSession: { _, subscriptions in
                    EventsSession(
                        subscriptions: subscriptions,
                        connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                        keepalive: nil)
                },
                makeCoreSession: { _ in
                    HerdrCoreHostSession(connect: { transport }, keepalive: nil)
                },
                coreHostMemory: HerdrCoreHostMemory())
            store.setHosts([host])
            await store.resume()
            try await until("the first snapshot") { !self.store.hostsAwaitingSnapshot.contains(host.id) }
        }

        func until(
            _ what: String, _ condition: @MainActor () async -> Bool,
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            for _ in 0..<500 {
                if await condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
        }

        var derived: String { HerdrCoreOrganization.workspaceID(directory: "/work/app") }

        func startAgent(
            _ kind: SupportedAgentKind, arguments: [String] = [], workspaceID: String? = nil,
            cwd: String? = nil
        ) async throws -> Agent {
            try await store.startAgent(
                AgentLaunchRequest(
                    kind: kind.rawValue, name: kind.rawValue, arguments: arguments,
                    workspaceID: workspaceID ?? derived, cwd: cwd),
                on: host.id)
        }

        /// The params of the one launch it runs.
        func launch(
            _ kind: SupportedAgentKind, arguments: [String] = [], workspaceID: String? = nil
        ) async throws -> JSONValue {
            _ = try await startAgent(kind, arguments: arguments, workspaceID: workspaceID)
            return try #require(await transport.runs.last)
        }

        func startAgentForm(
            existingNames: Set<String> = [], agentWait: Duration = .seconds(5)
        ) -> StartAgentStore {
            let store = store
            return StartAgentStore(
                hosts: [host],
                workspaces: { store.workspaces(for: $0) },
                existingAgentNames: { existingNames.union(store.takenAgentNames(on: $0)) },
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
                awaitAgentVisible: { await store.waitForAgent($0, timeout: agentWait) },
                isAgentListed: { id in store.agents.contains { $0.id == id } },
                programExit: { store.programExit(of: $0) },
                recents: RecentWorkspaceStore(defaults: UserDefaults(suiteName: "launch-\(UUID())") ?? .standard))
        }

        func finish() {
            store.setHosts([])
        }
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap(\.stringValue)
    }

    private static func stringFields(_ value: JSONValue?) -> [String: String]? {
        guard case .object(let fields)? = value else { return nil }
        return fields.compactMapValues(\.stringValue)
    }

    /// The agent's own words, after the wrapper and its `$0`.
    private static func program(of params: JSONValue) -> [String] {
        Array(strings(params["argv"]).dropFirst(4))
    }

    private static func labels(of params: JSONValue) -> [String: String] {
        stringFields(params["labels"]) ?? [:]
    }

    private static func environment(of params: JSONValue) -> [String: String]? {
        stringFields(params["env"])
    }

    // MARK: The launch form

    @Test(arguments: [
        (SupportedAgentKind.claude, "claude", ["CLAUDE_CODE_CHILD_SESSION": "", "CLAUDE_CODE_SKIP_PROMPT_HISTORY": ""]),
        (SupportedAgentKind.grok, "grok", ["TMUX": "", "STY": "", "ZELLIJ": ""]),
        (SupportedAgentKind.codex, "codex", [:]),
        (SupportedAgentKind.pi, "pi", [:]),
        (SupportedAgentKind.omp, "omp", [:]),
        (SupportedAgentKind.cursor, "cursor-agent", [:]),
    ])
    func aLaunchExecsTheProgramThroughALoginShellKeptWithItsBlanksAndNoPath(
        kind: SupportedAgentKind, executable: String, blanks: [String: String]
    ) async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        let params = try await fixture.launch(kind)

        let argv = Self.strings(params["argv"])
        #expect(Array(argv.prefix(4)) == [Self.zsh, "-ic", Self.posixBody, Self.zsh])
        #expect(argv[4] == executable)
        #expect(params["keep"] == .bool(true))
        #expect(params["name"]?.stringValue == kind.rawValue)
        #expect(params["line"] == nil)
        #expect((Self.environment(of: params) ?? [:]) == blanks)
        #expect(Self.environment(of: params)?["PATH"] == nil)
    }

    @Test func aFishLoginShellGetsFishsForm() async throws {
        let fixture = try await Fixture(host: host, shell: Self.fish)
        defer { fixture.finish() }

        let params = try await fixture.launch(.codex)

        #expect(
            Self.strings(params["argv"])
                == [Self.fish, "-ic", Self.fishBody, "fish", "codex", "--no-daemon"])
        #expect(params["keep"] == .bool(true))
    }

    @Test func noReportedShellStartsNothing() async throws {
        let fixture = try await Fixture(host: host, shell: nil)
        defer { fixture.finish() }

        await #expect(throws: TransportError.self) { try await fixture.startAgent(.claude) }

        #expect(await fixture.transport.runs.isEmpty)
    }

    @Test func argumentsWithSpacesQuotesAndDollarsStaySeparateArgvEntries() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        let hostile = ["--model", "gpt 5", "it's", "\"quoted\"", "$HOME", "`id`", "", "a;b"]

        let params = try await fixture.launch(.omp, arguments: hostile)

        #expect(Self.strings(params["argv"])[2] == Self.posixBody)
        #expect(Self.program(of: params) == ["omp"] + hostile)
    }

    @Test func theFormParsesArgumentsIntoTheSameSeparateEntries() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setDiscovery(programs: ["omp"])
        let form = fixture.startAgentForm()
        await form.discoverAgents()
        form.arguments = #"--model "gpt 5" '$HOME'"#

        await form.submit()

        let params = try #require(await fixture.transport.runs.last)
        #expect(Self.program(of: params) == ["omp", "--model", "gpt 5", "$HOME"])
    }

    // MARK: The session from the start

    @Test func claudeCodeAndPiCarryAGeneratedSessionIDWrittenAsAHint() async throws {
        for kind in [SupportedAgentKind.claude, .pi] {
            let fixture = try await Fixture(host: host)
            defer { fixture.finish() }

            let params = try await fixture.launch(kind)

            let program = Self.program(of: params)
            #expect(program.count == 3)
            #expect(program[1] == "--session-id")
            #expect(program[2].wholeMatch(of: Self.uuid) != nil)
            #expect(Self.labels(of: params) == [HerdrCoreLaunch.sessionHintLabel: program[2]])
        }
    }

    @Test func grokBuildCarriesItsSessionIDWithDashS() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        let params = try await fixture.launch(.grok)

        let program = Self.program(of: params)
        #expect(program.count == 3)
        #expect(program[1] == "-s")
        #expect(program[2].wholeMatch(of: Self.uuid) != nil)
        #expect(Self.labels(of: params) == [HerdrCoreLaunch.sessionHintLabel: program[2]])
    }

    @Test func codexRunsEmbeddedWithNoIDAndOhMyPiWithNoFlag() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        let codex = try await fixture.launch(.codex)
        #expect(Self.program(of: codex) == ["codex", "--no-daemon"])
        #expect(Self.labels(of: codex).isEmpty)

        let omp = try await fixture.launch(.omp)
        #expect(Self.program(of: omp) == ["omp"])
        #expect(Self.labels(of: omp).isEmpty)
    }

    @Test(arguments: [
        ("2.2.2", true), ("opencode v2.2.2", true), ("v2.1.0-beta.1", true), ("2.1", true), ("3.0.0", true),
        ("1.19.5", false), ("2.0.32", false), ("opencode v2.0.32", false), ("0.0.0-main-2025", false),
        ("", false), ("not a version", false), ("2", false),
    ])
    func openCodeGetsItsIDOnlyFromTwoPointOneOn(version: String, named: Bool) async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setDiscovery(programs: ["opencode"], openCodeVersion: version)
        _ = try await fixture.store.availableAgentKinds(on: host.id)

        let params = try await fixture.launch(.opencode)

        let program = Self.program(of: params)
        if named {
            #expect(program.count == 3)
            #expect(program[1] == "-s")
            #expect(program[2].wholeMatch(of: Self.openCodeID) != nil)
            #expect(Self.labels(of: params) == [HerdrCoreLaunch.sessionHintLabel: program[2]])
        } else {
            #expect(program == ["opencode"])
            #expect(Self.labels(of: params).isEmpty)
        }
    }

    @Test func openCodeWithNoProbedVersionGetsNoID() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        let params = try await fixture.launch(.opencode)

        #expect(Self.program(of: params) == ["opencode"])
    }

    /// These programs refuse a second session flag, so the user's choice stands.
    @Test(arguments: [
        (SupportedAgentKind.claude, ["--resume"]),
        (SupportedAgentKind.claude, ["-c", "fix it"]),
        (SupportedAgentKind.claude, ["--session-id=abc"]),
        (SupportedAgentKind.pi, ["--no-session"]),
        (SupportedAgentKind.grok, ["-r", "title"]),
        (SupportedAgentKind.codex, ["--no-daemon"]),
    ])
    func argumentsThatAlreadyPickASessionGetNoFlagAndNoHint(
        kind: SupportedAgentKind, arguments: [String]
    ) async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        let params = try await fixture.launch(kind, arguments: arguments)

        #expect(Self.program(of: params) == [kind.executable] + arguments)
        #expect(Self.labels(of: params).isEmpty)
    }

    @Test func wordsAfterADoubleDashPickNothing() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        let params = try await fixture.launch(.claude, arguments: ["--", "-c"])

        let program = Self.program(of: params)
        #expect(program[1] == "--session-id")
        #expect(Array(program.suffix(2)) == ["--", "-c"])
    }

    // MARK: Discovery

    @Test func discoveryRunsThroughTheSameInteractiveShellAndFeedsTheLaunch() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setDiscovery(
            programs: ["cursor-agent", "opencode", "claude"], openCodeVersion: "opencode v2.2.2")
        let form = fixture.startAgentForm()

        await form.discoverAgents()

        #expect(form.agentDiscoveryState == .loaded)
        #expect(form.availableAgentKinds == [.claude, .cursor, .opencode])
        let script = try #require(await fixture.transport.discoveryScripts.first)
        #expect(script.hasPrefix("'\(Self.zsh)' -ic '"))
        #expect(script.contains("opencode"))
        #expect(script.contains("--version"))

        form.selectedAgentKind = .opencode
        await form.submit()

        let params = try #require(await fixture.transport.runs.last)
        #expect(Self.program(of: params)[1] == "-s")
        #expect(await fixture.transport.discoveryScripts.count == 1)
    }

    /// Discovery goes by exec and a start by the link, so a core that stopped
    /// with SSH still up reaches the form as this.
    @Test func aStartWithNoCoreRunningSaysSo() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setDiscovery(programs: ["claude"])
        await fixture.transport.setRunFailure(
            TransportError.herdrCoreNotRunning(socketPath: "/run/core.sock", socketFilePresent: false))
        let form = fixture.startAgentForm()
        await form.discoverAgents()

        await form.submit()

        #expect(
            form.state
                == .failed(
                    "herdr-core is not running: Nothing is listening at /run/core.sock. "
                        + "Start the core on the Host, then check again."))
    }

    /// What the Host reports of its login shell comes over the link.
    @Test func aDiscoveryWithNoCoreRunningSaysSo() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setShellFailure(
            TransportError.herdrCoreNotRunning(socketPath: "/run/core.sock", socketFilePresent: false))
        let form = fixture.startAgentForm()

        await form.discoverAgents()

        #expect(
            form.agentDiscoveryState
                == .failed(
                    "herdr-core is not running: Nothing is listening at /run/core.sock. "
                        + "Start the core on the Host, then check again."))
    }

    @Test func aFreshDiscoveryReplacesTheVersionItRemembered() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setDiscovery(programs: ["opencode"], openCodeVersion: "2.2.2")
        _ = try await fixture.store.availableAgentKinds(on: host.id)
        await fixture.transport.setDiscovery(programs: ["opencode"], openCodeVersion: "1.19.5")
        _ = try await fixture.store.availableAgentKinds(on: host.id)

        let params = try await fixture.launch(.opencode)

        #expect(Self.program(of: params) == ["opencode"])
    }

    // MARK: Where it lands

    @Test func aDesktopSpaceTargetCarriesItsSpaceAndANewTab() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        let first = try await fixture.launch(.omp, workspaceID: "space-s1")
        let second = try await fixture.launch(.pi, workspaceID: "space-s1")

        let labels = Self.labels(of: first)
        #expect(labels["herdr.space"] == "s1")
        let tab = try #require(labels["herdr.tab"])
        #expect(tab != "tb1")
        #expect(!tab.isEmpty)
        #expect(Self.labels(of: second)["herdr.tab"] != tab)
        #expect(first["cwd"]?.stringValue == "/work/alpha")
    }

    @Test func aDesktopSpaceLaunchFromAnAgentStartsInThatAgentsDirectory() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        _ = try await fixture.startAgent(.omp, workspaceID: "space-s1", cwd: "/work/alpha/sub")

        let params = try #require(await fixture.transport.runs.last)
        #expect(params["cwd"]?.stringValue == "/work/alpha/sub")
    }

    @Test func aDerivedWorkspaceTargetHasNoDesktopLabelsAndStartsInItsKeyDirectory() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        // Its current Pane has moved, and the launch still came from there.
        await fixture.transport.deliver(
            Self.event(
                sequence: 2, type: "restarted", terminal: "t1",
                data: Self.record("t1", cwd: "/work/app/moved", keep: true)))
        try await fixture.until("the restart") {
            fixture.store.terminals.first { $0.paneID == "t1" }?.cwd == "/work/app/moved"
        }

        _ = try await fixture.startAgent(.codex, cwd: "/work/app/moved")

        let params = try #require(await fixture.transport.runs.last)
        #expect(params["cwd"]?.stringValue == "/work/app")
        #expect(Self.labels(of: params).isEmpty)
    }

    @Test func aNewAgentInADerivedWorkspaceShowsThereAtOnce() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        let agent = try await fixture.startAgent(.claude)

        #expect(agent.kind == "claude")
        #expect(agent.workspaceID == fixture.derived)
        #expect(agent.paneID == "t101")
        let row = try #require(fixture.store.agents.first { $0.agent.paneID == "t101" })
        #expect(row.agent.workspaceID == fixture.derived)

        // The core's own event for it changes nothing.
        let created = Self.record("t101", cwd: "/work/app", keep: true)
        await fixture.transport.deliver(
            Self.event(sequence: 2, type: "created", terminal: "t101", data: created))
        try await fixture.until("the event") {
            fixture.store.terminals.first { $0.paneID == "t101" } != nil
        }
        #expect(fixture.store.terminals.filter { $0.paneID == "t101" }.count == 1)
    }

    @Test func aFormLaunchInADesktopSpaceOpensItsAgent() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setDiscovery(programs: ["claude"])
        let form = fixture.startAgentForm()
        await form.discoverAgents()
        form.selectExistingWorkspace("space-s1")

        await form.submit()

        #expect(form.state == .started(ConsoleAgent.ID(hostID: host.id, paneID: "t101")))
    }

    // MARK: New Terminal

    @Test func aNewTerminalInADesktopSpaceCarriesItsSpaceAndANewTab() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        let identity = try await fixture.store.createShellTerminal(
            ShellTerminalCreationRequest(workspaceID: "space-s1", cwd: "/work/alpha/sub"), on: host.id)

        let params = try #require(await fixture.transport.runs.last)
        #expect(params["argv"] == nil)
        #expect(params["keep"] == .bool(true))
        #expect(params["cwd"]?.stringValue == "/work/alpha/sub")
        #expect(params["env"] == nil)
        #expect(Self.labels(of: params)["herdr.space"] == "s1")
        let tab = try #require(Self.labels(of: params)["herdr.tab"])
        #expect(tab != "tb1")
        let row = try #require(fixture.store.terminals.first { $0.terminalID == identity.terminalID })
        #expect(row.workspaceID == "space-s1")
        #expect(row.pane.tabID == identity.tabID)
    }

    @Test func aDrawerNewTerminalInADerivedWorkspaceFollowsTheSameRule() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.deliver(
            Self.event(
                sequence: 2, type: "restarted", terminal: "t1",
                data: Self.record("t1", cwd: "/work/app/moved", keep: true)))
        try await fixture.until("the restart") {
            fixture.store.terminals.first { $0.paneID == "t1" }?.cwd == "/work/app/moved"
        }
        let beside = try #require(fixture.store.terminals.first { $0.paneID == "t1" })
        let request = try #require(
            fixture.store.capabilities(for: host.id)
                .newTerminalRequest(workspaceID: beside.workspaceID, cwd: beside.cwd))

        let identity = try await fixture.store.createShellTerminal(request, on: host.id)

        let params = try #require(await fixture.transport.runs.last)
        #expect(params["cwd"]?.stringValue == "/work/app")
        #expect(params["labels"] == nil)
        let row = try #require(fixture.store.terminals.first { $0.terminalID == identity.terminalID })
        #expect(row.workspaceID == beside.workspaceID)
    }

    // MARK: New Workspace

    private static let spaceID = #/^sp[0-9a-f]{32}$/#
    private static let tabID = #/^tb[0-9a-f]{32}$/#

    @Test func aNewTerminalAtAPickedDirectoryStartsANewDesktopSpace() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        let identity = try await fixture.store.createShellWorkspace(
            NewWorkspaceSpec(directory: "/srv/new"), tabLabel: nil, on: host.id)

        let params = try #require(await fixture.transport.runs.last)
        #expect(params["cwd"]?.stringValue == "/srv/new")
        #expect(params["keep"] == .bool(true))
        let labels = Self.labels(of: params)
        let space = try #require(labels["herdr.space"])
        #expect(space.wholeMatch(of: Self.spaceID) != nil)
        #expect(try #require(labels["herdr.tab"]).wholeMatch(of: Self.tabID) != nil)
        let row = try #require(fixture.store.terminals.first { $0.terminalID == identity.terminalID })
        #expect(row.workspaceID == "space-\(space)")
        #expect(await fixture.transport.documentWrites.isEmpty)
    }

    @Test func aNewAgentAtAPickedDirectoryStartsANewDesktopSpace() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        let agent = try await fixture.store.startAgentInNewWorkspace(
            AgentLaunchRequest(kind: "omp", name: "omp"),
            workspace: NewWorkspaceSpec(directory: "/srv/new"), on: host.id)

        let params = try #require(await fixture.transport.runs.last)
        #expect(params["cwd"]?.stringValue == "/srv/new")
        let labels = Self.labels(of: params)
        let space = try #require(labels["herdr.space"])
        #expect(space.wholeMatch(of: Self.spaceID) != nil)
        #expect(try #require(labels["herdr.tab"]).wholeMatch(of: Self.tabID) != nil)
        #expect(agent.workspaceID == "space-\(space)")
        #expect(await fixture.transport.documentWrites.isEmpty)
    }

    @Test func eachNewWorkspaceIsItsOwnSpaceEvenInTheSameDirectory() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        for _ in 0..<2 {
            _ = try await fixture.store.createShellWorkspace(
                NewWorkspaceSpec(directory: "/srv/new"), tabLabel: nil, on: host.id)
        }

        let labels = await fixture.transport.runs.map(Self.labels(of:))
        #expect(Set(labels.compactMap { $0["herdr.space"] }).count == 2)
        #expect(Set(labels.compactMap { $0["herdr.tab"] }).count == 2)
    }

    @Test func aSpaceNoDesktopAppNamedIsCalledAfterItsTerminalsCheckoutFolder() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.services.setRoots(["/srv/repo/sub": "/srv/repo"])

        let identity = try await fixture.store.createShellWorkspace(
            NewWorkspaceSpec(directory: "/srv/repo/sub"), tabLabel: nil, on: host.id)

        let row = try #require(fixture.store.terminals.first { $0.terminalID == identity.terminalID })
        try await fixture.until("the checkout's name") {
            fixture.store.workspaces(for: fixture.host.id).first { $0.id == row.workspaceID }?.label == "repo"
        }
    }

    @Test func theNewWorkspaceFormStartsItsTerminalAtTheDirectoryItWasGiven() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setDiscovery(programs: ["codex"])
        let form = fixture.startAgentForm()
        await form.discoverAgents()
        form.applyBrowsedDirectory("/srv/picked")

        await form.submit()

        let params = try #require(await fixture.transport.runs.last)
        #expect(params["cwd"]?.stringValue == "/srv/picked")
        #expect(Self.labels(of: params)["herdr.space"] != nil)
        #expect(await fixture.transport.documentWrites.isEmpty)
    }

    @Test func theFormOffersNoTabNameOnACoreHost() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        let form = fixture.startAgentForm()
        #expect(!form.offersWorkspaceAndTabNames)
        #expect(!form.offersWorktree)

        let terminals = NewTerminalStore(
            hosts: [host], workspaces: { _ in [] }, directory: { _, _ in nil },
            remoteHome: { _ in "/home/dev" },
            create: { _, _ in ShellTerminalIdentity(paneID: "", tabID: "", terminalID: "") },
            awaitTerminal: { _, _ in nil })
        #expect(!terminals.offersWorkspaceAndTabNames)
    }

    @Test func aDerivedWorkspaceThatNoLongerExistsStartsNothing() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        await #expect(throws: TransportError.self) {
            try await fixture.startAgent(.omp, workspaceID: HerdrCoreOrganization.workspaceID(directory: "/gone"))
        }

        #expect(await fixture.transport.runs.isEmpty)
    }

    // MARK: No answer

    @Test func aLaunchWithNoAnswerReadsUnknownAndIsNotSentAgain() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setDiscovery(programs: ["claude"])
        await fixture.transport.setRunFailure(TransportError.coreMutationOutcomeUnknown)
        let form = fixture.startAgentForm()
        await form.discoverAgents()

        await form.submit()

        guard case .failed(let message) = form.state else {
            Issue.record("The form reads \(form.state)")
            return
        }
        #expect(message.contains("did not confirm"))
        #expect(await fixture.transport.runs.count == 1)
    }

    @Test func aNewTerminalWithNoAnswerIsNotSentAgain() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setRunFailure(TransportError.coreMutationOutcomeUnknown)

        await #expect(throws: TransportError.coreMutationOutcomeUnknown) {
            try await fixture.store.createShellTerminal(
                ShellTerminalCreationRequest(workspaceID: fixture.derived, cwd: "/work/app"), on: host.id)
        }

        #expect(await fixture.transport.runs.count == 1)
    }

    // MARK: Templates

    private static func template(
        _ name: String, description: String = "", command: String = "pi --thinking high",
        error: String? = nil
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "name": .string(name), "description": .string(description), "command": .string(command),
        ]
        if let error { fields["error"] = .string(error) }
        return .object(fields)
    }

    @Test func newAgentListsTheHostsTemplatesBesideHeelersAgents() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setDiscovery(programs: ["claude"])
        await fixture.transport.setTemplates([
            Self.template("planner"), Self.template("reviewer", description: "Read-only code review"),
        ])
        let form = fixture.startAgentForm()

        await form.discoverAgents()

        #expect(form.agentDiscoveryState == .loaded)
        #expect(form.availableAgentKinds == [.claude])
        #expect(
            form.availableTemplates == [
                AgentTemplate(name: "planner", description: ""),
                AgentTemplate(name: "reviewer", description: "Read-only code review"),
            ])
        #expect(form.selectedAgentKind == .claude)
        #expect(form.selectedTemplate == nil)
    }

    @Test func aHostWithNoTemplatesListsNone() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setDiscovery(programs: ["omp"])
        let form = fixture.startAgentForm()

        await form.discoverAgents()

        #expect(form.availableTemplates.isEmpty)
        #expect(form.availableAgentKinds == [.omp])
    }

    @Test func aTemplateFileThatCannotBeUsedIsNotOffered() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setTemplates([
            Self.template("broken", command: "", error: "no command"), Self.template("reviewer"),
        ])
        let form = fixture.startAgentForm()

        await form.discoverAgents()

        #expect(form.availableTemplates.map(\.name) == ["reviewer"])
    }

    @Test func aFailedTemplateListStillOffersHeelersAgents() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setDiscovery(programs: ["claude"])
        await fixture.transport.setTemplateListFailure(TransportError.timedOut)
        let form = fixture.startAgentForm()

        await form.discoverAgents()

        #expect(form.agentDiscoveryState == .loaded)
        #expect(form.availableAgentKinds == [.claude])
        #expect(form.availableTemplates.isEmpty)
    }

    /// A form that has discovered the Host, with `reviewer` picked.
    private func formWithTemplatePicked(
        on fixture: Fixture, named name: String = "reviewer", existingNames: Set<String> = []
    ) async throws -> StartAgentStore {
        await fixture.transport.setDiscovery(programs: ["claude"])
        await fixture.transport.setTemplates([Self.template(name)])
        let form = fixture.startAgentForm(existingNames: existingNames)
        await form.discoverAgents()
        form.selectedAgent = .template(try #require(form.availableTemplates.first))
        return form
    }

    // MARK: A Template that has gone

    /// The core would run a program of that name without a word.
    @Test func aTemplateGoneByStartSendsNoRun() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        let form = try await formWithTemplatePicked(on: fixture)
        await fixture.transport.setTemplates([Self.template("planner")])

        await form.submit()

        #expect(await fixture.transport.templateRuns == 0)
        #expect(await fixture.transport.runs.isEmpty)
        #expect(
            form.state
                == .failed(
                    "reviewer is no longer a Template on this Host, so nothing started. Detect Again refreshes the list."
                ))
    }

    /// Which name is a Template is not known, so nothing runs under it.
    @Test func aListThatCannotBeReadAtStartSendsNoRun() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        let form = try await formWithTemplatePicked(on: fixture)
        await fixture.transport.setTemplateListFailure(TransportError.timedOut)

        await form.submit()

        #expect(await fixture.transport.templateRuns == 0)
        #expect(form.state == .failed("The Host did not answer in time."))
    }

    /// The file can go between the check and the run, and no core call rules that
    /// out, so the answer is read and the program is left for the user to judge.
    @Test func aRunThatNamesNoTemplateSaysWhatStartedAndWhere() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        let form = try await formWithTemplatePicked(on: fixture)
        form.selectExistingWorkspace(fixture.derived)
        await fixture.transport.runTemplatesAsPrograms()

        await form.submit()

        #expect(await fixture.transport.templateRuns == 1)
        #expect(
            form.state
                == .failed(
                    "reviewer is no longer a Template on this Host, so the core ran a program of that name in a Terminal at /work/app. Close it if you did not mean to run it."
                ))
    }

    // MARK: Where it starts

    /// A derived Workspace is its key directory, wherever its Terminal has gone.
    @Test func theOriginFormShowsADerivedWorkspacesKeyDirectory() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        #expect(
            fixture.store.launchDirectory(
                ofWorkspace: fixture.derived, asked: "/work/app/sub", on: host.id) == "/work/app")

        _ = try await fixture.store.startAgent(
            AgentLaunchRequest(
                kind: "claude", name: "claude", arguments: [], workspaceID: fixture.derived,
                cwd: "/work/app/sub"),
            on: host.id)
        #expect(await fixture.transport.runs.last?["cwd"]?.stringValue == "/work/app")
    }

    /// A desktop space takes the directory it is given.
    @Test func theOriginFormShowsTheAskedDirectoryInADesktopSpace() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }

        #expect(
            fixture.store.launchDirectory(
                ofWorkspace: "space-s1", asked: "/work/alpha/sub", on: host.id) == "/work/alpha/sub")
    }

    @Test func aTemplateInADerivedWorkspaceIsRunByNameAndNothingElse() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        let form = try await formWithTemplatePicked(on: fixture)
        form.selectExistingWorkspace(fixture.derived)

        await form.submit()

        let params = try #require(await fixture.transport.runs.last)
        #expect(
            params
                == .object([
                    "argv": .array([.string("reviewer")]), "cwd": .string("/work/app"),
                    "keep": .bool(true), "name": .string("reviewer"),
                ]))
        #expect(await fixture.transport.templateRuns == 1)
        #expect(form.state == .started(ConsoleAgent.ID(hostID: host.id, paneID: "t101")))
    }

    @Test func aTemplateInADesktopSpaceCarriesOnlyThatSpacesLabels() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        let form = try await formWithTemplatePicked(on: fixture)
        form.selectExistingWorkspace("space-s1")

        await form.submit()

        let params = try #require(await fixture.transport.runs.last)
        #expect(Self.strings(params["argv"]) == ["reviewer"])
        #expect(params["cwd"]?.stringValue == "/work/alpha")
        #expect(params["env"] == nil)
        let labels = Self.labels(of: params)
        #expect(Set(labels.keys) == ["herdr.space", "herdr.tab"])
        #expect(labels["herdr.space"] == "s1")
        #expect(labels["herdr.tab"] != "tb1")
    }

    @Test func aTemplateFromAnAgentInADesktopSpaceStartsInThatAgentsDirectory() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setTemplates([Self.template("reviewer")])

        _ = try await fixture.store.startTemplate(
            TemplateLaunchRequest(
                template: "reviewer", name: nil, workspaceID: "space-s1", cwd: "/work/alpha/sub"),
            on: host.id)

        let params = try #require(await fixture.transport.runs.last)
        #expect(params["cwd"]?.stringValue == "/work/alpha/sub")
        #expect(params["name"] == nil)
    }

    @Test func aTemplateAtABrowsedDirectoryStartsANewDesktopSpace() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        let form = try await formWithTemplatePicked(on: fixture)
        form.applyBrowsedDirectory("/srv/new")

        await form.submit()

        let params = try #require(await fixture.transport.runs.last)
        #expect(Self.strings(params["argv"]) == ["reviewer"])
        #expect(params["cwd"]?.stringValue == "/srv/new")
        let labels = Self.labels(of: params)
        let space = try #require(labels["herdr.space"])
        #expect(space.wholeMatch(of: Self.spaceID) != nil)
        #expect(try #require(labels["herdr.tab"]).wholeMatch(of: Self.tabID) != nil)
        let row = try #require(fixture.store.agents.first { $0.agent.paneID == "t101" })
        #expect(row.agent.workspaceID == "space-\(space)")
    }

    @Test func aTemplateAgentShowsWhatItsCommandRuns() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        let form = try await formWithTemplatePicked(on: fixture)
        form.selectExistingWorkspace(fixture.derived)

        await form.submit()

        let row = try #require(fixture.store.agents.first { $0.agent.paneID == "t101" })
        #expect(row.agent.kind == "pi")
        #expect(row.agent.name == "reviewer")
    }

    @Test func aTemplateProgramHeelerDoesNotKnowBecomesAnAgentOnceItReports() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setTemplateCommand("/opt/mytool --flag")
        await fixture.transport.setTemplates([Self.template("reviewer")])

        let agent = try await fixture.store.startTemplate(
            TemplateLaunchRequest(
                template: "reviewer", name: nil, workspaceID: fixture.derived, cwd: nil),
            on: host.id)

        #expect(agent.paneID == "t101")
        #expect(agent.workspaceID == fixture.derived)
        #expect(!fixture.store.agents.contains { $0.agent.paneID == "t101" })
        #expect(fixture.store.terminals.contains { $0.paneID == "t101" })

        await fixture.transport.deliver(
            Self.event(
                sequence: 2, type: "status", terminal: "t101",
                data: .object([
                    "status": .object(["state": .string("idle"), "app": .string("mytool")]),
                    "records": .object([:]), "reported": .bool(true),
                ])))
        try await fixture.until("the report") {
            fixture.store.agents.contains { $0.agent.paneID == "t101" }
        }
    }

    @Test func aTemplateThatIsNoAgentYetClosesTheFormWithoutOpeningAnAgent() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setTemplateCommand("/opt/mytool --flag")
        await fixture.transport.setTemplates([Self.template("reviewer")])
        let form = fixture.startAgentForm(agentWait: .milliseconds(20))
        await form.discoverAgents()
        form.selectExistingWorkspace(fixture.derived)

        await form.submit()

        #expect(form.state == .startedAsTerminal)
        #expect(fixture.store.terminals.contains { $0.paneID == "t101" })
    }

    // MARK: A Template's program ending

    private static func finished(
        sequence: Int = 2, terminal: String = "t101", reason: String = "exited", exitCode: Int?,
        signal: Int? = nil
    ) -> Data {
        event(
            sequence: sequence, type: "finished", terminal: terminal,
            data: .object([
                "reason": .string(reason), "exit_code": exitCode.map { .number(Double($0)) } ?? .null,
                "signal": signal.map { .number(Double($0)) } ?? .null, "finished_ms": .number(5),
            ]))
    }

    @Test(arguments: [
        (
            "exited", 127 as Int?, nil as Int?,
            "reviewer ended right after it started, with exit code 127, so no Agent is running. "
                + "That code means its command was not found: a Template runs without your shell, "
                + "so it needs a full path or a PATH of its own."
        ),
        (
            "exited", 1, nil,
            "reviewer ended right after it started, with exit code 1, so no Agent is running."
        ),
        ("exited", 0, nil, "reviewer finished right after it started, so no Agent is running."),
        ("killed", nil, 9, "reviewer ended right after it started, so no Agent is running."),
    ])
    func aTemplateWhoseProgramEndsDuringTheWaitSaysSoWithoutWaitingItOut(
        reason: String, exitCode: Int?, signal: Int?, message: String
    ) async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setTemplateCommand("nosuchtool --flag")
        await fixture.transport.setTemplates([Self.template("reviewer")])
        let form = fixture.startAgentForm(agentWait: .seconds(40))
        await form.discoverAgents()
        form.selectExistingWorkspace(fixture.derived)

        let submit = Task { await form.submit() }
        defer { submit.cancel() }
        try await fixture.until("the Terminal") {
            fixture.store.terminals.contains { $0.paneID == "t101" }
        }
        await fixture.transport.deliver(
            Self.finished(reason: reason, exitCode: exitCode, signal: signal))
        try await fixture.until("the form hearing of it") { form.state != .starting }

        #expect(form.state == .failed(message))
        #expect(form.canSubmit)
        #expect(await fixture.transport.templateRuns == 1)
        #expect(!fixture.store.terminals.contains { $0.paneID == "t101" })
    }

    /// With a first message the core answers only after the program ended, and
    /// that end can be in before the answer.
    @Test func aTemplateThatEndedBeforeItsAnswerReadsAsEnded() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setTemplates([Self.template("reviewer")])
        let form = fixture.startAgentForm(agentWait: .seconds(40))
        await form.discoverAgents()
        form.selectExistingWorkspace(fixture.derived)
        let created = try JSONEncoder().encode(
            JSONValue.object([
                "jsonrpc": .string("2.0"), "method": .string("event"),
                "params": .object([
                    "seq": .number(2), "type": .string("created"), "terminal": .string("t101"),
                    "data": Self.record("t101", keep: true),
                ]),
            ]))
        await fixture.transport.deliver(created)
        try await fixture.until("the Terminal") {
            fixture.store.terminals.contains { $0.paneID == "t101" }
        }
        await fixture.transport.deliver(Self.finished(sequence: 3, exitCode: 2))
        try await fixture.until("its end") {
            !fixture.store.terminals.contains { $0.paneID == "t101" }
        }

        await form.submit()

        #expect(
            form.state
                == .failed(
                    "reviewer ended right after it started, with exit code 2, so no Agent is running."))
    }

    // MARK: A kind's program ending

    /// The core's event for a program that went before the launch's reply.
    private func endBeforeTheReply(_ fixture: Fixture, reason: String = "exited", exitCode: Int?) async throws {
        await fixture.transport.deliver(
            Self.event(sequence: 2, type: "created", terminal: "t101", data: Self.record("t101", keep: true)))
        try await fixture.until("the Terminal") {
            fixture.store.terminals.contains { $0.paneID == "t101" }
        }
        await fixture.transport.deliver(Self.finished(sequence: 3, reason: reason, exitCode: exitCode))
        try await fixture.until("its end") {
            !fixture.store.terminals.contains { $0.paneID == "t101" }
        }
    }

    @Test(arguments: [
        (
            "exited", 127 as Int?,
            "Claude Code ended right after it started, with exit code 127, so no Agent is running. "
                + "That code means the Host's shell could not find its command."
        ),
        (
            "exited", 1,
            "Claude Code ended right after it started, with exit code 1, so no Agent is running."
        ),
        ("exited", 0, "Claude Code finished right after it started, so no Agent is running."),
        ("killed", nil, "Claude Code ended right after it started, so no Agent is running."),
    ])
    func aKindThatEndedBeforeItsAnswerReadsAsEnded(
        reason: String, exitCode: Int?, message: String
    ) async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setDiscovery(programs: ["claude"])
        let form = fixture.startAgentForm(agentWait: .seconds(40))
        await form.discoverAgents()
        form.selectExistingWorkspace(fixture.derived)
        try await endBeforeTheReply(fixture, reason: reason, exitCode: exitCode)

        await form.submit()

        #expect(form.state == .failed(message))
        #expect(form.canSubmit)
    }

    /// New Agent still closes on its row, and does not stay to watch it.
    @Test func aKindThatIsListedClosesTheFormAtOnce() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setDiscovery(programs: ["claude"])
        let form = fixture.startAgentForm(agentWait: .seconds(40))
        await form.discoverAgents()
        form.selectExistingWorkspace(fixture.derived)

        await form.submit()

        #expect(form.state == .started(ConsoleAgent.ID(hostID: host.id, paneID: "t101")))
    }

    // MARK: Names live Terminals hold

    @Test func startingATemplateThatIsNoAgentYetAgainTakesTheNextName() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setTemplateCommand("/opt/mytool --flag")
        await fixture.transport.setTemplates([Self.template("silent")])

        let first = fixture.startAgentForm(agentWait: .milliseconds(20))
        await first.discoverAgents()
        first.selectExistingWorkspace(fixture.derived)
        await first.submit()
        #expect(first.state == .startedAsTerminal)

        let second = fixture.startAgentForm(agentWait: .milliseconds(20))
        await second.discoverAgents()
        second.selectExistingWorkspace(fixture.derived)
        #expect(second.defaultAgentName == "silent-2")
        await second.submit()

        #expect(second.state == .startedAsTerminal)
        #expect(await fixture.transport.runs.map { $0["name"]?.stringValue } == ["silent", "silent-2"])
    }

    @Test func aTerminalThatEndedGivesItsNameBack() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setTemplateCommand("/opt/mytool --flag")
        await fixture.transport.setTemplates([Self.template("silent")])
        let first = fixture.startAgentForm(agentWait: .milliseconds(20))
        await first.discoverAgents()
        first.selectExistingWorkspace(fixture.derived)
        await first.submit()

        await fixture.transport.deliver(Self.finished(exitCode: 0))
        try await fixture.until("its end") {
            !fixture.store.terminals.contains { $0.paneID == "t101" }
        }

        let second = fixture.startAgentForm()
        await second.discoverAgents()
        #expect(second.defaultAgentName == "silent")
    }

    @Test func aShellHoldingAnAgentsNameBumpsTheDefault() async throws {
        let fixture = try await Fixture(
            host: host, terminals: [Self.record("t1", keep: true, name: "claude")])
        defer { fixture.finish() }
        await fixture.transport.setDiscovery(programs: ["claude"])
        let form = fixture.startAgentForm()

        await form.discoverAgents()

        #expect(!fixture.store.agents.contains { $0.agent.paneID == "t1" })
        #expect(form.defaultAgentName == "claude-2")
    }

    @Test(arguments: [
        ("reviewer", [String](), "reviewer" as String?),
        ("reviewer", ["reviewer"], "reviewer-2"),
        ("Code Review", [], nil),
        ("code.review", [], nil),
        (String(repeating: "a", count: 32), [String(repeating: "a", count: 32)], nil),
    ])
    func anEmptyNameFieldNamesTheAgentAfterItsTemplateWhereTheNameFits(
        template: String, taken: [String], name: String?
    ) async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        let form = try await formWithTemplatePicked(
            on: fixture, named: template, existingNames: Set(taken))
        form.selectExistingWorkspace(fixture.derived)

        #expect(form.defaultAgentName == name)
        await form.submit()

        let params = try #require(await fixture.transport.runs.last)
        #expect(params["name"]?.stringValue == name)
        #expect(Self.strings(params["argv"]) == [template])
    }

    @Test func aTypedNameNamesATemplateAgent() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        let form = try await formWithTemplatePicked(on: fixture)
        form.selectExistingWorkspace(fixture.derived)
        form.name = "second-look"

        await form.submit()

        let params = try #require(await fixture.transport.runs.last)
        #expect(params["name"]?.stringValue == "second-look")
    }

    @Test func aTemplateTakesNoArgumentsFromTheForm() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        let form = try await formWithTemplatePicked(on: fixture)
        form.selectExistingWorkspace(fixture.derived)
        form.arguments = "'an unclosed quote"

        #expect(!form.offersArguments)
        #expect(form.canSubmit)
        await form.submit()

        let params = try #require(await fixture.transport.runs.last)
        #expect(Self.strings(params["argv"]) == ["reviewer"])
    }

    @Test func pickingAnAgentAgainStartsItThroughTheShell() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        let form = try await formWithTemplatePicked(on: fixture)
        form.selectExistingWorkspace(fixture.derived)

        form.selectedAgent = .kind(.claude)
        #expect(form.selectedTemplate == nil)
        await form.submit()

        let params = try #require(await fixture.transport.runs.last)
        #expect(Self.strings(params["argv"]).first == Self.zsh)
        #expect(await fixture.transport.templateRuns == 0)
    }

    @Test func aHostOfferingOnlyTemplatesPicksTheFirst() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setTemplates([Self.template("reviewer")])
        let form = fixture.startAgentForm()

        await form.discoverAgents()

        #expect(form.agentDiscoveryState == .loaded)
        #expect(form.availableAgentKinds.isEmpty)
        #expect(form.selectedTemplate?.name == "reviewer")
    }

    @Test func aTemplateStartsWithoutTheShellThatFailedDiscovery() async throws {
        let fixture = try await Fixture(host: host, shell: nil)
        defer { fixture.finish() }
        await fixture.transport.setTemplates([Self.template("reviewer")])
        let form = fixture.startAgentForm()
        await form.discoverAgents()
        form.selectExistingWorkspace(fixture.derived)

        guard case .failed = form.agentDiscoveryState else {
            Issue.record("Discovery reads \(form.agentDiscoveryState)")
            return
        }
        #expect(form.selectedTemplate?.name == "reviewer")
        #expect(form.canSubmit)
        await form.submit()

        #expect(await fixture.transport.templateRuns == 1)
        #expect(form.state == .started(ConsoleAgent.ID(hostID: host.id, paneID: "t101")))
    }

    // MARK: Directory browsing

    @Test func thePickersBrowseRemoteDirectoriesThroughTheHostServices() async throws {
        let fixture = try await Fixture(
            host: host,
            listings: [
                "/home/dev": RemoteDirectoryListing(directories: ["code", "notes"], truncated: false),
                "/home/dev/code": RemoteDirectoryListing(directories: ["app"], truncated: false),
            ])
        defer { fixture.finish() }
        let store = fixture.store
        let hostID = host.id
        let browser = RemoteDirectoryBrowser(
            resolveHome: { try await store.remoteHomeDirectory(on: hostID) },
            list: { try await store.listRemoteDirectories(at: $0, on: hostID) })

        browser.start()
        try await fixture.until("the home listing") { browser.directories == ["code", "notes"] }
        browser.enter("code")
        try await fixture.until("the listing") { browser.directories == ["app"] }

        #expect(await fixture.services.listedPaths == ["/home/dev", "/home/dev/code"])
    }

    @Test func aCoreHostOffersNewAgentAndNewTerminal() {
        let capabilities = host.capabilities
        #expect(capabilities.startsAgents)
        #expect(capabilities.startsTerminals)
        #expect(!capabilities.tabNames)
        #expect(!capabilities.worktrees)
        #expect([host].offeringNewItem(listsTerminals: false) == [host])
        #expect([host].offeringNewItem(listsTerminals: true) == [host])
        #expect(
            capabilities.newTerminalRequest(workspaceID: "w1", cwd: "/srv/app")
                == ShellTerminalCreationRequest(workspaceID: "w1", cwd: "/srv/app"))
    }
}

/// A Template's long wait, from the form through the real framed transport and
/// link on a manual clock, with the core scripted to answer when the test says.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreTemplateWaitTests {
    /// Every deadline the link armed, each before it parks.
    private final class ArmedDeadlines: Sendable {
        private let durations = OSAllocatedUnfairLock<[Duration]>(initialState: [])

        func note(_ duration: Duration) {
            durations.withLock { $0.append(duration) }
        }

        var longest: Duration {
            durations.withLock { $0.max() ?? .zero }
        }
    }

    @MainActor
    private final class Fixture {
        let clock = ManualClock()
        let armed = ArmedDeadlines()
        let core: ScriptedCoreHost
        let store: ConsoleStore
        let form: StartAgentStore
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)

        init() async throws {
            let core = ScriptedCoreHost(channel: .core(ScriptedCoreHost.Core()))
            await core.setTemplateList(
                .object([
                    "templates": .array([
                        .object(["name": .string("reviewer"), "description": .string("Reviews")])
                    ])
                ]))
            let clock = clock
            let armed = armed
            let transport = core.transport(sleep: { duration in
                armed.note(duration)
                try await clock.parkedSleep(for: duration)
            })
            let store = ConsoleStore(
                makeSession: { _, subscriptions in
                    EventsSession(
                        subscriptions: subscriptions,
                        connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                        keepalive: nil)
                },
                makeCoreSession: { _ in
                    HerdrCoreHostSession(connect: { transport }, keepalive: nil)
                },
                coreHostMemory: HerdrCoreHostMemory())
            self.core = core
            self.store = store
            form = StartAgentStore(
                hosts: [host],
                workspaces: { store.workspaces(for: $0) },
                existingAgentNames: { _ in [] },
                discoverAgentKinds: { try await store.availableAgentKinds(on: $0) },
                discoverTemplates: { try await store.availableTemplates(on: $0) },
                startTemplate: { try await store.startTemplate($0, on: $1) },
                remoteHome: { try await store.remoteHomeDirectory(on: $0) },
                start: { _, _, _ in throw TransportError.hostFeatureUnavailable(feature: "kinds") },
                awaitAgentVisible: { await store.waitForAgent($0) },
                recents: RecentWorkspaceStore(defaults: UserDefaults(suiteName: "wait-\(UUID())") ?? .standard))
            store.setHosts([host])
            await store.resume()
            let id = host.id
            while store.hostsAwaitingSnapshot.contains(id) {
                try await Task.sleep(for: .milliseconds(10))
            }
            await form.discoverAgents()
            form.selectedTemplate = form.availableTemplates.first
            form.applyBrowsedDirectory("/srv/work")
        }

        /// Starts the launch and returns once its `terminal.run` is out with its
        /// deadline armed.
        func startAndWaitForTheRun() async throws -> Task<Void, Never> {
            let form = form
            let starting = Task { await form.submit() }
            await core.waitForMethod("terminal.run")
            while armed.longest < .seconds(20) {
                try await Task.sleep(for: .milliseconds(5))
            }
            await clock.untilParked(1)
            return starting
        }

        /// Time passes, and whatever that was going to set off has happened.
        func pass(_ duration: Duration) async throws {
            clock.advance(duration)
            try await Task.sleep(for: .milliseconds(100))
        }

        func finish() {
            store.setHosts([])
        }
    }

    private static let started: JSONValue = .object([
        "address": .string("t9"), "cwd": .string("/srv/work"), "state": .string("live"),
        "argv": .array(["sh", "-c", "pi --thinking high"].map(JSONValue.string)),
        "keep": .bool(true), "name": .string("reviewer"), "labels": .object([:]),
        "cols": .number(80), "rows": .number(24), "pid": .number(4000),
        "template": .string("reviewer"), "submit": .string("ctrl+j"), "stop": .string("ctrl+c"),
    ])

    @Test func newAgentStillReadsStartingAt35SecondsAndSucceedsOnTheReply() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        #expect(fixture.form.canSubmit)

        let starting = try await fixture.startAndWaitForTheRun()
        #expect(fixture.armed.longest >= .seconds(40))
        try await fixture.pass(.seconds(35))

        #expect(fixture.form.state == .starting)
        #expect(!fixture.form.canDismiss)
        #expect(await fixture.core.runs.count == 1)

        await fixture.core.answerWaitingRuns(with: Self.started)
        await starting.value

        #expect(fixture.form.state == .started(ConsoleAgent.ID(hostID: fixture.host.id, paneID: "t9")))
        #expect(fixture.store.agents.contains { $0.agent.paneID == "t9" })
    }

    @Test func aTemplateWithNoAnswerByItsDeadlineReadsUnknownAndIsNeverSentAgain() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }

        let starting = try await fixture.startAndWaitForTheRun()
        try await fixture.pass(.seconds(39))
        #expect(fixture.form.state == .starting)

        fixture.clock.advance(fixture.armed.longest)
        await starting.value

        guard case .failed(let message) = fixture.form.state else {
            Issue.record("The form reads \(fixture.form.state)")
            return
        }
        #expect(message.contains("did not confirm"))
        try await fixture.pass(.seconds(120))
        #expect(await fixture.core.methods.filter { $0 == "terminal.run" }.count == 1)
    }

    @Test func aTemplateWhoseLinkEndsMidWaitReadsUnknownAndIsNeverSentAgain() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }

        let starting = try await fixture.startAndWaitForTheRun()
        let socket = try #require(await fixture.core.socket)
        await socket.deliverEndOfFile()
        await starting.value

        guard case .failed(let message) = fixture.form.state else {
            Issue.record("The form reads \(fixture.form.state)")
            return
        }
        #expect(message.contains("did not confirm"))
        #expect(await fixture.core.runs.count == 1)
    }
}

/// The launch seam on the real framed transport, with the exec and core scripted.
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreLaunchTransportTests {
    private static let coreChannel = ScriptedCoreHost.Channel.core(ScriptedCoreHost.Core())

    @Test func theLoginShellTheLocatorReportsIsTheShell() async throws {
        let host = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(shell: "/usr/bin/fish"), channel: Self.coreChannel)
        let transport = host.transport()

        #expect(try await transport.launchShell() == "/usr/bin/fish")

        #expect(await host.log == ["locator"])
        try await transport.close()
    }

    @Test func noLoginShellFallsBackToTheCoresShellReadByName() async throws {
        let host = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(shell: nil),
            processRead: .values(["SHELL": "/bin/zsh"]), channel: Self.coreChannel)
        let transport = host.transport()

        #expect(try await transport.launchShell() == "/bin/zsh")

        let script = try #require(await host.scripts.last)
        // The core's pid, and the reader names the one variable.
        #expect(script.contains("4242"))
        #expect(script.contains("SHELL"))
        try await transport.close()
    }

    @Test(arguments: [
        ScriptedCoreHost.ProcessRead.values([:]), .values(["SHELL": ""]), .unreadable,
        .exits(status: 1, stdout: ""),
    ])
    func aHostThatSaysNeitherStartsNothing(read: ScriptedCoreHost.ProcessRead) async throws {
        let host = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(shell: nil), processRead: read, channel: Self.coreChannel)
        let transport = host.transport()

        await #expect(throws: TransportError.self) { try await transport.launchShell() }

        try await transport.close()
    }

    @Test func aRunGoesOutOnceAndNoAnswerIsOutcomeUnknown() async throws {
        let host = ScriptedCoreHost(channel: Self.coreChannel)
        let transport = host.transport()
        let params: JSONValue = .object(["argv": .array([.string("/bin/true")]), "keep": .bool(true)])

        let run = Task { try await transport.runTerminal(params: params) }
        await host.waitForMethod("terminal.run")
        let socket = try #require(await host.socket)
        await socket.deliverEndOfFile()

        await #expect(throws: TransportError.coreMutationOutcomeUnknown) { try await run.value }
        #expect(await host.runs == [params])
        #expect(await host.methods.filter { $0 == "terminal.run" }.count == 1)
        try await transport.close()
    }

    @Test func theTemplateListIsOneCallOverTheLink() async throws {
        let host = ScriptedCoreHost(channel: Self.coreChannel)
        await host.setTemplateList(
            .object([
                "templates": .array([
                    .object([
                        "name": .string("reviewer"), "description": .string("Reviews"),
                        "command": .string("pi"),
                    ])
                ])
            ]))
        let transport = host.transport()

        let templates = try await transport.listTemplates()

        #expect(templates == [AgentTemplate(name: "reviewer", description: "Reviews")])
        #expect(await host.methods.filter { $0 == "templates.list" }.count == 1)
        #expect(await host.log == ["locator", "open \(ScriptedCoreHost.socketPath)"])
        try await transport.close()
    }

    @Test func aRunReturnsWhatTheCoreAnswers() async throws {
        let host = ScriptedCoreHost(channel: Self.coreChannel)
        await host.setRunReply(.object(["address": .string("t9")]))
        let transport = host.transport()

        let reply = try await transport.runTerminal(params: .object([:]))

        #expect(reply["address"]?.stringValue == "t9")
        try await transport.close()
    }

    @Test func discoveryIsOneBoundedExecOnTheConnection() async throws {
        let host = ScriptedCoreHost(channel: Self.coreChannel)
        await host.setAgentDiscovery(stdout: "printed")
        let transport = host.transport()

        let result = try await transport.runAgentDiscovery(Data("the script".utf8))

        #expect(result.stdout == Data("printed".utf8))
        #expect(await host.log == ["agent-discovery"])
        #expect(await host.scripts == ["the script"])
        try await transport.close()
    }
}
