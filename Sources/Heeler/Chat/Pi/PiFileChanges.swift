import Foundation

/// The files a Pi or Oh My Pi edit changed, from its result's `details`.
///
/// Oh My Pi records `diff` as numbered lines without hunk headers:
/// ` 12|text` and `-12|text` carry the old file's line number, `+12|text`
/// the new file's, and a blank line or a jump in the numbers starts another
/// hunk. `path` names the file, and an edit of several files lists each
/// one's details in `perFileResults`. Pi records a unified diff in `patch`
/// and leaves the path to the call's arguments.
enum PiFileChanges {
    /// Nil when the details record no change a row can show.
    static func changes(details: JSONValue?, callPath: String?, directory: String?) -> ChatFileChanges? {
        var changes = ChatFileChanges(files: [], directory: directory)
        if case .array(let results) = details?["perFileResults"] {
            for result in results {
                guard let file = numberedFile(result) else { continue }
                if changes.files.count < ChatFileChanges.maximumFiles {
                    changes.files.append(file)
                } else {
                    changes.moreFiles += 1
                }
            }
        } else if let patch = details?["patch"]?.stringValue {
            guard let path = callPath, !path.isEmpty, let file = unifiedFile(patch, path: path) else { return nil }
            changes.files = [file]
        } else if let file = numberedFile(details) {
            changes.files = [file]
        }
        return changes.files.isEmpty && changes.moreFiles == 0 ? nil : changes
    }

    // MARK: Oh My Pi

    /// The files an Oh My Pi free-form edit patch names, in order: hashline
    /// sections open with `[path#HASH]`, and the patch form with `*** Add
    /// File:`, `*** Update File:` or `*** Delete File:`. Headers start at
    /// the line's first column; a body line starts with its operation or
    /// sign, a context line with a space, so neither reads as a header.
    static func patchPaths(_ input: String) -> [String] {
        var paths: [String] = []
        for line in input.split(whereSeparator: \.isNewline) {
            var text = line
            while text.last?.isWhitespace == true { text.removeLast() }
            var path: String?
            for header in ["*** Add File:", "*** Update File:", "*** Delete File:"] where text.hasPrefix(header) {
                path = text.dropFirst(header.count).trimmingCharacters(in: .whitespaces)
            }
            if path == nil, text.hasPrefix("["), text.hasSuffix("]"), let hash = text.lastIndex(of: "#") {
                let anchor = text[text.index(after: hash)..<text.index(before: text.endIndex)]
                if !anchor.isEmpty, anchor.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                    path = String(text[text.index(after: text.startIndex)..<hash])
                }
            }
            if let path, !path.isEmpty, !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    private static func numberedFile(_ details: JSONValue?) -> ChatFileChange? {
        guard let path = details?["path"]?.stringValue, !path.isEmpty,
            let hunks = numberedHunks(details?["diff"]?.stringValue ?? "")
        else { return nil }
        let kind: ChatFileChange.Kind =
            switch details?["op"]?.stringValue {
            case "create": .created
            case "delete": .deleted
            default: .updated
            }
        // A deleted file may record no lines; any other change shows some.
        guard !hunks.isEmpty || kind == .deleted else { return nil }
        return ChatFileChange(path: path, kind: kind, recorded: hunks)
    }

    /// Hunks from Oh My Pi's numbered diff lines; nil when a line has
    /// another form, which would number every line after it wrongly.
    static func numberedHunks(_ diff: String) -> [ChatDiffHunk]? {
        var hunks: [ChatDiffHunk] = []
        var current: ChatDiffHunk?
        var nextOld = 0
        var nextNew = 0
        /// New line numbers less old ones, past the hunks closed so far.
        var delta = 0
        func close() {
            guard var hunk = current else { return }
            // A side with no lines names the line before the change.
            if hunk.oldLines == 0 { hunk.oldStart = max(hunk.oldStart - 1, 0) }
            if hunk.newLines == 0 { hunk.newStart = max(hunk.newStart - 1, 0) }
            hunks.append(hunk)
            delta = nextNew - nextOld
            current = nil
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                close()
                continue
            }
            guard let (sign, number, text) = numberedLine(line) else { return nil }
            if current == nil || number != (sign == "+" ? nextNew : nextOld) {
                close()
                let oldStart = sign == "+" ? number - delta : number
                current = ChatDiffHunk(
                    oldStart: oldStart, oldLines: 0, newStart: oldStart + delta, newLines: 0, lines: [])
                nextOld = oldStart
                nextNew = oldStart + delta
            }
            if sign != "+" {
                current?.oldLines += 1
                nextOld += 1
            }
            if sign != "-" {
                current?.newLines += 1
                nextNew += 1
            }
            current?.lines.append(String(sign) + text)
        }
        close()
        return hunks
    }

    /// `^([+\- ])\s*(\d+)\|(.*)$`
    private static func numberedLine(_ line: Substring) -> (Character, Int, Substring)? {
        guard let sign = line.first, sign == " " || sign == "-" || sign == "+",
            let bar = line.firstIndex(of: "|")
        else { return nil }
        let digits = line[line.index(after: line.startIndex)..<bar].drop(while: { $0 == " " })
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(digits) else {
            return nil
        }
        return (sign, number, line[line.index(after: bar)...])
    }

    // MARK: Pi

    /// Pi's patch has only `---`/`+++` file headers, so the Changes parser
    /// reads it under a git header of its own. OpenCode's patches read the
    /// same way once their `Index:` lines are dropped.
    static func unifiedFile(_ patch: String, path: String) -> ChatFileChange? {
        let body = Data("diff --git a/file b/file\n".utf8) + Data(patch.utf8)
        guard let file = GitProbe.parsePatchFiles(body, isTruncated: false).first, !file.hunks.isEmpty else {
            return nil
        }
        let hunks = file.hunks.map { hunk in
            ChatDiffHunk(
                oldStart: hunk.oldStart, oldLines: hunk.oldCount, newStart: hunk.newStart, newLines: hunk.newCount,
                lines: hunk.lines.flatMap { line -> [String] in
                    let sign =
                        switch line.kind {
                        case .added: "+"
                        case .removed: "-"
                        case .context: " "
                        }
                    let text = sign + line.text
                    return line.missingNewline ? [text, "\\ No newline at end of file"] : [text]
                })
        }
        return ChatFileChange(path: path, kind: .updated, recorded: hunks)
    }
}
