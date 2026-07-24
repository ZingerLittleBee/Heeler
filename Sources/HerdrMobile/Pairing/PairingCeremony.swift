import Foundation

/// The steps of the pairing ceremony, in order (ADR 0007). Failure copy is
/// keyed per step so the user knows whether to rescan, fix the network, or
/// regenerate the Pairing Code. `parse` failures never reach the ceremony
/// client — `PairingCode.decode` reports them as `PairingCodeError` — but the
/// step exists so every failure surface shares one taxonomy.
enum PairingStep: Sendable, Equatable, CaseIterable {
    /// Decoding the scanned string into a Pairing Code.
    case parse
    /// Finding a candidate address that presents the pinned host key.
    case reach
    /// Authenticating with the Bootstrap Key.
    case authenticate
    /// Submitting the Device Key public line to the Enrollment entrypoint.
    case enroll
    /// Reconnecting with the Device Key to prove Enrollment took effect.
    case verify
}

/// Why the pairing ceremony failed, classified per step.
enum PairingCeremonyError: Error, Sendable, Equatable {
    /// No candidate address yielded an SSH server presenting the pinned host
    /// key within the per-address timeout. Carries one line per attempted
    /// address for diagnostics.
    case hostUnreachable(detail: String)
    /// The Host is there — its key matched the pinned fingerprint — but it
    /// rejected the Bootstrap Key: the code was already used, its line
    /// expired and was swept, or the popup was closed.
    case bootstrapRejected
    /// The Enrollment entrypoint answered, and said no.
    case enrollmentRefused(EnrollmentRefusal)
    /// The Enrollment exchange broke down: the forced command's stdout did
    /// not speak the accept protocol, the channel died, or the exchange
    /// timed out.
    case enrollmentFailed(detail: String)
    /// The reconnect with the enrolled Device Key failed, so the Host was
    /// not persisted.
    case verificationFailed(detail: String)

    /// The Pairing step this failure is attributed to.
    var step: PairingStep {
        switch self {
        case .hostUnreachable: .reach
        case .bootstrapRejected: .authenticate
        case .enrollmentRefused, .enrollmentFailed: .enroll
        case .verificationFailed: .verify
        }
    }
}

/// A refusal code from the Enrollment accept protocol (`plugin/README.md`).
/// Unrecognized codes are kept verbatim: a newer plugin may refuse for
/// reasons this build does not know, and that is still a refusal.
enum EnrollmentRefusal: Sendable, Equatable {
    /// No pending ceremony: already used, cleaned up, or never existed.
    case unknownPairing
    /// The TTL passed; the Bootstrap Key line was removed. Regenerate.
    case expired
    /// The submission was not a bare Ed25519 public line. Retry is allowed.
    case invalidKey
    /// Nothing arrived on stdin. Retry is allowed.
    case noInput
    case unrecognized(code: String)

    init(wireCode: String) {
        switch wireCode {
        case "unknown_pairing": self = .unknownPairing
        case "expired": self = .expired
        case "invalid_key": self = .invalidKey
        case "no_input": self = .noInput
        default: self = .unrecognized(code: wireCode)
        }
    }
}

/// What a completed ceremony proves: the facts the app persists as a Host
/// (only after the verified reconnect — a failed pairing leaves nothing).
struct PairingResult: Sendable, Equatable {
    /// The candidate address the ceremony succeeded against.
    let address: String
    let port: Int
    let username: String
    /// The fingerprint the Host actually presented, digest-equal to the
    /// pinned one from the Pairing Code but algorithm-aware, ready for the
    /// known-hosts store.
    let hostKeyFingerprint: HostKeyFingerprint
}

/// One line of the Enrollment accept stdout protocol:
///
///     HERDR-ENROLL:OK:<SHA256:fingerprint>
///     HERDR-ENROLL:ERR:<code>
///
/// Anything else is not a response at all (login-shell noise, a wrong forced
/// command) and parses to nil.
enum EnrollmentResponse: Sendable, Equatable {
    case enrolled(fingerprint: String)
    case refused(EnrollmentRefusal)

    static func parse(line: String) -> EnrollmentResponse? {
        if let fingerprint = line.wholeMatch(of: /HERDR-ENROLL:OK:(SHA256:[A-Za-z0-9+\/]{43})/) {
            return .enrolled(fingerprint: String(fingerprint.1))
        }
        if let refusal = line.wholeMatch(of: /HERDR-ENROLL:ERR:([a-z_]+)/) {
            return .refused(EnrollmentRefusal(wireCode: String(refusal.1)))
        }
        return nil
    }
}
