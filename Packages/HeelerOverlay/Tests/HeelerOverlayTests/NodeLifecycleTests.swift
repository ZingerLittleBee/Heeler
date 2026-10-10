import Foundation
import Testing

@testable import HeelerOverlay

/// Start/stop bookkeeping of the nodes, with the native layers replaced by
/// fakes that make the racy windows wide.
@Suite("Overlay node lifecycle")
struct NodeLifecycleTests {
    // MARK: Tailscale

    @Test func restartingAfterStopNeverRunsTwoServersOnOneStateDirectory() async throws {
        let native = FakeTailscaleNative(createDelay: .milliseconds(50), closeDelay: .milliseconds(300))
        let node = TailscaleNode(configuration: Self.tailscaleConfiguration, native: native)

        try await node.start(timeout: .seconds(5))
        #expect(native.openCount == 1)

        // A start re-entering while stop's close is still running must wait
        // for that close before it creates a new server.
        async let stopped: Void = node.stop()
        try await Task.sleep(for: .milliseconds(20))
        try await node.start(timeout: .seconds(5))
        await stopped

        #expect(native.maximumOpen == 1)
        #expect(native.openCount == 1)
        #expect(await node.status() == .online(addresses: ["100.64.0.1"]))

        await node.stop()
        #expect(native.openCount == 0)
        #expect(native.maximumOpen == 1)
    }

    @Test func stoppingDuringCreationClosesTheServerOnce() async throws {
        let native = FakeTailscaleNative(createDelay: .milliseconds(200), closeDelay: .milliseconds(10))
        let node = TailscaleNode(configuration: Self.tailscaleConfiguration, native: native)

        let starting = Task { try await node.start(timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        await node.stop()

        await #expect(throws: OverlayError.cancelled) { try await starting.value }
        #expect(native.openCount == 0)
        #expect(native.closeCount == 1)
        #expect(await node.status() == .stopped)

        // The node starts cleanly afterwards.
        try await node.start(timeout: .seconds(5))
        #expect(native.openCount == 1)
        #expect(native.maximumOpen == 1)
        await node.stop()
    }

    @Test func cancellingAStartClosesTheServerItWasStarting() async throws {
        let native = FakeTailscaleNative(createDelay: .milliseconds(10), closeDelay: .milliseconds(100))
        native.stuck = true
        let node = TailscaleNode(configuration: Self.tailscaleConfiguration, native: native)

        let starting = Task { try await node.start(timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(native.openCount == 1)
        let cancelled = ContinuousClock.now
        starting.cancel()
        await #expect(throws: OverlayError.cancelled) { try await starting.value }
        // Returns at once, not at the 30 s deadline nor after the close.
        #expect(ContinuousClock.now - cancelled < .seconds(1))
        #expect(await node.status() == .stopped)

        // The close went through the lifecycle queue; a new start creates
        // its server only after it, never two at once.
        native.stuck = false
        try await node.start(timeout: .seconds(5))
        #expect(native.closeCount == 1)
        #expect(native.openCount == 1)
        #expect(native.maximumOpen == 1)
        await node.stop()
    }

    @Test func aCancelledStartKeepsAServerAnotherStartStillWaitsFor() async throws {
        let native = FakeTailscaleNative(createDelay: .milliseconds(10), closeDelay: .milliseconds(10))
        native.stuck = true
        let node = TailscaleNode(configuration: Self.tailscaleConfiguration, native: native)

        let first = Task { try await node.start(timeout: .seconds(30)) }
        let second = Task { try await node.start(timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        first.cancel()
        await #expect(throws: OverlayError.cancelled) { try await first.value }
        #expect(native.closeCount == 0)

        native.stuck = false
        try await second.value
        #expect(await node.status() == .online(addresses: ["100.64.0.1"]))
        await node.stop()
    }

    @Test func cancellingAStartOfAnOnlineServerLeavesItRunning() async throws {
        let native = FakeTailscaleNative(createDelay: .milliseconds(10), closeDelay: .milliseconds(10))
        let node = TailscaleNode(configuration: Self.tailscaleConfiguration, native: native)
        try await node.start(timeout: .seconds(5))

        native.stuck = true
        let again = Task { try await node.start(timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        again.cancel()
        await #expect(throws: OverlayError.cancelled) { try await again.value }
        // Streams may already ride this server.
        #expect(native.closeCount == 0)
        #expect(native.openCount == 1)
        await node.stop()
    }

    @Test func logoutClosesTheRunningServerBeforeSigningOut() async throws {
        let native = FakeTailscaleNative(createDelay: .milliseconds(20), closeDelay: .milliseconds(200))
        let node = TailscaleNode(configuration: Self.tailscaleConfiguration, native: native)
        #expect(await node.details() == OverlayNodeDetails())

        try await node.start(timeout: .seconds(5))
        #expect(await node.details().nodeID == "nFake")

        try await node.logout(timeout: .seconds(5))
        #expect(native.logoutCount == 1)
        // The logout's own server never overlapped the node's.
        #expect(native.maximumOpen == 1)
        #expect(native.openCount == 0)
        #expect(await node.status() == .stopped)
        #expect(await node.details() == OverlayNodeDetails())

        // A failed sign-out is reported.
        native.failLogout = true
        await #expect(throws: OverlayError.startFailed("offline")) {
            try await node.logout(timeout: .seconds(1))
        }
    }

    @Test func logoutWithoutStateOnlyEmptiesTheDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsnet-logout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try LiveTailscaleNative.prepareStateDirectory(directory)
        let leftover = directory.appendingPathComponent("tailscaled.log.conf")
        try Data("{}".utf8).write(to: leftover)
        #expect(!LiveTailscaleNative.hasLoginState(directory))

        let configuration = TailscaleConfiguration(
            stateDirectory: directory, hostname: "heeler-test", authKey: "tskey-unused", controlURL: nil)
        let result = LiveTailscaleNative().logout(configuration, timeoutMilliseconds: 1000)
        #expect((try? result.get()) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        // The directory and its owner-only permissions stay.
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        // A missing directory is already signed out.
        let missing = directory.appendingPathComponent("missing", isDirectory: true)
        let other = TailscaleConfiguration(
            stateDirectory: missing, hostname: "heeler-test", authKey: nil, controlURL: nil)
        #expect((try? LiveTailscaleNative().logout(other, timeoutMilliseconds: 1000).get()) != nil)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    // MARK: ZeroTier

    @Test func stoppingDuringJoinGivesTheNetworkBack() async throws {
        let runtime = FakeZeroTierRuntime(joinDelay: .milliseconds(300))
        let node = ZeroTierNetworkNode(
            configuration: ZeroTierConfiguration(networkID: 0x8056_c2e2_1c00_0001, identity: nil),
            identityGenerated: { _ in },
            runtime: runtime)

        let starting = Task { try await node.start(timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        await node.stop()

        await #expect(throws: OverlayError.cancelled) { try await starting.value }
        #expect(await runtime.references(0x8056_c2e2_1c00_0001) == 0)
        #expect(await node.status() == .stopped)

        try await node.start(timeout: .seconds(5))
        #expect(await runtime.references(0x8056_c2e2_1c00_0001) == 1)
        await node.stop()
        #expect(await runtime.references(0x8056_c2e2_1c00_0001) == 0)
    }

    @Test func cancellingTheWaitForAnAddressKeepsTheNetworkJoined() async throws {
        let runtime = FakeZeroTierRuntime(joinDelay: .milliseconds(1), ready: false)
        let node = ZeroTierNetworkNode(
            configuration: ZeroTierConfiguration(networkID: 42, identity: nil),
            identityGenerated: { _ in },
            runtime: runtime)

        let starting = Task { try await node.start(timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelled = ContinuousClock.now
        starting.cancel()
        await #expect(throws: OverlayError.cancelled) { try await starting.value }
        #expect(ContinuousClock.now - cancelled < .seconds(1))
        // Still joined: an address or an approval that comes later applies
        // without joining again.
        #expect(await runtime.references(42) == 1)

        await runtime.setReady(true)
        try await node.start(timeout: .seconds(5))
        #expect(await runtime.references(42) == 1)
        await node.stop()
        #expect(await runtime.references(42) == 0)
    }

    @Test func concurrentStartsHoldOneNetworkReference() async throws {
        let runtime = FakeZeroTierRuntime(joinDelay: .milliseconds(100))
        let reported = Recorder()
        let node = ZeroTierNetworkNode(
            configuration: ZeroTierConfiguration(networkID: 42, identity: nil),
            identityGenerated: { reported.record($0.count) },
            runtime: runtime)

        async let first: Void = node.start(timeout: .seconds(5))
        async let second: Void = node.start(timeout: .seconds(5))
        _ = try await (first, second)

        #expect(await runtime.references(42) == 1)
        #expect(reported.values == [FakeZeroTierRuntime.identity.count])
        await node.stop()
        #expect(await runtime.references(42) == 0)
    }

    @Test func moonsAreHeldWhileJoinedAndGivenBackOnStopOrLogout() async throws {
        let runtime = FakeZeroTierRuntime(joinDelay: .milliseconds(10))
        let moon = ZeroTierMoon(worldID: 0xdead_beef_00, seed: 0xdead_beef_00)
        let node = ZeroTierNetworkNode(
            configuration: ZeroTierConfiguration(networkID: 42, identity: nil, moons: [moon, moon]),
            identityGenerated: { _ in },
            runtime: runtime)

        try await node.start(timeout: .seconds(5))
        #expect(await runtime.moonReferences(moon) == 1)
        try await node.start(timeout: .seconds(5))
        #expect(await runtime.moonReferences(moon) == 1)
        await node.stop()
        #expect(await runtime.moonReferences(moon) == 0)

        try await node.start(timeout: .seconds(5))
        try await node.logout(timeout: .seconds(1))
        #expect(await runtime.moonReferences(moon) == 0)
        #expect(await runtime.references(42) == 0)
    }

    @Test func detailsUseTheConfiguredIdentityUntilJoined() async throws {
        let runtime = FakeZeroTierRuntime(joinDelay: .milliseconds(1))
        let identity = Data("89e92ceee5:0:public:secret".utf8)
        let node = ZeroTierNetworkNode(
            configuration: ZeroTierConfiguration(networkID: 42, identity: identity),
            identityGenerated: { _ in },
            runtime: runtime)
        #expect(await node.details() == OverlayNodeDetails(nodeID: "89e92ceee5"))

        try await node.start(timeout: .seconds(5))
        let joined = await node.details()
        #expect(joined.nodeID == "abcdef0123")
        #expect(joined.addresses == ["10.147.17.2"])
        #expect(joined.peers == [])
        await node.stop()
    }

    @Test func identityConflictsAreDetectedInEveryState() {
        let a = "aaaaaaaaaa:0:a"
        let b = "bbbbbbbbbb:0:b"

        // nil accepts whatever runs; a minted identity cannot match.
        #expect(ZeroTierRuntime.conflict(requestedIdentity: nil, runningIdentity: a) == nil)
        #expect(ZeroTierRuntime.conflict(requestedIdentity: a, runningIdentity: a) == nil)
        #expect(ZeroTierRuntime.conflict(requestedIdentity: b, runningIdentity: a)
            == ZeroTierRuntime.identityConflict)
        #expect(ZeroTierRuntime.conflict(requestedIdentity: a, runningIdentity: nil)
            == ZeroTierRuntime.identityConflict)
        #expect(ZeroTierRuntime.conflict(requestedIdentity: nil, runningIdentity: nil) == nil)
    }

    @Test func waitingForATaskHonorsTheDeadlineAndLeavesItRunning() async throws {
        let finished = Recorder()
        let slow = Task<Int, Never> {
            try? await Task.sleep(for: .seconds(1))
            finished.record(5)
            return 5
        }
        let started = ContinuousClock.now
        await #expect(throws: OverlayError.timedOut) {
            _ = try await BlockingCall.wait(for: slow, timeout: .milliseconds(50))
        }
        // Well before the task's own second, even on a loaded runner.
        #expect(ContinuousClock.now - started < .milliseconds(800))
        #expect(await finished.waitForValue() == 5)
        #expect(try await BlockingCall.wait(for: slow, timeout: .seconds(1)) == 5)
    }

    @Test func stateDirectoryIsTightenedEvenWhenItExists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsnet-dir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        try LiveTailscaleNative.prepareStateDirectory(directory)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    private static let tailscaleConfiguration = TailscaleConfiguration(
        stateDirectory: URL(fileURLWithPath: "/tmp/heeler-fake-tsnet"),
        hostname: "heeler-test",
        authKey: nil,
        controlURL: nil)
}

/// Counts live servers; creation and close take time like tsnet's do.
private final class FakeTailscaleNative: TailscaleNative, @unchecked Sendable {
    private let lock = NSLock()
    private var open: Set<Int32> = []
    private var next: Int32 = 1
    private var maximum = 0
    private var closes = 0
    private let createDelay: Duration
    private let closeDelay: Duration

    init(createDelay: Duration, closeDelay: Duration) {
        self.createDelay = createDelay
        self.closeDelay = closeDelay
    }

    private var logouts = 0
    private var shouldFailLogout = false

    var openCount: Int { locked { open.count } }
    var maximumOpen: Int { locked { maximum } }
    var closeCount: Int { locked { closes } }
    var logoutCount: Int { locked { logouts } }
    var failLogout: Bool {
        get { locked { shouldFailLogout } }
        set { locked { shouldFailLogout = newValue } }
    }

    func createAndStart(_ configuration: TailscaleConfiguration) -> Result<Int32, OverlayError> {
        usleep(UInt32(createDelay.milliseconds * 1000))
        return .success(locked {
            let handle = next
            next += 1
            open.insert(handle)
            maximum = max(maximum, open.count)
            return handle
        })
    }

    func close(_ handle: Int32) {
        usleep(UInt32(closeDelay.milliseconds * 1000))
        locked {
            if open.remove(handle) != nil { closes += 1 }
        }
    }

    /// While set, the server never comes online (no coordination server).
    private var isStuck = false
    var stuck: Bool {
        get { locked { isStuck } }
        set { locked { isStuck = newValue } }
    }

    func status(_ handle: Int32) -> TailscaleStatus? {
        TailscaleStatus(
            backendState: stuck ? .starting : .running, authURL: nil, addresses: ["100.64.0.1"], health: [],
            details: OverlayNodeDetails(nodeID: "nFake", addresses: ["100.64.0.1"], peers: []))
    }

    /// Like the live logout: its own server on the state directory.
    func logout(_ configuration: TailscaleConfiguration, timeoutMilliseconds: Int32) -> Result<Void, OverlayError> {
        guard case .success(let handle) = createAndStart(configuration) else { return .failure(.startFailed("fake")) }
        close(handle)
        // `close` counted the logout's server; only the node's own count.
        return locked {
            closes -= 1
            logouts += 1
            return shouldFailLogout ? .failure(.startFailed("offline")) : .success(())
        }
    }

    func dial(_ handle: Int32, address: String) -> Result<Int32, OverlayError> {
        .failure(.dialFailed("fake"))
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Reference-counts joins like `ZeroTierRuntime`, with a slow join.
private actor FakeZeroTierRuntime: ZeroTierNetworkRuntime {
    static let identity = Data("abcdef0123:0:fake".utf8)
    private var joined: [UInt64: Int] = [:]
    private var moons = ZeroTierMoonOrbits()
    private var planets = ZeroTierLocalMoons()
    private let joinDelay: Duration
    /// Whether a joined network has its address; when not, waits poll.
    private var ready: Bool

    init(joinDelay: Duration, ready: Bool = true) {
        self.joinDelay = joinDelay
        self.ready = ready
    }

    func setReady(_ ready: Bool) {
        self.ready = ready
    }

    func references(_ networkID: UInt64) -> Int {
        joined[networkID, default: 0]
    }

    func moonReferences(_ moon: ZeroTierMoon) -> Int {
        moons.references[moon, default: 0]
    }

    func planetReferences() -> Int {
        planets.references.values.reduce(0, +)
    }

    func startNode(identity: Data?, deadline: OverlayDeadline) async throws -> Data {
        Self.identity
    }

    func join(_ networkID: UInt64, moons: [ZeroTierMoon], planet: ZeroTierPlanet?) async throws {
        joined[networkID, default: 0] += 1
        self.moons.retain(moons)
        planets.retain(planet)
        try? await Task.sleep(for: joinDelay)
    }

    func waitUntilReady(_ networkID: UInt64, deadline: OverlayDeadline) async throws {
        while !ready {
            do {
                try await deadline.pause(.milliseconds(20))
            } catch OverlayError.cancelled {
                throw ZeroTierRuntime.NotReady.cancelled
            } catch {
                throw ZeroTierRuntime.NotReady.timedOut
            }
        }
    }

    func leave(_ networkID: UInt64, moons: [ZeroTierMoon], planet: ZeroTierPlanet?) async {
        guard let count = joined[networkID] else { return }
        joined[networkID] = count > 1 ? count - 1 : nil
        self.moons.release(moons)
        planets.release(planet)
    }

    func details(joinedNetwork: UInt64?) async -> OverlayNodeDetails {
        var details = OverlayNodeDetails(nodeID: "abcdef0123")
        if let joinedNetwork, joined[joinedNetwork] != nil {
            details.addresses = ["10.147.17.2"]
            details.peers = []
        }
        return details
    }

    func networkSnapshot(_ networkID: UInt64) async -> ZeroTierRuntime.NetworkSnapshot {
        ZeroTierRuntime.NetworkSnapshot(
            isReady: joined[networkID] != nil && ready, addresses: ["10.147.17.2"], failure: nil)
    }
}
