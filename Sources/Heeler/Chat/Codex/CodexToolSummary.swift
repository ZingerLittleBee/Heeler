import Foundation

/// Titles, kinds and outcomes for Codex tool rows, matching what the Codex
/// TUI shows so a Blocked card's screen text and the row agree.
enum CodexToolSummary {
    // MARK: Commands

    /// A command row's title: the script of a `bash -lc` style wrapper, or
    /// the argv joined with shell quoting, as the TUI renders it
    /// (`strip_bash_lc_and_escape`).
    static func commandTitle(_ argv: [String]) -> String {
        shellScript(argv) ?? shellJoin(argv)
    }

    /// The script of `[sh|bash|zsh, -lc|-c, script]`, or of a PowerShell
    /// `-Command` invocation; nil for anything else.
    static func shellScript(_ argv: [String]) -> String? {
        guard argv.count >= 3, let shell = shellType(argv[0]) else { return nil }
        switch shell {
        case "bash", "zsh", "sh":
            guard argv.count == 3, argv[1] == "-lc" || argv[1] == "-c" else { return nil }
            return argv[2]
        case "pwsh", "powershell":
            var index = 1
            while index + 1 < argv.count {
                let flag = argv[index].lowercased()
                guard ["-nologo", "-noprofile", "-command", "-c"].contains(flag) else { return nil }
                if flag == "-command" || flag == "-c" {
                    return argv[index + 1]
                }
                index += 1
            }
            return nil
        default:
            return nil
        }
    }

    /// The shell a path names: an exact name, else its file stem
    /// (`/bin/zsh`, `bash.exe`).
    private static func shellType(_ path: String) -> String? {
        let shells: Set<String> = ["zsh", "sh", "bash", "pwsh", "powershell"]
        if shells.contains(path) {
            return path
        }
        let base = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
        var stem = base
        if let dot = base.lastIndex(of: "."), dot != base.startIndex {
            stem = String(base[..<dot])
        }
        return shells.contains(stem) ? stem : nil
    }

    /// Joins words the way the Rust `shlex` crate's `try_join` does, falling
    /// back to plain spaces when a word holds a NUL, as the TUI does.
    static func shellJoin(_ words: [String]) -> String {
        if words.contains(where: { $0.utf8.contains(0) }) {
            return words.joined(separator: " ")
        }
        return words.map(shellQuote).joined(separator: " ")
    }

    /// One word quoted by `shlex::Quoter::quote`: unquoted when safe, else in
    /// single or double quotes chunk by chunk.
    static func shellQuote(_ word: String) -> String {
        let bytes = Array(word.utf8)
        guard !bytes.isEmpty else { return "''" }
        var output: [UInt8] = []
        var rest = bytes[...]
        while !rest.isEmpty {
            let (length, strategy) = quotingStrategy(rest)
            if length == rest.count, strategy == .unquoted, output.isEmpty {
                return word
            }
            let chunk = rest.prefix(length)
            rest = rest.dropFirst(length)
            switch strategy {
            case .unquoted:
                output.append(contentsOf: chunk)
            case .singleQuoted:
                output.append(UInt8(ascii: "'"))
                output.append(contentsOf: chunk)
                output.append(UInt8(ascii: "'"))
            case .doubleQuoted:
                output.append(UInt8(ascii: "\""))
                for byte in chunk {
                    if [UInt8(ascii: "$"), UInt8(ascii: "`"), UInt8(ascii: "\""), UInt8(ascii: "\\")].contains(byte) {
                        output.append(UInt8(ascii: "\\"))
                    }
                    output.append(byte)
                }
                output.append(UInt8(ascii: "\""))
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private enum QuotingStrategy {
        case unquoted
        case singleQuoted
        case doubleQuoted
    }

    private static func quotingStrategy(_ bytes: ArraySlice<UInt8>) -> (Int, QuotingStrategy) {
        let unquotedOK: UInt8 = 1
        let singleOK: UInt8 = 2
        let doubleOK: UInt8 = 4
        var previous = unquotedOK | singleOK | doubleOK
        var count = 0
        var index = bytes.startIndex
        if bytes[index] == UInt8(ascii: "^") {
            previous = singleOK
            count = 1
            index += 1
        }
        while index < bytes.endIndex {
            let byte = bytes[index]
            var current = previous
            if byte >= 0x80 {
                current &= ~unquotedOK
            } else {
                if !isUnquotedSafe(byte) { current &= ~unquotedOK }
                if byte == UInt8(ascii: "'") || byte == UInt8(ascii: "^") || byte == UInt8(ascii: "\\") {
                    current &= ~singleOK
                }
                if byte == UInt8(ascii: "`") || byte == UInt8(ascii: "$") || byte == UInt8(ascii: "!")
                    || byte == UInt8(ascii: "^")
                {
                    current &= ~doubleOK
                }
            }
            if current == 0 { break }
            previous = current
            count += 1
            index += 1
        }
        if previous & unquotedOK != 0 { return (count, .unquoted) }
        if previous & singleOK != 0 { return (count, .singleQuoted) }
        return (count, .doubleQuoted)
    }

    private static func isUnquotedSafe(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "/"), UInt8(ascii: ":"),
            UInt8(ascii: "@"), UInt8(ascii: "]"), UInt8(ascii: "_"):
            return true
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "a")...UInt8(ascii: "z"):
            return true
        default:
            return false
        }
    }

    /// The row kind `parsed_cmd` implies, and a subtitle naming what was read
    /// or searched. Anything the TUI cannot read as exploration stays a
    /// command.
    static func commandKind(_ parsed: [CodexRawParsedCommand]) -> (ChatToolActivity.Kind, String?) {
        guard !parsed.isEmpty else { return (.command, nil) }
        let types = parsed.map { $0.type ?? "unknown" }
        if types.allSatisfy({ $0 == "read" }) {
            let names = parsed.compactMap { $0.name ?? $0.path }
            return (.fileRead, names.isEmpty ? nil : names.joined(separator: ", "))
        }
        if types.allSatisfy({ ["read", "list_files", "search"].contains($0) }) {
            let queries = parsed.compactMap { $0.type == "search" ? ($0.query ?? $0.path) : nil }
            return (.search, queries.isEmpty ? nil : queries.joined(separator: ", "))
        }
        return (.command, nil)
    }

    // MARK: Files

    /// `path` relative to the session's working directory when it lies
    /// inside it.
    static func relativePath(_ path: String, cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return path }
        var base = cwd
        while base.count > 1, base.hasSuffix("/") || base.hasSuffix("\\") {
            base.removeLast()
        }
        for separator in ["/", "\\"] where path.hasPrefix(base + separator) {
            let rest = path.dropFirst(base.count + 1)
            if !rest.isEmpty {
                return String(rest)
            }
        }
        return path
    }

    struct FileChangeSummary: Equatable, Sendable {
        var title: String
        var kind: ChatToolActivity.Kind
        var diff: ChatDiffStats
    }

    /// Title, kind and line counts for a `FileChange` item's or
    /// `patch_apply_end`'s `changes`. A change that only adds files writes;
    /// anything else edits.
    static func fileChangeSummary(_ changes: [String: CodexRawFileChange], cwd: String?) -> FileChangeSummary {
        let paths = changes.keys.sorted()
        var added = 0
        var removed = 0
        var onlyAdds = !paths.isEmpty
        var titles: [String] = []
        for path in paths {
            guard let change = changes[path] else { continue }
            switch change.type {
            case "add":
                added += lineCount(change.content ?? "")
            case "delete":
                removed += lineCount(change.content ?? "")
                onlyAdds = false
            default:
                let counts = diffLineCounts(change.unifiedDiff ?? "")
                added += counts.added
                removed += counts.removed
                onlyAdds = false
            }
            var title = relativePath(path, cwd: cwd)
            if let movePath = change.movePath {
                title += " → " + relativePath(movePath, cwd: cwd)
            }
            titles.append(title)
        }
        return FileChangeSummary(
            title: titles.joined(separator: ", "), kind: onlyAdds ? .fileWrite : .fileEdit,
            diff: ChatDiffStats(added: added, removed: removed, files: paths.count))
    }

    /// The same summary from an `apply_patch` call's patch text, for legacy
    /// rollouts whose patch rows come from the call alone.
    static func patchSummary(_ patch: String, cwd: String?) -> FileChangeSummary? {
        var titles: [String] = []
        var added = 0
        var removed = 0
        var onlyAdds = true
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if let path = line.trimmedPrefix("*** Add File: ") {
                titles.append(relativePath(path, cwd: cwd))
            } else if let path = line.trimmedPrefix("*** Update File: ") {
                titles.append(relativePath(path, cwd: cwd))
                onlyAdds = false
            } else if let path = line.trimmedPrefix("*** Delete File: ") {
                titles.append(relativePath(path, cwd: cwd))
                onlyAdds = false
            } else if let path = line.trimmedPrefix("*** Move to: "), let last = titles.popLast() {
                titles.append(last + " → " + relativePath(path, cwd: cwd))
            } else if line.hasPrefix("+"), !line.hasPrefix("+++") {
                added += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                removed += 1
            }
        }
        guard !titles.isEmpty else { return nil }
        return FileChangeSummary(
            title: titles.joined(separator: ", "), kind: onlyAdds ? .fileWrite : .fileEdit,
            diff: ChatDiffStats(added: added, removed: removed, files: titles.count))
    }

    /// Lines in a file's content: a trailing newline does not start another.
    static func lineCount(_ content: String) -> Int {
        guard !content.isEmpty else { return 0 }
        var count = 0
        for byte in content.utf8 where byte == 0x0A {
            count += 1
        }
        return content.utf8.last == 0x0A ? count : count + 1
    }

    /// `+` and `-` lines of a unified diff, excluding its file headers.
    static func diffLineCounts(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                added += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                removed += 1
            }
        }
        return (added, removed)
    }

    // MARK: Outputs

    /// The exit code a legacy tool output records, and the output without
    /// its header. Three formats, oldest first: 0.45's JSON
    /// `{output, metadata: {exit_code}}`, the `Exit code: N` header, and
    /// unified exec's `Process exited with code N` header. Which versions
    /// wrote which is unverified, so each is tried in turn.
    static func legacyOutput(_ text: String) -> (exitCode: Int?, body: String) {
        if text.hasPrefix("{"), let output = try? JSONDecoder().decode(Legacy045Output.self, from: Data(text.utf8)) {
            return (output.exitCode, output.output)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var exitCode: Int?
        var sawHeader = false
        for (index, line) in lines.enumerated() {
            if let code = line.trimmedPrefix("Exit code: ").flatMap({ Int($0) }) {
                exitCode = code
                sawHeader = true
            } else if let code = line.trimmedPrefix("Process exited with code ").flatMap({ Int($0) }) {
                exitCode = code
                sawHeader = true
            } else if line.hasPrefix("Wall time: ") || line.hasPrefix("Chunk ID: ")
                || line.hasPrefix("Total output lines: ") || line.hasPrefix("Original token count: ")
                || line.hasPrefix("Process running with session ID ")
            {
                sawHeader = true
            } else if line == "Output:", sawHeader {
                return (exitCode, lines[(index + 1)...].joined(separator: "\n"))
            } else {
                break
            }
        }
        return (exitCode, text)
    }

    private struct Legacy045Output: Decodable {
        var output: String
        var exitCode: Int?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodexKey.self)
            output = try container.decode(String.self, forKey: "output")
            exitCode = container.lenient("metadata", as: Metadata.self)?.exitCode
        }

        struct Metadata: Decodable {
            var exitCode: Int?

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodexKey.self)
                exitCode = container.lenient("exit_code")
            }
        }
    }

    /// A preview of `text`, or nil when there is nothing to show.
    static func preview(_ text: String?, imageCount: Int = 0) -> ChatToolPreview? {
        guard let text, !text.isEmpty || imageCount > 0 else { return nil }
        return ChatToolPreview(capping: text, imageCount: imageCount)
    }

    /// An MCP result's text blocks, joined, with its images counted.
    static func mcpPreview(_ result: CodexRawMcpResult?, error: String?) -> ChatToolPreview? {
        if let error, !error.isEmpty {
            return preview(error)
        }
        guard let result else { return nil }
        let text = result.content.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
        let images = result.content.filter { $0.type == "image" }.count
        return preview(text, imageCount: images)
    }

    /// A web search's title from its query or action.
    static func webSearchTitle(query: String?, action: CodexRawWebAction?) -> String {
        if let query, !query.isEmpty {
            return query
        }
        switch action?.type {
        case "search":
            let queries = action?.queries ?? []
            return action?.query ?? (queries.isEmpty ? "Web search" : queries.joined(separator: ", "))
        case "open_page", "openPage":
            return action?.url ?? "Open page"
        case "find_in_page", "findInPage":
            return [action?.pattern, action?.url].compactMap { $0 }.joined(separator: " in ")
        default:
            return "Web search"
        }
    }
}

extension Substring {
    /// The rest after `prefix`, trimmed of whitespace; nil when the line does
    /// not start with it.
    fileprivate func trimmedPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }
}
