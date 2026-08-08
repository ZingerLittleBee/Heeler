import Foundation

/// One deterministic impairment recipe for `scripts/fixtures/weak-network-proxy.py`.
///
/// Every knob is a fixed duration or a byte count, so the same profile treats
/// the link the same way on every run. `jitterMillis` is the only stochastic
/// one and is drawn from `jitterSeed`, so it replays exactly too.
struct WeakNetworkProfile: Sendable, Codable, Equatable {
    /// Delivery delay applied once to each chunk read off the source socket.
    var latencyMillis: Double = 0
    var jitterMillis: Double = 0
    var jitterSeed: Int = 0
    /// Token-bucket cap per direction; zero leaves the link unmetered.
    var bandwidthBytesPerSecond: Int = 0
    /// Largest single write onto the destination socket. Small values force
    /// the peer through many partial reads and EAGAIN cycles.
    var segmentBytes: Int = 0

    /// A link that is slow and choppy but still workable: roughly a poor
    /// mobile connection. Sized so the product's default 15 s request deadline
    /// stays comfortable, since these tests are about correctness under
    /// degradation rather than about the deadline.
    static let degraded = WeakNetworkProfile(
        latencyMillis: 40,
        jitterMillis: 15,
        jitterSeed: 7,
        bandwidthBytesPerSecond: 256 * 1_024,
        segmentBytes: 512)

    /// Barely alive: enough for a handshake, not enough to finish much else
    /// promptly. Fragmentation is aggressive so partial reads dominate.
    static let severe = WeakNetworkProfile(
        latencyMillis: 120,
        jitterMillis: 40,
        jitterSeed: 11,
        bandwidthBytesPerSecond: 16 * 1_024,
        segmentBytes: 128)

    /// A hard rate limit no request can finish under. Used to produce a real
    /// bandwidth-starvation timeout rather than a scripted hang.
    static let starved = WeakNetworkProfile(
        latencyMillis: 50,
        bandwidthBytesPerSecond: 64,
        segmentBytes: 32)
}

struct WeakNetworkProxyStats: Sendable, Equatable {
    var acceptedConnections: Int
    var liveConnections: Int
    var cutConnections: Int
    var bytesToServer: Int
    var bytesToClient: Int
}

enum WeakNetworkProxyError: Error, Equatable {
    case unreachable(String)
    case rejected(String)
}

/// Control client for the impairment proxy the merge fixture puts in front of
/// the fixture sshd. One JSON request line per connection, one response line
/// back — the same shape as the herdr API socket.
struct WeakNetworkProxyControl: Sendable {
    let host: String
    let port: UInt16

    private static let queue = DispatchQueue(label: "dev.bybee.heeler.weak-network-control")

    /// Puts a profile in force and proves it landed.
    ///
    /// A proxy that accepted the request and ignored it would look identical to
    /// one that applied it, and four of the seven weak-network tests would pass
    /// over an undegraded link. Comparing the echoed profile against what was
    /// sent is what closes that: the impairment is verified, not assumed.
    func apply(_ profile: WeakNetworkProfile) async throws {
        let response = try await send(ControlRequest(command: "profile", profile: profile))
        guard let applied = response.profile else {
            throw WeakNetworkProxyError.rejected("the proxy echoed no profile")
        }
        guard applied == profile else {
            throw WeakNetworkProxyError.rejected(
                "the proxy applied \(applied) rather than \(profile)")
        }
    }

    /// Restores pass-through forwarding and zeroes the byte counters.
    func reset() async throws {
        _ = try await send(ControlRequest(command: "reset"))
    }

    /// Severs every live proxied connection abruptly, so the peer sees RST
    /// rather than an orderly close. Returns how many were cut.
    @discardableResult
    func cut() async throws -> Int {
        try await send(ControlRequest(command: "cut")).cutConnections ?? 0
    }

    func stats() async throws -> WeakNetworkProxyStats {
        let response = try await send(ControlRequest(command: "stats"))
        return WeakNetworkProxyStats(
            acceptedConnections: response.acceptedConnections ?? 0,
            liveConnections: response.liveConnections ?? 0,
            cutConnections: response.cutConnections ?? 0,
            bytesToServer: response.bytesToServer ?? 0,
            bytesToClient: response.bytesToClient ?? 0)
    }

    private func send(_ request: ControlRequest) async throws -> ControlResponse {
        let payload = try JSONEncoder().encode(request) + Data("\n".utf8)
        let host = self.host
        let port = self.port
        let line: Data = try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result {
                    try Self.exchange(payload, host: host, port: port)
                })
            }
        }
        let response = try JSONDecoder().decode(ControlResponse.self, from: line)
        if let error = response.error {
            throw WeakNetworkProxyError.rejected(error)
        }
        return response
    }

    /// Blocking request/response against the control port, off the cooperative
    /// pool. The control path is deliberately dependency-free: the proxy is a
    /// fixture, and a test that needs a networking stack to steer its own
    /// fixture has one more thing that can fail.
    private static func exchange(_ payload: Data, host: String, port: UInt16) throws -> Data {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw WeakNetworkProxyError.unreachable("socket() failed")
        }
        defer { close(descriptor) }

        // Swift Testing cannot unblock a continuation that never resumes, so a
        // wedged control thread would hang the whole run to the xcodebuild
        // timeout rather than failing it. These bound that to five seconds.
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        let limitSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, limitSize)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, limitSize)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            throw WeakNetworkProxyError.unreachable("\(host) is not an IPv4 address")
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw WeakNetworkProxyError.unreachable("connect() failed with errno \(errno)")
        }

        var sent = 0
        try payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while sent < buffer.count {
                let written = write(descriptor, base + sent, buffer.count - sent)
                guard written > 0 else {
                    throw WeakNetworkProxyError.unreachable("write() failed with errno \(errno)")
                }
                sent += written
            }
        }

        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while !line.contains(UInt8(ascii: "\n")) {
            let received = read(descriptor, &buffer, buffer.count)
            guard received > 0 else {
                throw WeakNetworkProxyError.unreachable("the control port closed early")
            }
            line.append(contentsOf: buffer[0..<received])
        }
        return line
    }

    private struct ControlRequest: Encodable {
        let command: String
        var profile: WeakNetworkProfile?
    }

    private struct ControlResponse: Decodable {
        var ok: Bool?
        var error: String?
        var profile: WeakNetworkProfile?
        var cutConnections: Int?
        var acceptedConnections: Int?
        var liveConnections: Int?
        var bytesToServer: Int?
        var bytesToClient: Int?
    }
}

/// How many file descriptors this process currently holds open.
///
/// A leak instrument rather than a diagnostic: an SSH session that fails to
/// reclaim its socket, its SFTP handles, or its pipes shows up here as growth
/// proportional to the number of rounds, which no amount of one-off warm-up
/// allocation can imitate.
enum OpenFileDescriptorCount {
    static var current: Int {
        var limit = rlimit()
        // Descriptors are dense from zero, and the cap can be unlimited, so
        // scan a bounded window rather than the reported soft limit.
        let ceiling = getrlimit(RLIMIT_NOFILE, &limit) == 0
            ? Int(min(limit.rlim_cur, 8_192))
            : 1_024
        var open = 0
        for descriptor in 0..<Int32(ceiling) where fcntl(descriptor, F_GETFD) != -1 {
            open += 1
        }
        return open
    }
}
