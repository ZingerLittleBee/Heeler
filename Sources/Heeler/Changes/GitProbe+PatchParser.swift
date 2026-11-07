import Foundation

extension GitProbe {
    /// Git's patch protocol is line-oriented in bytes. In particular CRLF
    /// is one Swift Character, so splitting a String would merge rows.
    static func parsePatchFiles(_ body: Data, isTruncated: Bool) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: PatchFileBuilder?
        var nextHunkID = 0
        var nextLineID = 0
        for bytes in body.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var line = Data(bytes)
            if line.last == 0x0D { line.removeLast() }
            if line.starts(with: Data("diff --git ".utf8)) {
                if let current { files.append(current.document(id: files.count)) }
                let paths = patchHeaderPaths(Data(line.dropFirst(11)))
                current = PatchFileBuilder(oldPath: paths.0, newPath: paths.1)
                continue
            }
            guard current != nil else { continue }
            if let hunk = patchHunk(line, id: nextHunkID) {
                current?.begin(hunk)
                nextHunkID += 1
                continue
            }
            if line == Data("\\ No newline at end of file".utf8) {
                current?.markMissingNewline()
                continue
            }
            if current?.append(line, id: nextLineID) == true {
                nextLineID += 1
                continue
            }
            current?.readMetadata(line)
        }
        if let current {
            files.append(current.document(id: files.count, isComplete: !isTruncated))
        }
        return files
    }

    private static func patchHunk(_ line: Data, id: Int) -> DiffHunk? {
        guard line.starts(with: Data("@@ -".utf8)),
            let close = line.range(of: Data(" @@".utf8), in: 3..<line.count)
        else { return nil }
        let ranges = line[3..<close.lowerBound].split(separator: 0x20)
        guard ranges.count == 2,
            ranges[0].first == UInt8(ascii: "-"), ranges[1].first == UInt8(ascii: "+"),
            let old = patchRange(Data(ranges[0].dropFirst())),
            let new = patchRange(Data(ranges[1].dropFirst()))
        else { return nil }
        var section = Data(line[close.upperBound...])
        if section.first == 0x20 { section.removeFirst() }
        return DiffHunk(
            id: id, oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1,
            section: String(decoding: section, as: UTF8.self), lines: [])
    }

    private static func patchRange(_ bytes: Data) -> (Int, Int)? {
        let parts = bytes.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
            let start = Int(String(decoding: parts[0], as: UTF8.self)), start >= 0
        else { return nil }
        let count = parts.count == 1 ? 1 : Int(String(decoding: parts[1], as: UTF8.self))
        guard let count, count >= 0, start <= Int.max - count else { return nil }
        return (start, count)
    }

    /// Header paths need a small tokenizer because spaces are not quoted by
    /// git. Content headers and rename metadata later provide exact paths.
    private static func patchHeaderPaths(_ bytes: Data) -> (Data?, Data?) {
        if bytes.first == UInt8(ascii: "\"") {
            let old = patchUnquote(bytes)
            let remainder = Data(bytes.dropFirst(old.consumed).drop(while: { $0 == 0x20 }))
            return (patchPath(old.bytes), patchPath(patchUnquote(remainder).bytes))
        }
        // With relaxed quoting, equal paths can themselves contain " b/".
        // Prefer the split whose two decoded suffixes agree before taking
        // the first separator (renames provide authoritative metadata).
        let separators = [Data(" b/".utf8), Data(" \"b/".utf8)]
        var candidates: [(Data?, Data?)] = []
        for separator in separators {
            var start = bytes.startIndex
            while start < bytes.endIndex,
                let split = bytes.range(of: separator, in: start..<bytes.endIndex)
            {
                let old = patchPath(Data(bytes[..<split.lowerBound]))
                let new = patchPath(patchUnquote(Data(bytes[(split.lowerBound + 1)...])).bytes)
                if old == new { return (old, new) }
                candidates.append((old, new))
                start = split.upperBound
            }
        }
        return candidates.first ?? (nil, nil)
    }

    fileprivate static func patchPath(_ bytes: Data) -> Data? {
        if bytes == Data("/dev/null".utf8) { return nil }
        if bytes.starts(with: Data("a/".utf8)) || bytes.starts(with: Data("b/".utf8)) {
            return Data(bytes.dropFirst(2))
        }
        return bytes
    }

    /// C-quoted names are emitted even with core.quotePath=false for control
    /// bytes, quotes and backslashes. Octal escapes recover raw path bytes.
    fileprivate static func patchUnquote(_ data: Data) -> (bytes: Data, consumed: Int) {
        let bytes = Array(data)
        guard bytes.first == UInt8(ascii: "\"") else { return (data, data.count) }
        var output = Data()
        var index = 1
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\"") { return (output, index) }
            guard byte == UInt8(ascii: "\\"), index < bytes.count else {
                output.append(byte)
                continue
            }
            let escape = bytes[index]
            index += 1
            if (0x30...0x37).contains(escape) {
                var value = Int(escape - 0x30)
                var digits = 1
                while digits < 3, index < bytes.count, (0x30...0x37).contains(bytes[index]) {
                    value = value * 8 + Int(bytes[index] - 0x30)
                    index += 1
                    digits += 1
                }
                output.append(UInt8(truncatingIfNeeded: value))
            } else {
                switch escape {
                case 0x61: output.append(0x07)
                case 0x62: output.append(0x08)
                case 0x74: output.append(0x09)
                case 0x6E: output.append(0x0A)
                case 0x76: output.append(0x0B)
                case 0x66: output.append(0x0C)
                case 0x72: output.append(0x0D)
                default: output.append(escape)
                }
            }
        }
        return (output, index)
    }
}

/// Mutable only while parsing one file. Appending through a hunk's array
/// subscript mutates in place rather than copying its growing line array.
private struct PatchFileBuilder {
    var oldPath: Data?
    var newPath: Data?
    var hunks: [DiffHunk] = []
    var isBinary = false
    var isNew = false
    var isDeleted = false
    var isRename = false
    var oldMode: String?
    var newMode: String?
    var oldLine = 0
    var newLine = 0
    var oldRemaining = 0
    var newRemaining = 0

    mutating func begin(_ hunk: DiffHunk) {
        hunks.append(hunk)
        oldLine = hunk.oldStart
        newLine = hunk.newStart
        oldRemaining = hunk.oldCount
        newRemaining = hunk.newCount
    }

    mutating func append(_ bytes: Data, id: Int) -> Bool {
        guard !hunks.isEmpty else { return false }
        let kind: DiffLine.Kind
        let oldNumber: Int?
        let newNumber: Int?
        switch bytes.first {
        case UInt8(ascii: "+") where newRemaining > 0:
            kind = .added; oldNumber = nil; newNumber = newLine
            newLine += 1; newRemaining -= 1
        case UInt8(ascii: "-") where oldRemaining > 0:
            kind = .removed; oldNumber = oldLine; newNumber = nil
            oldLine += 1; oldRemaining -= 1
        // An empty line is a blank context line written without its
        // space, as `diff.suppressBlankEmpty` writes it and `git apply`
        // reads it; skipping it would shift every later line's number.
        case UInt8(ascii: " ") where oldRemaining > 0 && newRemaining > 0,
            nil where oldRemaining > 0 && newRemaining > 0:
            kind = .context; oldNumber = oldLine; newNumber = newLine
            oldLine += 1; oldRemaining -= 1
            newLine += 1; newRemaining -= 1
        default: return false
        }
        hunks[hunks.count - 1].lines.append(DiffLine(
            id: id, kind: kind, oldNumber: oldNumber, newNumber: newNumber,
            text: String(decoding: bytes.dropFirst(), as: UTF8.self)))
        return true
    }

    mutating func markMissingNewline() {
        guard let hunk = hunks.indices.last, let line = hunks[hunk].lines.indices.last else { return }
        hunks[hunk].lines[line].missingNewline = true
    }

    mutating func readMetadata(_ line: Data) {
        func value(after prefix: String) -> Data? {
            let prefix = Data(prefix.utf8)
            return line.starts(with: prefix) ? Data(line.dropFirst(prefix.count)) : nil
        }
        if var path = value(after: "--- ") {
            if path.last == 0x09 { path.removeLast() }
            oldPath = GitProbe.patchPath(GitProbe.patchUnquote(path).bytes)
        } else if var path = value(after: "+++ ") {
            if path.last == 0x09 { path.removeLast() }
            newPath = GitProbe.patchPath(GitProbe.patchUnquote(path).bytes)
        } else if let path = value(after: "rename from ") {
            oldPath = GitProbe.patchUnquote(path).bytes; isRename = true
        } else if let path = value(after: "rename to ") {
            newPath = GitProbe.patchUnquote(path).bytes; isRename = true
        } else if let mode = value(after: "old mode ") {
            oldMode = String(decoding: mode, as: UTF8.self)
        } else if let mode = value(after: "new mode ") {
            newMode = String(decoding: mode, as: UTF8.self)
        } else if value(after: "new file mode ") != nil {
            oldPath = nil; isNew = true
        } else if value(after: "deleted file mode ") != nil {
            newPath = nil; isDeleted = true
        } else if value(after: "Binary files ") != nil || line == Data("GIT binary patch".utf8) {
            isBinary = true
        }
    }

    func document(id: Int, isComplete: Bool = true) -> DiffFile {
        var notes: [String] = []
        if isBinary { notes.append(String(localized: "Binary file.")) }
        if isRename, let oldPath, let newPath {
            notes.append("Renamed from \(ChangedFile.displayText(oldPath)) to \(ChangedFile.displayText(newPath)).")
        }
        if let oldMode, let newMode {
            notes.append("File mode changed from \(oldMode) to \(newMode).")
        }
        if isComplete && hunks.isEmpty && !isBinary {
            if isNew { notes.append(String(localized: "New empty file.")) }
            if isDeleted { notes.append(String(localized: "Deleted empty file.")) }
        }
        return DiffFile(
            id: id, oldPath: oldPath.map { String(decoding: $0, as: UTF8.self) },
            newPath: newPath.map { String(decoding: $0, as: UTF8.self) },
            summary: notes.isEmpty ? nil : notes.joined(separator: " "),
            isBinary: isBinary, hunks: hunks)
    }
}
