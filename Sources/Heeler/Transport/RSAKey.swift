import Foundation
import Security

/// An RSA SSH identity for Hosts that require RSA-SHA2 authentication. The
/// private PKCS#1 bytes are persisted only by `RSAKeyStore`; this value keeps
/// them in memory while authenticating.
struct RSAKey: Sendable {
    private static let requiredKeySizeInBits = 3_072

    let privateKeyDER: Data
    let publicKeyDER: Data
    let keySizeInBits: Int

    private let exponent: Data
    private let modulus: Data

    init(privateKeyDER: Data) throws {
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(
            privateKeyDER as CFData,
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            ] as CFDictionary,
            &error
        ) else {
            throw RSAKeyError.invalidPrivateKey
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else {
            throw RSAKeyError.publicKeyUnavailable
        }
        guard let attributes = SecKeyCopyAttributes(privateKey) as? [String: Any],
              let keySize = attributes[kSecAttrKeySizeInBits as String] as? Int,
              keySize == Self.requiredKeySizeInBits
        else {
            throw RSAKeyError.invalidPrivateKey
        }

        let components = try RSAPublicKeyDER.parse(publicKeyData)
        self.privateKeyDER = privateKeyDER
        publicKeyDER = publicKeyData
        keySizeInBits = keySize
        exponent = components.exponent
        modulus = components.modulus
    }

    static func generate() throws -> RSAKey {
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: Self.requiredKeySizeInBits,
            ] as CFDictionary,
            &error
        ), let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data?
        else {
            throw RSAKeyError.generationFailed
        }
        return try RSAKey(privateKeyDER: privateKeyData)
    }

    /// SSH wire-format RSA public key blob (RFC 4253 section 6.6):
    /// `string "ssh-rsa"` + `mpint e` + `mpint n`.
    var publicKeyBlob: Data {
        var blob = Data()
        blob.appendSSHField(Data("ssh-rsa".utf8))
        blob.appendSSHField(exponent)
        blob.appendSSHField(modulus)
        return blob
    }

    var openSSHPublicKey: String {
        "ssh-rsa " + publicKeyBlob.base64EncodedString()
    }

    func authorizedKeysLine(comment: String) -> String {
        openSSHPublicKey + " " + comment
    }

    /// Signs the SSH user-auth payload with RSA-SHA2-512. This intentionally
    /// has no legacy ssh-rsa/SHA-1 fallback.
    func signature(for data: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(
            privateKeyDER as CFData,
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: keySizeInBits,
            ] as CFDictionary,
            &error
        ), let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA512,
            data as CFData,
            &error
        ) as Data?
        else {
            throw RSAKeyError.signingFailed
        }
        return signature
    }
}

enum RSAKeyError: Error, Equatable {
    case generationFailed
    case invalidPrivateKey
    case publicKeyUnavailable
    case invalidPublicKey
    case signingFailed
}

private enum RSAPublicKeyDER {
    struct Components {
        let modulus: Data
        let exponent: Data
    }

    static func parse(_ data: Data) throws -> Components {
        var outer = DERReader(data: data)
        let sequence = try outer.readValue(tag: 0x30)
        guard outer.isAtEnd else { throw RSAKeyError.invalidPublicKey }

        var fields = DERReader(data: sequence)
        let modulus = try positiveMPInt(fields.readValue(tag: 0x02))
        let exponent = try positiveMPInt(fields.readValue(tag: 0x02))
        guard fields.isAtEnd, !modulus.isEmpty, !exponent.isEmpty else {
            throw RSAKeyError.invalidPublicKey
        }
        return Components(modulus: modulus, exponent: exponent)
    }

    private static func positiveMPInt(_ integer: Data) throws -> Data {
        guard !integer.isEmpty else { throw RSAKeyError.invalidPublicKey }
        var bytes = Array(integer)
        guard bytes[0] & 0x80 == 0 else { throw RSAKeyError.invalidPublicKey }
        while bytes.count > 1, bytes[0] == 0 {
            bytes.removeFirst()
        }
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return Data(bytes)
    }
}

private struct DERReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(data: Data) {
        bytes = Array(data)
    }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func readValue(tag: UInt8) throws -> Data {
        guard offset < bytes.count, bytes[offset] == tag else {
            throw RSAKeyError.invalidPublicKey
        }
        offset += 1
        let length = try readLength()
        guard length <= bytes.count - offset else {
            throw RSAKeyError.invalidPublicKey
        }
        let end = offset + length
        let value = Data(bytes[offset..<end])
        offset = end
        return value
    }

    private mutating func readLength() throws -> Int {
        guard offset < bytes.count else { throw RSAKeyError.invalidPublicKey }
        let first = bytes[offset]
        offset += 1
        if first & 0x80 == 0 {
            return Int(first)
        }

        let byteCount = Int(first & 0x7f)
        guard byteCount > 0, byteCount <= MemoryLayout<Int>.size,
              byteCount <= bytes.count - offset
        else {
            throw RSAKeyError.invalidPublicKey
        }
        var length = 0
        for _ in 0..<byteCount {
            guard length <= (Int.max >> 8) else { throw RSAKeyError.invalidPublicKey }
            length = (length << 8) | Int(bytes[offset])
            offset += 1
        }
        return length
    }
}

private extension Data {
    mutating func appendSSHField(_ field: Data) {
        var length = UInt32(field.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(field)
    }
}
