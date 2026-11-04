import Foundation

/// The files a Grok Build edit or write changes, from the ACP diff items in
/// its records' `content`: `{type: diff, path, oldText, newText, _meta}`.
///
/// A result's item lists the edits Grok applied in `_meta.details`: each
/// replaced string where it starts, with up to three whole lines of context
/// around it and the text before it on its first line (`line_prefix`).
/// Chat builds hunks from them as Grok's pager does (`build_diff_hunks`),
/// so context, indentation and trimming read the same. An input update's
/// item previews the edit before it runs: the old and new text, and in
/// `_meta` the line it starts on, which the pager diffs line by line
/// (`diff_hunks_from_strings`).
enum GrokFileChanges {
    /// The unchanged lines the pager keeps on each side of a change.
    static let context = 3
    /// Texts longer than this together, in lines, read as every old line
    /// removed and every new one added rather than diffed line by line.
    static let maximumDiffLines = 2_000

    /// Nil when `content` holds no diff item a row can show.
    static func changes(content: JSONValue?) -> ChatFileChanges? {
        guard case .array(let items) = content else { return nil }
        var changes = ChatFileChanges(files: [])
        for item in items where item["type"]?.stringValue == "diff" {
            guard let file = file(item) else { continue }
            if changes.files.count < ChatFileChanges.maximumFiles {
                changes.files.append(file)
            } else {
                changes.moreFiles += 1
            }
        }
        return changes.files.isEmpty && changes.moreFiles == 0 ? nil : changes
    }

    /// The change a `SearchReplace` result's `EditsApplied` records, for a
    /// result whose `content` holds no diff item.
    static func changes(applied: JSONValue) -> ChatFileChanges? {
        guard let path = applied["absolute_path"]?.stringValue else { return nil }
        var item: [String: JSONValue] = ["type": .string("diff"), "path": .string(path)]
        item["oldText"] = applied["old_string"]
        item["newText"] = applied["new_string"]
        if let details = applied["edits"]?["details"] {
            item["_meta"] = .object(["details": details])
        }
        return changes(content: .array([.object(item)]))
    }

    private static func file(_ item: JSONValue) -> ChatFileChange? {
        guard let path = item["path"]?.stringValue, !path.isEmpty, let newText = item["newText"]?.stringValue else {
            return nil
        }
        let oldText = item["oldText"]?.stringValue ?? ""
        // Grok creates a file through an edit whose old text is empty.
        let kind: ChatFileChange.Kind = oldText.isEmpty ? .created : .updated
        let details = Self.details(item["_meta"]?["details"])
        let groups =
            details.isEmpty
            ? grouped(oldText, newText, startLine: line(item["_meta"]?["new_line"]) ?? 1)
            : details.compactMap(rows)
        let hunks = groups.compactMap(hunk)
        // A created file may be empty; any other change shows some lines.
        guard !hunks.isEmpty || kind == .created else { return nil }
        return ChatFileChange(path: path, kind: kind, recorded: hunks)
    }

    // MARK: Rows

    private enum Tag {
        case equal
        case delete
        case insert
    }

    /// One line of a hunk as the pager tags it, with its line numbers in the
    /// old and new file.
    private struct Row {
        let tag: Tag
        /// The line with its newline, as the diff split it.
        let text: Substring
        let old: Int
        let new: Int
    }

    /// One `SearchReplaceEditDetail`. Every field but `line_prefix` is
    /// required: the pager skips details missing one.
    private struct Detail {
        let oldString: String
        let oldLine: Int
        let newString: String
        let newLine: Int
        let contextBefore: String
        let contextAfter: String
        let linePrefix: String
    }

    private static func details(_ value: JSONValue?) -> [Detail] {
        guard case .array(let items) = value else { return [] }
        var details: [Detail] = []
        for item in items {
            guard let oldString = item["old_string"]?.stringValue, let oldLine = line(item["old_line"]),
                let newString = item["new_string"]?.stringValue, let newLine = line(item["new_line"]),
                let contextBefore = item["context_before"]?.stringValue,
                let contextAfter = item["context_after"]?.stringValue
            else { return [] }
            details.append(
                Detail(
                    oldString: oldString, oldLine: oldLine, newString: newString, newLine: newLine,
                    contextBefore: contextBefore, contextAfter: contextAfter,
                    linePrefix: item["line_prefix"]?.stringValue ?? ""))
        }
        return details
    }

    /// One detail's rows: its context before, the line diff of the old and
    /// new string, its context after, then trimmed to `context` unchanged
    /// lines and no blank ones at either end. Nil when nothing changed.
    private static func rows(_ detail: Detail) -> [Row]? {
        var rows: [Row] = []
        let before = lines(detail.contextBefore)
        for (index, text) in before.enumerated() {
            // The last line of the context sits just above the edit.
            let fromEnd = before.count - index
            rows.append(
                Row(
                    tag: .equal, text: text, old: max(detail.oldLine - fromEnd, 0),
                    new: max(detail.newLine - fromEnd, 0)))
        }
        // A blank line inserted mid-file records two empty strings.
        let insertsBlankLine =
            detail.oldString.isEmpty && detail.newString.isEmpty
            && (!detail.contextBefore.isEmpty || !detail.contextAfter.isEmpty)
        let newText = insertsBlankLine ? "\n" : detail.newString
        var old = detail.oldLine
        var new = detail.newLine
        // A match that starts mid-line lacks the text before it on that
        // line: the first removed and the first added line get it back.
        var prefixedOld = false
        var prefixedNew = false
        for change in lineDiff(lines(detail.oldString), lines(newText)) {
            var text = change.text
            if !detail.linePrefix.isEmpty {
                let needsPrefix =
                    switch change.tag {
                    case .delete: !prefixedOld
                    case .insert: !prefixedNew
                    case .equal: !prefixedOld && !prefixedNew
                    }
                if needsPrefix { text = Substring(detail.linePrefix + text) }
                switch change.tag {
                case .delete, .equal: prefixedOld = true
                case .insert: prefixedNew = true
                }
            }
            rows.append(Row(tag: change.tag, text: text, old: old, new: new))
            advance(change.tag, &old, &new)
        }
        for text in lines(detail.contextAfter) {
            rows.append(Row(tag: .equal, text: text, old: old, new: new))
            old += 1
            new += 1
        }
        guard rows.contains(where: { $0.tag != .equal }) else { return nil }
        let equalBefore = rows.prefix { $0.tag == .equal }.count
        let equalAfter = rows.reversed().prefix { $0.tag == .equal }.count
        var start = max(equalBefore - context, 0)
        var end = rows.count - max(equalAfter - context, 0)
        while start < end, rows[start].tag == .equal, isBlank(rows[start].text) { start += 1 }
        while start < end, rows[end - 1].tag == .equal, isBlank(rows[end - 1].text) { end -= 1 }
        return start < end ? Array(rows[start..<end]) : nil
    }

    /// The old and new text diffed line by line from `startLine`, in groups
    /// of changes with `context` unchanged lines around them; a stretch of
    /// more than twice that unchanged starts another group.
    private static func grouped(_ oldText: String, _ newText: String, startLine: Int) -> [[Row]] {
        var rows: [Row] = []
        var old = startLine
        var new = startLine
        for change in lineDiff(lines(oldText), lines(newText)) {
            rows.append(Row(tag: change.tag, text: change.text, old: old, new: new))
            advance(change.tag, &old, &new)
        }
        var groups: [[Row]] = []
        var start: Int?
        var lastChange: Int?
        for index in rows.indices where rows[index].tag != .equal {
            if let first = start, let previous = lastChange, index - previous - 1 > 2 * context {
                groups.append(Array(rows[first...(previous + context)]))
                start = index - context
            } else if start == nil {
                start = max(index - context, 0)
            }
            lastChange = index
        }
        if let first = start, let previous = lastChange {
            groups.append(Array(rows[first...min(previous + context, rows.count - 1)]))
        }
        return groups
    }

    private static func advance(_ tag: Tag, _ old: inout Int, _ new: inout Int) {
        switch tag {
        case .equal:
            old += 1
            new += 1
        case .delete:
            old += 1
        case .insert:
            new += 1
        }
    }

    /// The rows as a hunk. A side with no lines names the line before the
    /// change, as a unified diff does.
    private static func hunk(_ rows: [Row]) -> ChatDiffHunk? {
        guard let first = rows.first else { return nil }
        let oldLines = rows.count { $0.tag != .insert }
        let newLines = rows.count { $0.tag != .delete }
        let oldStart = oldLines == 0 ? max(first.old - 1, 0) : rows.first { $0.tag != .insert }?.old ?? first.old
        let newStart = newLines == 0 ? max(first.new - 1, 0) : rows.first { $0.tag != .delete }?.new ?? first.new
        let lines = rows.map { row in
            let sign =
                switch row.tag {
                case .equal: " "
                case .delete: "-"
                case .insert: "+"
                }
            return sign + row.text.withoutTrailingLineBreaks
        }
        return ChatDiffHunk(oldStart: oldStart, oldLines: oldLines, newStart: newStart, newLines: newLines, lines: lines)
    }

    // MARK: Lines

    /// `old` and `new` diffed line by line, each change's removed lines
    /// before its added ones. Past `maximumDiffLines`, every old line is
    /// removed and every new one added.
    private static func lineDiff(_ old: [Substring], _ new: [Substring]) -> [(tag: Tag, text: Substring)] {
        guard old.count + new.count <= maximumDiffLines else {
            return old.map { (.delete, $0) } + new.map { (.insert, $0) }
        }
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [(tag: Tag, text: Substring)] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, removed.contains(oldIndex) {
                result.append((.delete, old[oldIndex]))
                oldIndex += 1
            } else if newIndex < new.count, inserted.contains(newIndex) {
                result.append((.insert, new[newIndex]))
                newIndex += 1
            } else if oldIndex < old.count, newIndex < new.count {
                result.append((.equal, old[oldIndex]))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }
        return result
    }

    /// `text`'s lines, each with its newline, as the pager splits them; a
    /// last line without one is a line too.
    private static func lines(_ text: String) -> [Substring] {
        var lines: [Substring] = []
        var start = text.startIndex
        for index in text.unicodeScalars.indices where text.unicodeScalars[index] == "\n" {
            let end = text.unicodeScalars.index(after: index)
            lines.append(text[start..<end])
            start = end
        }
        if start < text.endIndex { lines.append(text[start...]) }
        return lines
    }

    /// Only ASCII whitespace, as the pager's `trim_ascii` reads a blank line.
    private static func isBlank(_ line: Substring) -> Bool {
        line.unicodeScalars.allSatisfy { [" ", "\t", "\n", "\r", "\u{0C}"].contains($0) }
    }

    /// A 1-based line number, which JSON decodes as a double.
    private static func line(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value, let line = Int(exactly: number), line >= 0 else { return nil }
        return line
    }
}
