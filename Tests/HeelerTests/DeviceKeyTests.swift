import CryptoKit
import Foundation
import Security
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
            try key.authorizedKeysLine(comment: "heeler iPhone")
                == Self.expectedLine + " heeler iPhone")
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

@Suite("RSA key")
struct RSAKeyTests {
    @Test func generatedKeyUsesRSA3072OpenSSHWireFormat() throws {
        let key = try RSAKey.generate()
        let fields = try decodeSSHStrings(key.publicKeyBlob)

        #expect(key.keySizeInBits == 3_072)
        #expect(fields.count == 3)
        #expect(String(data: fields[0], encoding: .utf8) == "ssh-rsa")
        #expect(fields[1] == Data([0x01, 0x00, 0x01]))
        #expect(fields[2].count == 385)
        #expect(fields[2].first == 0)
        #expect(key.openSSHPublicKey == "ssh-rsa " + key.publicKeyBlob.base64EncodedString())
    }

    @Test func signsWithRSASHA512UsingTheGeneratedPrivateKey() throws {
        let key = try RSAKey.generate()
        let message = Data("rsa-sha2 authentication challenge".utf8)
        let signature = try key.signature(for: message)
        let publicKey = try #require(SecKeyCreateWithData(
            key.publicKeyDER as CFData,
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                kSecAttrKeySizeInBits as String: key.keySizeInBits,
            ] as CFDictionary,
            nil))

        #expect(SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA512,
            message as CFData,
            signature as CFData,
            nil))
    }

    @Test func rejectsAStoredRSAKeyWithTheWrongSize() throws {
        let smallerKey = try #require(SecKeyCreateRandomKey(
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: 2_048,
            ] as CFDictionary,
            nil))
        let smallerKeyData = try #require(
            SecKeyCopyExternalRepresentation(smallerKey, nil) as Data?)

        #expect(throws: RSAKeyError.invalidPrivateKey) {
            try RSAKey(privateKeyDER: smallerKeyData)
        }
    }

    @Test func authorizedKeysLineAppendsAComment() throws {
        let key = try RSAKey.generate()
        #expect(
            key.authorizedKeysLine(comment: "heeler rsa")
                == key.openSSHPublicKey + " heeler rsa")
    }

    private func decodeSSHStrings(_ blob: Data) throws -> [Data] {
        var offset = 0
        var fields: [Data] = []
        while offset < blob.count {
            let lengthEnd = offset + 4
            guard lengthEnd <= blob.count else { throw RSAKeyTestError.invalidBlob }
            let length = blob[offset..<lengthEnd].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset = lengthEnd
            let fieldEnd = offset + Int(length)
            guard fieldEnd <= blob.count else { throw RSAKeyTestError.invalidBlob }
            fields.append(Data(blob[offset..<fieldEnd]))
            offset = fieldEnd
        }
        return fields
    }
}

private enum RSAKeyTestError: Error {
    case invalidBlob
}
