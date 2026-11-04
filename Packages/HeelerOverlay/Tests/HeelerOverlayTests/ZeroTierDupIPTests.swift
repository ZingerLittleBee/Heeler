import CZeroTier
import Foundation
import Testing

@testable import HeelerOverlay

/// Two ZeroTier networks that assign this device the same address and the
/// same subnet, through the real CZeroTier, against a self-hosted planet and
/// controller. Runs only with `TEST_RUNNER_HEELER_OV_DUPIP=1` and:
///
/// - `TEST_RUNNER_HEELER_OV_DUPIP_DIR`: a directory with this device's
///   `identity.secret` and the controller's `planet` (results are also
///   written there, as `result-<phase>.log`);
/// - `TEST_RUNNER_HEELER_OV_DUPIP_NETWORK_A`, `..._NETWORK_B`: the two
///   network IDs (16 hex digits);
/// - `TEST_RUNNER_HEELER_OV_DUPIP_PHASE`: `same` (both networks assign this
///   device the same address and push the managed route
///   `192.168.77.0/24 via 10.99.0.2`), `distinct` (different device
///   addresses, otherwise as `same`), or `noRouteA` (as `same`, but network
///   A has no managed route to 192.168.77.0/24).
///
/// Each network has one peer at 10.99.0.2 that also holds 192.168.77.10 on
/// its loopback and answers on port 7000 with `BANNER-A …` or
/// `BANNER-B …`. Every dial must reach its own network's peer; in `noRouteA`
/// a dial to 192.168.77.10 through A must fail at once with "not reachable"
/// instead of waiting for its timeout.
@Suite(
    "ZeroTier networks sharing an address",
    .enabled(if: ProcessInfo.processInfo.environment["HEELER_OV_DUPIP"] == "1"))
struct ZeroTierDupIPTests {
    private static let subnetHost = "10.99.0.2"
    private static let routedHost = "192.168.77.10"

    private struct Fixture {
        let directory: String
        let networkA: UInt64
        let networkB: UInt64
        let phase: String

        init() throws {
            let environment = ProcessInfo.processInfo.environment
            directory = try #require(environment["HEELER_OV_DUPIP_DIR"], "set HEELER_OV_DUPIP_DIR")
            networkA = try #require(
                environment["HEELER_OV_DUPIP_NETWORK_A"].flatMap(ZeroTierNetworkID.parse),
                "set HEELER_OV_DUPIP_NETWORK_A")
            networkB = try #require(
                environment["HEELER_OV_DUPIP_NETWORK_B"].flatMap(ZeroTierNetworkID.parse),
                "set HEELER_OV_DUPIP_NETWORK_B")
            phase = environment["HEELER_OV_DUPIP_PHASE"] ?? "same"
            try #require(["same", "distinct", "noRouteA"].contains(phase), "unknown phase \(phase)")
        }
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private let path: String

        init(path: String) { self.path = path }

        func add(_ line: String) {
            lock.withLock {
                lines.append("\(Date().timeIntervalSince1970) \(line)")
                try? (lines.joined(separator: "\n") + "\n").write(
                    toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func readLine(_ fd: Int32, timeoutMs: Int = 8000) -> String {
        var data = [UInt8]()
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 500) <= 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data += buffer[0..<count]
            if data.contains(10) { break }
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum Outcome {
        case banner(String)
        case failed(OverlayError, Duration)
    }

    private static func dial(_ node: any OverlayNode, _ host: String) async -> Outcome {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let stream = try await node.dial(host: host, port: 7000, timeout: .seconds(15))
            let fd = stream.descriptor
            let line = await Task.detached { readLine(fd) }.value
            close(fd)
            stream.release()
            return .banner(line)
        } catch let error as OverlayError {
            return .failed(error, clock.now - start)
        } catch {
            return .failed(.dialFailed("\(error)"), clock.now - start)
        }
    }

    @Test(.timeLimit(.minutes(5)))
    func eachDialStaysOnItsOwnNetwork() async throws {
        let fixture = try Fixture()
        let log = Log(path: "\(fixture.directory)/result-\(fixture.phase).log")
        log.add("phase \(fixture.phase)")
        let identity = try String(
            contentsOfFile: "\(fixture.directory)/identity.secret", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let planet = try Data(contentsOf: URL(fileURLWithPath: "\(fixture.directory)/planet"))

        let a = OverlayNodes.zerotier(
            ZeroTierConfiguration(networkID: fixture.networkA, identity: Data(identity.utf8), roots: planet),
            identityGenerated: { _ in })
        let b = OverlayNodes.zerotier(
            ZeroTierConfiguration(networkID: fixture.networkB, identity: Data(identity.utf8), roots: planet),
            identityGenerated: { _ in })
        try await a.start(timeout: .seconds(120))
        try await b.start(timeout: .seconds(120))
        let statusA = await a.status()
        let statusB = await b.status()
        log.add("A status \(statusA)")
        log.add("B status \(statusB)")
        if fixture.phase != "distinct", case .online(let addressesA) = statusA,
            case .online(let addressesB) = statusB
        {
            #expect(!Set(addressesA).isDisjoint(with: addressesB), "the networks should share an address")
        }
        // Let both peers' paths settle.
        try await Task.sleep(for: .seconds(3))

        for (name, id) in [("A", fixture.networkA), ("B", fixture.networkB)] {
            for host in [Self.subnetHost, Self.routedHost, "172.31.9.9"] {
                var raw = in_addr()
                inet_pton(AF_INET, host, &raw)
                let code = withUnsafeBytes(of: &raw) {
                    heeler_zt_network_reaches(id, Int32(ZTS_AF_INET), $0.baseAddress)
                }
                log.add("reaches \(name) \(host) -> \(code)")
                let reachable = host == Self.subnetHost
                    || (host == Self.routedHost && !(fixture.phase == "noRouteA" && name == "A"))
                #expect(code == (reachable ? ZTS_ERR_OK.rawValue : HEELER_ZT_ERR_NO_ROUTE),
                        "network \(name) reaching \(host)")
            }
        }

        let unreachable = OverlayError.dialFailed(
            "\(Self.routedHost) is not reachable on ZeroTier network \(ZeroTierNetworkID.format(fixture.networkA))")
        func check(_ outcome: Outcome, name: String, host: String, label: String) -> Bool {
            let ok: Bool
            switch outcome {
            case .banner(let line):
                ok = !(fixture.phase == "noRouteA" && name == "A" && host == Self.routedHost)
                    && line.hasPrefix("BANNER-\(name) ")
                log.add("\(label) \(host) bound=\(name) -> \(line) \(ok ? "OK" : "WRONG")")
            case .failed(let error, let elapsed):
                ok = fixture.phase == "noRouteA" && name == "A" && host == Self.routedHost
                    && error == unreachable && elapsed < .seconds(2)
                log.add("\(label) \(host) bound=\(name) -> ERROR \(error) after \(elapsed) \(ok ? "OK" : "WRONG")")
            }
            return ok
        }

        var failures = 0
        for host in [Self.subnetHost, Self.routedHost] {
            for round in 0..<6 {
                for (name, node) in [("A", a), ("B", b)] {
                    if !check(await Self.dial(node, host), name: name, host: host, label: "seq round \(round)") {
                        failures += 1
                    }
                }
            }
        }
        for host in [Self.subnetHost, Self.routedHost] {
            let results = await withTaskGroup(of: (String, Outcome).self) { group in
                for index in 0..<16 {
                    let name = index % 2 == 0 ? "A" : "B"
                    let node = index % 2 == 0 ? a : b
                    group.addTask { (name, await Self.dial(node, host)) }
                }
                var all: [(String, Outcome)] = []
                for await result in group { all.append(result) }
                return all
            }
            for (name, outcome) in results where !check(outcome, name: name, host: host, label: "concurrent") {
                failures += 1
            }
        }
        log.add("failures \(failures)")
        #expect(failures == 0)
        await a.stop()
        await b.stop()
    }
}
