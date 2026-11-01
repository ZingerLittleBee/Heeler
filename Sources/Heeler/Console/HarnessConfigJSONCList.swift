import Foundation

/// One string in a list at the top of a JSON-with-comments configuration file.
struct HarnessConfigListEntry: Codable, Equatable, Hashable, Sendable {
    let key: String
    let value: String
}

/// Adds a string to a top-level list of a JSON-with-comments file, or takes it out,
/// and leaves every other byte as it was. It is a scanner, not a parser that writes
/// the file again, because a configuration file holds comments and layout that are
/// the user's. Anything it can't read with certainty is left alone.
enum HarnessConfigJSONCList {
    enum Addition: Equatable {
        case changed(Data)
        case alreadyThere
        case unreadable
        case notAList
        /// The file sets this key, whose meaning a new top-level list would change.
        case keyInTheWay(String)
    }

    enum Removal: Equatable {
        case changed(Data)
        case notThere
        case unreadable
        case notAList
    }

    /// `sameAs` holds other strings that name the same thing as the entry.
    static func adding(
        _ entry: HarnessConfigListEntry, sameAs: Set<String> = [], refusingKeys: Set<String> = [], to file: Data
    ) -> Addition {
        guard String(data: file, encoding: .utf8) != nil, let document = try? Document(Array(file)) else {
            return .unreadable
        }
        let names = document.members.map(\.key)
        guard Set(names).count == names.count else { return .unreadable }
        guard let text = encoded(entry.value), let key = encoded(entry.key) else { return .unreadable }
        guard let member = document.members.first(where: { $0.key == entry.key }) else {
            if let blocking = names.first(where: refusingKeys.contains) { return .keyInTheWay(blocking) }
            return .changed(document.insertingMember("\(key): [\(text)]", into: file))
        }
        guard let list = try? document.list(at: member) else { return .notAList }
        let same = sameAs.union([entry.value])
        if list.elements.contains(where: { $0.string.map(same.contains) == true }) { return .alreadyThere }
        return .changed(document.inserting(text, into: list, of: file))
    }

    static func removing(_ entry: HarnessConfigListEntry, from file: Data) -> Removal {
        guard String(data: file, encoding: .utf8) != nil, let document = try? Document(Array(file)) else {
            return .unreadable
        }
        let names = document.members.map(\.key)
        guard Set(names).count == names.count else { return .unreadable }
        guard let member = document.members.first(where: { $0.key == entry.key }) else { return .notThere }
        guard let list = try? document.list(at: member) else { return .notAList }
        guard let index = list.elements.firstIndex(where: { $0.string == entry.value }) else { return .notThere }
        return .changed(document.removing(index, of: list, from: file))
    }

    private static func encoded(_ text: String) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(text)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

private struct Member {
    let key: String
    let keyStart: Int
    let valueStart: Int
}

private struct ListShape {
    struct Element {
        let start: Int
        let end: Int
        let string: String?
    }

    let open: Int
    let elements: [Element]
}

/// The file's top level, with enough of each member to find it again.
private struct Document {
    let bytes: [UInt8]
    let open: Int
    let members: [Member]

    init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        var scanner = Scanner(bytes: bytes)
        try scanner.skipTrivia()
        open = scanner.at
        guard scanner.peek == UInt8(ascii: "{") else { throw Scanner.Failure() }
        scanner.at += 1
        var found: [Member] = []
        while true {
            try scanner.skipTrivia()
            if scanner.peek == UInt8(ascii: "}") {
                scanner.at += 1
                break
            }
            let keyStart = scanner.at
            let key = try scanner.string()
            try scanner.skipTrivia()
            try scanner.expect(UInt8(ascii: ":"))
            try scanner.skipTrivia()
            let valueStart = scanner.at
            try scanner.value()
            found.append(Member(key: key, keyStart: keyStart, valueStart: valueStart))
            try scanner.skipTrivia()
            if scanner.peek == UInt8(ascii: ",") {
                scanner.at += 1
            } else if scanner.peek != UInt8(ascii: "}") {
                throw Scanner.Failure()
            }
        }
        try scanner.skipTrivia()
        guard scanner.at == bytes.count else { throw Scanner.Failure() }
        members = found
    }

    func list(at member: Member) throws -> ListShape {
        var scanner = Scanner(bytes: bytes, at: member.valueStart)
        guard scanner.peek == UInt8(ascii: "[") else { throw Scanner.Failure() }
        scanner.at += 1
        var elements: [ListShape.Element] = []
        while true {
            try scanner.skipTrivia()
            if scanner.peek == UInt8(ascii: "]") { break }
            let start = scanner.at
            let isString = scanner.peek == UInt8(ascii: "\"")
            let string = isString ? try scanner.string() : nil
            if !isString { try scanner.value() }
            elements.append(ListShape.Element(start: start, end: scanner.at, string: string))
            try scanner.skipTrivia()
            if scanner.peek == UInt8(ascii: ",") {
                scanner.at += 1
            } else if scanner.peek != UInt8(ascii: "]") {
                throw Scanner.Failure()
            }
        }
        return ListShape(open: member.valueStart, elements: elements)
    }

    /// A new member comes first, on a line of its own where the members have them,
    /// so no other line changes.
    func insertingMember(_ text: String, into file: Data) -> Data {
        guard let first = members.first else {
            return spliced(file, at: open + 1, removing: 0, text)
        }
        if let line = lineStartIfAlone(first.keyStart) {
            return spliced(file, at: line, removing: 0, indent(from: line, to: first.keyStart) + text + "," + lineEnding)
        }
        return spliced(file, at: first.keyStart, removing: 0, text + ", ")
    }

    /// A new element comes first, for the same reason. Adding it last would have to
    /// put a comma on the line before it.
    func inserting(_ text: String, into list: ListShape, of file: Data) -> Data {
        guard let first = list.elements.first else {
            return spliced(file, at: list.open + 1, removing: 0, text)
        }
        if let line = lineStartIfAlone(first.start) {
            return spliced(file, at: line, removing: 0, indent(from: line, to: first.start) + text + "," + lineEnding)
        }
        return spliced(file, at: first.start, removing: 0, text + ", ")
    }

    func removing(_ index: Int, of list: ListShape, from file: Data) -> Data {
        let element = list.elements[index]
        let comma = comma(after: element.end)
        let isLast = index == list.elements.count - 1
        let afterElement = comma.map { $0 + 1 } ?? element.end
        // A last element with no comma of its own leaves the one before it trailing.
        let previousComma = isLast && comma == nil && index > 0 ? self.comma(after: list.elements[index - 1].end) : nil

        if let line = lineStartIfAlone(element.start), let next = nextLineStart(ifBlankFrom: afterElement) {
            let removed = spliced(file, at: line, removing: next - line, "")
            return previousComma.map { spliced(removed, at: $0, removing: 1, "") } ?? removed
        }
        if comma != nil {
            var end = afterElement
            while end < bytes.count, bytes[end] == UInt8(ascii: " ") || bytes[end] == UInt8(ascii: "\t") { end += 1 }
            return spliced(file, at: element.start, removing: end - element.start, "")
        }
        if let previousComma {
            return spliced(file, at: previousComma, removing: element.end - previousComma, "")
        }
        return spliced(file, at: element.start, removing: element.end - element.start, "")
    }

    private func comma(after position: Int) -> Int? {
        var scanner = Scanner(bytes: bytes, at: position)
        guard (try? scanner.skipTrivia()) != nil, scanner.peek == UInt8(ascii: ",") else { return nil }
        return scanner.at
    }

    /// The start of the line that holds `position`, when only blanks come before it.
    private func lineStartIfAlone(_ position: Int) -> Int? {
        var start = position
        while start > 0, bytes[start - 1] != UInt8(ascii: "\n") {
            start -= 1
            guard bytes[start] == UInt8(ascii: " ") || bytes[start] == UInt8(ascii: "\t") else { return nil }
        }
        return start > 0 ? start : nil
    }

    private func nextLineStart(ifBlankFrom position: Int) -> Int? {
        var at = position
        while at < bytes.count {
            switch bytes[at] {
            case UInt8(ascii: "\n"): return at + 1
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"): at += 1
            default: return nil
            }
        }
        return nil
    }

    private func indent(from start: Int, to end: Int) -> String {
        String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private var lineEnding: String {
        zip(bytes, bytes.dropFirst()).contains { $0 == UInt8(ascii: "\r") && $1 == UInt8(ascii: "\n") } ? "\r\n" : "\n"
    }

    private func spliced(_ file: Data, at position: Int, removing count: Int, _ text: String) -> Data {
        var result = Data(file.prefix(position))
        result.append(Data(text.utf8))
        result.append(Data(file.dropFirst(position + count)))
        return result
    }
}

/// JSON with comments and trailing commas, as OpenCode's own `jsonc-parser` reads it.
private struct Scanner {
    struct Failure: Error {}

    private static let depthLimit = 64

    let bytes: [UInt8]
    var at = 0

    var peek: UInt8? { at < bytes.count ? bytes[at] : nil }

    mutating func expect(_ byte: UInt8) throws {
        guard peek == byte else { throw Failure() }
        at += 1
    }

    mutating func skipTrivia() throws {
        while let byte = peek {
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                at += 1
            case UInt8(ascii: "/"):
                guard at + 1 < bytes.count else { throw Failure() }
                if bytes[at + 1] == UInt8(ascii: "/") {
                    while let next = peek, next != UInt8(ascii: "\n") {
                        _ = next
                        at += 1
                    }
                } else if bytes[at + 1] == UInt8(ascii: "*") {
                    at += 2
                    while !(peek == UInt8(ascii: "*") && at + 1 < bytes.count && bytes[at + 1] == UInt8(ascii: "/")) {
                        guard peek != nil else { throw Failure() }
                        at += 1
                    }
                    at += 2
                } else {
                    throw Failure()
                }
            default:
                return
            }
        }
    }

    mutating func string() throws -> String {
        let start = at
        try expect(UInt8(ascii: "\""))
        while true {
            guard let byte = peek, byte >= 0x20 else { throw Failure() }
            at += 1
            if byte == UInt8(ascii: "\"") { break }
            if byte == UInt8(ascii: "\\") {
                guard peek != nil else { throw Failure() }
                at += 1
            }
        }
        guard let text = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<at])) else {
            throw Failure()
        }
        return text
    }

    mutating func value(depth: Int = 0) throws {
        guard depth < Self.depthLimit, let byte = peek else { throw Failure() }
        switch byte {
        case UInt8(ascii: "\""):
            _ = try string()
        case UInt8(ascii: "{"):
            at += 1
            try members(depth: depth)
        case UInt8(ascii: "["):
            at += 1
            try elements(depth: depth)
        default:
            try literal()
        }
    }

    private mutating func members(depth: Int) throws {
        while true {
            try skipTrivia()
            if peek == UInt8(ascii: "}") {
                at += 1
                return
            }
            _ = try string()
            try skipTrivia()
            try expect(UInt8(ascii: ":"))
            try skipTrivia()
            try value(depth: depth + 1)
            try skipTrivia()
            if peek == UInt8(ascii: ",") {
                at += 1
            } else if peek != UInt8(ascii: "}") {
                throw Failure()
            }
        }
    }

    private mutating func elements(depth: Int) throws {
        while true {
            try skipTrivia()
            if peek == UInt8(ascii: "]") {
                at += 1
                return
            }
            try value(depth: depth + 1)
            try skipTrivia()
            if peek == UInt8(ascii: ",") {
                at += 1
            } else if peek != UInt8(ascii: "]") {
                throw Failure()
            }
        }
    }

    private mutating func literal() throws {
        let start = at
        while let byte = peek, Self.literalBytes.contains(byte) { at += 1 }
        let word = String(decoding: bytes[start..<at], as: UTF8.self)
        guard ["true", "false", "null"].contains(word) || Double(word) != nil else { throw Failure() }
    }

    private static let literalBytes = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.".utf8)
}
