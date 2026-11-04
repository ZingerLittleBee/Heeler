import CZeroTier
import Foundation
import Testing

@testable import HeelerOverlay

@Suite("ZeroTier readiness, authorization, and diagnostics")
struct ZeroTierReadinessTests {
    // MARK: The node-online flag

    @Test func laterStartsDoNotWaitOnTheOnlineFlag() async throws {
        let native = ScriptedZeroTierControl()
        let runtime = ZeroTierRuntime(startedWith: "abcdef0123:0:fake", control: native.control)
        native.set(online: true)
        _ = try await runtime.startNode(identity: nil, deadline: OverlayDeadline(after: .seconds(2)))

        // libzt reads offline for minutes on an idle node whose networks
        // work; a start then must not block until its deadline.
        native.set(online: false)
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await runtime.startNode(
                identity: nil, deadline: OverlayDeadline(after: .seconds(5)))
        }
        #expect(elapsed < .seconds(1))
    }

    @Test func theFirstStartWaitsUntilTheNodeIsOnline() async throws {
        let native = ScriptedZeroTierControl()
        let runtime = ZeroTierRuntime(startedWith: "abcdef0123:0:fake", control: native.control)
        native.set(online: false)
        await #expect(throws: OverlayError.timedOut) {
            _ = try await runtime.startNode(
                identity: nil, deadline: OverlayDeadline(after: .milliseconds(300)))
        }
        native.set(online: true)
        _ = try await runtime.startNode(identity: nil, deadline: OverlayDeadline(after: .seconds(2)))
        #expect(await runtime.hasBeenOnline)
    }

    // MARK: Authorization

    @Test func aNetworkAwaitingAuthorizationStaysJoinedUntilApproved() async throws {
        let native = ScriptedZeroTierControl()
        native.set(online: true)
        native.set(network: .denied)
        let runtime = ZeroTierRuntime(startedWith: "abcdef0123:0:fake", control: native.control)
        let node = ZeroTierNetworkNode(
            configuration: ZeroTierConfiguration(networkID: 42, identity: nil),
            identityGenerated: { _ in },
            runtime: runtime)
        let waiting = "Waiting for authorization of node abcdef0123 on ZeroTier network 000000000000002a"

        await #expect(throws: OverlayError.startFailed(waiting)) {
            try await node.start(timeout: .seconds(2))
        }
        #expect(await node.status() == .waiting(waiting))
        #expect(await runtime.references(42) == 1)
        // Retrying keeps the one join: libzt keeps asking the controller.
        await #expect(throws: OverlayError.startFailed(waiting)) {
            try await node.start(timeout: .seconds(2))
        }
        #expect(native.log == ["join 42"])

        native.set(network: .ready)
        try await node.start(timeout: .seconds(2))
        #expect(await node.status() == .online(addresses: ["10.147.17.2"]))
        #expect(native.log == ["join 42"])

        await node.stop()
        #expect(native.log == ["join 42", "leave 42"])
        #expect(await runtime.references(42) == 0)
        #expect(await node.status() == .stopped)
    }

    @Test func aDefinitiveRefusalGivesTheNetworkBack() async throws {
        let native = ScriptedZeroTierControl()
        native.set(online: true)
        let missing = "ZeroTier network 000000000000002a does not exist."
        native.set(network: .failed(missing))
        let runtime = ZeroTierRuntime(startedWith: "abcdef0123:0:fake", control: native.control)
        let node = ZeroTierNetworkNode(
            configuration: ZeroTierConfiguration(networkID: 42, identity: nil),
            identityGenerated: { _ in },
            runtime: runtime)

        await #expect(throws: OverlayError.startFailed(missing)) {
            try await node.start(timeout: .seconds(2))
        }
        #expect(await runtime.references(42) == 0)
        #expect(native.log == ["join 42", "leave 42"])
        #expect(await node.status() == .failed(missing))
    }

    @Test func aNetworkWithoutAnAddressYetTimesOutButStaysJoined() async throws {
        let native = ScriptedZeroTierControl()
        native.set(online: true)
        native.set(network: .pending)
        let runtime = ZeroTierRuntime(startedWith: "abcdef0123:0:fake", control: native.control)
        let node = ZeroTierNetworkNode(
            configuration: ZeroTierConfiguration(networkID: 42, identity: nil),
            identityGenerated: { _ in },
            runtime: runtime)

        await #expect(throws: OverlayError.timedOut) {
            try await node.start(timeout: .milliseconds(300))
        }
        #expect(await node.status() == .starting)
        #expect(await runtime.references(42) == 1)
        native.set(network: .ready)
        try await node.start(timeout: .seconds(2))
        #expect(native.log == ["join 42"])
        await node.stop()
    }

    // MARK: Diagnostics

    @Test func eventsAreDescribedAndKeptToTheLatestFifty() {
        #expect(ZeroTierEventLog.describe(
            code: Int32(ZTS_EVENT_NETWORK_ACCESS_DENIED.rawValue), networkID: 42, peerID: nil)
            == "Network 000000000000002a access denied")
        #expect(ZeroTierEventLog.describe(
            code: Int32(ZTS_EVENT_PEER_RELAY.rawValue), networkID: nil, peerID: 0x89_e92c_eee5)
            == "Peer 89e92ceee5 relayed")
        #expect(ZeroTierEventLog.describe(
            code: Int32(ZTS_EVENT_NODE_OFFLINE.rawValue), networkID: nil, peerID: nil)
            == "Node offline (no recent root contact)")
        #expect(ZeroTierEventLog.describe(
            code: Int32(ZTS_EVENT_NETWORK_UPDATE.rawValue), networkID: 42, peerID: nil) == nil)

        let log = ZeroTierEventLog()
        for index in 0..<60 {
            log.append("event \(index)", at: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(log.recent.count == ZeroTierEventLog.capacity)
        #expect(log.recent.first?.message == "event 10")
        #expect(log.recent.last?.message == "event 59")
    }

    @Test func routesSayWhetherTheyNeedAGateway() {
        #expect(ZeroTierRuntime.describe(
            ZeroTierRuntime.Route(target: "10.147.20.0", via: nil, flags: 0, metric: 0))
            == "10.147.20.0 (on the network), flags 0, metric 0")
        #expect(ZeroTierRuntime.describe(
            ZeroTierRuntime.Route(target: "192.168.77.0", via: "10.147.20.2", flags: 0, metric: 5))
            == "192.168.77.0 via 10.147.20.2 (through a gateway member), flags 0, metric 5")
        #expect(ZeroTierRuntime.statusName(2) == "Access denied (2)")
        #expect(ZeroTierRuntime.statusName(Int32(ZTS_ERR_NO_RESULT.rawValue)).hasPrefix("Not joined"))
    }

    @Test func diagnosticsCopyAsText() async {
        let diagnostics = OverlayDiagnostics(
            entries: [.init(label: "Network status", value: "OK (1)")],
            events: [.init(date: Date(timeIntervalSince1970: 0), message: "Node online")])
        #expect(diagnostics.text == "Network status: OK (1)\nEvents:\n1970-01-01T00:00:00.000Z Node online")
        #expect(OverlayDiagnostics().isEmpty)

        let native = ScriptedZeroTierControl()
        let runtime = ZeroTierRuntime(control: native.control)
        let node = ZeroTierNetworkNode(
            configuration: ZeroTierConfiguration(networkID: 42, identity: nil),
            identityGenerated: { _ in },
            runtime: runtime)
        let idle = await node.diagnostics()
        #expect(idle.entries.prefix(3).map(\.label) == ["Network ID", "Joined", "Node"])
        #expect(idle.entries.first?.value == "000000000000002a")
    }
}

/// libzt's network calls with a scripted network state and online flag.
private final class ScriptedZeroTierControl: @unchecked Sendable {
    enum Network {
        case pending, denied, ready
        case failed(String)
    }

    private let lock = NSLock()
    private var online = false
    private var network = Network.ready
    private var joined: Set<UInt64> = []
    private var calls: [String] = []

    var log: [String] { lock.withLock { calls } }
    func set(online: Bool) { lock.withLock { self.online = online } }
    func set(network: Network) { lock.withLock { self.network = network } }

    var control: ZeroTierControl {
        ZeroTierControl(
            joinNetwork: { networkID in
                self.lock.withLock {
                    self.calls.append("join \(networkID)")
                    self.joined.insert(networkID)
                    return 0
                }
            },
            leaveNetwork: { networkID in
                self.lock.withLock {
                    self.calls.append("leave \(networkID)")
                    self.joined.remove(networkID)
                    return 0
                }
            },
            orbit: { _, _ in 0 },
            deorbit: { _ in 0 },
            snapshot: { networkID in
                self.lock.withLock {
                    guard self.joined.contains(networkID) else {
                        return ZeroTierRuntime.NetworkSnapshot(isReady: false, addresses: [])
                    }
                    switch self.network {
                    case .pending:
                        return ZeroTierRuntime.NetworkSnapshot(isReady: false, addresses: [])
                    case .denied:
                        return ZeroTierRuntime.NetworkSnapshot(
                            isReady: false, addresses: [], isAwaitingAuthorization: true)
                    case .ready:
                        return ZeroTierRuntime.NetworkSnapshot(isReady: true, addresses: ["10.147.17.2"])
                    case .failed(let message):
                        return ZeroTierRuntime.NetworkSnapshot(isReady: false, addresses: [], failure: message)
                    }
                }
            },
            isOnline: { self.lock.withLock { self.online } })
    }
}
