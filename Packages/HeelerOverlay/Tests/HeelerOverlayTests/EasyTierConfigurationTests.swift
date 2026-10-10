import Foundation
import Testing

@testable import HeelerOverlay

private func configuration(
    networkName: String = "home",
    networkSecret: String = "s3cret",
    peers: [String] = ["tcp://public.easytier.top:11010"],
    hostname: String = "iphone",
    ipv4: String? = nil,
    key: String = "manual"
) -> EasyTierConfiguration {
    EasyTierConfiguration(
        networkName: networkName, networkSecret: networkSecret, peers: peers, hostname: hostname, ipv4: ipv4,
        instanceKey: key)
}

// MARK: - TOML rendering

@Test("the rendered TOML joins one network over the given peers without a TUN")
func renderedTOMLHasTheExpectedShape() throws {
    let toml = try EasyTierTOML.render(configuration(peers: ["tcp://a.example:11010", " udp://10.0.0.1:11010 "]))
    #expect(toml == """
    instance_name = "heeler"
    hostname = "iphone"
    dhcp = true
    listeners = []

    [network_identity]
    network_name = "home"
    network_secret = "s3cret"

    [[peer]]
    uri = "tcp://a.example:11010"

    [[peer]]
    uri = "udp://10.0.0.1:11010"

    [flags]
    no_tun = true
    disable_relay_data = true
    relay_network_whitelist = ""
    private_mode = true

    """)
}

@Test("an empty hostname is left to EasyTier")
func emptyHostnameIsOmitted() throws {
    let toml = try EasyTierTOML.render(configuration(hostname: "  "))
    #expect(!toml.contains("hostname"))
}

@Test("TOML strings escape quotes, backslashes, and control characters")
func quotedEscapesEverythingTOMLRequires() {
    #expect(EasyTierTOML.quoted("plain") == "\"plain\"")
    #expect(EasyTierTOML.quoted("a\"b") == "\"a\\\"b\"")
    #expect(EasyTierTOML.quoted("a\\b") == "\"a\\\\b\"")
    #expect(EasyTierTOML.quoted("a\nb\rc\td") == "\"a\\nb\\rc\\td\"")
    #expect(EasyTierTOML.quoted("\u{08}\u{0C}") == "\"\\b\\f\"")
    #expect(EasyTierTOML.quoted("\u{00}\u{1F}\u{7F}") == "\"\\u0000\\u001F\\u007F\"")
    #expect(EasyTierTOML.quoted("家-🐕") == "\"家-🐕\"")
}

@Test("a hostile secret cannot add keys or tables")
func hostileValuesStayInsideTheirString() throws {
    let secret = "x\"\nno_tun = false\n[flags]\nno_tun = false\n#"
    let toml = try EasyTierTOML.render(configuration(networkSecret: secret, hostname: "h\"\n[[peer]]"))
    let lines = toml.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.filter { $0 == "[flags]" }.count == 1)
    #expect(lines.filter { $0 == "[[peer]]" }.count == 1)
    #expect(lines.filter { $0.hasPrefix("no_tun") } == ["no_tun = true"])
    #expect(lines.filter { $0.hasPrefix("private_mode") } == ["private_mode = true"])
    #expect(lines.contains(#"network_secret = "x\"\nno_tun = false\n[flags]\nno_tun = false\n#""#))
    #expect(lines.contains(#"hostname = "h\"\n[[peer]]""#))
}

@Test("a network name is required")
func networkNameIsRequired() {
    #expect(throws: OverlayError.invalidConfiguration("EasyTier needs a network name.")) {
        try EasyTierTOML.render(configuration(networkName: " \n"))
    }
}

@Test("a network secret is required")
func networkSecretIsRequired() {
    #expect(throws: OverlayError.invalidConfiguration("EasyTier needs a network secret.")) {
        try EasyTierTOML.render(configuration(networkSecret: ""))
    }
}

@Test("at least one peer is required")
func peersAreRequired() {
    #expect(throws: OverlayError.invalidConfiguration("EasyTier needs at least one peer.")) {
        try EasyTierTOML.render(configuration(peers: ["", "  "]))
    }
}

@Test("peers must be tcp, udp, ws or wss URIs with a host and port", arguments: [
    "public.easytier.top:11010",
    "tcp://",
    "tcp://host",
    "wss://relay.example",
    "quic://relay.example:11012",
    "not a uri",
])
func invalidPeersAreRejected(peer: String) {
    #expect(throws: OverlayError.self) {
        try EasyTierTOML.render(configuration(peers: [peer]))
    }
}

@Test("peer schemes are case-insensitive")
func peerSchemesAreCaseInsensitive() throws {
    try EasyTierTOML.validate(peer: "TCP://relay.example:11010")
    try EasyTierTOML.validate(peer: "udp://[2001:db8::1]:11010")
    try EasyTierTOML.validate(peer: "WSS://relay.example:443/path")
    try EasyTierTOML.validate(peer: "ws://10.0.0.1:80")
}

// MARK: - Status JSON

@Test("an online status reports its virtual address")
func onlineStatusParses() throws {
    let status = try EasyTierStatus.parse(
        #"{"error":null,"hostname":"iphone","ipv4":"10.126.126.3","peer_count":2,"running":true}"#
    )
    #expect(status == EasyTierStatus(running: true, ipv4: "10.126.126.3", hostname: "iphone", peerCount: 2, error: nil))
    #expect(EasyTierStatus.nodeStatus(status) == .online(addresses: ["10.126.126.3"]))
}

@Test("a running node without an address is still starting")
func runningWithoutAddressIsStarting() throws {
    let status = try EasyTierStatus.parse(#"{"running":true,"ipv4":null,"hostname":"","peer_count":0,"error":null}"#)
    #expect(EasyTierStatus.nodeStatus(status) == .starting)
}

@Test("no network is stopped, a stopped network with an error has failed")
func stoppedAndFailedStatuses() throws {
    #expect(EasyTierStatus.nodeStatus(try EasyTierStatus.parse(#"{"running":false}"#)) == .stopped)
    let failed = try EasyTierStatus.parse(#"{"running":false,"error":"bind failed","peer_count":0}"#)
    #expect(EasyTierStatus.nodeStatus(failed) == .failed("bind failed"))
    #expect(EasyTierStatus.nodeStatus(nil) == .failed("EasyTier returned an unreadable status"))
}

@Test("malformed status JSON is rejected")
func malformedStatusThrows() {
    #expect(throws: (any Error).self) { try EasyTierStatus.parse("{") }
    #expect(throws: (any Error).self) { try EasyTierStatus.parse(#"{"ipv4":"10.0.0.1"}"#) }
}

@Test("dial failures map to overlay errors")
func dialErrorsMap() {
    #expect(EasyTierStatus.dialError(code: -2, message: "deadline") == .timedOut)
    #expect(EasyTierStatus.dialError(code: -3, message: "") == .dialFailed("EasyTier is not running"))
    #expect(EasyTierStatus.dialError(code: -4, message: "no peer") == .dialFailed("no peer"))
    #expect(EasyTierStatus.dialError(code: -5, message: "") == .dialFailed(
        "The address is on more than one of the config server's networks"))
    #expect(EasyTierStatus.dialError(code: -5, message: "10.0.0.2 is on two") == .dialFailed("10.0.0.2 is on two"))
    #expect(EasyTierStatus.dialError(code: -1, message: "") == .dialFailed("EasyTier could not connect"))
}

@Test("start failures map to overlay errors")
func startErrorsMap() {
    #expect(EasyTierStatus.startError(code: -2, message: "slow") == .timedOut)
    #expect(EasyTierStatus.startError(code: -1, message: "bad peer") == .startFailed("bad peer"))
    #expect(EasyTierStatus.startError(code: -1, message: "") == .startFailed("EasyTier could not start"))
}

@Test("timeouts convert to positive, clamped milliseconds")
func timeoutMilliseconds() {
    #expect(EasyTierStatus.milliseconds(.seconds(3)) == 3000)
    #expect(EasyTierStatus.milliseconds(.milliseconds(1500)) == 1500)
    #expect(EasyTierStatus.milliseconds(.microseconds(10)) == 1)
    #expect(EasyTierStatus.milliseconds(.seconds(-1)) == 1)
    #expect(EasyTierStatus.milliseconds(.seconds(Int64.max)) == UInt32.max)
}

// MARK: - Instances

/// A native library with one network or session per instance key, recording
/// every call with its key.
private final class FakeNative: @unchecked Sendable {
    private struct Instance {
        var toml: String?
        var web: (fields: String, running: String)?
    }

    private let lock = NSLock()
    private var instances: [String: Instance] = [:]
    private var calls: [String] = []
    private var webStartCalls: [[String]] = []
    /// Starts of these keys wait until `release(_:)`.
    private var held: [String: DispatchSemaphore] = [:]

    var native: EasyTierNative {
        EasyTierNative(
            start: { key, toml, _ in
                let gate = self.lock.withLock { self.held[key] }
                gate?.wait()
                return self.lock.withLock {
                    self.calls.append("start \(key)")
                    if toml.contains("bad") {
                        self.instances[key] = nil
                        return (-1, "boom")
                    }
                    self.instances[key] = Instance(toml: toml)
                    return (0, "")
                }
            },
            stop: { key in
                self.lock.withLock {
                    self.calls.append("stop \(key)")
                    self.instances[key] = nil
                }
            },
            connect: { key, network, host, _, _ in
                self.lock.withLock {
                    self.calls.append("connect \(key) \(network ?? "-") \(host)")
                    if host == "ambiguous" { return (-5, "\(host) is on two networks") }
                    guard self.instances[key] != nil else { return (-3, "") }
                    return (40 + Int32(key.count), "")
                }
            },
            statusJSON: { key in
                self.lock.withLock {
                    guard let instance = self.instances[key] else { return #"{"running":false}"# }
                    if let web = instance.web {
                        return #"{"mode":"web",\#(web.running),"web":{\#(web.fields)}}"#
                    }
                    let address = "10.1.1.\(key.count)"
                    return #"{"mode":"manual","running":true,"ipv4":"\#(address)","peer_count":1}"#
                }
            },
            webStart: { key, url, machineID, hostname, requireEncryption in
                self.lock.withLock {
                    self.calls.append("webStart \(key)")
                    self.webStartCalls.append([key, url, machineID, hostname, requireEncryption ? "encrypted" : "open"])
                    if self.instances[key]?.web == nil {
                        self.instances[key] = Instance(
                            web: (#""connected":false,"networks":[],"failures":[]"#, #""running":false"#))
                    }
                    return (0, "")
                }
            }
        )
    }

    /// The session `key` reports from now on.
    func setWeb(_ key: String, _ fields: String, running: String = #""running":false"#) {
        lock.withLock { instances[key] = Instance(web: (fields, running)) }
    }

    func hold(_ key: String) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.withLock { held[key] = gate }
        return gate
    }

    var webStarts: [[String]] { lock.withLock { webStartCalls } }
    var log: [String] { lock.withLock { calls } }
    func count(_ prefix: String) -> Int { log.filter { $0 == prefix }.count }
}

@Test("networks under different keys run side by side; the same key replaces")
func keysRunSideBySide() async throws {
    let fake = FakeNative()
    let runtime = EasyTierRuntime(native: fake.native)
    let first = EasyTierNode(configuration: configuration(networkName: "one", key: "a"), runtime: runtime)
    let second = EasyTierNode(configuration: configuration(networkName: "two", key: "bb"), runtime: runtime)

    try await first.start(timeout: .seconds(1))
    try await second.start(timeout: .seconds(1))
    #expect(await first.status() == .online(addresses: ["10.1.1.1"]))
    #expect(await second.status() == .online(addresses: ["10.1.1.2"]))
    // Each dial goes through its own key.
    #expect(try await first.dial(host: "10.1.1.9", port: 22, timeout: .seconds(1)).descriptor == 41)
    #expect(try await second.dial(host: "10.1.1.9", port: 22, timeout: .seconds(1)).descriptor == 42)
    #expect(fake.log.filter { $0.hasPrefix("connect") } == ["connect a - 10.1.1.9", "connect bb - 10.1.1.9"])
    #expect(await first.details().networkName == "one")
    #expect(await second.details().networkName == "two")

    // Stopping one leaves the other running.
    await first.stop()
    #expect(fake.log.last == "stop a")
    #expect(await first.status() == .stopped)
    #expect(await second.status() == .online(addresses: ["10.1.1.2"]))

    // A different configuration under the same key replaces it, and the
    // replaced node no longer touches the key.
    let replacement = EasyTierNode(configuration: configuration(networkName: "three", key: "bb"), runtime: runtime)
    try await replacement.start(timeout: .seconds(1))
    #expect(await second.status() == .stopped)
    let stale = try EasyTierRuntime.Key(configuration(networkName: "two", key: "bb"))
    await #expect(throws: OverlayError.dialFailed("another EasyTier network replaced this one")) {
        _ = try await runtime.dial(key: stale, network: nil, host: "10.1.1.9", port: 22, timeout: .seconds(1))
    }
    await second.stop()
    #expect(await replacement.status() == .online(addresses: ["10.1.1.2"]))
    #expect(fake.count("stop bb") == 0)
    await replacement.stop()
    #expect(fake.count("stop bb") == 1)
}

@Test("a failed start empties only its own key")
func failedStartReleasesOnlyItsKey() async throws {
    let fake = FakeNative()
    let runtime = EasyTierRuntime(native: fake.native)
    let good = EasyTierNode(configuration: configuration(networkName: "good", key: "a"), runtime: runtime)
    let bad = EasyTierNode(configuration: configuration(networkName: "bad", key: "b"), runtime: runtime)
    let badReplacement = EasyTierNode(configuration: configuration(networkName: "bad", key: "a"), runtime: runtime)

    try await good.start(timeout: .seconds(1))
    await #expect(throws: OverlayError.startFailed("boom")) {
        try await bad.start(timeout: .seconds(1))
    }
    #expect(await good.status() == .online(addresses: ["10.1.1.1"]))
    #expect(await bad.status() == .stopped)

    await #expect(throws: OverlayError.startFailed("boom")) {
        try await badReplacement.start(timeout: .seconds(1))
    }
    #expect(await good.status() == .stopped)
}

@Test("a slow start on one key holds up no other key")
func slowStartsDoNotBlockOtherKeys() async throws {
    let fake = FakeNative()
    let runtime = EasyTierRuntime(native: fake.native)
    let slow = EasyTierNode(configuration: configuration(networkName: "slow", key: "slow"), runtime: runtime)
    let fast = EasyTierNode(configuration: configuration(networkName: "fast", key: "fast"), runtime: runtime)
    let gate = fake.hold("slow")
    let starting = Task { try await slow.start(timeout: .seconds(5)) }
    // The slow key's start is in its barrier; the other key starts, dials
    // and stops meanwhile.
    try await fast.start(timeout: .seconds(1))
    #expect(try await fast.dial(host: "10.1.1.9", port: 22, timeout: .seconds(1)).descriptor == 44)
    #expect(await fast.status() == .online(addresses: ["10.1.1.4"]))
    await fast.stop()
    #expect(!fake.log.contains("start slow"))
    gate.signal()
    try await starting.value
    #expect(await slow.status() == .online(addresses: ["10.1.1.4"]))
}

@Test("an invalid configuration fails before touching the native network")
func invalidConfigurationNeverStarts() async {
    let fake = FakeNative()
    let node = EasyTierNode(configuration: configuration(peers: []), runtime: EasyTierRuntime(native: fake.native))
    await #expect(throws: OverlayError.invalidConfiguration("EasyTier needs at least one peer.")) {
        try await node.start(timeout: .seconds(1))
    }
    #expect(await node.status() == .failed("EasyTier needs at least one peer."))
    for key in ["", String(repeating: "k", count: 129), "line\nbreak"] {
        let unusable = EasyTierNode(
            configuration: configuration(key: key), runtime: EasyTierRuntime(native: fake.native))
        await #expect(throws: OverlayError.invalidConfiguration("The EasyTier instance key is not usable.")) {
            try await unusable.start(timeout: .seconds(1))
        }
    }
    #expect(fake.log.isEmpty)
}

@Test("dials on a running network do not restart it")
func dialsReuseTheRunningNetwork() async throws {
    let fake = FakeNative()
    let node = EasyTierNode(configuration: configuration(), runtime: EasyTierRuntime(native: fake.native))
    try await node.start(timeout: .seconds(1))
    for _ in 0..<3 {
        _ = try await node.dial(host: "10.1.1.2", port: 22, timeout: .seconds(1))
    }
    #expect(fake.count("start manual") == 1)

    // A network that died underneath is started again.
    fake.native.stop("manual")
    _ = try await node.dial(host: "10.1.1.2", port: 22, timeout: .seconds(1))
    #expect(fake.count("start manual") == 2)

    // The native refusal to guess between networks reaches the caller.
    await #expect(throws: OverlayError.dialFailed("ambiguous is on two networks")) {
        _ = try await node.dial(host: "ambiguous", port: 22, timeout: .seconds(1))
    }
}

// MARK: - Static address

@Test("a fixed IPv4 address replaces DHCP in the TOML")
func staticIPv4TurnsDHCPOff() throws {
    let fixed = configuration(ipv4: " 10.144.144.7/24 ")
    let toml = try EasyTierTOML.render(fixed)
    let lines = toml.split(separator: "\n")
    #expect(lines.contains(#"ipv4 = "10.144.144.7/24""#))
    #expect(lines.contains("dhcp = false"))
    #expect(!lines.contains("dhcp = true"))

    let blank = configuration(ipv4: "  ")
    #expect(try EasyTierTOML.render(blank).split(separator: "\n").contains("dhcp = true"))
}

@Test("fixed addresses must be IPv4 with a prefix of 1 to 32", arguments: [
    "10.144.144.7", "10.144.144.7/0", "10.144.144.7/33", "10.144.144.7/024", "10.144.144/24",
    "10.144.144.256/24", "10.144.144.07/24", "10.144.144.7/24\"\nno_tun = false", "fd00::1/64",
    "10.144.144.7/+8", "١٠.144.144.7/24", "10.144.144.7/24/8", "0.1.2.3/8", "127.0.0.2/8",
    "224.0.0.1/4", "255.255.255.255/32",
])
func malformedStaticIPv4IsRefused(_ value: String) {
    let fixed = configuration(ipv4: value)
    #expect(throws: OverlayError.self) { try EasyTierTOML.render(fixed) }
}

@Test("valid fixed addresses come back canonical")
func validStaticIPv4() throws {
    #expect(try EasyTierTOML.staticIPv4("10.0.0.1/8") == "10.0.0.1/8")
    #expect(try EasyTierTOML.staticIPv4("192.168.0.10/32") == "192.168.0.10/32")
    #expect(try EasyTierTOML.staticIPv4("100.64.0.0/1") == "100.64.0.0/1")
    #expect(try EasyTierTOML.staticIPv4("") == nil)
}

// MARK: - Peers

@Test("status peers map to overlay peers, sorted by hostname")
func statusPeersBecomeOverlayPeers() throws {
    let json = """
        {"running":true,"ipv4":"10.144.144.7","hostname":"iphone","peer_count":3,"error":null,
         "peers":[
          {"peer_id":3104729049,"hostname":"relayed","ipv4":"10.144.146.2","direct":false,"cost":2,"latency_ms":null},
          {"peer_id":7,"hostname":"Build-Box","ipv4":"10.144.144.2","direct":true,"cost":1,"latency_ms":0.25},
          {"peer_id":9,"hostname":"","ipv4":null,"direct":true,"cost":1,"latency_ms":12}
         ]}
        """
    let status = try EasyTierStatus.parse(json)
    let details = status.details
    #expect(details.nodeID == nil)
    #expect(details.hostname == "iphone")
    #expect(details.addresses == ["10.144.144.7"])
    #expect(details.peers == [
        OverlayPeer(id: "9", name: nil, addresses: [], isOnline: true, isDirect: true, latency: .milliseconds(12)),
        OverlayPeer(
            id: "7", name: "Build-Box", addresses: ["10.144.144.2"], isOnline: true, isDirect: true,
            latency: .microseconds(250)),
        OverlayPeer(
            id: "3104729049", name: "relayed", addresses: ["10.144.146.2"], isOnline: true, isDirect: false,
            latency: nil),
    ])
}

@Test("a status without peers still parses, with an empty peer list")
func statusWithoutPeers() throws {
    let status = try EasyTierStatus.parse(#"{"running":true,"ipv4":"10.1.1.1","peer_count":0}"#)
    #expect(status.details.peers == [])
    #expect(status.details.addresses == ["10.1.1.1"])
}

@Test("details come only from the network this configuration owns; logout stops it")
func detailsFollowOwnership() async throws {
    let fake = FakeNative()
    let runtime = EasyTierRuntime(native: fake.native)
    let first = EasyTierNode(configuration: configuration(networkName: "one"), runtime: runtime)
    let second = EasyTierNode(configuration: configuration(networkName: "two"), runtime: runtime)

    #expect(await first.details() == OverlayNodeDetails())
    try await first.start(timeout: .seconds(1))
    #expect(await first.details().addresses == ["10.1.1.6"])
    // Same key, another configuration: not the owner.
    #expect(await second.details() == OverlayNodeDetails())

    try await first.logout(timeout: .seconds(1))
    #expect(fake.count("stop manual") == 1)
    #expect(await first.status() == .stopped)
    #expect(await first.details() == OverlayNodeDetails())
}

// MARK: - Config server

@Test("a bare user name means the official config server", arguments: [
    ("alice", "udp://config-server.easytier.cn:22020/alice"),
    ("  bob-2_x.y~ ", "udp://config-server.easytier.cn:22020/bob-2_x.y~"),
    ("team/carol", "udp://config-server.easytier.cn:22020/team%2Fcarol"),
    ("dé?#%", "udp://config-server.easytier.cn:22020/d%C3%A9%3F%23%25"),
])
func bareUserNamesExpand(input: String, expected: String) {
    #expect(EasyTierConfigServer.normalizedURL(input) == expected)
}

@Test("config server URLs keep their token and lowercase the scheme and host", arguments: [
    ("udp://127.0.0.1:22020/admin", "udp://127.0.0.1:22020/admin"),
    ("TCP://Example.COM:22020/team%2Fbob", "tcp://example.com:22020/team%2Fbob"),
    ("ws://example.com:8080/alice", "ws://example.com:8080/alice"),
    ("WSS://Console.Example/api/web/alice", "wss://console.example/api/web/alice"),
    ("udp://[2001:db8::1]:22020/alice", "udp://[2001:db8::1]:22020/alice"),
])
func configServerURLsNormalize(input: String, expected: String) {
    #expect(EasyTierConfigServer.normalizedURL(input) == expected)
}

@Test("unusable config server addresses are refused", arguments: [
    "", "   ", "two words", "tab\tname",
    "udp://127.0.0.1/admin", "tcp://example.com:22020", "udp://example.com:22020/",
    "wss://example.com/", "ws://:80/alice", "quic://example.com:22020/alice",
    "http://example.com:80/alice", "unix:///tmp/socket/alice", "udp://user:pw@example.com:22020/alice",
    "wss://example.com/alice?x=1", "wss://example.com/alice#frag", "udp://example.com:70000/alice",
])
func badConfigServerAddressesAreRefused(input: String) {
    #expect(EasyTierConfigServer.normalizedURL(input) == nil)
}

@Test("redacted config server addresses keep the origin and drop the token", arguments: [
    ("udp://127.0.0.1:22020/s3cret-token", "udp://127.0.0.1:22020/…"),
    ("WSS://Console.Example/api/web/s3cret-token?x=1#frag", "wss://Console.Example/…"),
    ("udp://user:s3cret-token@example.com:22020/alice", "udp://example.com:22020/…"),
    ("udp://[2001:db8::1]:22020/s3cret-token", "udp://[2001:db8::1]:22020/…"),
])
func configServerAddressesRedact(input: String, expected: String) {
    #expect(EasyTierConfigServerURL.redacted(input) == expected)
}

@Test("addresses without a scheme and host redact to nothing", arguments: [
    "s3cret-token", "", "udp:///s3cret-token", "not a url://s3cret-token",
])
func unparsableAddressesRedactToNothing(input: String) {
    #expect(EasyTierConfigServerURL.redacted(input) == nil)
}

@Test("a refused config server address is reported without its token", arguments: [
    "udp://example.com:70000/s3cret-token", "wss://example.com/s3cret-token?x=1", "two s3cret-token",
])
func refusedConfigServerAddressesHideTheToken(input: String) throws {
    let configuration = EasyTierConfiguration(
        source: .configServer(EasyTierConfigServer(url: input, machineID: UUID())), hostname: "iphone",
        instanceKey: "server")
    do {
        _ = try EasyTierRuntime.Key(configuration)
        Issue.record("\(input) was accepted")
    } catch let OverlayError.invalidConfiguration(message) {
        #expect(!message.contains("s3cret-token"), "\(message)")
        #expect(message.contains("is not an EasyTier config server"))
    }
}

private let machineID = UUID(uuidString: "6A1F0E44-6C1E-4F43-9B7F-0123456789AB")!

private func serverConfiguration(
    _ url: String = "alice", hostname: String = "iphone", requireEncryption: Bool = true, key: String = "server"
) -> EasyTierConfiguration {
    EasyTierConfiguration(
        source: .configServer(EasyTierConfigServer(url: url, machineID: machineID, requireEncryption: requireEncryption)),
        hostname: hostname, instanceKey: key)
}

private func web(_ fields: String, running: String = #""running":false"#) throws -> EasyTierStatus {
    try EasyTierStatus.parse(#"{"mode":"web",\#(running),"web":{\#(fields)}}"#)
}

private let homeRunning = #"{"instance_id":"i1","network_name":"home","running":true,"ipv4":"10.144.144.9","ipv4_prefix":24,"hostname":"iphone","peer_count":1,"peers":[{"peer_id":7,"hostname":"box","ipv4":"10.144.144.2","direct":true,"cost":1,"latency_ms":0.5}],"error":null}"#
private let labRunning = #"{"instance_id":"i2","network_name":"lab","running":true,"ipv4":"10.150.0.9","ipv4_prefix":16,"hostname":"iphone","peer_count":1,"peers":[{"peer_id":7,"hostname":"rig","ipv4":"10.150.3.4","direct":false,"cost":2,"latency_ms":null}],"error":null}"#

@Test("a config-server node waits for the server, then for a network")
func configServerStatusMapsTheSession() throws {
    let disconnected = try web(#""connected":false,"machine_id":"x","networks":[],"failures":[]"#)
    #expect(EasyTierStatus.configServerStatus(disconnected, machineID: machineID)
        == .waiting("Connecting to the config server"))

    let unassigned = try web(#""connected":true,"networks":[],"failures":[]"#)
    #expect(EasyTierStatus.configServerStatus(unassigned, machineID: machineID) == .waiting(
        "Assign a network to this device (machine ID 6a1f0e44-6c1e-4f43-9b7f-0123456789ab) in the EasyTier console"))

    let joining = try web(
        #""connected":true,"networks":[{"instance_id":"i","network_name":"home","running":false,"error":null}],"failures":[]"#)
    #expect(EasyTierStatus.configServerStatus(joining, machineID: machineID) == .starting)

    let noAddressYet = try web(
        #""connected":true,"networks":[{"instance_id":"i","network_name":"home","running":true,"ipv4":null}],"failures":[]"#,
        running: #""running":true"#)
    #expect(EasyTierStatus.configServerStatus(noAddressYet, machineID: machineID) == .starting)

    let refused = try web(
        #""connected":true,"networks":[],"failures":[{"instance_id":"i","network_name":"home","message":"exit_nodes is not supported: Heeler only dials out"}]"#)
    #expect(EasyTierStatus.configServerStatus(refused, machineID: machineID) == .failed(
        "The config server's network \"home\" cannot run here: exit_nodes is not supported: Heeler only dials out"))

    let crashed = try web(
        #""connected":true,"networks":[{"instance_id":"i","network_name":"home","running":false,"error":"tun gone"}],"failures":[]"#)
    #expect(EasyTierStatus.configServerStatus(crashed, machineID: machineID) == .failed("tun gone"))

    // Running networks decide, even while the server is unreachable or
    // another of its networks was refused: every running address.
    let online = try web(
        #""connected":false,"networks":[\#(homeRunning),\#(labRunning)],"failures":[{"instance_id":"i3","network_name":"bad","message":"refused"}]"#,
        running: #""running":true"#)
    #expect(EasyTierStatus.configServerStatus(online, machineID: machineID)
        == .online(addresses: ["10.144.144.9", "10.150.0.9"]))

    // Without a session (the key runs a manual network) the node is stopped.
    let manual = try EasyTierStatus.parse(#"{"mode":"manual","running":true,"ipv4":"10.1.1.1"}"#)
    #expect(EasyTierStatus.configServerStatus(manual, machineID: machineID) == .stopped)
    #expect(EasyTierStatus.configServerStatus(nil, machineID: machineID)
        == .failed("EasyTier returned an unreadable status"))
}

@Test("a config server's networks are listed one by one, with their peers tagged by network")
func configServerDetailsListEveryAssignedNetwork() throws {
    let status = try web(
        #""connected":true,"machine_id":"m","networks":[\#(homeRunning),\#(labRunning),{"instance_id":"i4","network_name":"down","running":false,"ipv4":null,"peer_count":0,"peers":[],"error":"no route"}],"failures":[{"instance_id":"i3","network_name":"bad","message":"exit_nodes is not supported"}]"#,
        running: #""running":true"#)
    let details = status.configServerDetails(machineID: machineID)
    #expect(details.nodeID == "6a1f0e44-6c1e-4f43-9b7f-0123456789ab")
    #expect(details.hostname == "iphone")
    #expect(details.addresses == ["10.144.144.9", "10.150.0.9"])
    #expect(details.networkName == "home, lab")
    #expect(details.peers == [
        OverlayPeer(
            id: "i1/7", name: "box", addresses: ["10.144.144.2"], isOnline: true, isDirect: true,
            latency: .microseconds(500), network: "home"),
        OverlayPeer(
            id: "i2/7", name: "rig", addresses: ["10.150.3.4"], isOnline: true, isDirect: false, network: "lab"),
    ])
    #expect(details.assignedNetworks == [
        OverlayAssignedNetwork(id: "i1", name: "home", isRunning: true, address: "10.144.144.9/24", peerCount: 1),
        OverlayAssignedNetwork(id: "i2", name: "lab", isRunning: true, address: "10.150.0.9/16", peerCount: 1),
        OverlayAssignedNetwork(id: "i4", name: "down", isRunning: false, error: "no route"),
        OverlayAssignedNetwork(id: "i3", name: "bad", isRunning: false, error: "exit_nodes is not supported"),
    ])

    // Before any network runs: the machine ID and the assignments only.
    let waiting = try web(#""connected":true,"networks":[],"failures":[]"#).configServerDetails(machineID: machineID)
    #expect(waiting == OverlayNodeDetails(nodeID: "6a1f0e44-6c1e-4f43-9b7f-0123456789ab"))
}

@Test("an unusable config server fails before touching the native network")
func invalidConfigServerNeverStarts() async {
    let fake = FakeNative()
    let node = EasyTierNode(configuration: serverConfiguration("quic://x:1/a"), runtime: EasyTierRuntime(native: fake.native))
    await #expect(throws: OverlayError.self) { try await node.start(timeout: .seconds(1)) }
    #expect(fake.webStarts.isEmpty)
}

@Test("a config-server node runs its session under its own key, beside a manual network")
func configServerNodeLifecycle() async throws {
    let fake = FakeNative()
    let runtime = EasyTierRuntime(native: fake.native)
    let manual = EasyTierNode(configuration: configuration(networkName: "one"), runtime: runtime)
    let server = EasyTierNode(configuration: serverConfiguration(" alice "), runtime: runtime)

    try await manual.start(timeout: .seconds(1))
    #expect(await manual.details().networkName == "one")

    // Online once one of the server's networks runs; the wait before that
    // is the error when the timeout passes.
    fake.setWeb("server", #""connected":true,"networks":[],"failures":[]"#)
    await #expect(throws: OverlayError.startFailed(
        "Assign a network to this device (machine ID 6a1f0e44-6c1e-4f43-9b7f-0123456789ab) in the EasyTier console"
    )) {
        try await server.start(timeout: .milliseconds(300))
    }
    // The session started (and stays) even though no network ran in time.
    #expect(fake.webStarts == [
        ["server", "udp://config-server.easytier.cn:22020/alice", "6a1f0e44-6c1e-4f43-9b7f-0123456789ab", "iphone", "encrypted"]
    ])
    #expect(await manual.status() == .online(addresses: ["10.1.1.6"]))
    #expect(await server.details() == OverlayNodeDetails(nodeID: "6a1f0e44-6c1e-4f43-9b7f-0123456789ab"))

    fake.setWeb(
        "server", #""connected":true,"networks":[\#(homeRunning),\#(labRunning)],"failures":[]"#,
        running: #""running":true"#)
    try await server.start(timeout: .seconds(1))
    #expect(fake.webStarts.count == 1)
    #expect(await server.status() == .online(addresses: ["10.144.144.9", "10.150.0.9"]))
    #expect(try await server.dial(host: "10.150.3.4", port: 22, timeout: .seconds(1)).descriptor == 46)
    #expect(fake.log.last == "connect server - 10.150.3.4")
    #expect(await server.details().assignedNetworks.map(\.name) == ["home", "lab"])

    await server.stop()
    #expect(await server.status() == .stopped)
    #expect(fake.log.last == "stop server")
    #expect(await manual.status() == .online(addresses: ["10.1.1.6"]))
}

@Test("encryption is required by default, and turning it off restarts the session without it")
func configServerEncryptionSettingReachesTheNativeSession() async throws {
    #expect(EasyTierConfigServer(url: "alice", machineID: machineID).requireEncryption)
    let fake = FakeNative()
    let runtime = EasyTierRuntime(native: fake.native)
    let encrypted = EasyTierNode(configuration: serverConfiguration(), runtime: runtime)
    fake.setWeb(
        "server", #""connected":true,"networks":[\#(homeRunning)],"failures":[]"#, running: #""running":true"#)
    try await encrypted.start(timeout: .seconds(1))
    try await encrypted.start(timeout: .seconds(1))
    let open = EasyTierNode(configuration: serverConfiguration(requireEncryption: false), runtime: runtime)
    try await open.start(timeout: .seconds(1))
    #expect(fake.webStarts.map { $0[4] } == ["encrypted", "open"])
    #expect(await encrypted.status() == .stopped)
}
