import Foundation
import Testing

@testable import HeelerOverlay

/// Several EasyTier networks at once through the real CEasyTier, against the
/// peers `examples/multi-peer` (heeler-easytier) runs on the Mac, which the
/// Simulator reaches on 127.0.0.1. Runs only with
/// `TEST_RUNNER_HEELER_OVERLAY_EASYTIER_LIVE=1`; the config-server test also
/// needs `TEST_RUNNER_HEELER_OVERLAY_EASYTIER_WEB=1` and the helper started
/// with `--web <easytier-web>`. Peers (network, peer address, hostname,
/// listener):
///
///     heeler-live-a  10.144.144.2  peer-a  tcp://127.0.0.1:21310
///     heeler-live-b  10.144.144.2  peer-b  tcp://127.0.0.1:21311
///     heeler-live-c  10.144.150.2  peer-c  tcp://127.0.0.1:21312
///
/// each answering on port 22 with `SSH-2.0-heeler-live-<letter>\r\n`.
@Suite(
    "EasyTier live networks",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["HEELER_OVERLAY_EASYTIER_LIVE"] == "1"))
struct EasyTierMultiLiveTests {
    private static func manual(_ letter: String, ipv4: String) -> EasyTierConfiguration {
        EasyTierConfiguration(
            networkName: "heeler-live-\(letter)", networkSecret: "live-\(letter)",
            peers: ["tcp://127.0.0.1:\(21310 + ["a", "b", "c"].firstIndex(of: letter)!)"],
            hostname: "heeler-live-device", ipv4: ipv4, instanceKey: "live-\(letter)")
    }

    /// Dials until the route is up and returns the banner's letter.
    private static func banner(
        _ node: any OverlayNode, _ host: String, attempts: Int = 20
    ) async throws -> String {
        var lastError: (any Error)?
        for _ in 0..<attempts {
            do {
                let stream = try await node.dial(host: host, port: 22, timeout: .seconds(5))
                defer {
                    close(stream.descriptor)
                    stream.release()
                }
                let text = try readLine(stream.descriptor)
                guard text.hasPrefix("SSH-2.0-heeler-live-") else { return text }
                return String(text.dropFirst("SSH-2.0-heeler-live-".count))
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw lastError ?? OverlayError.timedOut
    }

    /// Reads up to the first newline, waiting at most five seconds.
    private static func readLine(_ descriptor: Int32) throws -> String {
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 256 {
            let count = read(descriptor, &byte, 1)
            guard count == 1 else { throw OverlayError.dialFailed("read failed (\(count), errno \(errno))") }
            if byte == UInt8(ascii: "\n") { break }
            if byte != UInt8(ascii: "\r") { bytes.append(byte) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test(.timeLimit(.minutes(3)))
    func manualNetworksStayApartEvenOnTheSameSubnet() async throws {
        // a and b share 10.144.144.0/24, this device's address on it, and
        // the peer address; c is another subnet.
        let a = OverlayNodes.easytier(Self.manual("a", ipv4: "10.144.144.10/24"))
        let b = OverlayNodes.easytier(Self.manual("b", ipv4: "10.144.144.10/24"))
        let c = OverlayNodes.easytier(Self.manual("c", ipv4: "10.144.150.10/24"))
        defer {
            Task {
                for node in [a, b, c] { await node.stop() }
            }
        }
        try await a.start(timeout: .seconds(30))
        try await b.start(timeout: .seconds(30))
        try await c.start(timeout: .seconds(30))
        #expect(await a.status() == .online(addresses: ["10.144.144.10"]))
        #expect(await b.status() == .online(addresses: ["10.144.144.10"]))

        for _ in 0..<3 {
            #expect(try await Self.banner(a, "10.144.144.2") == "a")
            #expect(try await Self.banner(b, "10.144.144.2") == "b")
            #expect(try await Self.banner(c, "10.144.150.2") == "c")
        }
        #expect(try await Self.banner(a, "peer-a") == "a")
        #expect(try await Self.banner(b, "PEER-B.et.net") == "b")

        // Each node sees only its own network's peer.
        #expect(await a.details().peers?.map(\.name) == ["peer-a"])
        #expect(await b.details().peers?.map(\.name) == ["peer-b"])
        #expect(await c.details().peers?.map(\.name) == ["peer-c"])

        // Another network's hostname or address never resolves or routes.
        await #expect(throws: OverlayError.self) {
            _ = try await a.dial(host: "peer-b", port: 22, timeout: .seconds(2))
        }
        await #expect(throws: OverlayError.self) {
            _ = try await b.dial(host: "peer-a", port: 22, timeout: .seconds(2))
        }
        await #expect(throws: OverlayError.self) {
            _ = try await a.dial(host: "10.144.150.2", port: 22, timeout: .seconds(2))
        }

        // Stopping one leaves the others dialling; it comes back alone.
        await a.stop()
        #expect(await a.status() == .stopped)
        #expect(try await Self.banner(b, "10.144.144.2") == "b")
        #expect(try await Self.banner(c, "10.144.150.2") == "c")
        try await a.start(timeout: .seconds(30))
        #expect(try await Self.banner(a, "10.144.144.2") == "a")
        #expect(try await Self.banner(b, "10.144.144.2") == "b")
        await b.stop()
        #expect(try await Self.banner(a, "10.144.144.2") == "a")
        for node in [a, b, c] { await node.stop() }
        #expect(await c.status() == .stopped)
    }

    @Test(
        .timeLimit(.minutes(3)),
        .enabled(if: ProcessInfo.processInfo.environment["HEELER_OVERLAY_EASYTIER_WEB"] == "1"))
    func configServerNetworksAreSelectedByDestination() async throws {
        let server = OverlayNodes.easytier(
            EasyTierConfiguration(
                source: .configServer(
                    EasyTierConfigServer(
                        url: "udp://127.0.0.1:22550/user",
                        machineID: try #require(UUID(uuidString: "5c0f0e44-6c1e-4f43-9b7f-0123456789ef")))),
                hostname: "heeler-live-device", instanceKey: "live-web"))
        // A manual network on the same subnet as the server's heeler-live-a.
        let b = OverlayNodes.easytier(Self.manual("b", ipv4: "10.144.144.10/24"))
        defer {
            Task {
                await server.stop()
                await b.stop()
            }
        }
        try await server.start(timeout: .seconds(60))
        // The helper assigns two networks; wait until both run.
        for _ in 0..<120 {
            let running = await server.details().assignedNetworks.filter(\.isRunning).map(\.name)
            if Set(running) == ["heeler-live-a", "heeler-live-c"] { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let assigned = await server.details().assignedNetworks
        let names = assigned.map(\.name).sorted()
        let allRunning = assigned.allSatisfy(\.isRunning)
        #expect(names == ["heeler-live-a", "heeler-live-c"])
        #expect(allRunning)
        try await b.start(timeout: .seconds(30))

        #expect(try await Self.banner(server, "10.144.144.2") == "a")
        #expect(try await Self.banner(server, "10.144.150.2") == "c")
        #expect(try await Self.banner(server, "peer-c") == "c")
        #expect(try await Self.banner(b, "10.144.144.2") == "b")
        #expect(try await Self.banner(server, "10.144.144.2") == "a")
        let peerNetworks = Set((await server.details().peers ?? []).compactMap(\.network))
        #expect(peerNetworks == ["heeler-live-a", "heeler-live-c"])

        // An address on neither network is refused, not guessed.
        await #expect(throws: OverlayError.self) {
            _ = try await server.dial(host: "192.0.2.1", port: 22, timeout: .seconds(2))
        }
        await server.stop()
        #expect(await server.status() == .stopped)
        #expect(try await Self.banner(b, "10.144.144.2") == "b")
        await b.stop()
    }
}
