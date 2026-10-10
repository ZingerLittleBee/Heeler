import Darwin
import Foundation
import Testing

@testable import HeelerOverlay

/// Two tsnet nodes on two independent tailnets in one process, dialling the
/// same tailnet address and each reaching its own tailnet's host. Needs two
/// coordination servers with banner hosts (`Tests/Support/two-tailnets.sh`
/// sets up Headscale ones), so it only runs with `HEELER_TS2=1`.
///
/// Environment (pass each to `xcodebuild` as `TEST_RUNNER_<name>`):
/// - `TS2_A_URL`, `TS2_A_KEY`, `TS2_B_URL`, `TS2_B_KEY`: coordination servers
///   and reusable auth keys.
/// - `TS2_SHARED_HOST`: an address that is a host on both tailnets
///   (default `100.64.0.1`), answering on port 22 with `TS2_A_BANNER` and
///   `TS2_B_BANNER` (defaults `SSH-2.0-TailnetA` and `SSH-2.0-TailnetB`).
/// - `TS2_B_ONLY_HOST`, `TS2_B_ONLY_BANNER`: a host only tailnet B has
///   (defaults `100.64.0.3` and `SSH-2.0-TailnetB3`).
@Suite(
    "Two tailnets live",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["HEELER_TS2"] == "1"))
struct TailscaleTwoTailnetLiveTests {
    static let env = ProcessInfo.processInfo.environment

    static func value(_ name: String, _ fallback: String) -> String {
        env[name].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }

    static func log(_ message: String) {
        print("[TS2] \(message)")
    }

    /// Footprint, resident size, and thread count of this process.
    static func usage() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var threads: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        if task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS, let threads {
            for index in 0..<Int(threadCount) { mach_port_deallocate(mach_task_self_, threads[index]) }
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_act_t>.stride))
        }
        guard result == KERN_SUCCESS else { return "task_info failed" }
        let megabytes = { (value: UInt64) in String(format: "%.1fMB", Double(value) / 1_048_576) }
        return "footprint=\(megabytes(info.phys_footprint)) rss=\(megabytes(info.resident_size)) threads=\(threadCount)"
    }

    /// The first line the peer sends.
    static func readLine(_ descriptor: Int32, seconds: Double = 8) -> String {
        var collected = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 256)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !collected.contains(10) {
            var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pending, 1, Int32(max(1, deadline.timeIntervalSinceNow * 1000))) > 0 else { break }
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            collected.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: collected, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func banner(_ node: any OverlayNode, _ host: String, timeout: Duration = .seconds(20)) async
        -> Result<String, OverlayError>
    {
        do {
            let stream = try await node.dial(host: host, port: 22, timeout: timeout)
            let line = await Task.detached { readLine(stream.descriptor) }.value
            Darwin.close(stream.descriptor)
            stream.release()
            return .success(line)
        } catch let error as OverlayError {
            return .failure(error)
        } catch {
            return .failure(.dialFailed("\(error)"))
        }
    }

    static func peerNames(_ details: OverlayNodeDetails) -> Set<String> {
        Set((details.peers ?? []).compactMap(\.name))
    }

    @Test(.timeLimit(.minutes(5)))
    func twoTailnetsRunSideBySide() async throws {
        let urlA = try #require(Self.env["TS2_A_URL"].flatMap(URL.init(string:)))
        let urlB = try #require(Self.env["TS2_B_URL"].flatMap(URL.init(string:)))
        let keyA = try #require(Self.env["TS2_A_KEY"])
        let keyB = try #require(Self.env["TS2_B_KEY"])
        let shared = Self.value("TS2_SHARED_HOST", "100.64.0.1")
        let bannerA = Self.value("TS2_A_BANNER", "SSH-2.0-TailnetA")
        let bannerB = Self.value("TS2_B_BANNER", "SSH-2.0-TailnetB")
        let onlyB = Self.value("TS2_B_ONLY_HOST", "100.64.0.3")
        let bannerOnlyB = Self.value("TS2_B_ONLY_BANNER", "SSH-2.0-TailnetB3")

        let temporary = FileManager.default.temporaryDirectory
        let directoryA = temporary.appendingPathComponent("ts2-a-\(UUID().uuidString)", isDirectory: true)
        let directoryB = temporary.appendingPathComponent("ts2-b-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directoryA)
            try? FileManager.default.removeItem(at: directoryB)
        }
        Self.log("baseline \(Self.usage())")
        let nodeA = OverlayNodes.tailscale(TailscaleConfiguration(
            stateDirectory: directoryA, hostname: "heeler-ts2-a", authKey: keyA, controlURL: urlA))
        let nodeB = OverlayNodes.tailscale(TailscaleConfiguration(
            stateDirectory: directoryB, hostname: "heeler-ts2-b", authKey: keyB, controlURL: urlB))

        // Both come online at once.
        async let startA: Void = nodeA.start(timeout: .seconds(90))
        async let startB: Void = nodeB.start(timeout: .seconds(90))
        try await startA
        try await startB
        Self.log("online A=\(await nodeA.status()) B=\(await nodeB.status()) \(Self.usage())")

        // Each sees only its own tailnet's peers.
        var detailsA = await nodeA.details()
        var detailsB = await nodeB.details()
        for _ in 0..<20 where (detailsA.peers ?? []).isEmpty || (detailsB.peers ?? []).isEmpty {
            try await Task.sleep(for: .milliseconds(500))
            detailsA = await nodeA.details()
            detailsB = await nodeB.details()
        }
        Self.log("A peers \(Self.peerNames(detailsA)) B peers \(Self.peerNames(detailsB))")
        #expect(Self.peerNames(detailsA).isDisjoint(with: Self.peerNames(detailsB)))
        #expect(!Self.peerNames(detailsA).contains("heeler-ts2-b"))
        #expect(!Self.peerNames(detailsB).contains("heeler-ts2-a"))
        let addressA = try #require(detailsA.addresses.first)
        let addressB = try #require(detailsB.addresses.first)

        // The same address reaches each tailnet's own host.
        #expect(await Self.banner(nodeA, shared) == .success(bannerA))
        #expect(await Self.banner(nodeB, shared) == .success(bannerB))
        #expect(await Self.banner(nodeB, onlyB) == .success(bannerOnlyB))

        // The other tailnet's addresses are not reachable: refused when the
        // network map has nothing there, or answered by this
        // tailnet's own host when it uses the same address.
        let ownA = Set(detailsA.addresses + (detailsA.peers ?? []).flatMap(\.addresses))
        let ownB = Set(detailsB.addresses + (detailsB.peers ?? []).flatMap(\.addresses))
        for (label, node, host, own, ownBanner) in [
            ("A to B-only", nodeA, onlyB, ownA, bannerA),
            ("A to B's node", nodeA, addressB, ownA, bannerA),
            ("B to A's node", nodeB, addressA, ownB, bannerB),
        ] {
            let started = ContinuousClock.now
            let result = await Self.banner(node, host, timeout: .seconds(10))
            Self.log("cross \(label) \(host) (also local: \(own.contains(host))) -> \(result)")
            if own.contains(host) {
                if case .success(let line) = result, !line.isEmpty {
                    #expect(line.hasPrefix(ownBanner), "\(label)")
                }
            } else {
                #expect(result == .failure(.dialFailed("\(host) is not on this tailnet.")), "\(label)")
                // At most the network-map settle window (5s after coming
                // online), not the dial's 10s timeout.
                #expect(ContinuousClock.now - started < .seconds(8), "\(label)")
            }
        }

        // Concurrent dials on both nodes.
        let results = await withTaskGroup(of: (Bool, Result<String, OverlayError>).self) { group in
            for index in 0..<8 {
                group.addTask { (true, await Self.banner(nodeA, shared)) }
                let host = index.isMultiple(of: 2) ? shared : onlyB
                group.addTask { (host == shared, await Self.banner(nodeB, host)) }
            }
            var all: [(Bool, Result<String, OverlayError>)] = []
            for await result in group { all.append(result) }
            return all
        }
        let expected = Set([bannerA, bannerB, bannerOnlyB])
        #expect(results.allSatisfy { (try? $0.1.get()).map(expected.contains) == true })
        Self.log("concurrent \(results.count) dials \(Self.usage())")

        // Stop and restart both; the same identities come back.
        async let stopA: Void = nodeA.stop()
        async let stopB: Void = nodeB.stop()
        _ = await (stopA, stopB)
        async let restartA: Void = nodeA.start(timeout: .seconds(90))
        async let restartB: Void = nodeB.start(timeout: .seconds(90))
        try await restartA
        try await restartB
        #expect(await nodeA.details().addresses == detailsA.addresses)
        #expect(await nodeB.details().addresses == detailsB.addresses)
        #expect(await Self.banner(nodeA, shared) == .success(bannerA))
        #expect(await Self.banner(nodeB, shared) == .success(bannerB))

        // Stopping one leaves the other working.
        await nodeA.stop()
        #expect(await Self.banner(nodeB, shared) == .success(bannerB))
        Self.log("after restart \(Self.usage())")

        try await nodeA.logout(timeout: .seconds(20))
        try await nodeB.logout(timeout: .seconds(20))
        Self.log("final \(Self.usage())")
    }
}
