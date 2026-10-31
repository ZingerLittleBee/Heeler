import Foundation
import Testing

@testable import Heeler

/// The desktop-app control on the real framed transport, with the exec scripted:
/// how `herdr-app status` reads, and that `do` runs once whatever comes of it.
/// `scripts/test-herdr-app-control.py` runs these scripts through a real shell.
@Suite(.timeLimit(.minutes(1)))
struct HerdrAppControlTransportTests {
    private static let nonce = ScriptedCoreHost.nonce
    private static let banner = "welcome \u{1F44B} from the rc\n"

    private static func exec(_ stdout: String, status: Int32 = 0) -> Result<GitExecResult, TransportError> {
        .success(GitExecResult(stdout: Data(stdout.utf8), stderr: Data(), exitStatus: status))
    }

    /// The script's own frame around what the client printed.
    private static func client(_ printed: String, exit: Int32 = 0) -> Result<GitExecResult, TransportError> {
        exec("\(banner)\n\(nonce) begin\n\(printed)\n\(nonce) end \(exit)\n")
    }

    private static let statusReply = """
        {
          "zoom": 1.0,
          "space": "sp1",
          "errors": []
        }
        """

    private func transport(answer: Result<GitExecResult, TransportError>) async -> (
        HerdrCoreSSHTransport, ScriptedCoreHost
    ) {
        let host = ScriptedCoreHost(channel: .core(ScriptedCoreHost.Core()))
        await host.setHerdrAppAnswer(answer)
        return (HerdrCoreSSHTransport(connection: host, session: "x", nonce: { Self.nonce }), host)
    }

    // MARK: Status

    @Test func statusReadsRunningWhenTheAppAnswers() async {
        let (transport, host) = await transport(answer: Self.client(Self.statusReply))

        #expect(await transport.desktopAppIsRunning())

        #expect(await host.log == ["herdr-app"])
        let script = await host.scripts.last ?? ""
        #expect(script.contains(#""$__app" status </dev/null"#))
        #expect(!script.contains("hc "))
    }

    @Test(arguments: [
        ("no client on the Host", exec("\(nonce) absent\n")),
        ("no window", client("", exit: 2)),
        ("a window that did not answer", client(#"{"error": "the window did not answer"}"#, exit: 1)),
        ("an error with a clean exit", client(#"{"error": "busy"}"#)),
        ("words instead of a reply", client("not json")),
        ("a reply cut short", exec("\(banner)\n\(nonce) begin\n{\"zoom\"")),
        ("startup files alone", exec(banner)),
        ("an exec that failed", exec("", status: 127)),
        ("no exec at all", .failure(TransportError.timedOut)),
    ] as [(String, Result<GitExecResult, TransportError>)])
    func statusReadsNotRunning(_ what: String, answer: Result<GitExecResult, TransportError>) async {
        let (transport, _) = await transport(answer: answer)

        #expect(await !transport.desktopAppIsRunning(), "\(what)")
    }

    // MARK: Rename

    @Test func renameSendsTheSpaceAndTheNameOnce() async throws {
        let (transport, host) = await transport(answer: Self.client(#"{"ok": true}"#))

        try await transport.renameDesktopSpace("sp1", name: "it's 2026")

        #expect(await host.log == ["herdr-app"])
        let script = await host.scripts.last ?? ""
        #expect(script.contains(#""$__app" do space.rename '{"id":"sp1","name":"it'\''s 2026"}' </dev/null"#))
    }

    @Test func aRefusalThrowsTheAppsWordsAndIsNotSentAgain() async {
        let (transport, host) = await transport(
            answer: Self.client(#"{"error": "no space \"sp1\""}"#, exit: 1))

        await #expect(throws: HerdrAppControl.Refused(reason: #"no space "sp1""#)) {
            try await transport.renameDesktopSpace("sp1", name: "name")
        }

        #expect(await host.log == ["herdr-app"])
    }

    @Test func aClientWithNoWindowIsARefusalAndIsNotSentAgain() async {
        let (transport, host) = await transport(answer: Self.client("", exit: 2))

        await #expect(throws: HerdrAppControl.Refused(reason: nil)) {
            try await transport.renameDesktopSpace("sp1", name: "name")
        }

        #expect(await host.log == ["herdr-app"])
    }

    @Test func noClientOnTheHostIsARefusal() async {
        let (transport, _) = await transport(answer: Self.exec("\(Self.nonce) absent\n"))

        await #expect(throws: HerdrAppControl.Refused(reason: nil)) {
            try await transport.renameDesktopSpace("sp1", name: "name")
        }
    }

    @Test(arguments: [
        ("the exec timed out", .failure(TransportError.timedOut)),
        ("the connection went away", .failure(TransportError.sshUnreachable(detail: "gone"))),
        ("the exec died", exec("", status: 255)),
        ("the reply was cut short", exec("\(nonce) begin\n{\"ok\"")),
        ("the reply was unreadable", client("not json")),
    ] as [(String, Result<GitExecResult, TransportError>)])
    func aMissingAnswerReadsUnknownAndIsNotSentAgain(
        _ what: String, answer: Result<GitExecResult, TransportError>
    ) async {
        let (transport, host) = await transport(answer: answer)

        await #expect(throws: TransportError.coreMutationOutcomeUnknown, "\(what)") {
            try await transport.renameDesktopSpace("sp1", name: "name")
        }

        #expect(await host.log == ["herdr-app"], "\(what)")
    }
}

/// New Workspace's name and Rename Workspace on a core Host, through `ConsoleStore`
/// and the form stores over the scripted core transport.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreDesktopAppNamingTests {
    private static let adoptedSpaceID = "space-s1"
    private static let labeledSpaceID = "space-s2"

    private let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)

    private static func record(
        _ address: String, cwd: String = "/work/app", labels: [String: String] = [:]
    ) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string(cwd), "state": .string("live"),
            "argv": .array([.string("/bin/zsh")]), "cols": .number(80), "rows": .number(24),
            "pid": .number(7), "keep": .bool(true), "labels": .object(labels.mapValues(JSONValue.string)),
        ])
    }

    private static func documentEvent(sequence: Int, version: Int) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(Double(sequence)), "type": .string("doc"),
                "data": .object(["name": .string("herdr-app"), "version": .number(Double(version))]),
            ]),
        ]))) ?? Data()
    }

    /// `s1` is a space the document lists, `s2` a label no desktop app has
    /// adopted, and `t1` a Terminal in a derived Workspace.
    private static let document = CoreDesktopJSON.document([
        CoreDesktopJSON.space("s1", name: "Alpha", tabs: [CoreDesktopJSON.tab("tb1", terminals: ["t2"])])
    ])

    @MainActor
    private final class Fixture {
        let transport: ScriptedCoreTransport
        let store: ConsoleStore
        let host: Host
        private var sequence = 10
        private var version = 1

        /// `rename` nil leaves the capability at the app's default.
        init(host: Host, rename: Bool? = true, isRunning: Bool = true) async throws {
            self.host = host
            let transport = ScriptedCoreTransport(
                subscribeResults: [
                    .object([
                        "seq": .number(1), "channel": .number(1),
                        "terminals": .array([
                            HerdrCoreDesktopAppNamingTests.record("t1"),
                            HerdrCoreDesktopAppNamingTests.record(
                                "t2", labels: ["herdr.space": "s1", "herdr.tab": "tb1"]),
                            HerdrCoreDesktopAppNamingTests.record(
                                "t3", labels: ["herdr.space": "s2", "herdr.tab": "tb2"]),
                        ]),
                    ])
                ],
                services: ScriptedCoreServices(home: "/home/dev"))
            await transport.setShell("/bin/zsh")
            await transport.setDiscovery(programs: ["codex"])
            await transport.setDocument(HerdrCoreDesktopAppNamingTests.document, version: 1)
            await transport.setDesktopApp(running: isRunning)
            self.transport = transport
            let makeSession: @Sendable (Host, [EventSubscription]) -> EventsSession = { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            }
            let makeCoreSession: @Sendable (Host) -> HerdrCoreHostSession = { _ in
                HerdrCoreHostSession(connect: { transport }, keepalive: nil)
            }
            store =
                if let rename {
                    ConsoleStore(
                        makeSession: makeSession, makeCoreSession: makeCoreSession,
                        coreHostMemory: HerdrCoreHostMemory(), herdrAppRename: rename)
                } else {
                    ConsoleStore(
                        makeSession: makeSession, makeCoreSession: makeCoreSession,
                        coreHostMemory: HerdrCoreHostMemory())
                }
            store.setHosts([host])
            await store.resume()
            try await until("the first snapshot") { !self.store.hostsAwaitingSnapshot.contains(host.id) }
            if rename == true {
                try await until("the platform") { self.store.hostPlatforms[host.id] == .posix }
            }
            await store.checkDesktopApp(on: host.id)
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

        var capabilities: HostCapabilities { store.capabilities(for: host.id) }

        func newTerminalForm() -> NewTerminalStore {
            let store = store
            return NewTerminalStore(
                hosts: [host], initialHostID: host.id,
                workspaces: { store.workspaces(for: $0) }, directory: { _, _ in nil },
                remoteHome: { try await store.remoteHomeDirectory(on: $0) },
                create: { destination, hostID in
                    switch destination {
                    case .existing(let request):
                        try await store.createShellTerminal(request, on: hostID)
                    case .newWorkspace(let workspace, let tabLabel):
                        try await store.createShellWorkspace(workspace, tabLabel: tabLabel, on: hostID)
                    }
                },
                awaitTerminal: { await store.waitForTerminal($0, on: $1) },
                offersDesktopAppNames: { store.capabilities(for: $0).namesNewWorkspaces })
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
                recents: RecentWorkspaceStore(defaults: UserDefaults(suiteName: "naming-\(UUID())") ?? .standard),
                offersDesktopAppNames: { store.capabilities(for: $0).namesNewWorkspaces })
        }

        /// The desktop app writes its document, with no new space in it.
        func writeDocumentAgain() async throws {
            version += 1
            sequence += 1
            let reads = await transport.documentReads.count
            await transport.setDocument(HerdrCoreDesktopAppNamingTests.document, version: version)
            await transport.deliver(HerdrCoreDesktopAppNamingTests.documentEvent(sequence: sequence, version: version))
            try await until("the document read") { await self.transport.documentReads.count > reads }
            try await Task.sleep(for: .milliseconds(50))
        }

        /// The desktop app writes its document, adding a space under this id.
        func adopt(_ space: String) async throws {
            version += 1
            sequence += 1
            await transport.setDocument(
                CoreDesktopJSON.document([
                    CoreDesktopJSON.space("s1", name: "Alpha", tabs: [CoreDesktopJSON.tab("tb1", terminals: ["t2"])]),
                    CoreDesktopJSON.space(space, tabs: [CoreDesktopJSON.tab("tbn")]),
                ]),
                version: version)
            await transport.deliver(HerdrCoreDesktopAppNamingTests.documentEvent(sequence: sequence, version: version))
            let workspaceID = HerdrCoreOrganization.spaceWorkspaceID(space)
            try await until("the document to list \(space)") {
                self.capabilities.renameWorkspace(id: workspaceID)
            }
        }

        /// The new space's id, from the last launch's labels.
        func lastSpace() async throws -> String {
            let params = try #require(await transport.runs.last)
            guard case .object(let labels)? = params["labels"] else {
                throw TransportError.hostFeatureUnavailable(feature: "no labels")
            }
            return try #require(labels["herdr.space"]?.stringValue)
        }

        func finish() {
            store.setHosts([])
        }
    }

    // MARK: The capability

    @Test func withTheCapabilityAtItsDefaultStatusIsNotAskedAndNothingShows() async throws {
        let fixture = try await Fixture(host: host, rename: nil, isRunning: true)
        defer { fixture.finish() }

        #expect(!fixture.capabilities.namesNewWorkspaces)
        #expect(!fixture.capabilities.renameWorkspace(id: Self.adoptedSpaceID))
        #expect(!fixture.newTerminalForm().offersWorkspaceName)
        #expect(!fixture.startAgentForm().offersWorkspaceName)
        #expect(await fixture.transport.desktopAppChecks == 0)
    }

    @Test func withTheCapabilityOffNewWorkspaceStillWorksAndATypedNameGoesNowhere() async throws {
        let fixture = try await Fixture(host: host, rename: false, isRunning: true)
        defer { fixture.finish() }
        let form = fixture.newTerminalForm()
        form.applyBrowsedDirectory("/srv/new")
        form.newWorkspaceLabel = "typed while hidden"

        await form.submit()

        #expect({ if case .created = form.state { true } else { false } }())
        let space = try await fixture.lastSpace()

        // Even a name a caller passes directly is not applied.
        _ = try await fixture.store.createShellWorkspace(
            NewWorkspaceSpec(directory: "/srv/other", label: "direct"), tabLabel: nil, on: host.id)
        let other = try await fixture.lastSpace()
        await fixture.transport.setDocument(
            CoreDesktopJSON.document([
                CoreDesktopJSON.space(space, tabs: []), CoreDesktopJSON.space(other, tabs: []),
            ]),
            version: 5)
        await fixture.transport.deliver(Self.documentEvent(sequence: 20, version: 5))
        let reads = await fixture.transport.documentReads.count
        try await fixture.until("the document read") {
            await fixture.transport.documentReads.count > reads
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(await fixture.transport.desktopAppRenames.isEmpty)
        await #expect(throws: TransportError.self) {
            try await fixture.store.renameWorkspace(Self.adoptedSpaceID, label: "no", on: fixture.host.id)
        }
        #expect(await fixture.transport.desktopAppRenames.isEmpty)
    }

    // MARK: What shows

    @Test func whileTheAppRunsTheFieldAndRenameShow() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        try await fixture.until("the app's status") { fixture.capabilities.desktopAppNaming != nil }

        #expect(fixture.newTerminalForm().offersWorkspaceName)
        #expect(fixture.startAgentForm().offersWorkspaceName)
        #expect(fixture.capabilities.renameWorkspace(id: Self.adoptedSpaceID))
    }

    @Test func aWorkspaceTheAppDoesNotShowHasNoRenameAndRenameAgentIsNeverOffered() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        try await fixture.until("the app's status") { fixture.capabilities.desktopAppNaming != nil }
        let derived = HerdrCoreOrganization.workspaceID(directory: "/work/app")
        #expect(fixture.store.workspaces(for: host.id).contains { $0.id == derived })
        #expect(fixture.store.workspaces(for: host.id).contains { $0.id == Self.labeledSpaceID })

        #expect(!fixture.capabilities.renameWorkspace(id: derived))
        #expect(!fixture.capabilities.renameWorkspace(id: Self.labeledSpaceID))
        #expect(!fixture.capabilities.renameAgent)
        await #expect(throws: TransportError.self) {
            try await fixture.store.renameWorkspace(derived, label: "no", on: fixture.host.id)
        }
        await #expect(throws: TransportError.self) {
            try await fixture.store.renameAgent("t1", name: "no", on: fixture.host.id)
        }
        #expect(await fixture.transport.desktopAppRenames.isEmpty)
    }

    @Test func whenTheAppCannotBeReachedTheFieldAndRenameStayHidden() async throws {
        let fixture = try await Fixture(host: host, isRunning: false)
        defer { fixture.finish() }

        #expect(await fixture.transport.desktopAppChecks >= 1)
        #expect(!fixture.newTerminalForm().offersWorkspaceName)
        #expect(!fixture.startAgentForm().offersWorkspaceName)
        #expect(!fixture.capabilities.renameWorkspace(id: Self.adoptedSpaceID))
    }

    @Test func aCheckFollowsTheAppQuittingAndComingBack() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        try await fixture.until("the app's status") { fixture.capabilities.desktopAppNaming != nil }

        await fixture.transport.setDesktopApp(running: false)
        await fixture.store.checkDesktopApp(on: host.id)
        #expect(fixture.capabilities.desktopAppNaming == nil)

        await fixture.transport.setDesktopApp(running: true)
        await fixture.store.checkDesktopApp(on: host.id)
        #expect(fixture.capabilities.desktopAppNaming != nil)
    }

    @Test func showingAnAgentAsksAgain() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        await fixture.transport.setDesktopApp(running: false)

        fixture.store.setAgentShown(
            ConsoleAgent.ID(hostID: host.id, paneID: "t1"), viewer: UUID(), scene: nil)

        try await fixture.until("the app's status") { fixture.capabilities.desktopAppNaming == nil }
    }

    @Test func aLinkThatEndsHidesThemUntilTheNextOneAsks() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        try await fixture.until("the app's status") { fixture.capabilities.desktopAppNaming != nil }
        let asked = await fixture.transport.desktopAppChecks

        await fixture.transport.endLink()

        try await fixture.until("the next link's status") {
            await fixture.transport.desktopAppChecks > asked && fixture.capabilities.desktopAppNaming != nil
        }
    }

    @Test func aNativeWindowsCoreHostOffersNeither() {
        let naming = HerdrAppNaming(workspaceIDs: [Self.adoptedSpaceID])
        let windows = HostCapabilities(serverKind: .herdrCore, platform: .nativeWindows, desktopAppNaming: naming)
        #expect(!windows.namesNewWorkspaces)
        #expect(!windows.renameWorkspace(id: Self.adoptedSpaceID))
        let posix = HostCapabilities(serverKind: .herdrCore, platform: .posix, desktopAppNaming: naming)
        #expect(posix.namesNewWorkspaces)
        #expect(posix.renameWorkspace(id: Self.adoptedSpaceID))
    }

    @Test func aHerdrTUIHostStillNamesAndRenamesEverything() {
        let capabilities = HostCapabilities(serverKind: .herdrTUI)
        #expect(capabilities.namesNewWorkspaces)
        #expect(capabilities.renameWorkspace(id: "w1"))
        #expect(capabilities.renameAgent)
        #expect(capabilities.desktopAppNaming == nil)
    }

    // MARK: Rename

    @Test func renameSendsOneDoWithTheSpaceAndTheName() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        try await fixture.until("the app's status") { fixture.capabilities.renameWorkspace(id: Self.adoptedSpaceID) }

        try await fixture.store.renameWorkspace(Self.adoptedSpaceID, label: "Beta", on: host.id)

        #expect(await fixture.transport.desktopAppRenames == [.init(space: "s1", name: "Beta")])
        #expect(await fixture.transport.documentWrites.isEmpty)
    }

    @Test(arguments: [
        HerdrAppControl.Refused(reason: "no space") as any Error,
        TransportError.coreMutationOutcomeUnknown as any Error,
    ])
    func aFailedRenameIsNotSentAgainAndAsksWhetherTheAppStillRuns(failure: any Error) async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        try await fixture.until("the app's status") { fixture.capabilities.renameWorkspace(id: Self.adoptedSpaceID) }
        await fixture.transport.setDesktopAppRenameFailure(failure)
        await fixture.transport.setDesktopApp(running: false)

        await #expect(throws: (any Error).self) {
            try await fixture.store.renameWorkspace(Self.adoptedSpaceID, label: "Beta", on: fixture.host.id)
        }

        try await fixture.until("Rename to go away") { !fixture.capabilities.renameWorkspace(id: Self.adoptedSpaceID) }
        #expect(await fixture.transport.desktopAppRenames.count == 1)
    }

    @Test func theRenameSheetSaysWhatBecameOfIt() async {
        let refused = RenameStore.workspace(currentLabel: "Alpha") { _ in
            throw HerdrAppControl.Refused(reason: "no space")
        }
        refused.input = "Beta"
        await refused.submit()
        #expect(refused.state == .failed("The desktop app refused the rename: no space"))

        let unreachable = RenameStore.workspace(currentLabel: "Alpha") { _ in
            throw HerdrAppControl.Refused(reason: nil)
        }
        unreachable.input = "Beta"
        await unreachable.submit()
        #expect(unreachable.state == .failed("The desktop app could not be reached."))

        let unknown = RenameStore.workspace(currentLabel: "Alpha") { _ in
            throw TransportError.coreMutationOutcomeUnknown
        }
        unknown.input = "Beta"
        await unknown.submit()
        guard case .failed(let message) = unknown.state else {
            Issue.record("The sheet reads \(unknown.state)")
            return
        }
        #expect(message.contains("did not confirm"))
    }

    // MARK: A typed name

    @Test func aTypedNameWaitsForTheAppToAdoptTheSpaceAndIsSentOnce() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        try await fixture.until("the app's status") { fixture.newTerminalForm().offersWorkspaceName }
        let form = fixture.newTerminalForm()
        form.applyBrowsedDirectory("/srv/new")
        form.newWorkspaceLabel = "  Fresh  "

        await form.submit()

        let space = try await fixture.lastSpace()
        #expect(await fixture.transport.desktopAppRenames.isEmpty)

        // A document that does not list the space yet changes nothing.
        try await fixture.writeDocumentAgain()
        #expect(await fixture.transport.desktopAppRenames.isEmpty)

        try await fixture.adopt(space)
        try await fixture.until("the name to be sent") {
            await !fixture.transport.desktopAppRenames.isEmpty
        }
        #expect(await fixture.transport.desktopAppRenames == [.init(space: space, name: "Fresh")])

        // Later writes of the document, and a new link's snapshot, send nothing more.
        try await fixture.adopt(space)
        await fixture.transport.endLink()
        let subscribes = await fixture.transport.subscribeCount
        try await fixture.until("a new link") { await fixture.transport.subscribeCount > subscribes }
        try await fixture.until("the new link's document") { fixture.capabilities.desktopAppNaming != nil }
        #expect(await fixture.transport.desktopAppRenames.count == 1)
        #expect(await fixture.transport.documentWrites.isEmpty)
    }

    @Test func theAgentFormsNameGoesTheSameWay() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        try await fixture.until("the app's status") { fixture.startAgentForm().offersWorkspaceName }
        let form = fixture.startAgentForm()
        await form.discoverAgents()
        form.applyBrowsedDirectory("/srv/new")
        form.newWorkspaceLabel = "Fresh"

        await form.submit()

        let space = try await fixture.lastSpace()
        #expect(await fixture.transport.desktopAppRenames.isEmpty)
        try await fixture.adopt(space)
        try await fixture.until("the name to be sent") {
            await fixture.transport.desktopAppRenames == [.init(space: space, name: "Fresh")]
        }
    }

    @Test(arguments: [
        HerdrAppControl.Refused(reason: nil) as any Error,
        TransportError.coreMutationOutcomeUnknown as any Error,
    ])
    func aTypedNameThatFailsIsNotSentAgain(failure: any Error) async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        try await fixture.until("the app's status") { fixture.capabilities.desktopAppNaming != nil }
        await fixture.transport.setDesktopAppRenameFailure(failure)
        _ = try await fixture.store.createShellWorkspace(
            NewWorkspaceSpec(directory: "/srv/new", label: "Fresh"), tabLabel: nil, on: host.id)
        let space = try await fixture.lastSpace()

        try await fixture.adopt(space)
        try await fixture.until("the name to be sent") {
            await !fixture.transport.desktopAppRenames.isEmpty
        }
        try await fixture.adopt(space)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await fixture.transport.desktopAppRenames.count == 1)
    }

    @Test func aNewWorkspaceWithNoNameSendsNothing() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        try await fixture.until("the app's status") { fixture.capabilities.desktopAppNaming != nil }
        _ = try await fixture.store.createShellWorkspace(
            NewWorkspaceSpec(directory: "/srv/new"), tabLabel: nil, on: host.id)
        let space = try await fixture.lastSpace()

        try await fixture.adopt(space)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await fixture.transport.desktopAppRenames.isEmpty)
    }

    @Test func aLaunchThatFailsHoldsNoName() async throws {
        let fixture = try await Fixture(host: host)
        defer { fixture.finish() }
        try await fixture.until("the app's status") { fixture.capabilities.desktopAppNaming != nil }
        await fixture.transport.setRunFailure(TransportError.coreMutationOutcomeUnknown)

        await #expect(throws: TransportError.coreMutationOutcomeUnknown) {
            try await fixture.store.createShellWorkspace(
                NewWorkspaceSpec(directory: "/srv/new", label: "Fresh"), tabLabel: nil, on: fixture.host.id)
        }
        let space = try await fixture.lastSpace()

        try await fixture.adopt(space)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await fixture.transport.desktopAppRenames.isEmpty)
    }
}
