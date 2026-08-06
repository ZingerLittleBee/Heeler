import HeelerSSH
import Testing

@testable import Heeler

/// Pins the shared SSHError → TransportError classifications so connect-time
/// and post-connect mappers cannot drift (#133).
@Suite("HeelerSSH error mapping")
struct HeelerSSHErrorMappingTests {
    @Test func sharedClassificationsAgreeOnUserVisibleOutcomes() {
        #expect(
            HeelerSSHTransport.sharedClassification(for: .forwardingDenied)
                == .tcpForwardingUnavailable)
        #expect(
            HeelerSSHTransport.sharedClassification(for: .authenticationFailed)
                == .authenticationFailed)
        #expect(HeelerSSHTransport.sharedClassification(for: .timedOut) == .timedOut)
        #expect(HeelerSSHTransport.sharedClassification(for: .cancelled) == .cancelled)
    }

    @Test func pathSpecificErrorsAreNotSharedClassifications() {
        #expect(HeelerSSHTransport.sharedClassification(for: .channelFailed) == nil)
        #expect(HeelerSSHTransport.sharedClassification(for: .streamLocalOpenFailed) == nil)
        #expect(HeelerSSHTransport.sharedClassification(for: .targetUnreachable) == nil)
        #expect(HeelerSSHTransport.sharedClassification(for: .connectionInvalidated) == nil)
        #expect(HeelerSSHTransport.sharedClassification(for: .unexpectedEOF) == nil)
    }
}
