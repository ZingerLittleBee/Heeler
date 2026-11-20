import Darwin
import Foundation
import Testing

@testable import HeelerOverlay

/// How a `TailcatNode` treats its client, with the server replaced by a
/// fake that can stop answering, forget a client, and serve chosen ports.
@Suite("Tailcat node")
struct TailcatNodeTests {
    private static let serverName = "3f2a9c.tailcat"

    private static func node(_ native: FakeTailcatNative) -> TailcatNode {
        TailcatNode(
            configuration: TailcatConfiguration(address: "tc-fake", serverName: serverName),
            native: native,
            probeLimit: .milliseconds(150),
            pathLifetime: .zero)
    }

    /// Waits for something a background close brings about.
    private static func eventually(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("the condition did not hold within 5 seconds")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func startPingsTheServerAndReportsItAsTheOnlyPeer() async throws {
        let native = FakeTailcatNative()
        let node = Self.node(native)
        #expect(await node.details() == OverlayNodeDetails())

        try await node.start(timeout: .seconds(5))

        #expect(await node.status() == .online(addresses: []))
        #expect(
            await node.details()
                == OverlayNodeDetails(
                    peers: [
                        OverlayPeer(
                            id: Self.serverName, addresses: [Self.serverName], isOnline: true, isDirect: true,
                            latency: .milliseconds(12))
                    ]))
        await node.stop()
        #expect(native.openHandles.isEmpty)
        #expect(await node.status() == .stopped)
    }

    @Test func dialOnlyAcceptsTheServerName() async throws {
        let native = FakeTailcatNative()
        let node = Self.node(native)

        await #expect(
            throws: OverlayError.invalidDestination(
                "A tailcat tunnel only reaches the machine running tailcat serve. Use 3f2a9c.tailcat as the address.")
        ) {
            _ = try await node.dial(host: "192.168.1.5", port: 22, timeout: .seconds(5))
        }
        #expect(native.opened == 0)

        let stream = try await node.dial(host: " 3F2A9C.Tailcat. ", port: 22, timeout: .seconds(5))
        #expect(native.dialledPorts == [22])
        Darwin.close(stream.descriptor)
        stream.release()
        await node.stop()
    }

    @Test func anUnservedPortIsUnreachableAndKeepsTheClient() async throws {
        let native = FakeTailcatNative()
        let node = Self.node(native)

        await #expect(
            throws: OverlayError.dialFailed(
                "The tailcat server answered, but not on port 2222. Check which ports tailcat serve exposes.")
        ) {
            _ = try await node.dial(host: Self.serverName, port: 2222, timeout: .milliseconds(400))
        }
        #expect(native.opened == 1)
        #expect(native.closed == 0)
        #expect(await node.status() == .online(addresses: []))
        await node.stop()
    }

    @Test func aServerThatForgotTheClientGetsAFreshOneWithinTheSameDial() async throws {
        let native = FakeTailcatNative()
        let node = Self.node(native)
        try await node.start(timeout: .seconds(5))

        // The server restarted: it answers new clients, never the old one.
        native.forgetOpenClients()
        let started = ContinuousClock.now
        let stream = try await node.dial(host: Self.serverName, port: 22, timeout: .seconds(10))

        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(native.opened == 2)
        // The old client closes in the background.
        try await Self.eventually { native.openHandles == [2] }
        #expect(native.closed == 1)
        Darwin.close(stream.descriptor)
        stream.release()
        await node.stop()
    }

    @Test func aClientWithLiveStreamsIsKeptUntilTheyAreReleased() async throws {
        let native = FakeTailcatNative()
        let node = Self.node(native)
        let stream = try await node.dial(host: Self.serverName, port: 22, timeout: .seconds(5))

        native.forgetOpenClients()
        await #expect(throws: OverlayError.dialFailed(TailcatNode.noAnswer)) {
            _ = try await node.dial(host: Self.serverName, port: 22, timeout: .seconds(5))
        }
        #expect(native.opened == 1)
        #expect(native.closed == 0)
        #expect(
            await node.details().peers?.first?.isOnline == false,
            "the server is still listed, as unanswered")

        Darwin.close(stream.descriptor)
        stream.release()
        let second = try await node.dial(host: Self.serverName, port: 22, timeout: .seconds(5))
        #expect(native.opened == 2)
        try await Self.eventually { native.closed == 1 }
        Darwin.close(second.descriptor)
        second.release()
        await node.stop()
    }

    @Test func aServerThatNeverAnsweredKeepsItsClientForTheNextAttempt() async throws {
        let native = FakeTailcatNative()
        native.answers = false
        let node = Self.node(native)

        await #expect(throws: OverlayError.dialFailed(TailcatNode.noAnswer)) {
            try await node.start(timeout: .milliseconds(200))
        }
        #expect(await node.status() == .failed(TailcatNode.noAnswer))
        #expect(await node.details() == OverlayNodeDetails())

        // The same client registers once the server is there.
        native.answers = true
        try await node.start(timeout: .seconds(5))
        #expect(native.opened == 1)
        #expect(native.closed == 0)
        await node.stop()
    }

    @Test func stopEndsAStartStillWaitingForTheServer() async throws {
        let native = FakeTailcatNative()
        native.answers = false
        let node = Self.node(native)

        let starting = Task { try await node.start(timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        let stopped = ContinuousClock.now
        await node.stop()

        await #expect(throws: OverlayError.cancelled) { try await starting.value }
        #expect(ContinuousClock.now - stopped < .seconds(2))
        #expect(native.openHandles.isEmpty)
        #expect(await node.status() == .stopped)
    }

    @Test func aFailureOtherThanSilenceIsAStartFailure() async throws {
        let native = FakeTailcatNative()
        native.pingError = "fetching the relay map: no route to host"
        let node = Self.node(native)

        await #expect(throws: OverlayError.startFailed("fetching the relay map: no route to host")) {
            try await node.start(timeout: .seconds(5))
        }
        #expect(await node.status() == .failed("fetching the relay map: no route to host"))
        await node.stop()
    }

    // MARK: The linked client

    @Test func addressesDescribeThemselvesWithoutTheNetwork() {
        #expect(
            TailcatAddress.info(TailcatFixture.relayRegion)
                == TailcatAddressInfo(hasPresharedKey: true, regionID: 1, relays: []))
        #expect(
            TailcatAddress.info("  " + TailcatFixture.ownRelay + "\n")
                == TailcatAddressInfo(hasPresharedKey: true, regionID: nil, relays: ["relay.invalid"]))
        #expect(TailcatAddress.info("tc-not-an-address") == nil)
        #expect(TailcatAddress.info("") == nil)
    }

    @Test func textThatIsNotAnAddressIsAConfigurationErrorThatDoesNotQuoteIt() async throws {
        let node = OverlayNodes.tailcat(
            TailcatConfiguration(address: "tc-not-an-address", serverName: Self.serverName))
        do {
            try await node.start(timeout: .seconds(5))
            Issue.record("a node started on text that is not a tailcat address")
        } catch OverlayError.invalidConfiguration(let detail) {
            #expect(!detail.contains("tc-not-an-address"))
            #expect(await node.status() == .failed(detail))
        }
    }

    /// The fixture names a relay that resolves nowhere, so the client builds
    /// its tunnel and waits without the network.
    @Test(.timeLimit(.minutes(1)))
    func aRealClientWithNoServerRunsIntoItsDeadline() async throws {
        let node = OverlayNodes.tailcat(
            TailcatConfiguration(address: TailcatFixture.ownRelay, serverName: Self.serverName))
        let started = ContinuousClock.now

        await #expect(throws: OverlayError.dialFailed(TailcatNode.noAnswer)) {
            _ = try await node.dial(host: Self.serverName, port: 22, timeout: .milliseconds(500))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        await node.stop()
        #expect(await node.status() == .stopped)
    }
}

/// Two tailcat addresses made for tests. Their keys were generated and
/// thrown away; no server ever held them.
enum TailcatFixture {
    /// Names region 1 of the relay map a client fetches.
    static let relayRegion =
        "tcpGFwWCBkoZFXSg4dBEdu4fjp2tm_BpZE5eiKlg3c-8pmFAIjAmFrWCB8zkWp5aaTXSRcU06s9WMJGxXVKGSf_UnkJQQtykEJT2FxWCBHZRmok7n2yjBJAVp9f2iOZjW1bEKJ0KVcOtYcTSIEiWFpAQ"
    /// Names its own relay, `relay.invalid`, which resolves nowhere.
    static let ownRelay =
        "tcpGFwWCDJasIaRszpCko-hlUp2muXWmw3lURRsH4SquxEm1SMJWFrWCCNPTH_iqWLhoZkURv5dX87UdtrW9annrwc8Fls-LyqQ2FxWCC7FUJAhPio8tZBoLluGTPzjyag1n6R27A913ipuAUlhWFygaFhToGhYWhtcmVsYXkuaW52YWxpZA"
}

/// A tailcat server and its clients. A client the server does not answer
/// waits out its timeout, as the real one does, unless it is closed first.
private final class FakeTailcatNative: TailcatNative, @unchecked Sendable {
    private let lock = NSLock()
    private var next: Int32 = 1
    private var open: Set<Int32> = []
    private var forgotten: Set<Int32> = []
    private var opens = 0
    private var closes = 0
    private var ports: [UInt16] = []
    private var peers: [Int32] = []
    private var isAnswering = true
    private var pingFailure: String?

    /// Ports `tailcat serve` exposes.
    private let served: Set<UInt16> = [22]

    var opened: Int { locked { opens } }
    var closed: Int { locked { closes } }
    var openHandles: Set<Int32> { locked { open } }
    var dialledPorts: [UInt16] { locked { ports } }

    /// Whether the server is there at all.
    var answers: Bool {
        get { locked { isAnswering } }
        set { locked { isAnswering = newValue } }
    }

    /// A failure every ping reports at once.
    var pingError: String? {
        get { locked { pingFailure } }
        set { locked { pingFailure = newValue } }
    }

    /// The server restarted: clients registered before are never answered.
    func forgetOpenClients() {
        locked { forgotten.formUnion(open) }
    }

    func open(address: String) -> Result<Int32, OverlayError> {
        .success(
            locked {
                let handle = next
                next += 1
                open.insert(handle)
                opens += 1
                return handle
            })
    }

    func ping(_ handle: Int32, timeoutMilliseconds: UInt32) -> Result<TailcatPath, TailcatFailure> {
        if let pingError { return .failure(.failed(pingError)) }
        guard locked({ open.contains(handle) }) else { return .failure(.closed) }
        if locked({ isAnswering && !forgotten.contains(handle) }) {
            return .success(TailcatPath(latency: .milliseconds(12), isDirect: true))
        }
        return .failure(waitOut(handle, timeoutMilliseconds))
    }

    func dial(_ handle: Int32, port: UInt16, timeoutMilliseconds: UInt32) -> Result<Int32, TailcatFailure> {
        guard locked({ open.contains(handle) }) else { return .failure(.closed) }
        locked { ports.append(port) }
        guard served.contains(port) else { return .failure(waitOut(handle, timeoutMilliseconds)) }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return .failure(.failed("socketpair")) }
        locked { peers.append(pair[1]) }
        return .success(pair[0])
    }

    func close(_ handle: Int32) {
        locked {
            if open.remove(handle) != nil { closes += 1 }
        }
    }

    deinit {
        for peer in peers { Darwin.close(peer) }
    }

    /// Silence until the timeout, or `.closed` as soon as the client is.
    private func waitOut(_ handle: Int32, _ milliseconds: UInt32) -> TailcatFailure {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(milliseconds)))
        while ContinuousClock.now < deadline {
            guard locked({ open.contains(handle) }) else { return .closed }
            usleep(5_000)
        }
        return .timedOut
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
