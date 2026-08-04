import CryptoKit
import Foundation

/// Shared policy for the disposable real-sshd fixtures.
///
/// `scripts/run-ci-ios-tests.sh` exports `HEELER_SSH_E2E_REQUIRED=1` into the
/// Simulator before the mandatory real-SSH suites run. Under that flag a
/// missing, undecodable, or partially configured fixture must fail the suite
/// rather than skip it: a merge gate that turns an unavailable fixture into a
/// green skip proves nothing. Without the variable — a developer laptop with
/// no fixture running — the same suites still skip cleanly.
///
/// The variable's *presence* is the separate, coarser signal that the gate is
/// driving the run at all; see `isUnderMergeGate`.
enum RealSSHFixture {
    /// True when the caller demands real SSH coverage rather than tolerating it.
    static var isRequired: Bool {
        Self.requirement == "1"
    }

    /// True while the merge gate drives the run, whether or not it currently
    /// has a fixture configured. The gate keeps `HEELER_SSH_E2E_REQUIRED` set
    /// for its whole run: `1` while the disposable fixture is up, `0` for the
    /// final full lane, where every fixture-backed suite is meant to skip.
    ///
    /// A suite that can otherwise fall back onto machine-owned resources — the
    /// developer's own sshd on port 22 and their real
    /// `~/.ssh/authorized_keys` — must refuse that fallback here. The gate
    /// promises to leave no machine state to undo, and a suite that proves one
    /// thing on CI and a different one on a laptop proves neither.
    static var isUnderMergeGate: Bool {
        Self.requirement?.isEmpty == false
    }

    /// The scheme forwards its whole test-environment allow-list
    /// unconditionally, substituting an empty string for anything the invoking
    /// shell has not exported — so "set" here means non-empty, not non-nil.
    private static var requirement: String? {
        ProcessInfo.processInfo.environment["HEELER_SSH_E2E_REQUIRED"]
    }

    /// Suite condition for a fixture-backed suite.
    ///
    /// Enables the suite when its fixture is configured, and also when the
    /// fixture is required but absent, so the per-test `#require` reports the
    /// missing fixture as a failure instead of a skip.
    static func gate(_ isConfigured: Bool) -> Bool { isConfigured || isRequired }

    /// The Ed25519 Device Key the fixture authorizes.
    ///
    /// The fixture script generates a fresh seed per run and passes it in the
    /// fixture configuration, so no long-lived key in this repository ever
    /// authorizes a login on a developer machine.
    static func deviceKey(seed base64Seed: String) throws -> Curve25519.Signing.PrivateKey {
        guard let seed = Data(base64Encoded: base64Seed) else {
            throw RealSSHFixtureError.malformedDeviceKeySeed
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }
}

enum RealSSHFixtureError: Error {
    case malformedDeviceKeySeed
}
