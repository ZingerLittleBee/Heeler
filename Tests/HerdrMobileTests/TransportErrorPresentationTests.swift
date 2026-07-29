import Testing

@testable import HerdrMobile

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
}
