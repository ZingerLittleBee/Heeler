import CryptoKit
import Foundation

/// Shared AES-256-GCM `{v,kid,n,ct}` framing used by the notification
/// envelope and the Live Activity details envelope. Domain separation is
/// the caller's AAD (`HERDR-NOTIFY:1` vs `HERDR-ACTIVITY:1`).
enum SealedEnvelopeCodec {
    static let version = 1
    static let keyBytes = 32
    static let nonceBytes = 12
    static let tagBytes = 16
    static let keyIDBytes = 8

    /// A parsed, validated v1 frame. Version, kid, nonce, and ciphertext
    /// have already been checked; GCM open is still the caller's job.
    struct Frame: Equatable, Sendable {
        var version: Int
        var keyID: String
        var nonce: Data
        var sealed: Data
    }

    /// Derives the cleartext key id for a raw 32-byte key: the first 8 bytes
    /// of SHA-256 over the key, unpadded base64url. Both ends derive it, so
    /// it never needs to be stored or exchanged separately.
    static func keyID(for key: Data) -> String {
        Data(SHA256.hash(data: key).prefix(keyIDBytes)).base64URLEncodedString()
    }

    /// Reads the cleartext key id off an envelope without decrypting it.
    /// Nil when the framing is too broken to carry one; version and
    /// ciphertext checks stay `open`'s job.
    static func peekKeyID(in envelope: Data) -> String? {
        guard let wire = try? JSONDecoder().decode(WireEnvelope.self, from: envelope),
            let kid = wire.kid, !kid.isEmpty
        else { return nil }
        return kid
    }

    /// Parses and validates the cleartext frame. Same checks and error
    /// reasons `NotificationEnvelope.decrypt` historically performed, so
    /// existing vectors stay byte-identical in their typed failures.
    static func parse(_ envelope: Data) throws(NotificationEnvelopeError) -> Frame {
        let wire: WireEnvelope
        do {
            wire = try JSONDecoder().decode(WireEnvelope.self, from: envelope)
        } catch {
            // Not a JSON object, or a field with the wrong JSON type
            // (including a non-numeric "v"): the framing is broken.
            throw .badEnvelope(reason: "envelope is not a well-formed JSON object")
        }
        guard let rawVersion = wire.v, let foundVersion = Int(exactly: rawVersion) else {
            throw .badEnvelope(reason: "v must be an integer")
        }
        guard foundVersion == version else {
            throw .unsupportedVersion(found: foundVersion)
        }
        guard let kid = wire.kid, !kid.isEmpty else {
            throw .badEnvelope(reason: "kid must be a non-empty string")
        }
        guard let nonceText = wire.n, let nonce = Data(base64URLEncoded: nonceText),
            nonce.count == nonceBytes
        else {
            throw .badEnvelope(reason: "n must be \(nonceBytes) bytes of base64url")
        }
        guard let ciphertextText = wire.ct, let sealed = Data(base64URLEncoded: ciphertextText),
            sealed.count >= tagBytes
        else {
            throw .badEnvelope(reason: "ct must be base64url of ciphertext plus GCM tag")
        }
        return Frame(version: foundVersion, keyID: kid, nonce: nonce, sealed: sealed)
    }

    /// Opens a frame with `key` under the caller-supplied AAD.
    static func open(
        _ envelope: Data, using key: Data, authenticating aad: Data
    ) throws(NotificationEnvelopeError) -> Data {
        let frame = try parse(envelope)
        guard key.count == keyBytes else {
            // Not a v1 Notification Key, so nothing it could ever decrypt.
            throw .decryptFailed
        }

        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: frame.nonce),
                ciphertext: frame.sealed.dropLast(tagBytes),
                tag: frame.sealed.suffix(tagBytes))
            return try AES.GCM.open(
                box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            // Tampered ciphertext, tag, or nonce, or the wrong key: GCM
            // cannot tell these apart and neither can we. Wrong AAD lands
            // here too (domain separation).
            throw .decryptFailed
        }
    }

    /// Seals `plaintext` under `key` and `aad`. `nonce` is injectable so
    /// shared vectors can assert the exact envelope string; production
    /// callers omit it and get a fresh 12-byte nonce.
    ///
    /// The frame is encoded with a fixed key order (`v`, `kid`, `n`, `ct`)
    /// matching the Node plugin. `.sortedKeys` is a plaintext concern, not
    /// a frame one — alphabetical frame keys would not match the vectors.
    static func seal(
        _ plaintext: Data,
        using key: Data,
        authenticating aad: Data,
        nonce: Data? = nil
    ) throws -> Data {
        guard key.count == keyBytes else {
            throw NotificationEnvelopeError.decryptFailed
        }
        let nonceData: Data
        if let nonce {
            guard nonce.count == nonceBytes else {
                throw NotificationEnvelopeError.badEnvelope(
                    reason: "n must be \(nonceBytes) bytes of base64url")
            }
            nonceData = nonce
        } else {
            nonceData = Data(AES.GCM.Nonce())
        }
        let box = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: try AES.GCM.Nonce(data: nonceData),
            authenticating: aad)
        let combined = box.ciphertext + box.tag
        // kid / n / ct are unpadded base64url, so they need no JSON escaping.
        let body =
            "{\"v\":\(version),\"kid\":\"\(keyID(for: key))\""
            + ",\"n\":\"\(nonceData.base64URLEncodedString())\""
            + ",\"ct\":\"\(combined.base64URLEncodedString())\"}"
        return Data(body.utf8)
    }

    /// Cleartext JSON wire shape. Every field is optional and numbers are
    /// decoded as Double so that missing keys and wrong types surface as
    /// `badEnvelope` after decoding instead of dying inside JSONDecoder.
    private struct WireEnvelope: Decodable {
        var v: Double?
        var kid: String?
        var n: String?
        var ct: String?
    }
}
