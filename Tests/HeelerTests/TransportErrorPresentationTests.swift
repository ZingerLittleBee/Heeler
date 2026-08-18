import Testing

@testable import Heeler

struct TransportErrorPresentationTests {
    @Test func authenticationFailureExplainsTheRequiredRepair() {
        #expect(
            TransportError.authenticationFailed.connectionGuidance
                == "Authentication failed. Update this Host's credentials or authorized key.")
    }

    @Test func jumpHostFailurePreservesTheUnderlyingCause() {
        #expect(
            TransportError.jumpHostFailed(.timedOut).connectionGuidance
                == "Jump Host: The connection timed out.")
    }

    @Test func forwardingPolicyFailureNamesTheJumpHostRepair() {
        #expect(
            TransportError.tcpForwardingUnavailable.connectionGuidance
                == "SSH TCP forwarding is disabled. Enable it on the Jump Host.")
        #expect(TransportError.tcpForwardingUnavailable.isRetryable == false)
    }

    @Test func missingHerdrBinaryNamesTheHomebrewPATH() {
        let guidance = TransportError.herdrBinaryNotFound.connectionGuidance
        #expect(guidance.contains("/opt/homebrew/bin"))
        #expect(guidance.contains("/home/linuxbrew/.linuxbrew/bin"))
        #expect(TransportError.herdrBinaryNotFound.isRetryable == false)
    }

    @Test func channelFailureIncludesItsDiagnosticDetail() {
        #expect(
            TransportError.channelFailed(detail: "connection reset").connectionGuidance
                == "The connection failed: connection reset")
    }

    @Test func streamLocalOpenFailureLeadsWithHerdrNotRunning() {
        #expect(
            TransportError.streamLocalOpenFailed(path: "/tmp/herdr.sock").connectionGuidance
                == "herdr is not running on this Host. If it is running, "
                + "check SSH stream-local forwarding.")
    }

    /// A server rejection reads as herdr's own sentence, not as a Swift value
    /// printed at the user.
    @Test func serverRejectionQuotesTheServersMessage() {
        #expect(
            TransportError.apiRejected(code: "pane_not_found", message: "pane w11:p9 not found")
                .connectionGuidance
                == "herdr rejected the request: pane w11:p9 not found")
    }
}
