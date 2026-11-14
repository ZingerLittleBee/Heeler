import Foundation

/// Heeler's Claude Code hooks for tmux status (ADR 0046): the entries Host detail
/// adds to a configuration root's `settings.json` on the user's word, and that an
/// Agent Heeler starts under a root without them gets through `--settings`.
///
/// Every entry runs one command, which runs Heeler's script with `/bin/sh` while
/// the script is there and does nothing once it is gone. Adding keeps every byte
/// of the file but the lines it adds; removing takes out every handler whose
/// command runs Heeler's script, and nothing else, so it needs no record of the
/// addition and works from any device. A file whose shape leaves either in doubt
/// is refused. `plugin/test-vectors/claude-code-hooks-v1.json` holds the forms.
enum ClaudeCodeHooks {
    static let addEditID = "claude-code.hooks"
    static let removeEditID = "claude-code.hooks.remove"
    /// A product name, persisted with each applied edit, so never localized.
    static let harness = "Claude Code"
    /// What every command running Heeler's script holds.
    static let marker = "/heeler/claude-code/hook.sh"
    static let timeout = 5
    /// Heeler's own folder under the Host's data home, apart from the Helper's.
    static let folderSuffix = "heeler/claude-code"
    static let scriptName = "hook.sh"
    /// The settings file a launch passes with `--settings`, beside the script.
    static let launchSettingsName = "hooks.json"
    static let settingsName = "settings.json"

    struct Entry: Equatable, Sendable {
        let event: String
        let matcher: String?
    }

    /// The events Heeler hooks, in the order it writes them.
    static let entries: [Entry] = [
        Entry(event: "SessionStart", matcher: "startup|resume|clear"),
        Entry(event: "UserPromptSubmit", matcher: nil),
        Entry(event: "PreToolUse", matcher: nil),
        Entry(event: "PermissionRequest", matcher: nil),
        Entry(event: "PostToolUse", matcher: nil),
        Entry(event: "PostToolUseFailure", matcher: nil),
        Entry(event: "Notification", matcher: "permission_prompt|idle_prompt"),
        Entry(event: "Stop", matcher: nil),
        Entry(event: "StopFailure", matcher: nil),
        Entry(event: "SessionEnd", matcher: nil),
    ]

    /// Whether a root's settings run Heeler's script for every event.
    enum Presence: Equatable, Sendable {
        case on
        /// Some events, or a script at another path.
        case partly
        case off
    }

    static func folder(dataHome: String) -> String { RemoteFilePath.join(dataHome, folderSuffix) }
    static func scriptPath(dataHome: String) -> String { RemoteFilePath.join(folder(dataHome: dataHome), scriptName) }
    static func launchSettingsPath(dataHome: String) -> String {
        RemoteFilePath.join(folder(dataHome: dataHome), launchSettingsName)
    }

    /// A configuration root's user settings.
    static func settingsPath(root: String) -> String {
        var root = root
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        return RemoteFilePath.join(root, settingsName)
    }

    /// The path single-quoted, so the shell expands nothing in it.
    static func command(script: String) -> String {
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "f=\(quoted); [ ! -r \"$f\" ] || exec /bin/sh \"$f\""
    }

    /// One event's matcher group, on one line.
    static func group(_ entry: Entry, script: String) -> String {
        var fields: [String] = []
        if let matcher = entry.matcher { fields.append("\"matcher\": \(jsonString(matcher))") }
        fields.append(
            "\"hooks\": [{\"type\": \"command\", \"command\": \(jsonString(command(script: script))), "
                + "\"timeout\": \(timeout)}]")
        return "{" + fields.joined(separator: ", ") + "}"
    }

    /// What `--settings` gives a launch: the file an addition would create.
    static func launchSettings(script: String) -> Data {
        Data(wholeFile(script: script).utf8)
    }

    static func addition(root: String, script: String) -> HarnessConfigEdit {
        HarnessConfigEdit(id: addEditID, harness: harness, path: settingsPath(root: root), transform: adding(script: script))
    }

    static func removal(root: String) -> HarnessConfigEdit {
        HarnessConfigEdit(id: removeEditID, harness: harness, path: settingsPath(root: root), transform: removing)
    }

    // MARK: Reading

    private static let unreadableReason =
        String(localized: "Heeler can't read this file as plain JSON, so it won't change it.")
    private static let mixedFormReason =
        String(localized: "This file sets Claude Code's hooks in a form Heeler won't change.")

    /// Nil when the file can't be read with certainty.
    static func presence(in settings: Data?, script: String) -> Presence? {
        guard let settings, !isBlank(settings) else { return .off }
        guard let tree = try? JSONTextTree(settings), case .object(let members, _) = tree.root else { return nil }
        let hooks = members.filter { $0.key == "hooks" }
        guard hooks.count <= 1, let value = hooks.first?.value else { return hooks.isEmpty ? .off : nil }
        guard case .object(let events, _) = value else { return .off }
        let command = command(script: script)
        let hooked = entries.filter { entry in
            events.filter { $0.key == entry.event }.contains { event in
                handlers(in: event.value).contains { $0.command == command }
            }
        }
        if hooked.count == entries.count { return .on }
        let anyOfHeelers = events.contains { event in
            handlers(in: event.value).contains { $0.command.contains(marker) }
        }
        return hooked.isEmpty && !anyOfHeelers ? .off : .partly
    }

    // MARK: Adding

    static func adding(script: String) -> @Sendable (Data?) -> HarnessConfigEdit.Transform {
        { settings in add(script: script, to: settings) }
    }

    private static func add(script: String, to settings: Data?) -> HarnessConfigEdit.Transform {
        guard let settings, !isBlank(settings) else { return .change(to: launchSettings(script: script)) }
        guard let tree = try? JSONTextTree(settings), case .object(let members, let rootSpan) = tree.root else {
            return .refused(reason: unreadableReason)
        }
        let style = Style(tree: tree)
        let hooks = members.filter { $0.key == "hooks" }
        guard hooks.count <= 1 else { return .refused(reason: mixedFormReason) }
        guard let hooksMember = hooks.first else {
            let item: (String) -> String = { indent in
                "\"hooks\": " + hooksObject(script: script, style: style.nested(at: indent))
            }
            return .change(to: tree.replacing([insertion(into: tree.root, span: rootSpan, items: [item], tree: tree, style: style)]))
        }
        guard case .object(let events, let hooksSpan) = hooksMember.value else {
            return .refused(reason: mixedFormReason)
        }
        let command = command(script: script)
        var missing: [(String) -> String] = []
        var replacements: [JSONTextTree.Replacement] = []
        for entry in entries {
            let matching = events.filter { $0.key == entry.event }
            guard matching.count <= 1 else { return .refused(reason: mixedFormReason) }
            guard let event = matching.first else {
                let line = "\(jsonString(entry.event)): [\(group(entry, script: script))]"
                missing.append { _ in line }
                continue
            }
            guard case .array(_, let span) = event.value else { return .refused(reason: mixedFormReason) }
            guard !handlers(in: event.value).contains(where: { $0.command == command }) else { continue }
            let group = group(entry, script: script)
            replacements.append(insertion(into: event.value, span: span, items: [{ _ in group }], tree: tree, style: style))
        }
        if !missing.isEmpty {
            replacements.append(insertion(into: hooksMember.value, span: hooksSpan, items: missing, tree: tree, style: style))
        }
        guard !replacements.isEmpty else { return .alreadyApplied }
        return .change(to: tree.replacing(replacements))
    }

    /// How new lines are laid out: as the file lays out its own, or on one line
    /// for a file on one line.
    private struct Style {
        var newline: String
        var unit: String
        /// The indentation of the line a new block opens on.
        var indent = ""
        var multiline: Bool

        init(tree: JSONTextTree) {
            newline = tree.newline
            unit = tree.indentUnit ?? "  "
            // An empty root has no layout of its own, and gets the whole block's.
            multiline = tree.isMultiline || tree.root.elementSpans.isEmpty
        }

        func nested(at indent: String) -> Style {
            var style = self
            style.indent = indent
            return style
        }
    }

    private static func eventLines(script: String) -> [String] {
        entries.map { entry in "\(jsonString(entry.event)): [\(group(entry, script: script))]" }
    }

    /// `{ "hooks": { … } }` as a file of its own.
    private static func wholeFile(script: String) -> String {
        "{\n  \"hooks\": {\n" + eventLines(script: script).map { "    " + $0 }.joined(separator: ",\n") + "\n  }\n}\n"
    }

    /// The hooks object alone, opening on a line indented by `style.indent`.
    private static func hooksObject(script: String, style: Style) -> String {
        let events = eventLines(script: script)
        guard style.multiline else { return "{" + events.joined(separator: ", ") + "}" }
        let inner = style.indent + style.unit
        return "{" + style.newline + events.map { inner + $0 }.joined(separator: "," + style.newline)
            + style.newline + style.indent + "}"
    }

    /// New elements at the end of a container. `items` get the indentation of
    /// the line they go on.
    private static func insertion(
        into container: JSONTextTree.Value, span: Range<Int>, items: [(String) -> String],
        tree: JSONTextTree, style: Style
    ) -> JSONTextTree.Replacement {
        let elements = container.elementSpans
        guard let last = elements.last else {
            // An empty array takes its group inline; an empty object opens on lines
            // of its own unless the file is on one line.
            let isObject = if case .object = container { true } else { false }
            let interior = (span.lowerBound + 1)..<(span.upperBound - 1)
            guard isObject, style.multiline || container.isRoot(of: tree) else {
                return .init(range: interior, text: items.map { $0("") }.joined(separator: ", "))
            }
            let indent = tree.lineIndent(at: span.lowerBound)
            let inner = indent + style.unit
            let newline = style.newline
            return .init(
                range: interior,
                text: newline + items.map { inner + $0(inner) }.joined(separator: "," + newline) + newline + indent)
        }
        let separator: String
        if elements.count >= 2 {
            separator = tree.whitespace(after: tree.comma(after: elements[elements.count - 2].upperBound), before: last.lowerBound)
        } else {
            separator = tree.text(in: (span.lowerBound + 1)..<last.lowerBound)
        }
        guard let lineStart = separator.lastIndex(where: { $0 == "\n" }) else {
            return .init(range: last.upperBound..<last.upperBound, text: items.map { ", " + $0("") }.joined())
        }
        let indent = String(separator[separator.index(after: lineStart)...])
        return .init(
            range: last.upperBound..<last.upperBound,
            text: items.map { "," + separator + $0(indent) }.joined())
    }

    // MARK: Removing

    @Sendable static func removing(_ settings: Data?) -> HarnessConfigEdit.Transform {
        guard let settings, !isBlank(settings) else { return .alreadyApplied }
        guard let tree = try? JSONTextTree(settings), case .object(let members, let rootSpan) = tree.root else {
            return .refused(reason: unreadableReason)
        }
        let hooks = members.filter { $0.key == "hooks" }
        guard hooks.count <= 1 else { return .refused(reason: mixedFormReason) }
        guard let hooksIndex = members.firstIndex(where: { $0.key == "hooks" }),
            case .object(let events, let hooksSpan) = members[hooksIndex].value
        else { return .alreadyApplied }

        var replacements: [JSONTextTree.Replacement] = []
        var emptiedEvents: Set<Int> = []
        for (eventIndex, event) in events.enumerated() {
            guard case .array(let groups, let groupsSpan) = event.value else { continue }
            var emptiedGroups: Set<Int> = []
            for (groupIndex, group) in groups.enumerated() {
                guard case .object(let fields, _) = group,
                    let handlerList = fields.last(where: { $0.key == "hooks" })?.value,
                    case .array(let handlerValues, let handlersSpan) = handlerList
                else { continue }
                let ours = Set(handlerValues.indices.filter { isHeelers(handlerValues[$0]) })
                guard !ours.isEmpty else { continue }
                if ours.count == handlerValues.count {
                    emptiedGroups.insert(groupIndex)
                } else {
                    replacements += tree.removals(of: ours, from: handlerList.elementSpans, in: handlersSpan)
                }
            }
            if !emptiedGroups.isEmpty, emptiedGroups.count == groups.count {
                emptiedEvents.insert(eventIndex)
            } else {
                replacements += tree.removals(of: emptiedGroups, from: event.value.elementSpans, in: groupsSpan)
            }
        }
        if !emptiedEvents.isEmpty, emptiedEvents.count == events.count {
            // Nothing is left inside these, so the hooks member goes whole.
            replacements = tree.removals(
                of: [hooksIndex], from: members.map(\.span), in: rootSpan)
        } else {
            replacements += tree.removals(of: emptiedEvents, from: events.map(\.span), in: hooksSpan)
        }
        guard !replacements.isEmpty else { return .alreadyApplied }
        return .change(to: tree.replacing(replacements))
    }

    // MARK: Plumbing

    private struct Handler {
        let command: String
    }

    /// The command handlers of an event's matcher groups.
    private static func handlers(in event: JSONTextTree.Value) -> [Handler] {
        guard case .array(let groups, _) = event else { return [] }
        return groups.flatMap { group -> [Handler] in
            guard case .object(let fields, _) = group,
                case .array(let handlers, _) = fields.last(where: { $0.key == "hooks" })?.value
            else { return [] }
            return handlers.compactMap { handler in
                guard case .object(let fields, _) = handler,
                    case .string(let command, _) = fields.last(where: { $0.key == "command" })?.value
                else { return nil }
                return Handler(command: command)
            }
        }
    }

    private static func isHeelers(_ handler: JSONTextTree.Value) -> Bool {
        guard case .object(let fields, _) = handler,
            case .string(let command, _) = fields.last(where: { $0.key == "command" })?.value
        else { return false }
        return command.contains(marker)
    }

    private static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { JSONTextTree.isWhitespace($0) }
    }

    /// A JSON string with only what JSON requires escaped, `/` and non-ASCII as they are.
    static func jsonString(_ text: String) -> String {
        var escaped = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case _ where scalar.value < 0x20: escaped += String(format: "\\u%04x", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "\""
    }
}

/// A strict JSON document's values with the bytes each spans, read only as far as
/// an edit that keeps every other byte needs. Anything Foundation won't read as
/// JSON, and anything nested past a sane depth, is not one.
struct JSONTextTree {
    indirect enum Value {
        case object([Member], Range<Int>)
        case array([Value], Range<Int>)
        case string(String, Range<Int>)
        case other(Range<Int>)

        var span: Range<Int> {
            switch self {
            case .object(_, let span), .array(_, let span), .string(_, let span), .other(let span): span
            }
        }

        /// Each member, key to value, or each element.
        var elementSpans: [Range<Int>] {
            switch self {
            case .object(let members, _): members.map(\.span)
            case .array(let values, _): values.map(\.span)
            case .string, .other: []
            }
        }

        func isRoot(of tree: JSONTextTree) -> Bool { span == tree.root.span }
    }

    struct Member {
        let key: String
        let keyStart: Int
        let value: Value

        var span: Range<Int> { keyStart..<value.span.upperBound }
    }

    /// Bytes `range` becomes, in the original's offsets.
    struct Replacement {
        let range: Range<Int>
        let text: String
    }

    struct Unreadable: Error {}

    let bytes: [UInt8]
    let root: Value

    init(_ data: Data) throws {
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw Unreadable() }
        bytes = Array(data)
        var scanner = Scanner(bytes: bytes)
        root = try scanner.value(depth: 0)
        scanner.skipWhitespace()
        guard scanner.isAtEnd else { throw Unreadable() }
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    var newline: String { bytes.indices.contains { bytes[$0] == 0x0D && $0 + 1 < bytes.count && bytes[$0 + 1] == 0x0A } ? "\r\n" : "\n" }

    var isMultiline: Bool { bytes[root.span].contains(0x0A) }

    /// What the root's members are indented by, past the root's own line.
    var indentUnit: String? {
        guard let first = root.elementSpans.first else { return nil }
        let between = text(in: (root.span.lowerBound + 1)..<first.lowerBound)
        guard let lineStart = between.lastIndex(of: "\n") else { return nil }
        let indent = String(between[between.index(after: lineStart)...])
        let rootIndent = lineIndent(at: root.span.lowerBound)
        guard indent.hasPrefix(rootIndent), indent.count > rootIndent.count else { return nil }
        return String(indent.dropFirst(rootIndent.count))
    }

    func text(in range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    /// The blanks a line starts with, for the line holding `offset`.
    func lineIndent(at offset: Int) -> String {
        var start = offset
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return text(in: start..<end)
    }

    /// The offset of the comma that follows an element ending at `offset`.
    func comma(after offset: Int) -> Int {
        var position = offset
        while position < bytes.count, bytes[position] != UInt8(ascii: ",") { position += 1 }
        return position
    }

    func whitespace(after comma: Int, before offset: Int) -> String {
        text(in: min(comma + 1, offset)..<offset)
    }

    /// Takes the elements at `indices` out of a container that keeps at least one,
    /// with the separators that went with them. Taking every element empties it.
    func removals(of indices: Set<Int>, from elements: [Range<Int>], in span: Range<Int>) -> [Replacement] {
        guard !indices.isEmpty else { return [] }
        guard indices.count < elements.count else {
            return [Replacement(range: (span.lowerBound + 1)..<(span.upperBound - 1), text: "")]
        }
        var replacements: [Replacement] = []
        var index = 0
        while index < elements.count {
            guard indices.contains(index) else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < elements.count, indices.contains(end + 1) { end += 1 }
            if index > 0 {
                replacements.append(Replacement(range: elements[index - 1].upperBound..<elements[end].upperBound, text: ""))
            } else {
                replacements.append(Replacement(range: elements[0].lowerBound..<elements[end + 1].lowerBound, text: ""))
            }
            index = end + 1
        }
        return replacements
    }

    /// The document with each replacement made. They must not overlap.
    func replacing(_ replacements: [Replacement]) -> Data {
        var result = bytes
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(replacement.range, with: Array(replacement.text.utf8))
        }
        return Data(result)
    }

    private struct Scanner {
        let bytes: [UInt8]
        var position = 0

        var isAtEnd: Bool { position >= bytes.count }

        mutating func skipWhitespace() {
            while position < bytes.count, JSONTextTree.isWhitespace(bytes[position]) { position += 1 }
        }

        private mutating func expect(_ byte: UInt8) throws {
            skipWhitespace()
            guard position < bytes.count, bytes[position] == byte else { throw Unreadable() }
            position += 1
        }

        private mutating func next(is byte: UInt8) -> Bool {
            skipWhitespace()
            guard position < bytes.count, bytes[position] == byte else { return false }
            position += 1
            return true
        }

        mutating func value(depth: Int) throws -> Value {
            guard depth < 64 else { throw Unreadable() }
            skipWhitespace()
            guard position < bytes.count else { throw Unreadable() }
            let start = position
            switch bytes[position] {
            case UInt8(ascii: "{"):
                position += 1
                var members: [Member] = []
                if !next(is: UInt8(ascii: "}")) {
                    repeat {
                        skipWhitespace()
                        let keyStart = position
                        guard case .string(let key, _) = try string() else { throw Unreadable() }
                        try expect(UInt8(ascii: ":"))
                        members.append(Member(key: key, keyStart: keyStart, value: try value(depth: depth + 1)))
                    } while next(is: UInt8(ascii: ","))
                    try expect(UInt8(ascii: "}"))
                }
                return .object(members, start..<position)
            case UInt8(ascii: "["):
                position += 1
                var values: [Value] = []
                if !next(is: UInt8(ascii: "]")) {
                    repeat {
                        values.append(try value(depth: depth + 1))
                    } while next(is: UInt8(ascii: ","))
                    try expect(UInt8(ascii: "]"))
                }
                return .array(values, start..<position)
            case UInt8(ascii: "\""):
                return try string()
            default:
                while position < bytes.count, !JSONTextTree.isWhitespace(bytes[position]),
                    ![UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}")].contains(bytes[position])
                {
                    position += 1
                }
                guard position > start else { throw Unreadable() }
                return .other(start..<position)
            }
        }

        private mutating func string() throws -> Value {
            let start = position
            guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else { throw Unreadable() }
            position += 1
            while position < bytes.count, bytes[position] != UInt8(ascii: "\"") {
                if bytes[position] == UInt8(ascii: "\\") { position += 1 }
                position += 1
            }
            guard position < bytes.count else { throw Unreadable() }
            position += 1
            guard
                let text = try? JSONSerialization.jsonObject(
                    with: Data(bytes[start..<position]), options: .fragmentsAllowed) as? String
            else { throw Unreadable() }
            return .string(text, start..<position)
        }
    }
}
