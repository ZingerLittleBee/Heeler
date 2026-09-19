import Darwin
import Foundation
import Testing

@testable import HeelerSSH

@Test("a bridge write to a closed peer reports peerClosed")
func bridgeWriteToClosedPeerReportsPeerClosed() throws {
    let transport = try DirectTCPIPByteTransport()
    var innerDescriptor = try transport.takeDescriptor()
    let pumpDescriptor = try transport.takePumpDescriptor()
    defer {
        if innerDescriptor >= 0 { Darwin.close(innerDescriptor) }
        Darwin.close(pumpDescriptor)
    }

    Darwin.close(innerDescriptor)
    innerDescriptor = -1

    let result = try SessionDriver.writeBridge(
        Data("pending outer bytes".utf8),
        descriptor: pumpDescriptor)

    #expect(result == .peerClosed)
}

// The pump reports the errno that ended a bridge write (#351). Folding it into
// `connectionFailed` inside `writeBridge` is what left a dead pump and a live
// one indistinguishable in a CI log, so the errno has to survive the throw.
@Test("a bridge write to an invalid descriptor surfaces its errno")
func bridgeWriteToInvalidDescriptorSurfacesErrno() throws {
    let transport = try DirectTCPIPByteTransport()
    let innerDescriptor = try transport.takeDescriptor()
    let pumpDescriptor = try transport.takePumpDescriptor()
    Darwin.close(innerDescriptor)
    Darwin.close(pumpDescriptor)

    // Both ends are closed, so the descriptor is no longer a socket at all.
    // EPIPE would be reported as `peerClosed` instead, which is the branch the
    // test above covers.
    #expect(throws: SessionDriver.BridgeWriteFailure(code: EBADF)) {
        _ = try SessionDriver.writeBridge(
            Data("pending outer bytes".utf8),
            descriptor: pumpDescriptor)
    }
}
