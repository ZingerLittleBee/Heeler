import Foundation

/// A Codex rollout file name,
/// `rollout-<YYYY-MM-DDThh-mm-ss>-<thread>[_<rollout>].jsonl[.zst]`.
///
/// Parsed as Codex 0.160 parses it: strip the suffixes and the `rollout-`
/// prefix, take the next 19 characters as an opaque timestamp key (the
/// Host's local time, so it sorts but is not converted), then split the rest
/// at the first `_`. A name without `_` is a root segment whose rollout id
/// equals its thread id; a revert writes a new `_<rollout>` segment.
struct CodexRolloutFileName: Hashable, Sendable {
    let fileName: String
    let timestampKey: String
    let threadID: String
    let rolloutID: String
    /// `.jsonl.zst`, which Chat cannot read without a decompressor.
    let isCompressed: Bool

    private static let timestampLength = 19

    init?(fileName: String) {
        var rest = Substring(fileName)
        let isCompressed = rest.hasSuffix(".zst")
        if isCompressed { rest = rest.dropLast(4) }
        guard rest.hasPrefix("rollout-"), rest.hasSuffix(".jsonl") else { return nil }
        rest = rest.dropFirst(8).dropLast(6)
        let timestampKey = rest.prefix(Self.timestampLength)
        rest = rest.dropFirst(Self.timestampLength)
        guard timestampKey.count == Self.timestampLength, rest.first == "-" else { return nil }
        rest = rest.dropFirst()
        let threadID: Substring
        let rolloutID: Substring
        if let separator = rest.firstIndex(of: "_") {
            threadID = rest[..<separator]
            rolloutID = rest[rest.index(after: separator)...]
        } else {
            threadID = rest
            rolloutID = rest
        }
        guard !threadID.isEmpty, !rolloutID.isEmpty else { return nil }
        self.fileName = fileName
        self.timestampKey = String(timestampKey)
        self.threadID = String(threadID)
        self.rolloutID = String(rolloutID)
        self.isCompressed = isCompressed
    }

    /// Codex's own order for a thread's segments: by timestamp key, then
    /// rollout id. Between two copies of one segment the plain file sorts
    /// last, so the newest readable segment is the maximum.
    static func isOrderedBefore(_ a: CodexRolloutFileName, _ b: CodexRolloutFileName) -> Bool {
        if a.timestampKey != b.timestampKey { return a.timestampKey < b.timestampKey }
        if a.rolloutID != b.rolloutID { return a.rolloutID < b.rolloutID }
        return a.isCompressed && !b.isCompressed
    }
}

enum CodexThreadID {
    /// The creation time in a version 7 UUID's first 48 bits (Unix
    /// milliseconds). Nil for other versions, which carry no usable time.
    static func creationDate(of id: String) -> Date? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let bytes = uuid.uuid
        guard bytes.6 >> 4 == 7 else { return nil }
        let milliseconds = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5]
            .reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}
