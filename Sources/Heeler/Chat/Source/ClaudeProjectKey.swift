import Foundation

/// The directory name Claude Code files a working directory's transcripts
/// under, in `<config>/projects/<key>/<session>.jsonl`.
///
/// This mirrors the CLI (2.1.x): NFC-normalize the path, then replace every
/// UTF-16 code unit outside `[A-Za-z0-9]` with `-`, so a character outside
/// the Basic Multilingual Plane becomes `--`. A key longer than 200 units is
/// cut to 200 and suffixed with `-` and a base-36 hash. The CLI may hash with
/// a different function than its SDKs, so a long key is also found by
/// listing directories that share the 200-unit prefix.
enum ClaudeProjectKey {
    static let maximumLength = 200

    static func key(forDirectory directory: String) -> String {
        let units = Array(directory.precomposedStringWithCanonicalMapping.utf16)
        let sanitized = sanitize(units)
        guard units.count > maximumLength else { return sanitized }
        return String(sanitized.prefix(maximumLength)) + "-" + hashSuffix(units)
    }

    /// The prefix every candidate directory of an over-long key starts
    /// with, or nil when the key is short enough to be exact.
    static func longKeyPrefix(forDirectory directory: String) -> String? {
        let units = Array(directory.precomposedStringWithCanonicalMapping.utf16)
        guard units.count > maximumLength else { return nil }
        return String(sanitize(units).prefix(maximumLength)) + "-"
    }

    /// The key without NFC normalization. The CLI's normalization of the
    /// key path is inferred, so a locator also tries this form.
    static func unnormalizedKey(forDirectory directory: String) -> String {
        let units = Array(directory.utf16)
        let sanitized = sanitize(units)
        guard units.count > maximumLength else { return sanitized }
        return String(sanitized.prefix(maximumLength)) + "-" + hashSuffix(units)
    }

    private static func sanitize(_ units: [UInt16]) -> String {
        String(decoding: units.map { isKept($0) ? UInt8($0) : UInt8(ascii: "-") }, as: UTF8.self)
    }

    private static func isKept(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        default: false
        }
    }

    /// `h = (h << 5) - h + unit` in wrapping 32-bit arithmetic, as the CLI's
    /// string hash, then the magnitude in base 36. The magnitude is taken in
    /// 64 bits because `Int32.min` has no 32-bit one.
    static func hashSuffix(_ units: [UInt16]) -> String {
        var hash: Int32 = 0
        for unit in units {
            hash = (hash << 5) &- hash &+ Int32(unit)
        }
        return String(abs(Int64(hash)), radix: 36)
    }
}
