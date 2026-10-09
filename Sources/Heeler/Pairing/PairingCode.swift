import Foundation

/// A parsed Pairing Code: the versioned payload the pairing plugin renders as
/// a QR image (ADR 0007). Wire format:
///
///     HERDR-PAIR:<version>:<base64url(JSON, no padding)>
///
/// Version 1 carries the SSH coordinates and an optional Bootstrap Key.
/// Version 2 adds a required Herdr Endpoint (`sock`, `herdr`) for a herdr
/// outside the user's config home (ADR 0021); only this app decodes it, and
/// the plugin keeps emitting version 1. The schema and error taxonomy live in
/// `plugin/README.md`; the shared test vectors in
/// `plugin/test-vectors/pairing-code-v1.json` are the single source of truth
/// for both this decoder and the plugin's encoder, and `pairing-code-v2.json`
/// pins version 2. Unknown payload fields are ignored (additive metadata
/// within a version); breaking changes bump the version, which both
/// implementations must honor together.
struct PairingCode: Sendable, Equatable {
    static let prefix = "HERDR-PAIR"
    static let version = 1
    /// The envelope version that carries a Herdr Endpoint (ADR 0021).
    static let endpointVersion = 2

    /// Candidate addresses in the order the app should try them.
    /// IPv6 literals carry no brackets and no zone id.
    let addresses: [String]
    /// SSH port, 1...65535.
    let port: Int
    /// SSH username.
    let username: String
    /// The Host's SSH host key fingerprint, pinned instead of a TOFU prompt.
    let hostKeyFingerprint: HostKeyFingerprint
    /// The Bootstrap Key material, absent on a config-only Pairing Code.
    let bootstrap: Bootstrap?
    /// The Host's own herdr: required by version 2, never read from version 1
    /// (a v1 code carrying `sock`/`herdr` still decodes without one).
    var endpoint: HerdrEndpoint? = nil

    /// The single-use Enrollment credential carried inside a Pairing Code.
    /// Lives in memory only; never enters the Keychain (ADR 0007).
    struct Bootstrap: Sendable, Equatable {
        /// Raw 32-byte Ed25519 seed of the Bootstrap Key.
        let seed: Data
        /// When the Host deletes the Bootstrap Key's authorized_keys line.
        let expiresAt: Date
    }

    /// Decodes and validates a scanned Pairing Code string.
    static func decode(_ scanned: String) throws(PairingCodeError) -> PairingCode {
        guard scanned.hasPrefix("\(prefix):") else {
            throw .badPrefix
        }
        let rest = scanned.dropFirst(prefix.count + 1)
        guard let separator = rest.firstIndex(of: ":") else {
            throw .badPrefix
        }
        let foundVersion = String(rest[..<separator])
        let encodedBody = String(rest[rest.index(after: separator)...])
        if foundVersion == String(version) {
            return try validated(decodedPayload(WirePayload.self, from: encodedBody))
        }
        guard foundVersion == String(endpointVersion) else {
            throw .unsupportedVersion(found: foundVersion)
        }

        // Version 2: the v1 fields first, with the same rules and reasons,
        // then the Herdr Endpoint.
        let wire = try decodedPayload(EndpointWirePayload.self, from: encodedBody)
        var code = try validated(wire.base)
        guard let socketPath = wire.sock else {
            throw .badPayload(reason: "sock is required in a version 2 Pairing Code")
        }
        guard let executablePath = wire.herdr else {
            throw .badPayload(reason: "herdr is required in a version 2 Pairing Code")
        }
        guard
            let endpoint = HerdrEndpoint(socketPath: socketPath, executablePath: executablePath)
        else {
            throw .badPayload(
                reason: "sock and herdr must be absolute paths without quotes, backslashes, "
                    + "or control characters, and sock a herdr socket path of at most "
                    + "\(HerdrEndpoint.maximumSocketPathUTF8Length) bytes")
        }
        code.endpoint = endpoint
        return code
    }

    /// Decodes the base64url JSON body every envelope version shares.
    private static func decodedPayload<Wire: Decodable>(
        _ type: Wire.Type, from encodedBody: String
    ) throws(PairingCodeError) -> Wire {
        guard let body = Data(base64URLEncoded: encodedBody) else {
            throw .badEncoding
        }
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch DecodingError.dataCorrupted {
            // Only unparseable JSON reaches here: every wire field is decoded
            // as an optional lenient type, so shape problems surface as
            // typeMismatch/valueNotFound and are classified below.
            throw .badEncoding
        } catch {
            throw .badPayload(reason: "payload shape mismatch")
        }
    }

    private static func validated(_ wire: WirePayload) throws(PairingCodeError) -> PairingCode {
        guard let addresses = wire.addrs, !addresses.isEmpty else {
            throw .badPayload(reason: "addresses must be a non-empty array")
        }
        for address in addresses where address.isEmpty || containsWhitespace(address) {
            throw .badPayload(reason: "invalid address: \(address)")
        }
        guard
            let portValue = wire.port, let port = Int(exactly: portValue),
            (1...65535).contains(port)
        else {
            throw .badPayload(reason: "port must be an integer in 1..65535")
        }
        guard let username = wire.user, !username.isEmpty, !containsWhitespace(username) else {
            throw .badPayload(reason: "username must be a non-empty string without whitespace")
        }
        guard let fingerprint = parseFingerprint(wire.fp) else {
            throw .badPayload(reason: "fp must be an OpenSSH SHA256 fingerprint")
        }

        let bootstrap: Bootstrap?
        switch (wire.seed, wire.exp) {
        case (nil, nil):
            bootstrap = nil
        case (let seed?, let exp?):
            guard let seedData = Data(base64URLEncoded: seed), seedData.count == bootstrapSeedBytes
            else {
                throw .badPayload(reason: "seed must be \(bootstrapSeedBytes) bytes of base64url")
            }
            guard let expiry = Int(exactly: exp), expiry > 0 else {
                throw .badPayload(reason: "exp must be a positive unix-seconds integer")
            }
            bootstrap = Bootstrap(
                seed: seedData, expiresAt: Date(timeIntervalSince1970: TimeInterval(expiry)))
        default:
            throw .badPayload(reason: "seed and exp must be present together")
        }

        return PairingCode(
            addresses: addresses, port: port, username: username,
            hostKeyFingerprint: fingerprint, bootstrap: bootstrap)
    }

    private static let bootstrapSeedBytes = 32

    /// JSON wire shape. Every field is optional and numbers are decoded as
    /// Double so that missing keys and wrong values fail validation with
    /// `badPayload` instead of dying inside JSONDecoder with an error we
    /// cannot tell apart from malformed JSON.
    private struct WirePayload: Decodable {
        var addrs: [String]?
        var port: Double?
        var user: String?
        var fp: String?
        var seed: String?
        var exp: Double?
    }

    /// JSON wire shape of a version 2 payload: the v1 fields plus the Herdr
    /// Endpoint, every field lenient for the same reason. v1 keeps its own
    /// shape, so a v1 code carrying `sock`/`herdr` still ignores them.
    private struct EndpointWirePayload: Decodable {
        var addrs: [String]?
        var port: Double?
        var user: String?
        var fp: String?
        var sock: String?
        var herdr: String?
        var seed: String?
        var exp: Double?

        /// The v1 fields, validated exactly as a version 1 payload.
        var base: WirePayload {
            WirePayload(addrs: addrs, port: port, user: user, fp: fp, seed: seed, exp: exp)
        }
    }

    /// OpenSSH presentation: "SHA256:" + 43 chars of unpadded standard base64
    /// (a 32-byte digest). Returns the digest-backed fingerprint, or nil.
    private static func parseFingerprint(_ text: String?) -> HostKeyFingerprint? {
        guard let text, text.wholeMatch(of: /SHA256:[A-Za-z0-9+\/]{43}/) != nil else {
            return nil
        }
        guard let digest = Data(base64Encoded: String(text.dropFirst("SHA256:".count)) + "=")
        else { return nil }
        return HostKeyFingerprint(digest: digest)
    }

    private static func containsWhitespace(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}

/// Why a scanned string is not a Pairing Code. These map 1:1 to the error
/// identifiers in the shared test vectors and belong to the "parse" step of
/// the pairing failure taxonomy (ADR 0007).
enum PairingCodeError: Error, Sendable, Equatable {
    /// Not a Pairing Code at all — likely someone else's QR.
    case badPrefix
    /// A Pairing Code from a plugin speaking another envelope version.
    case unsupportedVersion(found: String)
    /// The framing is right but the body is not base64url-encoded JSON.
    case badEncoding
    /// Well-formed JSON that violates the payload schema.
    case badPayload(reason: String)

    /// The cross-implementation identifier used by the shared test vectors.
    var wireCode: String {
        switch self {
        case .badPrefix: "bad_prefix"
        case .unsupportedVersion: "unsupported_version"
        case .badEncoding: "bad_encoding"
        case .badPayload: "bad_payload"
        }
    }
}
