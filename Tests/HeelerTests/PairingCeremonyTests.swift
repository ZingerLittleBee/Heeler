import Foundation
import Testing

@testable import Heeler

/// The pure parts of the pairing ceremony client (#65): the Enrollment accept
/// stdout protocol (documented in `plugin/README.md`) and the per-step
/// classification of ceremony failures (ADR 0007 failure taxonomy).
@Suite("Enrollment accept protocol")
struct EnrollmentResponseTests {
    @Test func parsesSuccessLineWithFingerprint() {
        let line = "HERDR-ENROLL:OK:SHA256:0Y1eCbGuGWCGKirP9nWzOTLIcuBLvewToJfOPQqrjHY"
        #expect(
            EnrollmentResponse.parse(line: line)
                == .enrolled(fingerprint: "SHA256:0Y1eCbGuGWCGKirP9nWzOTLIcuBLvewToJfOPQqrjHY"))
    }

    @Test(arguments: [
        ("HERDR-ENROLL:ERR:unknown_pairing", EnrollmentRefusal.unknownPairing),
        ("HERDR-ENROLL:ERR:expired", .expired),
        ("HERDR-ENROLL:ERR:invalid_key", .invalidKey),
        ("HERDR-ENROLL:ERR:no_input", .noInput),
    ])
    func parsesEveryDocumentedRefusalCode(line: String, refusal: EnrollmentRefusal) {
        #expect(EnrollmentResponse.parse(line: line) == .refused(refusal))
    }

    /// A future plugin may add refusal codes within the protocol's framing;
    /// they must surface as refusals, not as protocol violations.
    @Test func keepsUnrecognizedRefusalCodesAsRefusals() {
        #expect(
            EnrollmentResponse.parse(line: "HERDR-ENROLL:ERR:quota_exceeded")
                == .refused(.unrecognized(code: "quota_exceeded")))
    }

    @Test(arguments: [
        "",
        "HERDR-ENROLL:OK:",
        "HERDR-ENROLL:ERR:",
        "HERDR-ENROLL:WAT:hm",
        "welcome to fish, the friendly interactive shell",
        "HERDR-PAIR:1:e30",
    ])
    func rejectsLinesOutsideTheProtocol(line: String) {
        #expect(EnrollmentResponse.parse(line: line) == nil)
    }

    /// The accept script's OK fingerprint must be OpenSSH's SHA256 shape;
    /// anything else on the OK line is a protocol violation, not a success.
    @Test func rejectsSuccessLineWithMalformedFingerprint() {
        #expect(EnrollmentResponse.parse(line: "HERDR-ENROLL:OK:MD5:aa:bb") == nil)
    }
}

@Suite("Pairing failure taxonomy")
struct PairingCeremonyErrorTests {
    @Test func classifiesEveryFailureToItsStep() {
        #expect(PairingCeremonyError.hostUnreachable(detail: "x").step == .reach)
        #expect(PairingCeremonyError.bootstrapRejected.step == .authenticate)
        #expect(PairingCeremonyError.enrollmentRefused(.expired).step == .enroll)
        #expect(PairingCeremonyError.enrollmentFailed(detail: "x").step == .enroll)
        #expect(PairingCeremonyError.verificationFailed(detail: "x").step == .verify)
    }

    @Test func refusalCodesRoundTripTheWireCodes() {
        #expect(EnrollmentRefusal(wireCode: "unknown_pairing") == .unknownPairing)
        #expect(EnrollmentRefusal(wireCode: "expired") == .expired)
        #expect(EnrollmentRefusal(wireCode: "invalid_key") == .invalidKey)
        #expect(EnrollmentRefusal(wireCode: "no_input") == .noInput)
        #expect(EnrollmentRefusal(wireCode: "later_code") == .unrecognized(code: "later_code"))
    }
}
