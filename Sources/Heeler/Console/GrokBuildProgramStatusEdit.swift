import Foundation

/// The one edit that turns on Program Status for a Grok Build whose automatic
/// check left it off (ADR 0033): `program_status = "on"` under `[ui.notifications]`
/// in its `config.toml` (herdr compatibility, Grok Build 1.0.70).
///
/// It changes the setting wherever the file already holds it and adds it where
/// there is a table for it. A file whose shape leaves that in doubt is refused, so
/// the user never gets a configuration Grok Build cannot read.
enum GrokBuildProgramStatusEdit {
    static let id = "grok-build.program-status"
    /// A product name, persisted with each applied edit, so never localized.
    static let harness = "Grok Build"

    /// The line this edit asks for, to say what to do by hand.
    static let manualInstruction = String(localized: #"Add program_status = "on" under [ui.notifications] in Grok Build's config.toml."#)

    static func edit(path: String) -> HarnessConfigEdit {
        HarnessConfigEdit(
            id: id, harness: harness, path: path, transform: transform, manualInstruction: manualInstruction)
    }

    /// `$GROK_HOME/config.toml`, by default `~/.grok/config.toml`. Nil when the
    /// Agent's `GROK_HOME` names no absolute path Heeler can write to.
    static func configPath(grokHome: String?, home: String) -> String? {
        if let grokHome, !grokHome.isEmpty {
            guard grokHome.hasPrefix("/") else { return nil }
            return trimmingTrailingSlashes(grokHome) + "/config.toml"
        }
        return trimmingTrailingSlashes(home) + "/.grok/config.toml"
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static let unreadableReason =
        String(localized: "Heeler can't tell where this file's settings belong, so it won't change it.")
    private static let mixedFormReason =
        String(localized: "This file sets Grok Build's notifications in a form Heeler won't change.")

    private static let notifications = ["ui", "notifications"]
    private static let setting = notifications + ["program_status"]
    private static let on = #""on""#

    @Sendable static func transform(_ config: Data?) -> HarnessConfigEdit.Transform {
        guard let config = config.map({ Data($0) }) else {
            return .change(to: Data(block(lineEnding: "\n").utf8))
        }
        guard String(data: config, encoding: .utf8) != nil,
            let statements = try? TOMLStatements.scan(config)
        else { return .refused(reason: unreadableReason) }
        let lineEnding = config.range(of: Data("\r\n".utf8)) == nil ? "\n" : "\r\n"

        // A table of this setting's own holds it as `mode`.
        let settingTables = statements.tables.filter { $0.path == setting }
        let notificationTables = statements.tables.filter { $0.path == notifications }
        guard
            !statements.tables.contains(where: {
                $0.isArray && ($0.path.starts(with: notifications) || notifications.starts(with: $0.path))
            }), settingTables.count <= 1, notificationTables.count <= 1
        else { return .refused(reason: mixedFormReason) }

        let exact = statements.keys.filter { $0.path == setting }
        let mode = statements.keys.filter { $0.path == setting + ["mode"] }
        let underSetting = statements.keys.filter {
            $0.path.count > setting.count && $0.path.starts(with: setting)
        }
        if let table = settingTables.first {
            guard exact.isEmpty else { return .refused(reason: mixedFormReason) }
            if let mode = mode.first { return setValue(of: mode, in: config) }
            return insert(#"mode = "on""#, after: table, in: config, lineEnding: lineEnding)
        }
        if !underSetting.isEmpty {
            // Dotted keys hold it as a table with no header.
            guard exact.isEmpty, let mode = mode.first else { return .refused(reason: mixedFormReason) }
            return setValue(of: mode, in: config)
        }
        if let key = exact.first {
            return setValue(of: key, in: config)
        }

        // A table given as a value, or made by dotted keys, cannot take a header.
        let closesTheTable = statements.keys.contains {
            $0.path == notifications || $0.path == ["ui"]
                || ($0.path.starts(with: notifications) && !$0.table.starts(with: notifications))
        }
        guard !closesTheTable else { return .refused(reason: mixedFormReason) }
        if let table = notificationTables.first {
            return insert(#"program_status = "on""#, after: table, in: config, lineEnding: lineEnding)
        }
        return append(to: config, lineEnding: lineEnding)
    }

    private static func block(lineEnding: String) -> String {
        "[ui.notifications]\(lineEnding)program_status = \"on\"\(lineEnding)"
    }

    private static func setValue(
        of key: TOMLStatements.Key, in config: Data
    ) -> HarnessConfigEdit.Transform {
        guard let value = key.stringValue else { return .refused(reason: mixedFormReason) }
        if value == "on" { return .alreadyApplied }
        var after = config
        after.replaceSubrange(key.valueRange, with: Data(on.utf8))
        return .change(to: after)
    }

    private static func insert(
        _ line: String, after table: TOMLStatements.Table, in config: Data, lineEnding: String
    ) -> HarnessConfigEdit.Transform {
        var after = config
        // A header on the file's last line may have no newline to follow.
        let opening = table.lineEnd == config.count && config.last != UInt8(ascii: "\n") ? lineEnding : ""
        after.insert(contentsOf: Data((opening + line + lineEnding).utf8), at: table.lineEnd)
        return .change(to: after)
    }

    private static func append(to config: Data, lineEnding: String) -> HarnessConfigEdit.Transform {
        var after = config
        var separator = ""
        if !config.isEmpty {
            if config.last != UInt8(ascii: "\n") { separator += lineEnding }
            separator += lineEnding
        }
        after.append(Data((separator + block(lineEnding: lineEnding)).utf8))
        return .change(to: after)
    }
}

/// A TOML document's statements, read only as far as saying which table each key
/// lands in and where its value sits. It finds multi-line strings and arrays so
/// their contents never read as tables, and it throws on anything it cannot
/// follow rather than guess.
struct TOMLStatements {
    struct Table {
        let path: [String]
        let isArray: Bool
        /// Just past the header's line, its terminator included.
        let lineEnd: Int
    }

    struct Key {
        /// From the document's root.
        let path: [String]
        /// The table it was written in.
        let table: [String]
        let valueRange: Range<Int>
        /// A one-line string's text. Nil for any other value.
        let stringValue: String?
    }

    struct Unreadable: Error {}

    private(set) var tables: [Table] = []
    private(set) var keys: [Key] = []

    static func scan(_ data: Data) throws -> TOMLStatements {
        var scanner = Scanner(bytes: Array(data))
        var statements = TOMLStatements()
        var table: [String] = []
        while !scanner.isAtEnd {
            scanner.skipBlanks()
            guard let byte = scanner.peek else { break }
            switch byte {
            case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                try scanner.endLine()
            case UInt8(ascii: "#"):
                try scanner.endLine()
            case UInt8(ascii: "["):
                let header = try scanner.tableHeader()
                try scanner.endLine()
                table = header.path
                statements.tables.append(
                    Table(path: header.path, isArray: header.isArray, lineEnd: scanner.position))
            default:
                let path = try scanner.keyPath()
                scanner.skipBlanks()
                try scanner.expect(UInt8(ascii: "="))
                scanner.skipBlanks()
                let start = scanner.position
                let string = try scanner.value()
                let end = scanner.position
                try scanner.endLine()
                statements.keys.append(
                    Key(path: table + path, table: table, valueRange: start..<end, stringValue: string))
            }
        }
        return statements
    }

    private struct Scanner {
        let bytes: [UInt8]
        var position = 0

        var isAtEnd: Bool { position >= bytes.count }
        var peek: UInt8? { isAtEnd ? nil : bytes[position] }

        private func peek(at offset: Int) -> UInt8? {
            position + offset < bytes.count ? bytes[position + offset] : nil
        }

        private func starts(with text: StaticString) -> Bool {
            text.withUTF8Buffer { buffer in
                guard position + buffer.count <= bytes.count else { return false }
                return buffer.indices.allSatisfy { bytes[position + $0] == buffer[$0] }
            }
        }

        mutating func skipBlanks() {
            while let byte = peek, byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") {
                position += 1
            }
        }

        mutating func expect(_ byte: UInt8) throws {
            guard peek == byte else { throw Unreadable() }
            position += 1
        }

        /// Past optional blanks and a comment, to just after the line's terminator.
        mutating func endLine() throws {
            skipBlanks()
            if peek == UInt8(ascii: "#") {
                while let byte = peek, byte != UInt8(ascii: "\n") { position += 1 }
            } else if peek == UInt8(ascii: "\r"), peek(at: 1) == UInt8(ascii: "\n") {
                position += 1
            }
            if isAtEnd { return }
            guard peek == UInt8(ascii: "\n") else { throw Unreadable() }
            position += 1
        }

        mutating func tableHeader() throws -> (path: [String], isArray: Bool) {
            try expect(UInt8(ascii: "["))
            let isArray = peek == UInt8(ascii: "[")
            if isArray { position += 1 }
            skipBlanks()
            let path = try keyPath()
            skipBlanks()
            try expect(UInt8(ascii: "]"))
            if isArray { try expect(UInt8(ascii: "]")) }
            return (path, isArray)
        }

        mutating func keyPath() throws -> [String] {
            var path = [try keyPart()]
            skipBlanks()
            while peek == UInt8(ascii: ".") {
                position += 1
                skipBlanks()
                path.append(try keyPart())
                skipBlanks()
            }
            return path
        }

        private mutating func keyPart() throws -> String {
            guard let byte = peek else { throw Unreadable() }
            if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                guard let text = try oneLineString(), !text.utf8.contains(UInt8(ascii: "\\")) else {
                    throw Unreadable()
                }
                return text
            }
            let start = position
            while let byte = peek, Self.isBareKey(byte) { position += 1 }
            guard position > start else { throw Unreadable() }
            return String(decoding: bytes[start..<position], as: UTF8.self)
        }

        private static func isBareKey(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }

        /// Moves past one value. Answers its text if it is a one-line string.
        mutating func value() throws -> String? {
            guard let byte = peek else { throw Unreadable() }
            switch byte {
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                return try stringValue()
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                try nested()
                return nil
            default:
                try bareValue()
                return nil
            }
        }

        private mutating func stringValue() throws -> String? {
            if starts(with: "\"\"\"") || starts(with: "'''") {
                try multiLineString()
                return nil
            }
            return try oneLineString()
        }

        /// A string on one line, its quotes left out and its escapes as written.
        private mutating func oneLineString() throws -> String? {
            guard let quote = peek else { throw Unreadable() }
            position += 1
            let start = position
            while let byte = peek {
                if byte == UInt8(ascii: "\n") { throw Unreadable() }
                if byte == quote {
                    let text = String(decoding: bytes[start..<position], as: UTF8.self)
                    position += 1
                    return text
                }
                if byte == UInt8(ascii: "\\"), quote == UInt8(ascii: "\"") { position += 1 }
                position += 1
            }
            throw Unreadable()
        }

        private mutating func multiLineString() throws {
            guard let quote = peek else { throw Unreadable() }
            position += 3
            while let byte = peek {
                if byte == UInt8(ascii: "\\"), quote == UInt8(ascii: "\"") {
                    position += 2
                    continue
                }
                if byte == quote, peek(at: 1) == quote, peek(at: 2) == quote {
                    position += 3
                    // Up to two more quotes belong to the string.
                    for _ in 0..<2 where peek == quote { position += 1 }
                    return
                }
                position += 1
            }
            throw Unreadable()
        }

        /// An array or an inline table, over as many lines as it takes.
        private mutating func nested() throws {
            var depth = 0
            while let byte = peek {
                switch byte {
                case UInt8(ascii: "["), UInt8(ascii: "{"):
                    depth += 1
                    position += 1
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    depth -= 1
                    position += 1
                    if depth == 0 { return }
                case UInt8(ascii: "\""), UInt8(ascii: "'"):
                    _ = try stringValue()
                case UInt8(ascii: "#"):
                    while let next = peek, next != UInt8(ascii: "\n") { position += 1 }
                default:
                    position += 1
                }
            }
            throw Unreadable()
        }

        /// A number, boolean or date. Only a date holds a space, between its parts.
        private mutating func bareValue() throws {
            let first = bareToken()
            guard !first.isEmpty else { throw Unreadable() }
            if first.contains(UInt8(ascii: "-")), peek == UInt8(ascii: " "),
                let next = peek(at: 1), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(next)
            {
                position += 1
                _ = bareToken()
            }
        }

        private mutating func bareToken() -> ArraySlice<UInt8> {
            let start = position
            while let byte = peek, Self.isBareKey(byte) || byte == UInt8(ascii: "+")
                || byte == UInt8(ascii: ":") || byte == UInt8(ascii: ".")
            {
                position += 1
            }
            return bytes[start..<position]
        }
    }
}
