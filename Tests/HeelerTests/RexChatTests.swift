import Foundation
import Synchronization
import Testing

@testable import Heeler

/// What a Rex Host's projection keeps and reads for process-bound Chat, as a
/// tmux Host's does (ADRs 0034 and 0044): the Host's kernel, kept on this
/// device and learned from the server, never from an exec of its own, and
/// Chat's reads over the Host's SSH connection, which write nothing.
@MainActor
@Suite("Rex Chat", .timeLimit(.minutes(1)))
struct RexChatTests {
    private static let socket = "/run/user/1000/rex/server.sock"

    private static func host(storingSocket: Bool = true) -> Host {
        Host(
            name: "Rex", address: "rex.example", username: "dev", serverKind: .rex,
            rexSocket: storingSocket ? RexSocket(path: socket) : nil)
    }

    /// A started projection on one scripted SSH connection.
    private struct Rig {
        let host: Host
        let projection: RexConsoleProjection
        let connection: ScriptedRexHost
        let memory: HerdrCoreHostMemory
    }

    private func rig(
        _ connection: ScriptedRexHost, host: Host = RexChatTests.host(),
        memory: HerdrCoreHostMemory = HerdrCoreHostMemory()
    ) -> Rig {
        let dialer = RexHostSessionTests.Dialer([connection])
        let session = RexHostSession(
            storedSocket: host.rexSocket, connect: { try await dialer.dial($0, $1) },
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)))
        let projection = RexConsoleProjection(
            host: host, session: session, memory: memory, pins: PinnedAgentsStore(), onChange: {})
        projection.start(isActive: true)
        return Rig(host: host, projection: projection, connection: connection, memory: memory)
    }

    private func served(_ world: FakeRexWorld) async -> FakeRexServer {
        let server = FakeRexServer()
        await world.install(on: server)
        return server
    }

    private func waitUntil(
        _ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private func versionReads(_ server: FakeRexServer) async -> Int {
        await server.requests.count(where: { $0.method == "server.version" })
    }

    // MARK: The kernel

    /// `server.version` names the platform first, as Rex 0.1.0-preview.14 did
    /// on a Mac; only a system Heeler knows, Windows included since Rex
    /// Hosts reach it (ADR 0049), reads as a kernel.
    @Test(arguments: [
        ("darwin_arm64", HerdrCoreLocator.macOSKernel),
        ("darwin_x86_64", HerdrCoreLocator.macOSKernel),
        ("linux_x86_64", HerdrCoreLocator.linuxKernel),
        ("x86_64-unknown-linux-gnu", HerdrCoreLocator.linuxKernel),
        ("windows_x86_64", HerdrCoreLocator.windowsKernel),
        ("freebsd_amd64", nil),
        ("", nil),
    ] as [(String, String?)])
    func aServersPlatformReadsAsItsKernel(platform: String, kernel: String?) {
        #expect(RexServerPlatform.kernel(reading: ["platform": .string(platform)]) == kernel)
        #expect(RexServerPlatform.kernel(reading: ["version": "0.0.0"]) == nil)
    }

    /// A Host this device knows no kernel of learns it from the server once,
    /// keeps it, and runs nothing on the Host for it.
    @Test func aRexHostLearnsItsKernelFromTheServer() async throws {
        let server = await served(FakeRexWorld(sessions: [FakeRexWorld.studio()], platform: "linux_x86_64"))
        let rig = rig(ScriptedRexHost(control: [.server(server)]))
        defer { rig.projection.end() }

        try await waitUntil("the kernel") { rig.projection.kernel == HerdrCoreLocator.linuxKernel }

        #expect(rig.memory.kernel(for: rig.host.id) == HerdrCoreLocator.linuxKernel)
        #expect(await versionReads(server) == 1)
        #expect(await rig.connection.log == ["control \(Self.socket)"])
    }

    /// A kept kernel is not asked for again.
    @Test func aKeptKernelIsNotAskedForAgain() async throws {
        let server = await served(FakeRexWorld(sessions: [FakeRexWorld.studio()]))
        let memory = HerdrCoreHostMemory()
        let host = Self.host()
        memory.noteKernel(HerdrCoreLocator.linuxKernel, for: host.id)
        let rig = rig(ScriptedRexHost(control: [.server(server)]), host: host, memory: memory)
        defer { rig.projection.end() }

        #expect(rig.projection.kernel == HerdrCoreLocator.linuxKernel)
        try await waitUntil("the terminals") { !rig.projection.isAwaitingSnapshot }

        #expect(rig.projection.kernel == HerdrCoreLocator.linuxKernel)
        #expect(await versionReads(server) == 0)
    }

    /// A Host that stores no socket looks one up, and the look's own kernel
    /// is the one kept: nothing more is asked of the server.
    @Test func theLookThatFoundTheSocketNamesTheKernel() async throws {
        let server = await served(FakeRexWorld(sessions: [FakeRexWorld.studio()]))
        let connection = ScriptedRexHost(
            probe: ScriptedRexHost.probeFinding(Self.socket, kernel: HerdrCoreLocator.linuxKernel),
            control: [.server(server)])
        let rig = rig(connection, host: Self.host(storingSocket: false))
        defer { rig.projection.end() }

        try await waitUntil("the kernel") { rig.projection.kernel != nil }

        #expect(rig.projection.kernel == HerdrCoreLocator.linuxKernel)
        #expect(rig.memory.kernel(for: rig.host.id) == HerdrCoreLocator.linuxKernel)
        #expect(await versionReads(server) == 0)
        #expect(await connection.log == ["probe", "control \(Self.socket)"])
    }

    /// A server that names no platform leaves the kernel unknown, and the
    /// Host memory without one.
    @Test func aServerThatCannotSayLeavesTheKernelUnknown() async throws {
        let server = await served(FakeRexWorld(sessions: [FakeRexWorld.studio()], platform: nil))
        let rig = rig(ScriptedRexHost(control: [.server(server)]))
        defer { rig.projection.end() }

        try await waitUntil("the version read") { await versionReads(server) == 1 }
        try await waitUntil("the terminals") { !rig.projection.isAwaitingSnapshot }
        try await Task.sleep(for: .milliseconds(50))

        #expect(rig.projection.kernel == nil)
        #expect(rig.memory.kernel(for: rig.host.id) == nil)
    }

    // MARK: The read surface

    /// Chat reads a Rex Host's files and processes over the connection its
    /// server's links use. What it is handed is no Host's services, Transport
    /// or connection, so nothing can cast it back to write, and the Host's
    /// services stay closed. Nothing on the Host or the server changes.
    @Test func chatReadsTheHostAndCannotWriteToIt() async throws {
        let server = await served(FakeRexWorld(sessions: [FakeRexWorld.studio()]))
        let files = VirtualHostFiles(home: "/home/dev")
        let folder = "/home/dev/.claude/projects/-home-dev-app"
        let path = "\(folder)/e951205e-24af-4a5e-baa7-3ccbebd2de2c.jsonl"
        let line = Data("{\"type\":\"user\"}\n".utf8)
        await files.write(line, at: path)
        let connection = ScriptedRexHost(
            control: [.server(server)], files: files, processes: { _ in ["4242": HostProcessReader.Facts()] })
        let rig = rig(connection)
        defer { rig.projection.end() }
        try await waitUntil("the terminals") { !rig.projection.isAwaitingSnapshot }

        let chatFiles = rig.projection.chatHostFiles()
        let range = RemoteFileRange(path: path, offset: 0, maxBytes: 64)
        #expect(try await chatFiles.home() == "/home/dev")
        #expect(try await chatFiles.status(path)?.size == UInt64(line.count))
        #expect(try await chatFiles.list(RemoteFileListingRequest(directory: folder))?.entries.count == 1)
        #expect(try await chatFiles.read(range).data == line)
        #expect(try await rig.projection.sessionFileReader()(range).data == line)
        #expect(chatFiles.queryOpenCode == nil)
        #expect(try await rig.projection.modelContextWindowResolver()("gpt-5.5") == nil)

        let reads = try await rig.projection.session.withConnection { $0.transport.reads }
        #expect((reads as? any HostServices) == nil)
        #expect((reads as? any Transport) == nil)
        #expect((reads as? any RexHostConnection) == nil)
        #expect((reads as? any RexHostStaging) == nil)
        #expect(try await reads.readProcesses(HostProcessReader.Request(pids: ["4242"])).keys.sorted() == ["4242"])
        await #expect(throws: TransportError.self) {
            try await rig.projection.withHostServices { _ in 0 }
        }

        #expect(
            await connection.log == [
                "control \(Self.socket)", "home", "status \(path)", "list \(folder)", "read \(path)",
                "session read \(path)", "processes 4242",
            ])
        #expect(await files.contents(of: path) == line)
        #expect(Set(await server.requests.map(\.method)).isSubset(of: Self.serverReads))
    }

    /// What the projection asks of a Rex server for its rows and its Chat:
    /// reads only (ADR 0054).
    private static let serverReads: Set<String> = [
        "server.status", "server.version", "session.attach_all", "session.view", "session.list_blocks",
        RexInventoryWire.terminalMethod("title"), RexInventoryWire.terminalMethod("process"),
        RexInventoryWire.terminalMethod("program_status"),
    ]

    /// Reads take ordinary session slots and never the control link's events
    /// slot or a data link's attach slot, so reads that fill their slots hold
    /// up only the next read: the control link still answers, and a terminal
    /// still opens its data link.
    @Test func readsThatFillTheirSlotsHoldUpNoLink() async throws {
        let server = await served(FakeRexWorld(sessions: [FakeRexWorld.studio()]))
        let admission = SSHChannelAdmission()
        let gate = ScriptedTransportCallGate()
        let connection = ScriptedRexHost(
            control: [.server(server)], data: [.server(FakeRexServer(), welcome: nil)], admission: admission,
            processes: { _ in
                await gate.waitUntilOpen()
                return [:]
            })
        let rig = rig(connection)
        defer { rig.projection.end() }
        try await waitUntil("the terminals") { !rig.projection.isAwaitingSnapshot }
        let reads = try await rig.projection.session.withConnection { $0.transport.reads }

        let limit = SSHChannelAdmission.Limits.production.ordinarySession
        let held = (0...limit).map { index in
            Task { try await reads.readProcesses(HostProcessReader.Request(pids: [String(4000 + index)])) }
        }
        await gate.waitForEntry(count: limit)
        try await waitUntil("a read waiting for a slot") { await admission.waitingRequests() == 1 }

        _ = try await rig.projection.session.withConnection { try await $0.control.call("server.status") }
        let data = try await rig.projection.session.withConnection { try await $0.transport.openDataChannel() }
        #expect(await admission.snapshot().ordinarySession == limit)
        #expect(await admission.snapshot().attach == 1)

        await gate.open()
        for read in held { _ = try await read.value }
        try await data.close(timeout: .zero)
    }

    // MARK: Chat on a terminal

    private static let first = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
    private static let start = "Thu Nov 12 06:00:00 2026"
    private static let paneID = RexPaneAddress(sessionID: "session:studio", blockID: "block:left").paneID

    /// The studio with Claude Code in its left terminal, reporting `state`.
    private static func studioRunningClaude(reporting state: String = "working") -> FakeRexWorld.Session {
        var studio = FakeRexWorld.studio()
        var claude = FakeRexWorld.Block.running("block:left", program: "claude")
        claude.label = "left"
        claude.directory = "/home/dev/app"
        claude.status = claude.record(state, app: "claude")
        studio.windows[0].layers[0].blocks[2] = claude
        return studio
    }

    /// Claude Code's process in that terminal, as the Host lists it.
    private static func claudeProcess(pid: Int = 4242) -> ScriptedProcessTable.Process {
        .init(
            pid: pid, name: "claude", start: start,
            environment: [
                "REX_SESSION": "session:studio", "REX_BLOCK": "block:left",
                "REX_SERVER": "unix://%2Frun%2Fuser%2F1000%2Frex%2Fserver.sock", "HOME": "/home/dev",
            ])
    }

    private static func registryEntry(pid: Int = 4242) -> Data {
        Data(
            """
            {"pid":\(pid),"sessionId":"\(first)","cwd":"/home/dev/app","startedAt":1780000000000,\
            "procStart":"\(start)","version":"2.1.314","kind":"interactive","entrypoint":"cli",\
            "status":"idle","updatedAt":1780000000000}
            """.utf8)
    }

    private static func blockEvent(_ name: String, _ payload: JSONValue) -> JSONValue {
        ["block_id": "block:left", "creator_name": .string(RexInventoryWire.terminalCreator), "name": .string(name),
         "payload": payload]
    }

    private func details(_ rig: Rig) -> RexTerminalDetails? {
        RexPaneAddress(paneID: Self.paneID).flatMap { rig.projection.inventory?.details[$0] }
    }

    /// Until the kernel is known and Claude Code's terminal reads as Rex
    /// named it, a check could still answer differently. Its status shows
    /// before the other terminals' first reads answer, and each of those
    /// moves its terminal's revision when it does, so they are waited for too.
    private func waitForClaude(_ rig: Rig) async throws {
        try await waitUntil("Claude Code's terminal") {
            rig.projection.kernel != nil && !rig.projection.isAwaitingSnapshot
                && rig.projection.panesAwaitingForeground.isEmpty
                && details(rig)?.processID == 4242 && details(rig)?.program == "claude"
                && details(rig)?.status?.state != nil
        }
    }

    /// Every event pushed before it has reached the projection once its
    /// title shows.
    private func settle(_ rig: Rig, on server: FakeRexServer, title: String) async throws {
        await server.push(
            "block_event", Self.blockEvent("title_changed", ["title": .string(title)]), session: "session:studio")
        try await waitUntil("the title \(title)") { details(rig)?.title == title }
    }

    /// A Rex Host's Chat is process-bound and keyed to its server instance.
    /// The Host as the catalog has it knows no kernel, so its Chat opens only
    /// once a connection has learned one (ADR 0056).
    @Test func aRexHostsChatIsKeyedToItsServerInstance() async throws {
        let world = FakeRexWorld(sessions: [Self.studioRunningClaude()])
        let servers = [await served(world), await served(world)]
        let rig = rig(ScriptedRexHost(control: servers.map { .server($0) }))
        defer { rig.projection.end() }
        try await waitUntil("the terminals") { !rig.projection.isAwaitingSnapshot }

        #expect(rig.projection.usesProcessBoundChat)
        #expect(rig.projection.chatCacheScope == "rex:instance-0001")
        #expect(HostCapabilities.rexChatPrograms == [.claude, .codex, .pi, .omp])
        #expect(!rig.host.capabilities.chat)

        world.restart(as: "instance-0002")
        await servers[0].close(.goingAway, reason: "shutting down")
        try await waitUntil("the new server") { rig.projection.chatCacheScope == "rex:instance-0002" }
    }

    /// A check binds Claude Code in the terminal from one process read from
    /// the foreground Rex names, then its registry entry. A program a Rex
    /// Host does not bind, or a terminal no longer listed, cannot tell and
    /// reads nothing.
    @Test func aCheckBindsClaudeCodeInTheTerminal() async throws {
        let server = await served(FakeRexWorld(sessions: [Self.studioRunningClaude()]))
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: "/home/dev")
        await table.add(Self.claudeProcess())
        await files.write(Self.registryEntry(), at: "/home/dev/.claude/sessions/4242.json")
        let connection = ScriptedRexHost(
            control: [.server(server)], files: files, processes: { try await table.read($0) })
        let rig = rig(connection)
        defer { rig.projection.end() }
        try await waitForClaude(rig)

        #expect(
            try await rig.projection.checkChatSession(paneID: Self.paneID, program: .claude)
                == .bound(sessionID: Self.first, transcriptRoot: "/home/dev/.claude", directory: "/home/dev/app"))
        let request = try #require(await table.requests.first)
        #expect(request.pids == ["4242"])
        #expect(request.valuesOf.starts(with: ["REX_SESSION", "REX_BLOCK"]))

        let logged = await connection.log
        let grok = try await rig.projection.checkChatSession(paneID: Self.paneID, program: .grok)
        #expect(grok == .unavailable(.cannotTellSession(.grok)))
        let gone = RexPaneAddress(sessionID: "session:studio", blockID: "block:gone").paneID
        let unlisted = try await rig.projection.checkChatSession(paneID: gone, program: .claude)
        #expect(unlisted == .unavailable(.cannotTellSession(.claude)))
        #expect(try await rig.projection.chatCandidates(paneID: gone, program: .claude) == .noProcess)
        #expect(await connection.log == logged)
        #expect(rig.projection.chatCannotTell(.claude) == .cannotTellSession(.claude))
    }

    /// The revision moves when a check could answer differently: the
    /// terminal's foreground or Program Status changed. A title, or the same
    /// report made again, leaves it.
    @Test func theRevisionMovesOnlyWhenACheckCouldAnswerDifferently() async throws {
        let world = FakeRexWorld(sessions: [Self.studioRunningClaude()])
        let server = await served(world)
        let rig = rig(ScriptedRexHost(control: [.server(server)]))
        defer { rig.projection.end() }
        try await waitForClaude(rig)
        let claude = world.sessions[0].windows[0].layers[0].blocks[2]
        let other = RexPaneAddress(sessionID: "session:studio", blockID: "block:right").paneID
        let start = rig.projection.sessionEventRevision(of: Self.paneID)
        let otherStart = rig.projection.sessionEventRevision(of: other)

        try await settle(rig, on: server, title: "a new title")
        let again = claude.record("working", app: "claude", at: "2026-11-16T12:05:00+00:00")
        await server.push(
            "block_event", Self.blockEvent("program_status_changed", ["id": "", "record": again, "reason": "report"]),
            session: "session:studio")
        try await waitUntil("the report") { details(rig)?.status?.updatedAt == "2026-11-16T12:05:00+00:00" }
        #expect(rig.projection.sessionEventRevision(of: Self.paneID) == start)

        let blocked = claude.record("blocked", app: "claude")
        await server.push(
            "block_event", Self.blockEvent("program_status_changed", ["id": "", "record": blocked, "reason": "report"]),
            session: "session:studio")
        try await waitUntil("the new state") { details(rig)?.status?.state == "blocked" }
        let afterState = rig.projection.sessionEventRevision(of: Self.paneID)
        #expect(afterState != start)

        await server.push(
            "block_event",
            Self.blockEvent("process_changed", ["foreground": ["pid": 4300, "name": "claude", "cwd": "/home/dev/app"]]),
            session: "session:studio")
        try await waitUntil("the new foreground") { details(rig)?.processID == 4300 }
        #expect(rig.projection.sessionEventRevision(of: Self.paneID) != afterState)
        #expect(rig.projection.sessionEventRevision(of: other) == otherStart)
    }

    /// A pick is kept on this device for the terminal and its server
    /// instance, and binds while its process holds: nothing goes to the
    /// server or the Host, and another device knows nothing of it.
    @Test func aPickIsKeptOnThisDeviceOnly() async throws {
        let world = FakeRexWorld(sessions: [Self.studioRunningClaude()])
        let server = await served(world)
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: "/home/dev")
        await table.add(Self.claudeProcess())
        await files.write(
            Data("{\"type\":\"user\"}\n".utf8), at: "/home/dev/.claude/projects/-home-dev-app/\(Self.first).jsonl")
        let connection = ScriptedRexHost(
            control: [.server(server)], files: files, processes: { try await table.read($0) })
        let defaults = try #require(UserDefaults(suiteName: "rex-chat-picks-\(UUID().uuidString)"))
        let rig = rig(connection, memory: HerdrCoreHostMemory(defaults: defaults))
        defer { rig.projection.end() }
        try await waitForClaude(rig)

        #expect(
            try await rig.projection.checkChatSession(paneID: Self.paneID, program: .claude)
                == .unavailable(.cannotTellSession(.claude)))
        guard case .listed(let list) = try await rig.projection.chatCandidates(paneID: Self.paneID, program: .claude)
        else {
            Issue.record("Expected candidates")
            return
        }
        #expect(list.core == "instance-0001")
        #expect(list.pid == 4242)
        let candidate = try #require(list.candidates.first)
        let revision = rig.projection.sessionEventRevision(of: Self.paneID)

        try await rig.projection.writeChatPick(candidate, of: list, paneID: Self.paneID)

        #expect(rig.projection.sessionEventRevision(of: Self.paneID) != revision)
        let value = try #require(
            HerdrCoreSessionHint.pickLabelValue(session: Self.first, file: nil, pid: 4242, start: Self.start))
        let kept = HerdrCoreHostMemory.RexChatPick(label: value, foregroundPID: 4242, kind: "claude")
        #expect(rig.memory.rexChatPicks(for: rig.host.id) == [Self.paneID: kept])
        #expect(HerdrCoreHostMemory(defaults: defaults).rexChatPicks(for: rig.host.id) == [Self.paneID: kept])
        #expect(
            try await rig.projection.checkChatSession(paneID: Self.paneID, program: .claude)
                == .picked(sessionID: Self.first, transcriptRoot: "/home/dev/.claude"))

        let reads = ["control ", "home", "status ", "list ", "read ", "session read ", "processes "]
        let logged = await connection.log
        #expect(logged.allSatisfy { entry in reads.contains { entry.hasPrefix($0) } })
        #expect(Set(await server.requests.map(\.method)).isSubset(of: Self.serverReads))

        // Another device on the same server knows nothing of it.
        let another = ScriptedRexHost(
            control: [.server(await served(world))], files: files, processes: { try await table.read($0) })
        let elsewhere = self.rig(another)
        defer { elsewhere.projection.end() }
        try await waitForClaude(elsewhere)
        #expect(
            try await elsewhere.projection.checkChatSession(paneID: Self.paneID, program: .claude)
                == .unavailable(.cannotTellSession(.claude)))
        #expect(elsewhere.memory.rexChatPicks(for: elsewhere.host.id).isEmpty)
    }

    /// A pick goes when the terminal runs another process or another program,
    /// or another server instance answers, and when a send guard drops it,
    /// but only for the scope it was made in.
    @Test func aPickGoesWithWhatItWasMadeOn() async throws {
        let world = FakeRexWorld(sessions: [Self.studioRunningClaude()])
        let servers = [await served(world), await served(world)]
        let rig = rig(ScriptedRexHost(control: servers.map { .server($0) }))
        defer { rig.projection.end() }
        try await waitForClaude(rig)
        let value = try #require(
            HerdrCoreSessionHint.pickLabelValue(session: Self.first, file: nil, pid: 4242, start: Self.start))
        let list = ChatSessionCandidates(
            pid: 4242, start: Self.start, transcriptRoot: "/home/dev/.claude", directories: ["/home/dev/app"],
            core: "instance-0001", candidates: [])
        let candidate = ChatSessionCandidate(sessionID: Self.first, file: nil, origins: [.recentTranscript])
        func pick() -> String? { rig.memory.rexChatPicks(for: rig.host.id)[Self.paneID]?.label }
        func foreground(_ pid: Int, _ name: String) async throws {
            await servers[0].push(
                "block_event",
                Self.blockEvent("process_changed", ["foreground": ["pid": .number(Double(pid)), "name": .string(name)]]),
                session: "session:studio")
            try await settle(rig, on: servers[0], title: "\(name) \(pid)")
        }

        try await rig.projection.writeChatPick(candidate, of: list, paneID: Self.paneID)
        #expect(pick() == value)
        // The same foreground read again keeps it.
        try await foreground(4242, "claude")
        #expect(details(rig)?.processID == 4242)
        #expect(pick() == value)
        // Another process in the terminal, though the same program, voids it.
        try await foreground(4300, "claude")
        #expect(pick() == nil)

        try await rig.projection.writeChatPick(candidate, of: list, paneID: Self.paneID)
        #expect(rig.memory.rexChatPicks(for: rig.host.id)[Self.paneID]?.foregroundPID == 4300)
        try await foreground(4300, "zsh")
        #expect(pick() == nil)

        try await foreground(4400, "claude")
        try await rig.projection.writeChatPick(candidate, of: list, paneID: Self.paneID)
        let revision = rig.projection.sessionEventRevision(of: Self.paneID)
        rig.projection.dropChatPick(paneID: Self.paneID, scope: "rex:instance-0009", program: .claude)
        #expect(pick() == value)
        rig.projection.dropChatPick(paneID: Self.paneID, scope: rig.projection.chatCacheScope, program: .claude)
        #expect(pick() == nil)
        #expect(rig.projection.sessionEventRevision(of: Self.paneID) != revision)

        try await rig.projection.writeChatPick(candidate, of: list, paneID: Self.paneID)
        world.restart(as: "instance-0002")
        await servers[0].close(.goingAway, reason: "shutting down")
        try await waitUntil("the new server") { rig.projection.chatCacheScope == "rex:instance-0002" }
        #expect(rig.memory.rexChatPicks(for: rig.host.id).isEmpty)
        // A list made on the last instance picks nothing on this one.
        try await waitUntil("the new server's terminals") { !rig.projection.isAwaitingSnapshot }
        await #expect(throws: TransportError.rexServerGone) {
            try await rig.projection.writeChatPick(candidate, of: list, paneID: Self.paneID)
        }
    }

    // MARK: Pi and Oh My Pi, through Heeler's extension (ADR 0056)

    private static let piAgent = "/home/dev/.pi/agent"
    private static let piSession = "\(piAgent)/sessions/--home-dev-app--/2026-11-18T07-15-55-433Z_\(first).jsonl"
    private static let piSessionRecord = "\(piAgent)/heeler-session/4242.json"
    private static let piExtension = "\(piAgent)/extensions/heeler-session.js"

    /// The studio with Pi in its left terminal, reporting idle.
    private static func studioRunningPi() -> FakeRexWorld.Session {
        var studio = FakeRexWorld.studio()
        var pi = FakeRexWorld.Block.running("block:left", program: "pi")
        pi.label = "left"
        pi.directory = "/home/dev/app"
        pi.status = pi.record("idle", app: "pi")
        studio.windows[0].layers[0].blocks[2] = pi
        return studio
    }

    /// Pi's process in that terminal, with nothing set that moves its files.
    private static func piProcess() -> ScriptedProcessTable.Process {
        .init(
            pid: 4242, name: "pi", start: start,
            environment: ["REX_SESSION": "session:studio", "REX_BLOCK": "block:left", "HOME": "/home/dev"])
    }

    /// What the extension keeps for a process: the label's own shape.
    private static func sessionRecord(start: String = RexChatTests.start) -> Data {
        Data(#"{"session":"\#(first)","file":"\#(piSession)","pid":4242,"start":"\#(start)"}"#.utf8)
    }

    /// A projection on a Host whose left terminal runs Pi, with its files.
    private func piRig() async throws -> (rig: Rig, files: VirtualHostFiles, connection: ScriptedRexHost) {
        let server = await served(FakeRexWorld(sessions: [Self.studioRunningPi()]))
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: "/home/dev")
        await table.add(Self.piProcess())
        let connection = ScriptedRexHost(
            control: [.server(server)], files: files, processes: { try await table.read($0) })
        let rig = rig(connection)
        try await waitUntil("Pi's terminal") {
            rig.projection.kernel != nil && !rig.projection.isAwaitingSnapshot
                && details(rig)?.processID == 4242 && details(rig)?.program == "pi"
        }
        return (rig, files, connection)
    }

    /// Pi binds from the file Heeler's extension keeps for its process under
    /// the Agent's own directory, held against that process by pid and
    /// start. A file a reused pid left names nothing.
    @Test func aCheckBindsPiFromWhatItsExtensionKeeps() async throws {
        let (rig, files, _) = try await piRig()
        defer { rig.projection.end() }
        await files.write(Self.sessionRecord(), at: Self.piSessionRecord)

        #expect(
            try await rig.projection.checkChatSession(paneID: Self.paneID, program: .pi)
                == .bound(sessionID: Self.piSession, transcriptRoot: "\(Self.piAgent)/sessions", directory: nil))

        await files.write(Self.sessionRecord(start: "Wed Nov 11 06:00:00 2026"), at: Self.piSessionRecord)
        #expect(
            try await rig.projection.checkChatSession(paneID: Self.paneID, program: .pi)
                == .unavailable(.cannotTellSessionOnRex(.pi, extensionInPlace: false)))
    }

    /// Rex announces a foreground once, as it starts: Pi under Node is `node`
    /// then, takes its own name after, and is never announced again. A check
    /// goes by what Rex names when it is made, so the name it announced does
    /// not keep a Chat that stayed open from the process a read finds.
    @Test func aCheckGoesByTheForegroundRexNamesNow() async throws {
        var studio = FakeRexWorld.studio()
        var pi = FakeRexWorld.Block.running("block:left", program: "node", argv0: "pi")
        pi.label = "left"
        pi.directory = "/home/dev/app"
        pi.status = pi.record("idle", app: "pi")
        studio.windows[0].layers[0].blocks[2] = pi
        let server = await served(FakeRexWorld(sessions: [studio]))
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: "/home/dev")
        await table.add(Self.piProcess())
        await files.write(Self.sessionRecord(), at: Self.piSessionRecord)
        let rig = rig(
            ScriptedRexHost(control: [.server(server)], files: files, processes: { try await table.read($0) }))
        defer { rig.projection.end() }
        try await waitUntil("Pi's terminal") {
            rig.projection.kernel != nil && !rig.projection.isAwaitingSnapshot && details(rig)?.processID == 4242
        }
        // What Rex announced as Pi started, before Pi took its name.
        await server.push(
            "block_event",
            Self.blockEvent(
                "process_changed", ["foreground": ["pid": 4242, "name": "node", "argv0": "node"]]),
            session: "session:studio")
        try await waitUntil("the announced foreground") { details(rig)?.argv0 == "node" }

        #expect(
            try await rig.projection.checkChatSession(paneID: Self.paneID, program: .pi)
                == .bound(sessionID: Self.piSession, transcriptRoot: "\(Self.piAgent)/sessions", directory: nil))
        #expect(
            try await rig.projection.chatExtensionFolder(paneID: Self.paneID) == "\(Self.piAgent)/extensions")
    }

    private final class ManualClock: @unchecked Sendable {
        private let time = Mutex(Date(timeIntervalSince1970: 1_795_000_000))
        var now: Date { time.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
    }

    /// What a check answers next, and how many were made.
    private actor ScriptedEvidence {
        private(set) var checks = 0
        private var answer: ChatSessionEvidence

        init(_ answer: ChatSessionEvidence) {
            self.answer = answer
        }

        func set(_ next: ChatSessionEvidence) {
            answer = next
        }

        func check() -> ChatSessionEvidence {
            checks += 1
            return answer
        }
    }

    /// Heeler's extension names the conversation in a file just after the
    /// program starts, and Rex announces nothing when it does. So a check
    /// that couldn't tell is followed by a few more on Chat's own clock, each
    /// wait once, and then by none until something else asks for a check.
    @Test func aPiThatNamesNothingYetIsCheckedAgainAFewTimes() async throws {
        let clock = ManualClock()
        let inPlace = ChatUnavailableReason.cannotTellSessionOnRex(.pi, extensionInPlace: true)
        let evidence = ScriptedEvidence(.unavailable(inPlace))
        let agent = Agent(
            terminalID: "t1", kind: "pi", title: "", status: .idle, workspaceID: "w1", tabID: "t1",
            paneID: Self.paneID, cwd: "/home/dev/app", revision: 1, agentSession: nil)
        let files = VirtualHostFiles(home: "/home/dev")
        let host = Self.host()
        let chat = AgentChatStore(
            agentID: ConsoleAgent.ID(hostID: host.id, paneID: Self.paneID), agent: agent, program: .pi,
            source: AgentChatSource(
                hostID: host.id, socketLocation: .defaultSession, files: files.hostFiles(),
                agentInfo: { agent }, cache: VolatileChatTranscriptCache(),
                adapter: try #require(ChatTranscriptAdapter.standard(for: .pi)),
                sessionEvidence: { await evidence.check() }),
            now: { clock.now })
        let waits = AgentChatStore.Timing().unannouncedEvidenceChecks
        #expect(!waits.isEmpty)

        await chat.step()
        #expect(await evidence.checks == 1)
        #expect(chat.conversation.phase == .unavailable(inPlace))
        for (index, wait) in waits.enumerated() {
            await chat.step()
            #expect(await evidence.checks == index + 1)
            #expect(chat.interval <= .seconds(wait))
            clock.advance(wait)
            await chat.step()
            #expect(await evidence.checks == index + 2)
        }
        clock.advance(600)
        await chat.step()
        #expect(await evidence.checks == waits.count + 1)

        // A check something else asks for starts the waits again, and the
        // first of them finds what the extension has kept by then.
        chat.sessionEvidenceMayHaveChanged()
        await chat.step()
        #expect(await evidence.checks == waits.count + 2)
        await evidence.set(
            .bound(sessionID: Self.piSession, transcriptRoot: "\(Self.piAgent)/sessions", directory: nil))
        clock.advance(waits[0])
        await chat.step()
        #expect(await evidence.checks == waits.count + 3)
        #expect(chat.conversation.phase != .unavailable(inPlace))
        chat.end()
    }

    /// With nothing kept for the process, the reason says what the Agent's
    /// extension folder holds: none, or one from before the extension
    /// reported in a Rex terminal, offers Heeler's; one that reports there
    /// was not loaded by this process, which a restart mends.
    @Test func aPiThatNamesNothingSaysWhatItsExtensionFolderHolds() async throws {
        let (rig, files, _) = try await piRig()
        defer { rig.projection.end() }
        func reason() async throws -> ChatSessionEvidence {
            try await rig.projection.checkChatSession(paneID: Self.paneID, program: .pi)
        }
        let absent = ChatUnavailableReason.cannotTellSessionOnRex(.pi, extensionInPlace: false)
        let inPlace = ChatUnavailableReason.cannotTellSessionOnRex(.pi, extensionInPlace: true)

        #expect(try await reason() == .unavailable(absent))
        await files.write("const terminal = process.env.HC_TERMINAL_ID;\n", at: Self.piExtension)
        #expect(try await reason() == .unavailable(absent))
        await files.write("if (!env.REX_SESSION || !env.REX_BLOCK) return null;\n", at: Self.piExtension)
        #expect(try await reason() == .unavailable(inPlace))

        #expect(rig.projection.chatCannotTell(.pi) == absent)
        #expect(rig.projection.chatCannotTell(.omp) == .cannotTellSessionOnRex(.omp, extensionInPlace: false))
        #expect(absent.offersHeelersExtension)
        #expect(!inPlace.offersHeelersExtension)
        #expect(absent.offersRetry && inPlace.offersRetry)
        #expect(!absent.leavesItToAPick && !inPlace.leavesItToAPick)
        #expect(!ChatUnavailableReason.cannotTellSession(.claude).offersHeelersExtension)
    }

    /// Chat's offer writes Heeler's extension into the one folder the Agent
    /// loads from, found from its own process, and nowhere else. A terminal
    /// that runs no such Agent has no folder, and a server that has moved on
    /// takes no write.
    @Test func theExtensionGoesOnlyWhereTheAgentLoadsItFrom() async throws {
        let world = FakeRexWorld(sessions: [Self.studioRunningPi()])
        let servers = [await served(world), await served(world)]
        let table = ScriptedProcessTable()
        await table.add(Self.piProcess())
        let connection = ScriptedRexHost(
            control: servers.map { .server($0) }, files: VirtualHostFiles(home: "/home/dev"),
            processes: { try await table.read($0) })
        let rig = rig(connection)
        defer { rig.projection.end() }
        try await waitUntil("Pi's terminal") {
            rig.projection.kernel != nil && !rig.projection.isAwaitingSnapshot && details(rig)?.processID == 4242
        }
        let folder = "\(Self.piAgent)/extensions"
        let pin = TerminalCorePin(joined: rig.projection.inventoryCore)

        #expect(try await rig.projection.chatExtensionFolder(paneID: Self.paneID) == folder)
        let shell = RexPaneAddress(sessionID: "session:studio", blockID: "block:right").paneID
        await #expect(throws: TransportError.self) { try await rig.projection.chatExtensionFolder(paneID: shell) }
        #expect(await connection.placedExtensions.isEmpty)

        let revision = rig.projection.sessionEventRevision(of: Self.paneID)
        try await rig.projection.placeChatExtension(Data("extension".utf8), inFolder: folder, keepingTo: pin)
        let placed = await connection.placedExtensions
        #expect(placed.map(\.folder) == [folder])
        #expect(placed.first?.contents == Data("extension".utf8))
        #expect(rig.projection.sessionEventRevision(of: Self.paneID) != revision)

        world.restart(as: "instance-0002")
        await servers[0].close(.goingAway, reason: "shutting down")
        try await waitUntil("the new server") { rig.projection.chatCacheScope == "rex:instance-0002" }
        await #expect(throws: TransportError.rexServerGone) {
            try await rig.projection.placeChatExtension(Data("extension".utf8), inFolder: folder, keepingTo: pin)
        }
        #expect(await connection.placedExtensions.count == 1)
    }
}
