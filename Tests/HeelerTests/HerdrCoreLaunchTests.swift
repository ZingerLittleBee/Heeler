import Foundation
import Testing

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
        keep: Bool = false
    ) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string(cwd), "state": .string("live"),
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

        func startAgentForm() -> StartAgentStore {
            let store = store
            return StartAgentStore(
                hosts: [host],
                workspaces: { store.workspaces(for: $0) },
                existingAgentNames: { _ in [] },
                discoverAgentKinds: { try await store.availableAgentKinds(on: $0) },
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
                awaitAgentVisible: { await store.waitForAgent($0) },
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
        let second = try await fixture.launch(.omp, workspaceID: "space-s1")

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
