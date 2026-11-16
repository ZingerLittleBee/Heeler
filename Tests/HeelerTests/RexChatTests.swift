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
    /// on a Mac; only a system Heeler knows reads as a kernel.
    @Test(arguments: [
        ("darwin_arm64", HerdrCoreLocator.macOSKernel),
        ("darwin_x86_64", HerdrCoreLocator.macOSKernel),
        ("linux_x86_64", HerdrCoreLocator.linuxKernel),
        ("x86_64-unknown-linux-gnu", HerdrCoreLocator.linuxKernel),
        ("windows_x86_64", nil),
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
}
