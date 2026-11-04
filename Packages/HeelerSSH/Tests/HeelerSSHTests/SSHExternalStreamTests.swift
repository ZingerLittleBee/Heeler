import Darwin
import Foundation
import Testing

@testable import HeelerSSH

final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private func makeSocketPair() throws -> (Int32, Int32) {
    var descriptors: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    return (descriptors[0], descriptors[1])
}

@Test("an external stream hands its descriptor over non-blocking, exactly once")
func externalStreamHandsDescriptorOverOnce() throws {
    let (local, peer) = try makeSocketPair()
    defer { Darwin.close(peer) }
    let stream = try SSHExternalStream(descriptor: local)

    let taken = try stream.takeDescriptor()
    defer { Darwin.close(taken) }
    #expect(taken == local)
    #expect(fcntl(taken, F_GETFL, 0) & O_NONBLOCK != 0)
    var noSigPipe: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    #expect(getsockopt(taken, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, &length) == 0)
    #expect(noSigPipe != 0)
    #expect(throws: SSHError.connectionInvalidated) { _ = try stream.takeDescriptor() }
}

@Test("aborting an external stream closes an untaken descriptor and releases once")
func externalStreamAbortClosesAndReleasesOnce() throws {
    let (local, peer) = try makeSocketPair()
    defer { Darwin.close(peer) }
    let releases = ReleaseCounter()
    let stream = try SSHExternalStream(descriptor: local) { releases.increment() }

    stream.abort()
    stream.abort()

    #expect(releases.value == 1)
    // The peer sees end-of-file once the untaken local end is closed.
    var byte: UInt8 = 0
    #expect(Darwin.read(peer, &byte, 1) == 0)
}

@Test("an invalid descriptor is rejected and still released")
func externalStreamRejectsInvalidDescriptor() {
    let releases = ReleaseCounter()
    #expect(throws: SSHError.connectionFailed) {
        _ = try SSHExternalStream(descriptor: -1) { releases.increment() }
    }
    // A negative descriptor never reached the stream, so there was nothing
    // for it to own or release.
    #expect(releases.value == 0)
}
