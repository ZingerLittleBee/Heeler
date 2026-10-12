import HeelerSSH
import Testing

@testable import Heeler

/// Exercises the real connect-time and post-connect mappers (#133).
@Suite("HeelerSSH error mapping")
struct HeelerSSHErrorMappingTests {
    @Test func connectAndOperationMappersAgreeOnForwardingDenied() {
        let error = SSHError.forwardingDenied
        #expect(
            HeelerSSHTransport.mapConnectForTesting(error)
                == .tcpForwardingUnavailable)
        #expect(
            HeelerSSHTransport.mapOperationForTesting(error)
                == .tcpForwardingUnavailable)
    }

    @Test func connectAndOperationMappersAgreeOnAuthTimeoutAndCancel() {
        #expect(
            HeelerSSHTransport.mapConnectForTesting(SSHError.authenticationFailed)
                == .authenticationFailed)
        #expect(
            HeelerSSHTransport.mapOperationForTesting(SSHError.authenticationFailed)
                == .authenticationFailed)

        #expect(HeelerSSHTransport.mapConnectForTesting(SSHError.timedOut) == .timedOut)
        #expect(HeelerSSHTransport.mapOperationForTesting(SSHError.timedOut) == .timedOut)

        #expect(HeelerSSHTransport.mapConnectForTesting(SSHError.cancelled) == .cancelled)
        #expect(HeelerSSHTransport.mapOperationForTesting(SSHError.cancelled) == .cancelled)
    }

    /// Chat polls transcripts over weak links, so its own failures must not
    /// look like the link failures that make a Host redial.
    @Test func chatFileFailuresStayOffTheLinkFailurePath() {
        func failure(_ error: any Error) -> (TransportError, Bool)? {
            HeelerSSHTransport.hostFileFailure(for: error).map { ($0.error, $0.retiresChannel) }
        }
        #expect(failure(AsyncDeadlineError.timedOut)! == (.hostFileTimedOut, true))
        #expect(failure(SSHError.timedOut)! == (.hostFileTimedOut, true))
        #expect(failure(SSHError.sftpFailure(status: 3))! == (.hostFileUnreadable(status: 3), false))
        #expect(
            failure(SSHError.sftpUnavailable)!
                == (.hostFeatureUnavailable(feature: "Chat needs SFTP on the Host"), true))
        #expect(failure(CancellationError())! == (.cancelled, false))
        #expect(failure(SSHError.cancelled)! == (.cancelled, false))
        // A dead connection is the link's failure and keeps its own mapping.
        #expect(failure(SSHError.connectionInvalidated) == nil)
        #expect(
            failure(TransportError.sshUnreachable(detail: "gone"))!
                == (.sshUnreachable(detail: "gone"), true))
    }

    @Test func pathSpecificMappersStillDivergeWhereIntended() {
        // Connect treats a dead connection as unreachable; operations treat it
        // as a reusable-connection loss with its own copy.
        #expect(
            HeelerSSHTransport.mapConnectForTesting(SSHError.connectionInvalidated)
                == .sshUnreachable(detail: String(describing: SSHError.connectionInvalidated)))
        #expect(
            HeelerSSHTransport.mapOperationForTesting(SSHError.connectionInvalidated)
                == .sshUnreachable(detail: "The SSH connection is no longer reusable."))

        // Generic channel failure is the same classification on both paths.
        #expect(
            HeelerSSHTransport.mapConnectForTesting(SSHError.channelFailed)
                == .channelFailed(detail: String(describing: SSHError.channelFailed)))
        #expect(
            HeelerSSHTransport.mapOperationForTesting(SSHError.channelFailed)
                == .channelFailed(detail: String(describing: SSHError.channelFailed)))
    }
}
