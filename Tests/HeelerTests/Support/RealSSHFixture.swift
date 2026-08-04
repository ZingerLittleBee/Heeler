import CryptoKit
import Foundation

/// Shared policy for the disposable real-sshd fixtures.
///
/// `scripts/run-ci-ios-tests.sh` exports `HEELER_SSH_E2E_REQUIRED=1` into the
/// Simulator before the mandatory real-SSH suites run. Under that flag a
/// missing, undecodable, or partially configured fixture must fail the suite
/// rather than skip it: a merge gate that turns an unavailable fixture into a
/// green skip proves nothing. Without the flag — a developer laptop with no
/// fixture running — the same suites still skip cleanly.
enum RealSSHFixture {
    /// True when the caller demands real SSH coverage rather than tolerating it.
    static var isRequired: Bool {
        ProcessInfo.processInfo.environment["HEELER_SSH_E2E_REQUIRED"] == "1"
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
