import Darwin
import Foundation
import Testing

@testable import HeelerOverlay

/// The native pump, driven over an ordinary socketpair in place of a libzt
/// socket. `app` is the descriptor Heeler receives; `peer` stands in for the
/// remote end of the overlay connection.
@Suite("Overlay stream pump", .serialized)
struct OverlayPumpTests {
    private struct Harness {
        let pump: OverlayPump
        let app: Int32
        let peer: Int32

        init(stallingSendsFor stallMilliseconds: Int32? = nil) throws {
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
                throw POSIXError(.EIO)
            }
            var enabled: Int32 = 1
            setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            let pump = OverlayPump()
            self.pump = pump
            let app: Int32
            if let stallMilliseconds {
                app = pump.startPOSIXStallingSends(pair[0], stallMilliseconds: stallMilliseconds)
            } else {
                app = pump.startPOSIX(pair[0])
            }
            guard app >= 0 else {
                Darwin.close(pair[1])
                throw POSIXError(.EIO)
            }
            setsockopt(app, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            self.app = app
            peer = pair[1]
        }

        func closeAll() {
            Darwin.close(app)
            Darwin.close(peer)
            pump.release()
        }
    }

    @Test func bytesFlowBothWays() throws {
        let harness = try Harness()
        defer { harness.closeAll() }

        try writeAll(harness.app, Array("ssh-2.0 hello".utf8))
        #expect(try readExactly(harness.peer, count: 13) == Array("ssh-2.0 hello".utf8))

        try writeAll(harness.peer, Array("banner".utf8))
        #expect(try readExactly(harness.app, count: 6) == Array("banner".utf8))
    }

    @Test func appWriteShutdownReachesThePeerAndRepliesStillFlow() throws {
        let harness = try Harness()
        defer { harness.closeAll() }

        try writeAll(harness.app, Array("request".utf8))
        shutdown(harness.app, SHUT_WR)

        #expect(try readToEOF(harness.peer) == Array("request".utf8))
        try writeAll(harness.peer, Array("response".utf8))
        shutdown(harness.peer, SHUT_WR)
        #expect(try readToEOF(harness.app) == Array("response".utf8))
    }

    @Test func peerWriteShutdownReachesTheAppAndRequestsStillFlow() throws {
        let harness = try Harness()
        defer { harness.closeAll() }

        try writeAll(harness.peer, Array("greeting".utf8))
        shutdown(harness.peer, SHUT_WR)
        #expect(try readToEOF(harness.app) == Array("greeting".utf8))

        try writeAll(harness.app, Array("late request".utf8))
        shutdown(harness.app, SHUT_WR)
        #expect(try readToEOF(harness.peer) == Array("late request".utf8))
    }

    @Test func largeTransfersInBothDirectionsArriveIntact() async throws {
        let harness = try Harness()
        defer { harness.closeAll() }
        let upstream = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let downstream = (0..<(768 << 10)).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) }
        let app = harness.app
        let peer = harness.peer

        async let upWrite: Void = Self.detached { try writeAll(app, upstream); shutdown(app, SHUT_WR) }
        async let downWrite: Void = Self.detached { try writeAll(peer, downstream); shutdown(peer, SHUT_WR) }
        async let upRead = Self.detached { try readToEOF(peer) }
        async let downRead = Self.detached { try readToEOF(app) }

        try await upWrite
        try await downWrite
        #expect(try await upRead == upstream)
        #expect(try await downRead == downstream)
    }

    @Test(.timeLimit(.minutes(1)))
    func aLongStallBeyondTheOldBudgetDoesNotCutTheStream() async throws {
        // The remote stays "writable" yet accepts nothing for 3 s — longer
        // than the earlier ~2 s stall budget. The stream must survive and
        // deliver everything once sends go through again.
        let harness = try Harness(stallingSendsFor: 3_000)
        defer { harness.closeAll() }
        let started = ContinuousClock.now

        try writeAll(harness.app, Array("held back".utf8))
        // Replies still flow while the other direction is stalled.
        try writeAll(harness.peer, Array("meanwhile".utf8))
        #expect(try readExactly(harness.app, count: 9) == Array("meanwhile".utf8))

        let peer = harness.peer
        let received = try await Self.detached { () throws -> [UInt8] in
            var waitPoll = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
            guard poll(&waitPoll, 1, 10_000) > 0 else { throw POSIXError(.ETIMEDOUT) }
            return try readExactly(peer, count: 9)
        }
        #expect(received == Array("held back".utf8))
        #expect(ContinuousClock.now - started >= .milliseconds(2_900))

        shutdown(harness.app, SHUT_WR)
        #expect(try readToEOF(harness.peer).isEmpty)
    }

    @Test func closingTheAppDescriptorClosesThePeer() throws {
        let harness = try Harness()
        defer {
            Darwin.close(harness.peer)
            harness.pump.release()
        }

        try writeAll(harness.app, Array("bye".utf8))
        Darwin.close(harness.app)
        #expect(try readToEOF(harness.peer) == Array("bye".utf8))
        // The pump gives up once the app end is gone and anything is sent back.
        _ = try? writeAll(harness.peer, Array("ignored".utf8))
        #expect(waitForHangUp(harness.peer))
    }

    @Test func releaseStopsAnIdlePumpAndClosesBothEnds() throws {
        let harness = try Harness()
        defer {
            Darwin.close(harness.app)
            Darwin.close(harness.peer)
        }

        harness.pump.release()
        harness.pump.release()  // idempotent
        #expect(try readToEOF(harness.peer).isEmpty)
        #expect(try readToEOF(harness.app).isEmpty)
    }

    @Test func pumpThreadsExitAfterTheStreamEnds() async throws {
        let before = OverlayPump.liveCount
        let harness = try Harness()
        #expect(OverlayPump.liveCount >= 1)
        shutdown(harness.app, SHUT_WR)
        shutdown(harness.peer, SHUT_WR)
        #expect(try readToEOF(harness.peer).isEmpty)
        #expect(try readToEOF(harness.app).isEmpty)
        harness.closeAll()
        // Other suites may run pumps concurrently; only require ours to go.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while OverlayPump.liveCount > before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(OverlayPump.liveCount <= before)
    }

    private static func detached<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try body() }) }.start()
        }
    }
}

// MARK: - Blocking socket helpers with a test timeout

private let ioTimeoutMilliseconds: Int32 = 5_000

private func waitFor(_ descriptor: Int32, events: Int16) throws {
    var descriptorPoll = pollfd(fd: descriptor, events: events, revents: 0)
    let ready = poll(&descriptorPoll, 1, ioTimeoutMilliseconds)
    guard ready > 0 else { throw POSIXError(.ETIMEDOUT) }
}

private func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) throws {
    var offset = 0
    while offset < bytes.count {
        try waitFor(descriptor, events: Int16(POLLOUT))
        let written = bytes[offset...].withUnsafeBytes { buffer in
            send(descriptor, buffer.baseAddress, buffer.count, MSG_DONTWAIT)
        }
        if written < 0 {
            if errno == EAGAIN || errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        offset += written
    }
}

private func readExactly(_ descriptor: Int32, count: Int) throws -> [UInt8] {
    var result: [UInt8] = []
    while result.count < count {
        let chunk = try readChunk(descriptor, limit: count - result.count)
        guard !chunk.isEmpty else { break }
        result += chunk
    }
    return result
}

private func readToEOF(_ descriptor: Int32) throws -> [UInt8] {
    var result: [UInt8] = []
    while true {
        let chunk = try readChunk(descriptor, limit: 64 << 10)
        if chunk.isEmpty { return result }
        result += chunk
    }
}

private func readChunk(_ descriptor: Int32, limit: Int) throws -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: limit)
    while true {
        try waitFor(descriptor, events: Int16(POLLIN))
        let count = buffer.withUnsafeMutableBytes { pointer in
            recv(descriptor, pointer.baseAddress, pointer.count, MSG_DONTWAIT)
        }
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { continue }
            if errno == ECONNRESET { return [] }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Array(buffer.prefix(count))
    }
}

/// True once the other end of `descriptor` is fully closed.
private func waitForHangUp(_ descriptor: Int32) -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        if poll(&descriptorPoll, 1, 50) > 0, descriptorPoll.revents & Int16(POLLHUP) != 0 {
            return true
        }
        let probe: [UInt8] = [0]
        let sent = probe.withUnsafeBytes { send(descriptor, $0.baseAddress, 1, MSG_DONTWAIT) }
        if sent < 0, errno == EPIPE || errno == ECONNRESET { return true }
        usleep(20_000)
    }
    return false
}
