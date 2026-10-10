import Foundation
import Testing

@testable import HeelerOverlay

/// A Tailscale dial to an address the network map cannot route fails at
/// once instead of hanging in tsnet until the caller's deadline.
@Suite("Tailscale dial routing")
struct TailscaleRoutingTests {
    /// One peer that owns two addresses, routes a subnet as primary router,
    /// carries a 4via6 route, and offers (but is not) an exit node.
    static func status(
        backend: String = "Running", exitNode: String = "", peerIsExitNode: Bool = false,
        networkMap: Bool = true, peers: Bool = true
    ) throws -> TailscaleStatus {
        let tailnet = networkMap ? #""CurrentTailnet":{"Name":"example.com","MagicDNSSuffix":"tail.ts.net"},"# : ""
        let json = """
            {"BackendState":"\(backend)","TailscaleIPs":["100.64.0.2","fd7a:115c:a1e0::2"],
             "Self":{"ID":"nSelf","TailscaleIPs":["100.64.0.2","fd7a:115c:a1e0::2"]},
             \(exitNode) \(tailnet)
             "Peer":\(peers ? peerList(exitNode: peerIsExitNode) : "null")}
            """
        return try TailscaleStatus.decode(Data(json.utf8))
    }

    static func peerList(exitNode: Bool) -> String {
        """
            {
               "nodekey:a":{"ID":"nA","HostName":"box","ExitNode":\(exitNode),"ExitNodeOption":true,
                 "TailscaleIPs":["100.64.0.1","fd7a:115c:a1e0::1"],
                 "AllowedIPs":["100.64.0.1/32","fd7a:115c:a1e0::1/128","192.168.1.0/24",
                               "fd7a:115c:a1e0:b1a:0:7::/96","0.0.0.0/0","::/0"],
                 "PrimaryRoutes":["10.1.0.0/16"]},
               "nodekey:b":{"ID":"nB","HostName":"other","TailscaleIPs":["100.64.0.3"]}
             }
            """
    }

    @Test func peerAndOwnAddressesRoute() throws {
        let status = try Self.status()
        #expect(status.canRoute(to: "100.64.0.1") == true)
        #expect(status.canRoute(to: "100.64.0.3") == true)
        #expect(status.canRoute(to: "100.64.0.2") == true)
        #expect(status.canRoute(to: "fd7a:115c:a1e0::1") == true)
        #expect(status.canRoute(to: "[fd7a:115c:a1e0::1]") == true)
        #expect(status.canRoute(to: "fd7a:115c:a1e0:0:0:0:0:1") == true)
        #expect(status.canRoute(to: "::ffff:100.64.0.1") == true)
    }

    @Test func subnetRoutesRoute() throws {
        let status = try Self.status()
        #expect(status.canRoute(to: "192.168.1.20") == true)
        #expect(status.canRoute(to: "10.1.255.4") == true)
        // 4via6: site 7's 10.0.0.5.
        #expect(status.canRoute(to: "fd7a:115c:a1e0:b1a:0:7:a00:5") == true)
        #expect(status.canRoute(to: "192.168.2.20") == false)
        #expect(status.canRoute(to: "10.2.0.1") == false)
    }

    @Test func unknownAddressesDoNotRoute() throws {
        let status = try Self.status()
        #expect(status.canRoute(to: "100.64.0.9") == false)
        #expect(status.canRoute(to: "fd7a:115c:a1e0::9") == false)
        // An exit node that is only offered routes nothing beyond its subnets.
        #expect(status.canRoute(to: "8.8.8.8") == false)
        #expect(status.canRoute(to: "2001:db8::1") == false)
    }

    @Test func aSelectedExitNodeRoutesEverything() throws {
        let selected = try Self.status(
            exitNode: #""ExitNodeStatus":{"ID":"nA","Online":true,"TailscaleIPs":["100.64.0.1/32"]},"#)
        #expect(selected.canRoute(to: "8.8.8.8") == true)
        #expect(selected.canRoute(to: "2001:db8::1") == true)
        let flagged = try Self.status(peerIsExitNode: true)
        #expect(flagged.canRoute(to: "8.8.8.8") == true)
    }

    @Test func onlyARunningNodeWithANetworkMapJudges() throws {
        #expect(try Self.status(backend: "Starting").canRoute(to: "100.64.0.9") == nil)
        #expect(try Self.status(backend: "NeedsLogin").canRoute(to: "100.64.0.9") == nil)
        #expect(try Self.status(networkMap: false).canRoute(to: "100.64.0.9") == nil)
        #expect(try Self.status(peers: false).canRoute(to: "100.64.0.9") == false)
        #expect(try Self.status(peers: false).canRoute(to: "100.64.0.2") == true)
    }

    @Test func prefixesParseStrictly() {
        #expect(IPPrefix("10.0.0.0/8")?.length == 8)
        #expect(IPPrefix("::/0")?.length == 0)
        #expect(IPPrefix("10.0.0.0/33") == nil)
        #expect(IPPrefix("10.0.0.0") == nil)
        #expect(IPPrefix("box/24") == nil)
        let prefix = IPPrefix("100.64.0.0/10")
        #expect(IPAddressBytes("100.127.255.255").map { prefix?.contains($0) == true } == true)
        #expect(IPAddressBytes("100.128.0.0").map { prefix?.contains($0) == true } == false)
        #expect(IPAddressBytes("fd7a::1").map { prefix?.contains($0) == true } == false)
    }

    // MARK: Node

    @Test func dialToAnAddressOffTheTailnetFailsAtOnce() async throws {
        let native = try RoutingTailscaleNative(status: Self.status())
        let node = TailscaleNode(configuration: Self.configuration, native: native, networkMapSettle: .zero)

        let started = ContinuousClock.now
        await #expect(throws: OverlayError.dialFailed("100.64.0.9 is not on this tailnet.")) {
            _ = try await node.dial(host: "100.64.0.9", port: 22, timeout: .seconds(30))
        }
        await #expect(throws: OverlayError.dialFailed("fd7a:115c:a1e0::9 is not on this tailnet.")) {
            _ = try await node.dial(host: "[fd7a:115c:a1e0::9]", port: 22, timeout: .seconds(30))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(native.dialed.isEmpty)
        await node.stop()
    }

    @Test func routedAddressesAndNamesReachTsnet() async throws {
        let native = try RoutingTailscaleNative(status: Self.status())
        let node = TailscaleNode(configuration: Self.configuration, native: native, networkMapSettle: .zero)

        for host in ["100.64.0.1", "[fd7a:115c:a1e0::1]", "192.168.1.20", "box", "box.tail.ts.net"] {
            await #expect(throws: OverlayError.dialFailed("native")) {
                _ = try await node.dial(host: host, port: 22, timeout: .seconds(5))
            }
        }
        #expect(native.dialed == [
            "100.64.0.1:22", "[fd7a:115c:a1e0::1]:22", "192.168.1.20:22", "box:22", "box.tail.ts.net:22",
        ])
        await node.stop()
    }

    @Test func dialsThroughAnExitNodeReachTsnet() async throws {
        let native = try RoutingTailscaleNative(status: Self.status(
            exitNode: #""ExitNodeStatus":{"ID":"nA","Online":true,"TailscaleIPs":["100.64.0.1/32"]},"#))
        let node = TailscaleNode(configuration: Self.configuration, native: native, networkMapSettle: .zero)

        await #expect(throws: OverlayError.dialFailed("native")) {
            _ = try await node.dial(host: "8.8.8.8", port: 22, timeout: .seconds(5))
        }
        #expect(native.dialed == ["8.8.8.8:22"])
        await node.stop()
    }

    @Test func anUnreadableStatusLeavesTheDialToTsnet() async throws {
        let native = try RoutingTailscaleNative(status: Self.status())
        let node = TailscaleNode(configuration: Self.configuration, native: native, networkMapSettle: .zero)
        try await node.start(timeout: .seconds(5))
        // The dial's start reads the status, then the routing check cannot.
        native.plannedReads = [true, false]

        await #expect(throws: OverlayError.dialFailed("native")) {
            _ = try await node.dial(host: "100.64.0.9", port: 22, timeout: .seconds(5))
        }
        #expect(native.dialed == ["100.64.0.9:22"])
        await node.stop()
    }

    @Test func peersArrivingJustAfterComingOnlineAreWaitedFor() async throws {
        // tsnet reports Running before the network map lists the peers.
        let native = try RoutingTailscaleNative(status: Self.status())
        native.plannedStatuses = try [Self.status(peers: false), Self.status(peers: false), Self.status(peers: false)]
        let node = TailscaleNode(configuration: Self.configuration, native: native, networkMapSettle: .seconds(30))

        await #expect(throws: OverlayError.dialFailed("native")) {
            _ = try await node.dial(host: "100.64.0.1", port: 22, timeout: .seconds(10))
        }
        #expect(native.dialed == ["100.64.0.1:22"])
        await node.stop()
    }

    @Test func anAddressStillUnroutableWhenTheNetworkMapSettlesFails() async throws {
        let native = try RoutingTailscaleNative(status: Self.status())
        let node = TailscaleNode(
            configuration: Self.configuration, native: native, networkMapSettle: .milliseconds(600))

        let started = ContinuousClock.now
        await #expect(throws: OverlayError.dialFailed("100.64.0.9 is not on this tailnet.")) {
            _ = try await node.dial(host: "100.64.0.9", port: 22, timeout: .seconds(10))
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(500) && elapsed < .seconds(5))
        // Long online: refused at once.
        let again = ContinuousClock.now
        await #expect(throws: OverlayError.dialFailed("100.64.0.9 is not on this tailnet.")) {
            _ = try await node.dial(host: "100.64.0.9", port: 22, timeout: .seconds(10))
        }
        #expect(ContinuousClock.now - again < .milliseconds(400))
        #expect(native.dialed.isEmpty)
        await node.stop()
    }

    static let configuration = TailscaleConfiguration(
        stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ts-routing", isDirectory: true),
        hostname: "heeler-test",
        authKey: nil,
        controlURL: nil)
}

/// Reports a fixed status and records the addresses dialled; every dial
/// fails with `dialFailed("native")`.
private final class RoutingTailscaleNative: TailscaleNative, @unchecked Sendable {
    private let lock = NSLock()
    private let fixedStatus: TailscaleStatus
    private var planned: [Bool] = []
    private var statuses: [TailscaleStatus] = []
    private var addresses: [String] = []

    init(status: TailscaleStatus) {
        fixedStatus = status
    }

    /// Whether each of the next status reads succeeds; later ones do.
    var plannedReads: [Bool] {
        get { locked { planned } }
        set { locked { planned = newValue } }
    }

    /// Statuses the next reads report instead of the fixed one.
    var plannedStatuses: [TailscaleStatus] {
        get { locked { statuses } }
        set { locked { statuses = newValue } }
    }

    var dialed: [String] { locked { addresses } }

    func createAndStart(_ configuration: TailscaleConfiguration) -> Result<Int32, OverlayError> { .success(1) }
    func close(_ handle: Int32) {}
    func status(_ handle: Int32) -> TailscaleStatus? {
        locked {
            guard planned.isEmpty || planned.removeFirst() else { return nil }
            return statuses.isEmpty ? fixedStatus : statuses.removeFirst()
        }
    }

    func dial(_ handle: Int32, address: String) -> Result<Int32, OverlayError> {
        locked { addresses.append(address) }
        return .failure(.dialFailed("native"))
    }

    func logout(_ configuration: TailscaleConfiguration, timeoutMilliseconds: Int32) -> Result<Void, OverlayError> {
        .success(())
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
