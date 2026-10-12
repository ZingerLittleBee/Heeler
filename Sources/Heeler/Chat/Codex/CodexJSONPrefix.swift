import Foundation

/// Structural reads of a rollout line's raw bytes, without decoding it.
///
/// Two cases need the shape of a line but not its content. A line Chat never
/// shows must still be a whole record before it may take an ordinal, because
/// a crash fragment that the writer later ended with a newline shares its
/// ordinal with the complete record written after it. And a line longer than
/// the framer keeps arrives as a prefix, which no decoder accepts as it is:
/// cut back to the last complete value and closed, it still yields the fields
/// that precede the large one (a command's argv and status precede its
/// output).
enum CodexJSONPrefix {
    /// True when `data` holds exactly one complete JSON object, surrounded by
    /// whitespace at most.
    static func isCompleteObject(_ data: Data) -> Bool {
        if case .complete = scan(Array(data)) {
            return true
        }
        return false
    }

    /// `data`, a prefix of one JSON object, cut back to its last complete
    /// value and closed so it parses. Nil when the prefix is not the start of
    /// an object or has no complete value at all.
    static func repaired(_ data: Data) -> Data? {
        let bytes = Array(data)
        switch scan(bytes) {
        case .complete:
            return data
        case .malformed:
            return nil
        case .truncated(let cut, let openContainers):
            var output = Data(bytes[0..<cut])
            for opener in openContainers.reversed() {
                output.append(opener == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]"))
            }
            return output
        }
    }

    private enum Outcome {
        case complete
        /// The bytes ended inside the object. `cut` is the end of the last
        /// complete value (or container opening), and `openContainers` are
        /// the containers still open there, outermost first.
        case truncated(cut: Int, openContainers: [UInt8])
        case malformed
    }

    private enum Expectation {
        case root
        case keyOrEnd
        case key
        case colon
        case objectValue
        case arrayValueOrEnd
        case arrayValue
        case separatorOrEnd
        case done
    }

    private static func scan(_ bytes: [UInt8]) -> Outcome {
        var stack: [UInt8] = []
        var expectation = Expectation.root
        // The last point where the prefix could end, and how deep the open
        // containers were there. Containers above that depth only ever close
        // again through a later safe point, so the stack's first `safeDepth`
        // entries are still the ones open at the cut.
        var safeCut: Int?
        var safeDepth = 0
        var index = 0

        func markSafe(_ position: Int) {
            safeCut = position
            safeDepth = stack.count
        }

        func finishValue(_ position: Int) {
            if stack.isEmpty {
                expectation = .done
            } else {
                expectation = .separatorOrEnd
                markSafe(position)
            }
        }

        while index < bytes.count {
            let byte = bytes[index]
            if JSONBytes.isWhitespace(byte) {
                index += 1
                continue
            }
            switch expectation {
            case .done:
                return .malformed
            case .root:
                guard byte == UInt8(ascii: "{") else { return .malformed }
                stack.append(byte)
                index += 1
                expectation = .keyOrEnd
                markSafe(index)
            case .keyOrEnd, .key:
                if expectation == .keyOrEnd, byte == UInt8(ascii: "}") {
                    stack.removeLast()
                    index += 1
                    finishValue(index)
                    continue
                }
                guard byte == UInt8(ascii: "\"") else { return .malformed }
                guard let end = JSONBytes.stringEnd(bytes, quoteAt: index) else {
                    return truncated(safeCut, stack: stack, depth: safeDepth)
                }
                index = end
                expectation = .colon
            case .colon:
                guard byte == UInt8(ascii: ":") else { return .malformed }
                index += 1
                expectation = .objectValue
            case .objectValue, .arrayValue, .arrayValueOrEnd:
                if expectation == .arrayValueOrEnd, byte == UInt8(ascii: "]") {
                    stack.removeLast()
                    index += 1
                    finishValue(index)
                    continue
                }
                switch byte {
                case UInt8(ascii: "{"):
                    stack.append(byte)
                    index += 1
                    expectation = .keyOrEnd
                    markSafe(index)
                case UInt8(ascii: "["):
                    stack.append(byte)
                    index += 1
                    expectation = .arrayValueOrEnd
                    markSafe(index)
                case UInt8(ascii: "\""):
                    guard let end = JSONBytes.stringEnd(bytes, quoteAt: index) else {
                        return truncated(safeCut, stack: stack, depth: safeDepth)
                    }
                    index = end
                    finishValue(index)
                default:
                    guard let end = JSONBytes.tokenEnd(bytes, at: index) else {
                        return truncated(safeCut, stack: stack, depth: safeDepth)
                    }
                    guard isScalarToken(bytes[index..<end]) else { return .malformed }
                    index = end
                    finishValue(index)
                }
            case .separatorOrEnd:
                guard let open = stack.last else { return .malformed }
                if byte == UInt8(ascii: ",") {
                    index += 1
                    expectation = open == UInt8(ascii: "{") ? .key : .arrayValue
                } else if (byte == UInt8(ascii: "}") && open == UInt8(ascii: "{"))
                    || (byte == UInt8(ascii: "]") && open == UInt8(ascii: "["))
                {
                    stack.removeLast()
                    index += 1
                    finishValue(index)
                } else {
                    return .malformed
                }
            }
        }
        return expectation == .done ? .complete : truncated(safeCut, stack: stack, depth: safeDepth)
    }

    private static func truncated(_ cut: Int?, stack: [UInt8], depth: Int) -> Outcome {
        guard let cut, depth <= stack.count else { return .malformed }
        return .truncated(cut: cut, openContainers: Array(stack.prefix(depth)))
    }

    /// A literal or a number. Numbers are checked loosely: the decoder that
    /// reads the repaired bytes has the final say.
    private static func isScalarToken(_ token: ArraySlice<UInt8>) -> Bool {
        switch String(decoding: token, as: UTF8.self) {
        case "true", "false", "null":
            return true
        default:
            return token.allSatisfy { byte in
                (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+")
                    || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e")
                    || byte == UInt8(ascii: "E")
            }
        }
    }
}
