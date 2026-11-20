import CTailscale
import Darwin
import Foundation
import Synchronization

/// One tailcat client (github.com/tailscale/tailcat, linked inside
/// CTailscale): a WireGuard tunnel to one `tailcat serve` machine, set up
/// over a DERP relay with no tailnet and no coordination server. Everything
/// the client needs is in the server's address.
///
/// The tunnel has one destination, so `dial` only accepts the configured
/// server name, and the port must be one `tailcat serve` exposes.
///
/// Every start and dial pings the server first. That tells a server that is
/// gone from a port it does not serve (which answers nothing either), and it
/// is how a client learns the server forgot it: tailcat registers a client
/// once, so after the server restarts an old client is never answered
/// again. A client that was answered before and is not now is replaced,
/// unless streams or other calls still use it.
actor TailcatNode: OverlayNode {
    nonisolated let kind = OverlayKind.tailcat
    private let configuration: TailcatConfiguration
    private let native: any TailcatNative
    /// How long a client the server answered before may go unanswered
    /// before it is replaced, so the replacement still fits in the deadline.
    private let probeLimit: Duration
    /// How long `details` shows a measured path before measuring again.
    private let pathLifetime: Duration

    private var client: Client?
    private var lastStatus: OverlayNodeStatus = .stopped
    /// Starts and dials in progress.
    private var calls = 0
    /// The last close; `stop` returns once it has finished.
    private var closing: Task<Void, Never>?

    private struct Client {
        let handle: Int32
        /// Streams dialled through this client and not yet closed.
        let streams = StreamCount()
        /// Whether the server has answered: the client is registered there.
        var answered = false
        var path: TailcatPath?
        var measured: ContinuousClock.Instant?
    }

    static let noAnswer =
        "The tailcat server did not answer. Check that tailcat serve is running there and that the address is its current one."

    init(
        configuration: TailcatConfiguration,
        native: any TailcatNative = LiveTailcatNative(),
        probeLimit: Duration = .seconds(5),
        pathLifetime: Duration = .seconds(5)
    ) {
        self.configuration = configuration
        self.native = native
        self.probeLimit = probeLimit
        self.pathLifetime = pathLifetime
    }

    func start(timeout: Duration) async throws {
        _ = try await reachServer(deadline: OverlayDeadline(after: timeout))
    }

    func dial(host: String, port: UInt16, timeout: Duration) async throws -> OverlayDialedStream {
        guard port != 0 else {
            throw OverlayError.invalidDestination("A tailcat dial needs a port.")
        }
        let serverName = Self.normalizedName(configuration.serverName)
        guard Self.normalizedName(host) == serverName else {
            throw OverlayError.invalidDestination(
                "A tailcat tunnel only reaches the machine running tailcat serve. Use \(serverName) as the address.")
        }
        let deadline = OverlayDeadline(after: timeout)
        let handle = try await reachServer(deadline: deadline)
        guard let streams = liveClient(handle)?.streams else { throw OverlayError.cancelled }

        calls += 1
        defer { calls -= 1 }
        let native = native
        let remaining = deadline.remaining
        let milliseconds = Self.milliseconds(remaining)
        let result: Result<Int32, TailcatFailure>
        do {
            result = try await BlockingCall.run(
                name: "tailcat.dial",
                timeout: remaining,
                abandon: { result in
                    // The dial outlived its caller: nobody owns this descriptor.
                    if case .success(let descriptor) = result { Darwin.close(descriptor) }
                }
            ) {
                native.dial(handle, port: port, timeoutMilliseconds: milliseconds)
            }
        } catch OverlayError.timedOut {
            result = .failure(.timedOut)
        }

        switch result {
        case .success(let descriptor):
            guard liveClient(handle) != nil else {
                // Stopped meanwhile: the stream ended with its client.
                Darwin.close(descriptor)
                throw OverlayError.cancelled
            }
            streams.add(1)
            // libtailscale pumps the other socketpair end itself and stops
            // when this end closes; only the count is ours to release.
            return OverlayDialedStream(descriptor: descriptor, release: { streams.add(-1) })
        case .failure(.timedOut):
            // The server answered the ping just before, so it is there and
            // knows this client. A port it does not serve answers nothing.
            throw OverlayError.dialFailed(
                "The tailcat server answered, but not on port \(port). Check which ports tailcat serve exposes.")
        case .failure(.closed):
            throw OverlayError.cancelled
        case .failure(.failed(let detail)):
            throw OverlayError.dialFailed(detail)
        }
    }

    func status() async -> OverlayNodeStatus {
        lastStatus
    }

    func stop() async {
        lastStatus = .stopped
        if let client {
            self.client = nil
            close(client.handle)
        }
        await closing?.value
    }

    /// The tunnel's one peer, the server, with the path a ping measured;
    /// empty until the server has answered. Never opens a client.
    func details() async -> OverlayNodeDetails {
        guard let current = client, current.answered else { return OverlayNodeDetails() }
        let handle = current.handle
        if current.measured.map({ ContinuousClock.now - $0 >= pathLifetime }) ?? true {
            let outcome = await ping(handle, timeout: probeLimit)
            guard liveClient(handle) != nil else { return OverlayNodeDetails() }
            record(try? outcome.get(), for: handle)
        }
        let path = liveClient(handle)?.path
        let serverName = Self.normalizedName(configuration.serverName)
        return OverlayNodeDetails(
            peers: [
                OverlayPeer(
                    id: serverName,
                    addresses: [serverName],
                    isOnline: path != nil,
                    isDirect: path?.isDirect,
                    latency: path?.latency)
            ])
    }

    /// tailcat has no sign-in: the address is the whole credential, and
    /// forgetting it is the app's to do.
    func logout(timeout: Duration) async throws {
        await stop()
    }

    // MARK: - Client

    /// The handle of a client the server has just answered, opening one
    /// (and replacing one the server no longer answers) as needed.
    private func reachServer(deadline: OverlayDeadline) async throws -> Int32 {
        var replaced = false
        while true {
            let current = try openClient()
            let handle = current.handle
            if !current.answered { lastStatus = .starting }
            let limit = current.answered && !replaced ? min(deadline.remaining, probeLimit) : deadline.remaining
            calls += 1
            let outcome = await ping(handle, timeout: limit)
            calls -= 1
            guard liveClient(handle) != nil else { throw OverlayError.cancelled }

            switch outcome {
            case .success(let path):
                client?.answered = true
                record(path, for: handle)
                lastStatus = .online(addresses: [])
                return handle
            case .failure(.closed):
                throw OverlayError.cancelled
            case .failure(.timedOut):
                if current.answered, calls == 0, current.streams.value == 0 {
                    client = nil
                    close(handle)
                    if !replaced, !deadline.hasPassed {
                        replaced = true
                        continue
                    }
                } else {
                    record(nil, for: handle)
                }
                lastStatus = .failed(Self.noAnswer)
                throw OverlayError.dialFailed(Self.noAnswer)
            case .failure(.failed(let detail)):
                record(nil, for: handle)
                lastStatus = .failed(detail)
                throw OverlayError.startFailed(detail)
            }
        }
    }

    private func openClient() throws -> Client {
        if let client { return client }
        let address = configuration.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            throw OverlayError.invalidConfiguration("A tailcat address is required.")
        }
        guard !Self.normalizedName(configuration.serverName).isEmpty else {
            throw OverlayError.invalidConfiguration("A tailcat server name is required.")
        }
        // Prompt: it parses the address; the tunnel is built by the first ping.
        switch native.open(address: address) {
        case .success(let handle):
            let opened = Client(handle: handle)
            client = opened
            return opened
        case .failure(let error):
            if case .invalidConfiguration(let detail) = error { lastStatus = .failed(detail) }
            throw error
        }
    }

    /// The current client when it is still `handle`'s.
    private func liveClient(_ handle: Int32) -> Client? {
        client?.handle == handle ? client : nil
    }

    private func record(_ path: TailcatPath?, for handle: Int32) {
        guard client?.handle == handle else { return }
        client?.path = path
        client?.measured = .now
    }

    /// Queues the close behind any earlier one. Not awaited by the caller:
    /// clients are independent, so a replacement need not wait for it.
    private func close(_ handle: Int32) {
        let native = native
        let previous = closing
        closing = Task.detached {
            await previous?.value
            // Also ends dials and pings still waiting on the handle.
            await BlockingCall.run(name: "tailcat.close") { native.close(handle) }
        }
    }

    /// Cancellation reads as `.closed`: either way the caller is done.
    private func ping(_ handle: Int32, timeout: Duration) async -> Result<TailcatPath, TailcatFailure> {
        let native = native
        let milliseconds = Self.milliseconds(timeout)
        do {
            return try await BlockingCall.run(name: "tailcat.ping", timeout: timeout) {
                native.ping(handle, timeoutMilliseconds: milliseconds)
            }
        } catch OverlayError.timedOut {
            return .failure(.timedOut)
        } catch {
            return .failure(.closed)
        }
    }

    private static func milliseconds(_ timeout: Duration) -> UInt32 {
        UInt32(clamping: max(1, timeout.milliseconds))
    }

    /// Lowercased, without brackets or trailing dots.
    static func normalizedName(_ host: String) -> String {
        var name = OverlayAddress.unbracketed(host).lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }
}

/// Live streams of one client. `OverlayDialedStream.release` runs outside
/// the node's actor.
private final class StreamCount: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    func add(_ delta: Int) {
        count.withLock { $0 += delta }
    }
}

/// How a ping reached the server.
struct TailcatPath: Sendable, Equatable {
    var latency: Duration
    /// Whether the answer came over a direct UDP path rather than a relay.
    var isDirect: Bool

    init(latency: Duration, isDirect: Bool) {
        self.latency = latency
        self.isDirect = isDirect
    }

    /// `heeler_tailcat_ping`'s JSON; nil when it is not that.
    init?(json: Data) {
        struct Payload: Decodable {
            let latencyMilliseconds: Double
            let direct: Bool

            enum CodingKeys: String, CodingKey {
                case latencyMilliseconds = "latency_ms"
                case direct
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json),
            payload.latencyMilliseconds.isFinite, payload.latencyMilliseconds >= 0
        else { return nil }
        latency = .microseconds(Int64(payload.latencyMilliseconds * 1000))
        isDirect = payload.direct
    }
}

extension TailcatAddressInfo {
    /// `heeler_tailcat_address_info`'s JSON; nil when it is not that.
    init?(json: Data) {
        struct Payload: Decodable {
            let presharedKey: Bool
            let regionID: Int?
            let relays: [String]

            enum CodingKeys: String, CodingKey {
                case presharedKey = "preshared_key"
                case regionID = "region_id"
                case relays
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json) else { return nil }
        self.init(hasPresharedKey: payload.presharedKey, regionID: payload.regionID, relays: payload.relays)
    }
}

enum TailcatFailure: Error, Sendable, Equatable {
    case timedOut
    /// The client was closed while the call waited, or before it.
    case closed
    case failed(String)
}

/// The tailcat calls a `TailcatNode` makes; a seam so the node's handling of
/// its client can be tested without a server. `ping`, `dial` and `close`
/// block.
protocol TailcatNative: Sendable {
    func open(address: String) -> Result<Int32, OverlayError>
    func ping(_ handle: Int32, timeoutMilliseconds: UInt32) -> Result<TailcatPath, TailcatFailure>
    func dial(_ handle: Int32, port: UInt16, timeoutMilliseconds: UInt32) -> Result<Int32, TailcatFailure>
    func close(_ handle: Int32)
}

/// The address is a credential: nothing here logs it, the native side keeps
/// it out of its messages, and the client's own log is discarded (it names
/// the server's public keys, which is all an address without a pre-shared
/// key holds).
struct LiveTailcatNative: TailcatNative {
    private static let messageCapacity = 512

    static func addressInfo(_ address: String) -> TailcatAddressInfo? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var capacity = 1024
        // The JSON lists the relays an address names, so it has no fixed
        // bound: a longer result says how much room it needs.
        for _ in 0..<2 {
            var buffer = [CChar](repeating: 0, count: capacity)
            let length = Int(heeler_tailcat_address_info(trimmed, &buffer, capacity))
            guard length >= 0 else { return nil }
            if length < capacity {
                return TailcatAddressInfo(json: Self.data(buffer, count: length))
            }
            capacity = length + 1
        }
        return nil
    }

    func open(address: String) -> Result<Int32, OverlayError> {
        var message = [CChar](repeating: 0, count: Self.messageCapacity)
        let handle = heeler_tailcat_open(address, -1, &message, Self.messageCapacity)
        guard handle > 0 else {
            let detail = Self.string(message)
            return .failure(
                .invalidConfiguration(
                    detail.isEmpty
                        ? "The tailcat address is not valid."
                        : "The tailcat address cannot be used: \(detail)."))
        }
        return .success(handle)
    }

    func ping(_ handle: Int32, timeoutMilliseconds: UInt32) -> Result<TailcatPath, TailcatFailure> {
        let capacity = 512
        var buffer = [CChar](repeating: 0, count: capacity)
        var message = [CChar](repeating: 0, count: Self.messageCapacity)
        let length = heeler_tailcat_ping(
            handle, timeoutMilliseconds, &buffer, capacity, &message, Self.messageCapacity)
        guard length >= 0 else { return .failure(Self.failure(length, message)) }
        guard length < capacity, let path = TailcatPath(json: Self.data(buffer, count: Int(length))) else {
            return .failure(.failed("The tailcat client reported a path that could not be read."))
        }
        return .success(path)
    }

    func dial(_ handle: Int32, port: UInt16, timeoutMilliseconds: UInt32) -> Result<Int32, TailcatFailure> {
        var message = [CChar](repeating: 0, count: Self.messageCapacity)
        let descriptor = heeler_tailcat_dial(
            handle, port, timeoutMilliseconds, &message, Self.messageCapacity)
        guard descriptor >= 0 else { return .failure(Self.failure(descriptor, message)) }
        return .success(descriptor)
    }

    func close(_ handle: Int32) {
        _ = heeler_tailcat_close(handle)
    }

    private static func failure(_ code: Int32, _ message: [CChar]) -> TailcatFailure {
        switch code {
        case HEELER_TAILCAT_ERR_TIMEOUT:
            return .timedOut
        case HEELER_TAILCAT_ERR_CLOSED:
            return .closed
        default:
            let detail = string(message)
            return .failed(detail.isEmpty ? "tailcat error \(code)" : detail)
        }
    }

    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: data(buffer, count: buffer.firstIndex(of: 0) ?? buffer.count), as: UTF8.self)
    }

    private static func data(_ buffer: [CChar], count: Int) -> Data {
        Data(buffer.prefix(count).map { UInt8(bitPattern: $0) })
    }
}
