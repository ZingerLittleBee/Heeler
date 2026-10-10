import Foundation
import Testing

@testable import HeelerOverlay

@Suite("ZeroTier identities, moons, and peers")
struct ZeroTierDetailsTests {
    @Test func nodeIDIsTheIdentitysAddressField() {
        #expect(ZeroTierIdentity.nodeID(of: Data("89E92CEEE5:0:abcdef:0123".utf8)) == "89e92ceee5")
        #expect(ZeroTierIdentity.nodeID(of: Data("89e92ceee5:0:abcdef".utf8)) == "89e92ceee5")
        for text in ["", "89e92ceee:0:a", "89e92ceee55:0:a", "89e92ceeeg:0:a", ":89e92ceee5"] {
            #expect(ZeroTierIdentity.nodeID(of: Data(text.utf8)) == nil, "\(text)")
        }
        #expect(ZeroTierIdentity.nodeID(of: Data([0xff, 0xfe])) == nil)
    }

    @Test func generatedIdentitiesAreValidAndNameTheirNode() throws {
        // zts_id_new needs no running node.
        let identity = try ZeroTierIdentity.generate()
        let text = try #require(String(data: identity, encoding: .utf8))
        #expect(ZeroTierRuntime.isValidIdentity(text))
        let nodeID = try #require(ZeroTierIdentity.nodeID(of: identity))
        #expect(text.hasPrefix(nodeID + ":0:"))
        #expect(try ZeroTierIdentity.generate() != identity)
    }

    @Test func nodeIDsFormatAsTenHexDigits() {
        #expect(ZeroTierNodeID.format(0x89_e92c_eee5) == "89e92ceee5")
        #expect(ZeroTierNodeID.format(0xabc) == "0000000abc")
        #expect(ZeroTierNodeID.format(0) == nil)
        #expect(ZeroTierNodeID.format(0x100_0000_0000) == nil)
        // libzt's error code cast to UInt64 when no node runs.
        #expect(ZeroTierNodeID.format(UInt64(bitPattern: -2)) == nil)
    }

    @Test func moonsOrbitOnceAndDeorbitWithTheLastReference() {
        let moon = ZeroTierMoon(worldID: 0xaa, seed: 0x01)
        let otherSeed = ZeroTierMoon(worldID: 0xaa, seed: 0x02)
        let second = ZeroTierMoon(worldID: 0xbb, seed: 0x03)
        var orbits = ZeroTierMoonOrbits()

        // Two networks declare the same moon; one also declares it twice.
        orbits.retain([moon, moon])
        #expect(orbits.reconcile() == [.orbit(moon)])
        orbits.retain([moon, second])
        #expect(orbits.reconcile() == [.orbit(second)])
        #expect(orbits.reconcile() == [])

        orbits.release([moon, moon])
        #expect(orbits.reconcile() == [])
        orbits.release([moon, second])
        #expect(orbits.reconcile() == [.deorbit(worldID: 0xaa), .deorbit(worldID: 0xbb)])
        #expect(orbits.references.isEmpty)

        // Releasing what was never retained changes nothing.
        orbits.release([moon])
        #expect(orbits.reconcile() == [])

        // One world through two seeds is orbited once, through the lower.
        orbits.retain([otherSeed])
        orbits.retain([moon])
        #expect(orbits.reconcile() == [.orbit(moon)])
        orbits.release([moon])
        #expect(orbits.reconcile() == [])
        #expect(orbits.orbited == [0xaa: 0x01])
    }

    @Test func moonSeedsAreNodeIDs() async {
        #expect(ZeroTierMoon(worldID: 1, seed: 0xff_ffff_ffff).isValid)
        #expect(!ZeroTierMoon(worldID: 1, seed: 0x100_0000_0000).isValid)
        #expect(!ZeroTierMoon(worldID: 1, seed: 0).isValid)
        #expect(!ZeroTierMoon(worldID: 0, seed: 1).isValid)

        let node = ZeroTierNetworkNode(
            configuration: ZeroTierConfiguration(
                networkID: 42, identity: nil, moons: [ZeroTierMoon(worldID: 1, seed: 0x1_0000_0000_0000)]),
            identityGenerated: { _ in })
        await #expect(throws: OverlayError.self) { try await node.start(timeout: .seconds(1)) }
        guard case .failed = await node.status() else {
            Issue.record("an invalid moon must fail the start")
            return
        }
    }

    // MARK: Runtime bookkeeping under concurrency

    @Test func concurrentLeavesLeaveTheNetworkOnce() async throws {
        let native = FakeZeroTierControl()
        let runtime = ZeroTierRuntime(startedWith: "abcdef0123:0:fake", control: native.control)
        let moon = ZeroTierMoon(worldID: 7, seed: 0x12_3456_789a)
        try await runtime.join(42, moons: [moon])
        try await runtime.join(42, moons: [moon])
        #expect(await runtime.references(42) == 2)

        async let first: Void = runtime.leave(42, moons: [moon])
        async let second: Void = runtime.leave(42, moons: [moon])
        _ = await (first, second)

        #expect(await runtime.references(42) == 0)
        // Moons go first in each step: orbited before the join.
        #expect(native.log == ["orbit 7", "join 42", "deorbit 7", "leave 42"])
        #expect(native.violations == 0)
        #expect(!native.isJoined(42))
    }

    @Test func interleavedJoinsAndLeavesKeepNativeStateInStep() async throws {
        let native = FakeZeroTierControl()
        let runtime = ZeroTierRuntime(startedWith: "abcdef0123:0:fake", control: native.control)
        let moon = ZeroTierMoon(worldID: 7, seed: 0x12_3456_789a)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let moons = index.isMultiple(of: 2) ? [moon] : []
                    try await runtime.join(42, moons: moons)
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 0...5)))
                    await runtime.leave(42, moons: moons)
                }
            }
            try await group.waitForAll()
        }
        #expect(await runtime.references(42) == 0)
        #expect(native.violations == 0)
        #expect(!native.isJoined(42))
        #expect(!native.isOrbiting(7))

        // A leave racing a join of the same network ends joined.
        try await runtime.join(42, moons: [])
        async let leaving: Void = runtime.leave(42, moons: [])
        async let joining: Void = runtime.join(42, moons: [])
        _ = try await (leaving, joining)
        #expect(await runtime.references(42) == 1)
        #expect(native.isJoined(42))
        #expect(native.violations == 0)
    }

    @Test func peersListEveryNodeWithItsRole() {
        let raw = [
            ZeroTierPeers.Raw(peerID: 0x62_f865_ae71, latency: 120, role: 2, pathCount: 1, paths: "1.2.3.4/9993"),
            ZeroTierPeers.Raw(peerID: 0xde_adbe_ef00, latency: 30, role: 1, pathCount: 1, paths: "5.6.7.8/9993"),
            ZeroTierPeers.Raw(
                peerID: 0x89_e92c_eee5, latency: 12, role: 0, pathCount: 2,
                paths: "192.168.1.20/9993,2001:db8::1/9993"),
            ZeroTierPeers.Raw(peerID: 0xabc, latency: -1, role: 0, pathCount: 0, paths: ""),
            ZeroTierPeers.Raw(peerID: 0, latency: 1, role: 0, pathCount: 0, paths: ""),
        ]
        #expect(ZeroTierPeers.overlayPeers(raw) == [
            OverlayPeer(
                id: "62f865ae71", addresses: ["1.2.3.4/9993"], isDirect: true,
                latency: .milliseconds(120), role: "planet"),
            OverlayPeer(
                id: "deadbeef00", addresses: ["5.6.7.8/9993"], isDirect: true,
                latency: .milliseconds(30), role: "moon"),
            OverlayPeer(
                id: "89e92ceee5", addresses: ["192.168.1.20/9993", "2001:db8::1/9993"],
                isDirect: true, latency: .milliseconds(12), role: "leaf"),
            OverlayPeer(id: "0000000abc", addresses: [], isDirect: false, latency: nil, role: "leaf"),
        ])
        #expect(ZeroTierPeers.roleName(7) == "unknown")
    }

    @Test func readingPeersIsSafeWithOrWithoutANode() {
        // A live suite may have started this process's node; without one
        // heeler_zt_peers reports an error and the list is empty.
        #expect(ZeroTierPeers.read().allSatisfy { $0.peerID != 0 })
    }
}

/// libzt's network and moon calls, slowed down, with misuse counted: a join
/// of a joined network or a leave of one not joined is a violation.
private final class FakeZeroTierControl: @unchecked Sendable {
    private let lock = NSLock()
    private var joined: Set<UInt64> = []
    private var orbiting: Set<UInt64> = []
    private var calls: [String] = []
    private var misuse = 0

    var log: [String] { lock.withLock { calls } }
    var violations: Int { lock.withLock { misuse } }
    func isJoined(_ networkID: UInt64) -> Bool { lock.withLock { joined.contains(networkID) } }
    func isOrbiting(_ worldID: UInt64) -> Bool { lock.withLock { orbiting.contains(worldID) } }

    var control: ZeroTierControl {
        ZeroTierControl(
            joinNetwork: { networkID in
                usleep(2_000)
                return self.lock.withLock {
                    self.calls.append("join \(networkID)")
                    if !self.joined.insert(networkID).inserted { self.misuse += 1 }
                    return 0
                }
            },
            leaveNetwork: { networkID in
                usleep(2_000)
                return self.lock.withLock {
                    self.calls.append("leave \(networkID)")
                    if self.joined.remove(networkID) == nil { self.misuse += 1 }
                    return 0
                }
            },
            orbit: { worldID, _ in
                self.lock.withLock {
                    self.calls.append("orbit \(worldID)")
                    if !self.orbiting.insert(worldID).inserted { self.misuse += 1 }
                    return 0
                }
            },
            deorbit: { worldID in
                self.lock.withLock {
                    self.calls.append("deorbit \(worldID)")
                    if self.orbiting.remove(worldID) == nil { self.misuse += 1 }
                    return 0
                }
            },
            snapshot: { networkID in
                let ready = self.lock.withLock { self.joined.contains(networkID) }
                return ZeroTierRuntime.NetworkSnapshot(
                    isReady: ready, addresses: ready ? ["10.147.17.2"] : [], failure: nil)
            })
    }
}
