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
