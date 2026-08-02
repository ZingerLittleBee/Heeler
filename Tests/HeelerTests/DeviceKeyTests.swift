import CryptoKit
import Foundation
import Testing

@testable import Heeler

// Expected values come from an independent source of truth: the public key
// line was fed to `ssh-keygen -lf`, which reported this exact fingerprint
// for the key derived from this fixed seed.
@Suite("Device key")
struct DeviceKeyTests {
    private static let seed = Data((0..<32).map { UInt8($0) })
    private static let expectedLine =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAOhB7/zzhC+HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4"
    private static let expectedFingerprint =
        "SHA256:lbmsoA0yIEcEiVDRnMWuzm+nV+3ZEEpVIURqFoeSspg"
    /// Fixed macOS OpenSSH ECDSA Host public-key blob. The expected digest
    /// was produced independently with `ssh-keygen -lf ... -E sha256`.
    private static let hostKeyBlobBase64 =
        "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLyV4P8X5ejHCiSXChjxKWe2cdgcIxeGntnlZT3vKZnj7aFm1F8ZQ6x87oi61JenL3bH0Vw/Ipz4Pk6CL+zrLiA="
    private static let expectedHostKeyFingerprint =
        "SHA256:/z4b3jFj66ra/PAPVBN+nGDlLnPuHGm/Mlt0Je1YvyM"

    private var key: DeviceKey {
        get throws {
            DeviceKey(privateKey: try Curve25519.Signing.PrivateKey(rawRepresentation: Self.seed))
        }
    }

    @Test func openSSHPublicKeyMatchesSSHKeygenFormat() throws {
        #expect(try key.openSSHPublicKey == Self.expectedLine)
    }

    @Test func authorizedKeysLineAppendsComment() throws {
        #expect(
            try key.authorizedKeysLine(comment: "herdr-mobile iPhone")
                == Self.expectedLine + " herdr-mobile iPhone")
    }

    @Test func fingerprintOfPublicKeyBlobMatchesSSHKeygen() throws {
        let fingerprint = HostKeyFingerprint(publicKeyBlob: try key.publicKeyBlob)
        #expect(fingerprint.displayString == Self.expectedFingerprint)
    }

    @Test func fingerprintRoundTripsThroughItsDigest() throws {
        let fingerprint = HostKeyFingerprint(publicKeyBlob: try key.publicKeyBlob)
        #expect(HostKeyFingerprint(digest: fingerprint.digest) == fingerprint)
    }

    @Test func ecdsaHostKeyFingerprintMatchesSSHKeygenOracle() throws {
        let blob = try #require(Data(base64Encoded: Self.hostKeyBlobBase64))

        let fingerprint = HostKeyFingerprint(publicKeyBlob: blob)

        #expect(fingerprint.displayString == Self.expectedHostKeyFingerprint)
    }
}
