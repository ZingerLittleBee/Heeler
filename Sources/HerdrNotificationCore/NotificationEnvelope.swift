import CryptoKit
import Foundation

/// A decrypted Agent Notification payload: what a Host's notify hook tells
/// this device about an Agent Status transition (ADR 0008).
struct NotificationPayload: Sendable, Equatable {
    /// The herdr pane id the Agent lives in; drives the Attach deep link.
    let paneID: String
    /// The agent kind as herdr reports it (claude, codex, ...).
    let agentKind: String
    /// The new Agent Status. An open set like everywhere else on the herdr
    /// wire: unrecognized values pass through for forward compatibility.
    let status: AgentStatus
    /// When the transition happened.
    let timestamp: Date
}

/// The notification envelope v1: the encrypted payload carried from the
/// plugin's notify hook through the Push Relay and APNs to this app
/// (ADR 0008). Wire format, a compact JSON object:
///
///     {"v": 1, "kid": "...", "n": "...", "ct": "..."}
///
/// `ct` is the AES-256-GCM ciphertext (plus 16-byte tag) of a compact JSON
/// plaintext `{"pane", "kind", "status", "ts"}` under the per-host
/// Notification Key, with the version string bound as additional
/// authenticated data. The schema lives in `plugin/README.md`; the shared
/// test vectors in `plugin/test-vectors/notification-payload-v1.json` are
/// the single source of truth for this decoder and the plugin's encoder
/// (which proves the encrypt direction). Unknown fields at either layer are
/// ignored (additive v1 metadata); breaking changes bump the version, which
/// both implementations must honor together.
enum NotificationEnvelope {
    static let version = 1

    private static let keyBytes = 32
    private static let nonceBytes = 12
    private static let tagBytes = 16
    private static let keyIDBytes = 8

    /// Additional authenticated data binding the ciphertext to envelope v1,
    /// so a re-framed ciphertext under a different version fails to open.
    private static var additionalData: Data {
        Data("HERDR-NOTIFY:\(version)".utf8)
    }

    /// Derives the cleartext key id for a raw 32-byte Notification Key: the
    /// first 8 bytes of SHA-256 over the key, unpadded base64url. Both ends
    /// derive it, so it never needs to be stored or exchanged separately;
    /// the app uses it to select the right key (and thus Host) when several
    /// Hosts are registered.
    static func keyID(for key: Data) -> String {
        Data(SHA256.hash(data: key).prefix(keyIDBytes)).base64URLEncodedString()
    }

    /// Reads the cleartext key id off an envelope without decrypting it, so
    /// the right Notification Key can be selected when several Hosts are
    /// registered. Nil when the framing is too broken to carry one; version
    /// and ciphertext checks stay `decrypt`'s job.
    static func peekKeyID(in envelope: Data) -> String? {
        guard let wire = try? JSONDecoder().decode(WireEnvelope.self, from: envelope),
            let kid = wire.kid, !kid.isEmpty
        else { return nil }
        return kid
    }

    /// Decrypts an envelope's wire bytes with a Notification Key.
    ///
    /// Every way an envelope can be undecryptable — malformed framing, a
    /// future version, tampered or wrongly keyed ciphertext, a garbage
    /// plaintext — surfaces as a typed `NotificationEnvelopeError` so the
    /// service extension can fall back to a generic banner; nothing here
    /// crashes on hostile input.
    static func decrypt(
        _ envelope: Data, using key: Data
    ) throws(NotificationEnvelopeError) -> NotificationPayload {
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
        guard key.count == keyBytes else {
            // Not a v1 Notification Key, so nothing it could ever decrypt.
            throw .decryptFailed
        }

        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: sealed.dropLast(tagBytes),
                tag: sealed.suffix(tagBytes))
            plaintext = try AES.GCM.open(
                box, using: SymmetricKey(data: key), authenticating: additionalData)
        } catch {
            // Tampered ciphertext, tag, or nonce, or the wrong key: GCM
            // cannot tell these apart and neither can we.
            throw .decryptFailed
        }
        return try validated(plaintext)
    }

    private static func validated(
        _ plaintext: Data
    ) throws(NotificationEnvelopeError) -> NotificationPayload {
        let wire: WirePlaintext
        do {
            wire = try JSONDecoder().decode(WirePlaintext.self, from: plaintext)
        } catch {
            throw .badPayload(reason: "plaintext is not a well-formed JSON object")
        }
        guard let pane = wire.pane, !pane.isEmpty else {
            throw .badPayload(reason: "pane must be a non-empty string")
        }
        guard let kind = wire.kind, !kind.isEmpty else {
            throw .badPayload(reason: "kind must be a non-empty string")
        }
        guard let status = wire.status, !status.isEmpty else {
            throw .badPayload(reason: "status must be a non-empty string")
        }
        guard let rawTimestamp = wire.ts, let timestamp = Int(exactly: rawTimestamp),
            timestamp > 0
        else {
            throw .badPayload(reason: "ts must be a positive unix-seconds integer")
        }
        return NotificationPayload(
            paneID: pane, agentKind: kind, status: AgentStatus(rawValue: status),
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)))
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

    /// Decrypted JSON wire shape, lenient for the same reason.
    private struct WirePlaintext: Decodable {
        var pane: String?
        var kind: String?
        var status: String?
        var ts: Double?
    }
}

/// Why an envelope did not yield a payload. These map 1:1 to the error
/// identifiers in the shared test vectors. Any of them means the service
/// extension shows the generic fallback banner instead of decrypted content.
enum NotificationEnvelopeError: Error, Sendable, Equatable {
    /// The cleartext framing is broken: not a JSON object, or a missing or
    /// mistyped field.
    case badEnvelope(reason: String)
    /// An envelope from a plugin speaking another contract version.
    case unsupportedVersion(found: Int)
    /// GCM authentication failed: tampered material or the wrong key.
    case decryptFailed
    /// The ciphertext opened but its plaintext violates the payload schema.
    case badPayload(reason: String)

    /// The cross-implementation identifier used by the shared test vectors.
    var wireCode: String {
        switch self {
        case .badEnvelope: "bad_envelope"
        case .unsupportedVersion: "unsupported_version"
        case .decryptFailed: "decrypt_failed"
        case .badPayload: "bad_payload"
        }
    }
}
