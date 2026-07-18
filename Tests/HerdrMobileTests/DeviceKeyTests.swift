import CryptoKit
import Foundation
import Testing

@testable import HerdrMobile

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
}
