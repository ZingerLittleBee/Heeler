import Foundation

/// The shared Pairing Code v2 vectors from `plugin/test-vectors/`, the same
/// arrangement as `PairingCodeVectorFile` for v1. The v2 file is produced by
/// the plugin package and does not exist on every branch: `shared` is nil
/// when it is absent, and the vector-driven suite skips via `.enabled(if:)`
/// until integration lands the file.
///
/// Expected schema, mirroring v1 with the envelope carried as bytes:
/// `valid` entries have `name`, `envelopeHex` (the binary envelope as hex), and
/// `payload` (same shape as v1); `invalid` entries have `name`, `error`, and
/// either `envelopeHex` or `code` (a scanned-string form, for cases only
/// expressible as text, such as scalars above U+00FF).
struct PairingCodeV2VectorFile: Decodable, Sendable {
    let valid: [Valid]
    let invalid: [Invalid]

    struct Valid: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let envelopeHex: String
        let payload: PairingCodeVectorFile.Payload
        var description: String { name }
    }

    struct Invalid: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let envelopeHex: String?
        let code: String?
        /// The expected error identifier, e.g. "bad_prefix".
        let error: String
        var description: String { name }
    }

    static let shared: PairingCodeV2VectorFile? = {
        let url =
            Bundle(for: BundleLocator.self)
            .url(forResource: "pairing-code-v2", withExtension: "json") ?? sourceTreeURL
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(PairingCodeV2VectorFile.self, from: Data(contentsOf: url))
        } catch {
            fatalError("shared pairing v2 vectors exist but failed to load: \(error)")
        }
    }()

    /// The repo checkout's copy, reachable from Simulator test hosts. Lets
    /// the suite light up the moment the plugin package lands the file, even
    /// before a project regeneration bundles it as a test resource.
    private static var sourceTreeURL: URL? {
        URL(fileURLWithPath: #filePath)  // Tests/HeelerTests/Support/…
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugin/test-vectors/pairing-code-v2.json")
    }

    private final class BundleLocator {}
}

extension Data {
    /// Decodes an even-length hex string (case-insensitive), or nil.
    init?(hexEncoded text: String) {
        guard text.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: text.count / 2)
        var digits = text.makeIterator()
        while let high = digits.next() {
            guard
                let low = digits.next(),
                let highValue = high.hexDigitValue, let lowValue = low.hexDigitValue,
                highValue < 16, lowValue < 16
            else { return nil }
            data.append(UInt8(highValue << 4 | lowValue))
        }
        self = data
    }
}
