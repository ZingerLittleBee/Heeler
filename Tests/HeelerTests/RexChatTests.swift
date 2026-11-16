import Foundation
import Synchronization
import Testing

@testable import Heeler

/// What a Rex Host's projection keeps and reads for process-bound Chat, as a
/// tmux Host's does (ADRs 0034 and 0044): the Host's kernel, kept on this
/// device and learned from the server, never from an exec of its own.
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
}
