import Foundation

/// What one rollout line holds, read from its first bytes only.
///
/// Rollout lines reach megabytes (tool output, base64 images), and almost all
/// of those bytes are records Chat never shows. The envelope's `type` sits in
/// the first hundred bytes and a turn item's `type` within the first few
/// hundred, so reading a short prefix decides which lines are worth decoding,
/// and it works the same on a line the framer cut short.
enum CodexLineKind: Equatable, Sendable {
    /// `session_meta`, the segment header.
    case sessionMeta
    /// An `event_msg` other than `item_completed`, with its payload type.
    case event(String)
    /// An `item_completed` event, with the turn item's type.
    case item(String)
    /// A `response_item`, with its payload type.
    case response(String)
    /// A `retained_context` record, with its payload type.
    case retainedContext(String)
    /// A `compacted` record: model context only.
    case compacted
    /// A known top-level type that carries nothing Chat shows.
    case ignorable(String)
    /// A top-level type this adapter does not know.
    case unknown(String)
    /// Not an envelope the prefix could read.
    case unclassified
}

/// A line's kind plus the few fields that decide whether to decode it.
struct CodexLineClassification: Equatable, Sendable {
    var kind: CodexLineKind
    /// The envelope's `ordinal`; absent in legacy rollouts.
    var ordinal: UInt64?
    /// `payload.name`: a response item's tool name.
    var name: String?
    /// `payload.role`: a response message's role.
    var role: String?
    /// `payload.call_id`, when it falls inside the scanned prefix.
    var callID: String?

    init(
        kind: CodexLineKind, ordinal: UInt64? = nil, name: String? = nil, role: String? = nil,
        callID: String? = nil
    ) {
        self.kind = kind
        self.ordinal = ordinal
        self.name = name
        self.role = role
        self.callID = callID
    }
}

enum CodexLineClassifier {
    /// How much of a line the classifier reads by default. The envelope type
    /// ends within 99 bytes and `item.type` within 227 in every observed file.
    static let prefixLimit = 512

    /// Top-level types Codex writes that hold nothing for Chat.
    static let ignorableTypes: Set<String> = [
        "turn_context", "world_state", "token_usage_record", "security_risk_score",
        "inter_agent_communication", "inter_agent_communication_metadata", "realtime_item",
    ]

    /// Classifies a line from at most `limit` of its first bytes. Fields the
    /// limit cuts off stay nil; a kind the prefix cannot settle is
    /// `.unclassified`, and the caller may retry with a larger limit.
    static func classify(_ bytes: some Collection<UInt8>, limit: Int = prefixLimit) -> CodexLineClassification {
        var scanner = EnvelopeScanner(bytes: Array(bytes.prefix(max(0, limit))))
        scanner.scan()
        let kind: CodexLineKind
        switch scanner.rootType {
        case nil:
            kind = .unclassified
        case "session_meta":
            kind = .sessionMeta
        case "event_msg":
            switch scanner.payloadType {
            case nil:
                kind = .unclassified
            case "item_completed":
                kind = scanner.itemType.map(CodexLineKind.item) ?? .unclassified
            case let type?:
                kind = .event(type)
            }
        case "response_item":
            kind = scanner.payloadType.map(CodexLineKind.response) ?? .unclassified
        case "retained_context":
            kind = scanner.payloadType.map(CodexLineKind.retainedContext) ?? .unclassified
        case "compacted":
            kind = .compacted
        case let type? where ignorableTypes.contains(type):
            kind = .ignorable(type)
        case let type?:
            kind = .unknown(type)
        }
        return CodexLineClassification(
            kind: kind, ordinal: scanner.ordinal, name: scanner.name, role: scanner.role,
            callID: scanner.callID)
    }
}

/// Reads the handful of envelope fields the classifier needs, in whatever
/// order they appear, and stops quietly where the bytes run out.
private struct EnvelopeScanner {
    private enum Level {
        case root
        case payload
        case item
    }

    let bytes: [UInt8]
    private var index = 0

    private(set) var rootType: String?
    private(set) var ordinal: UInt64?
    private(set) var payloadType: String?
    private(set) var name: String?
    private(set) var role: String?
    private(set) var callID: String?
    private(set) var itemType: String?

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func scan() {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return }
        index += 1
        _ = scanObject(.root)
    }

    /// Scans an object's members after its `{`. Returns false when the bytes
    /// ran out or stopped making sense, which ends the whole scan.
    private mutating func scanObject(_ level: Level) -> Bool {
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return true
        }
        while true {
            skipWhitespace()
            guard let key = readString() else { return false }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return false }
            index += 1
            skipWhitespace()
            guard index < bytes.count else { return false }
            switch (level, key) {
            case (.root, "type"):
                guard capture(into: \.rootType) else { return false }
            case (.root, "ordinal"):
                guard captureOrdinal() else { return false }
            case (.root, "payload"):
                guard descend(into: .payload) else { return false }
            case (.payload, "type"):
                guard capture(into: \.payloadType) else { return false }
            case (.payload, "name"):
                guard capture(into: \.name) else { return false }
            case (.payload, "role"):
                guard capture(into: \.role) else { return false }
            case (.payload, "call_id"):
                guard capture(into: \.callID) else { return false }
            case (.payload, "item"):
                guard descend(into: .item) else { return false }
            case (.item, "type"):
                guard capture(into: \.itemType) else { return false }
            default:
                guard skipValue() else { return false }
            }
            skipWhitespace()
            guard index < bytes.count else { return false }
            switch bytes[index] {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "}"):
                index += 1
                return true
            default:
                return false
            }
        }
    }

    private mutating func descend(into level: Level) -> Bool {
        guard bytes[index] == UInt8(ascii: "{") else { return skipValue() }
        index += 1
        return scanObject(level)
    }

    /// Keeps a string value; any other value is skipped and leaves the field nil.
    private mutating func capture(into field: WritableKeyPath<EnvelopeScanner, String?>) -> Bool {
        guard bytes[index] == UInt8(ascii: "\"") else { return skipValue() }
        guard let value = readString() else { return false }
        self[keyPath: field] = value
        return true
    }

    private mutating func captureOrdinal() -> Bool {
        let start = index
        guard skipValue() else { return false }
        let token = bytes[start..<index]
        if !token.isEmpty, token.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
            ordinal = UInt64(String(decoding: token, as: UTF8.self))
        }
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, JSONBytes.isWhitespace(bytes[index]) {
            index += 1
        }
    }

    /// Reads a complete string at `index` and decodes its escapes; nil when
    /// the string does not end within the bytes.
    private mutating func readString() -> String? {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
        guard let (value, end) = JSONBytes.decodeString(bytes, quoteAt: index) else { return nil }
        index = end
        return value
    }

    /// Skips one complete value. False when it does not end within the bytes.
    private mutating func skipValue() -> Bool {
        guard let end = JSONBytes.valueEnd(bytes, at: index) else { return false }
        index = end
        return true
    }
}

/// Byte-level JSON helpers shared by the classifier and the prefix repair.
enum JSONBytes {
    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    /// Where a token that is not a string or container ends: at the next
    /// delimiter, or nil when the bytes end first (a number may continue).
    static func tokenEnd(_ bytes: [UInt8], at start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x0A, 0x0D, 0x09:
                return index > start ? index : nil
            default:
                index += 1
            }
        }
        return nil
    }

    /// The index just past the closing quote of the string starting at
    /// `quote`, or nil when the string does not end within the bytes.
    static func stringEnd(_ bytes: [UInt8], quoteAt quote: Int) -> Int? {
        var index = quote + 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"):
                index += 2
            case UInt8(ascii: "\""):
                return index + 1
            default:
                index += 1
            }
        }
        return nil
    }

    /// The index just past the value starting at `start`, or nil when the
    /// value does not end within the bytes.
    static func valueEnd(_ bytes: [UInt8], at start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            return stringEnd(bytes, quoteAt: start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var index = start
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    guard let end = stringEnd(bytes, quoteAt: index) else { return nil }
                    index = end
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return index + 1 }
                default:
                    break
                }
                index += 1
            }
            return nil
        default:
            return tokenEnd(bytes, at: start)
        }
    }

    /// Decodes the string starting at `quote`, escapes included, and returns
    /// it with the index past its closing quote.
    static func decodeString(_ bytes: [UInt8], quoteAt quote: Int) -> (String, Int)? {
        guard let end = stringEnd(bytes, quoteAt: quote) else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(end - quote)
        var index = quote + 1
        var pendingHighSurrogate: UInt32?
        while index < end - 1 {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < end - 1 else {
                flush(&pendingHighSurrogate, into: &output)
                output.append(byte)
                index += 1
                continue
            }
            let escape = bytes[index + 1]
            index += 2
            if escape == UInt8(ascii: "u") {
                guard index + 4 <= end - 1,
                    let unit = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
                else {
                    flush(&pendingHighSurrogate, into: &output)
                    appendScalar(0xFFFD, to: &output)
                    continue
                }
                index += 4
                if (0xD800...0xDBFF).contains(unit) {
                    flush(&pendingHighSurrogate, into: &output)
                    pendingHighSurrogate = unit
                } else if (0xDC00...0xDFFF).contains(unit), let high = pendingHighSurrogate {
                    pendingHighSurrogate = nil
                    appendScalar(0x10000 + ((high - 0xD800) << 10) + (unit - 0xDC00), to: &output)
                } else {
                    flush(&pendingHighSurrogate, into: &output)
                    appendScalar(unit, to: &output)
                }
                continue
            }
            flush(&pendingHighSurrogate, into: &output)
            switch escape {
            case UInt8(ascii: "n"): output.append(0x0A)
            case UInt8(ascii: "t"): output.append(0x09)
            case UInt8(ascii: "r"): output.append(0x0D)
            case UInt8(ascii: "b"): output.append(0x08)
            case UInt8(ascii: "f"): output.append(0x0C)
            default: output.append(escape)
            }
        }
        flush(&pendingHighSurrogate, into: &output)
        return (String(decoding: output, as: UTF8.self), end)
    }

    /// A lone high surrogate becomes U+FFFD, as a lenient decoder renders it.
    private static func flush(_ pending: inout UInt32?, into output: inout [UInt8]) {
        guard pending != nil else { return }
        pending = nil
        appendScalar(0xFFFD, to: &output)
    }

    private static func appendScalar(_ value: UInt32, to output: inout [UInt8]) {
        let scalar = Unicode.Scalar(value) ?? "\u{FFFD}"
        output.append(contentsOf: Array(String(Character(scalar)).utf8))
    }
}
