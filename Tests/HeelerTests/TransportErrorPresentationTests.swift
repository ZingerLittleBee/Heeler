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

    @Test func channelFailureIncludesItsDiagnosticDetail() {
        #expect(
            TransportError.channelFailed(detail: "connection reset").connectionGuidance
                == "The connection failed: connection reset")
    }

    @Test func streamLocalOpenFailureNamesBothObservableCauses() {
        #expect(
            TransportError.streamLocalOpenFailed(path: "/tmp/herdr.sock").connectionGuidance
                == "herdr may not be running, or SSH stream-local forwarding may be disabled.")
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
