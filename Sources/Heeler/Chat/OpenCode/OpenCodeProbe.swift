import Foundation

/// Builds the POSIX shell script that reads one OpenCode session from
/// OpenCode's own SQLite database on the Host, and parses what it prints.
/// Pure: no I/O. ADR 0025 records why Chat reads the store and how.
///
/// The script finds the default store (`$XDG_DATA_HOME/opencode/opencode.db`
/// when that is absolute, else under `~/.local/share`) and reads it with the
/// `sqlite3` CLI, or with `python3` when the Host has no CLI. Both open the
/// database read-only, ignore the user's settings, set `query_only`, and run
/// every statement after the version inside one transaction, so the lines
/// come from one snapshot. A store whose `-wal` or `-shm` file is missing is
/// closed and never opened, because stock SQLite would create them. Output
/// is cut at ``outputCap`` bytes. Each line carries a one-letter tag
/// (`OpenCodeProbe+SQL.swift` and ADR 0025 list them) between markers
/// holding a per-request nonce.
///
/// The only values that reach the script are the nonce, the validated
/// session id inside SQL string literals, and integers. Nothing is
/// interpolated into a shell word. The statements travel once, in one
/// here-document that whichever reader runs reads, because every poll
/// uploads the whole script.
enum OpenCodeProbe {
    enum Reader: Equatable, Sendable {
        /// `sqlite3`, else a `python3` that is not Darwin's install shim.
        case automatic
        /// Python only, so a test can exercise that reader on a Host that
        /// has both.
        case pythonOnly
    }

    /// The reader's output past this many bytes is cut, and its exit line
    /// with it.
    static let outputCap = 2_097_152

    /// 24 lowercase hexadecimal digits from the system's random source.
    /// Hex only, so it needs no quoting.
    static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<12).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
    }

    static func beginMarker(nonce: String) -> String { "__HEELER_OC_BEGIN_\(nonce)" }
    static func endMarker(nonce: String) -> String { "__HEELER_OC_END_\(nonce)" }

    // MARK: Script

    static func script(_ query: OpenCodeQuery, nonce: String, reader: Reader = .automatic) -> Data {
        let statements = statements(query)
        let sqlDelimiter = "__HEELER_SQL_\(nonce)__"
        var lines = [
            "N=\(nonce)",
            "LC_ALL=C",
            "export LC_ALL",
            HerdrHostPath.pathExport,
            "d=${XDG_DATA_HOME:-}",
            "case $d in /*) ;; *) d=$HOME/.local/share ;; esac",
            "o=$d/opencode",
            "db=$o/opencode.db",
            "sq=",
            "py=",
            "if [ \"$(uname -s)\" = Darwin ]; then",
            "  if [ -x /usr/bin/sqlite3 ]; then sq=/usr/bin/sqlite3; "
                + "else sq=$(command -v sqlite3 2>/dev/null) || sq=; fi",
            "  py=$(command -v python3 2>/dev/null) || py=",
            "  [ \"$py\" = /usr/bin/python3 ] && py=",
            "else",
            "  sq=$(command -v sqlite3 2>/dev/null) || sq=",
            "  py=$(command -v python3 2>/dev/null) || py=",
            "fi",
        ]
        if reader == .pythonOnly {
            lines.append("sq=")
        }
        lines += [
            "printf '%s\\n' \"__HEELER_OC_BEGIN_$N\"",
            "if [ ! -f \"$db\" ]; then",
            "  case $db in \"$HOME\"/*) p=\"~${db#\"$HOME\"}\" ;; *) p=$db ;; esac",
            // A range rather than `[:print:]`, which BusyBox's `tr -c` reads
            // as its letters, so it mangled the whole line.
            "  printf 'P nodb %s\\n' \"$p\" | tr -c ' -~\\n' '?'",
            // Stock SQLite opens a WAL database read-only by creating its
            // missing side files; Apple's refuses. Neither reader starts.
            "elif [ ! -e \"$db-wal\" ] || [ ! -e \"$db-shm\" ]; then",
            "  printf 'P closed\\n'",
            "elif [ -n \"$sq$py\" ]; then",
            // The CLI whenever there is one, Python only without it. Both
            // read the statements from the here-document below.
            "  { if [ -n \"$sq\" ]; then",
            "    \"$sq\" -init /dev/null -readonly -batch -bail -noheader -list \"$db\"",
            "  else",
            "    \"$py\" -I -c '",
            pythonReader,
            "' \"$db\"",
            "  fi <<'\(sqlDelimiter)'",
            ".timeout 1000",
            "PRAGMA query_only = 1;",
            "\(statements.first ?? versionStatement);",
            "BEGIN;",
            "\(statements.dropFirst().joined(separator: ";\n"));",
            "COMMIT;",
            sqlDelimiter,
            "    printf 'Z %s\\n' \"$?\"; } | head -c \(outputCap)",
            "else",
            "  printf 'P noreader\\n'",
            "fi",
            "w=0; [ -e \"$db-wal\" ] && w=1",
            "s=0; [ -e \"$db-shm\" ] && s=1",
            "printf 'W %s %s\\n' \"$w\" \"$s\"",
        ]
        if case .tail = query.kind {
            // Stores beside the default one, named for the hint when the
            // session is not in the default store. Names only, never read.
            lines += [
                "n=0; names=",
                "for f in \"$o\"/opencode-*.db; do",
                "  [ -f \"$f\" ] || continue",
                "  b=\"${f##*/}\"",
                "  case \"$b\" in *[!A-Za-z0-9._-]*) continue ;; esac",
                "  n=\"$((n + 1))\"; [ \"$n\" -le 8 ] || break",
                "  names=\"$names $b\"",
                "done",
                "[ -n \"$names\" ] && printf 'O%s\\n' \"$names\"",
            ]
        }
        lines.append("printf '\\n%s\\n' \"__HEELER_OC_END_$N\"")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Python reads the statements the CLI reads, from the same
    /// here-document: it runs each text that ends in `;` at a line end and
    /// skips the CLI's dot-command lines, so no statement holds a `;` or
    /// starts a line with `.`. The program goes in single quotes on the
    /// command line, so it holds no `'` itself.
    ///
    /// It writes the bytes SQLite returns, as the CLI does: text that is not
    /// UTF-8 (SQLite's form of a lone surrogate escape) reaches the parse
    /// instead of failing the read, and an ASCII stdout under `LC_ALL=C`
    /// (Python 3.6) never fails on text. It skips NULL rows, as the CLI's
    /// empty lines are skipped, and reports any failure in the CLI's form,
    /// a Python built without its `sqlite3` module included.
    static let pythonReader = """
        import sys
        from urllib.parse import quote
        out = sys.stdout.buffer
        try:
            import sqlite3
            c = sqlite3.connect("file:" + quote(sys.argv[1]) + "?mode=ro", uri=True,
                                timeout=1.0, isolation_level=None)
            c.text_factory = bytes
            c.execute("PRAGMA query_only = 1")
            for s in sys.stdin.buffer.read().decode("utf-8").split(";\\n"):
                s = "\\n".join(l for l in s.split("\\n") if not l.startswith("."))
                if not s.strip():
                    continue
                for row in c.execute(s):
                    v = row[0]
                    if v is not None:
                        out.write((v if isinstance(v, bytes) else str(v).encode("utf-8")) + b"\\n")
            out.flush()
        except Exception as e:
            out.flush()
            sys.stderr.write("Error: " + type(e).__name__ + ": " + str(e) + "\\n")
            sys.exit(1)
        """

    // MARK: Parse

    /// Reads the tagged lines between this request's markers. Anything
    /// outside them, such as login-shell noise, is ignored. Throws
    /// `TransportError.malformedResponse` when either marker is missing and
    /// `.hostStoreUnreadable` for a reader failure Chat cannot explain as a
    /// store problem.
    static func parse(
        stdout: Data, stderr: Data, exitStatus: Int32, nonce: String, query: OpenCodeQuery
    ) throws -> OpenCodeQueryResponse {
        guard let begin = stdout.range(of: Data("\(beginMarker(nonce: nonce))\n".utf8)),
            let end = stdout.range(
                of: Data("\n\(endMarker(nonce: nonce))\n".utf8),
                in: begin.upperBound..<stdout.endIndex)
        else {
            throw TransportError.malformedResponse(
                "OpenCode's store query stopped before its end (exit status \(exitStatus))")
        }
        let output = Output(Data(stdout[begin.upperBound..<end.lowerBound]))

        switch output.problem {
        case "noreader"?:
            return .unavailable(.noReader)
        case "closed"?:
            return .unavailable(.storeClosed)
        case let problem? where problem.hasPrefix("nodb "):
            return .unavailable(.noStore(path: printable(String(problem.dropFirst(5)), limit: 512)))
        default:
            break
        }
        if let version = output.version, isBelowFloor(version) {
            return .unavailable(.readerTooOld(version))
        }
        if output.olderTables != nil {
            return .unavailable(.olderOpenCode)
        }
        if let missing = output.missingColumns {
            return .unavailable(.layout(missing: missing))
        }
        if output.sessionMissing {
            return .sessionMissing(otherStores: output.otherStores.filter(isStoreName))
        }
        guard let exitLine = output.exitLine else {
            // `head -c` cut the reader's output, its exit line with it.
            // Short of the cap, a missing exit line is a script that went
            // wrong, not a conversation too large to read.
            guard output.readerBytes >= outputCap else {
                throw TransportError.malformedResponse(
                    "OpenCode's store query printed no exit status (exit status \(exitStatus))")
            }
            return .records(output.records(overflow: true))
        }
        if exitLine != 0 {
            return try readerFailure(
                stderr: stderr, status: exitLine, version: output.version, walPresent: output.walPresent)
        }
        if case .poll(let cursor) = query.kind, let counter = cursor.eventSeq,
            output.eventSeq == counter
        {
            return .unchanged(eventSeq: counter)
        }
        return .records(output.records(overflow: output.overBudget))
    }

    /// The tagged lines of one output, read in one pass.
    private struct Output {
        var version: String?
        var problem: String?
        var olderTables: String?
        var missingColumns: [String]?
        var eventSeq: Int64?
        var sessionMissing = false
        var sessionLine: Data?
        var rows: [OpenCodeRowLine] = []
        var overBudget = false
        var firstSeq: Int64?
        var windowCount: Int?
        var inboxLine: Data?
        var exitLine: Int32?
        var walPresent: Bool?
        var otherStores: [String] = []
        var ignoredLines = 0
        /// The body less the script's own `W` and `O` lines: what the
        /// reader printed through `head -c`, with its exit line. A `W` line
        /// joined to a row cut mid-line counts too, past the cap.
        private(set) var readerBytes = 0

        private struct RowHead: Decodable {
            let id: String
            let seq: Int64
            let tu: Int64?
            let f: Bool?
        }

        init(_ body: Data) {
            var lines = body.split(separator: 0x0A, omittingEmptySubsequences: false)
            if lines.last?.isEmpty == true {
                lines.removeLast()
            }
            var scriptBytes = 0
            for slice in lines {
                let line = Data(slice)
                guard let tag = line.first, line.count == 1 || line[1] == 0x20,
                    read(tag: tag, value: line.count > 2 ? Data(line[2...]) : Data())
                else {
                    ignoredLines += 1
                    continue
                }
                if tag == UInt8(ascii: "W") || tag == UInt8(ascii: "O") {
                    scriptBytes += line.count + 1
                }
            }
            readerBytes = body.count - scriptBytes
        }

        /// False for a line this parse does not know. SQLite turns a lone
        /// surrogate escape in OpenCode's JSON, such as a line OpenCode cut
        /// inside an emoji, into bytes that are not UTF-8; JSON lines keep
        /// them as U+FFFD, so the rest of the line still decodes.
        private mutating func read(tag: UInt8, value: Data) -> Bool {
            let text = String(decoding: value, as: UTF8.self)
            switch Character(UnicodeScalar(tag)) {
            case "V": version = text
            case "P": problem = text
            case "T": olderTables = text
            case "L": missingColumns = text.split(separator: ",").map(String.init)
            case "E":
                guard text.isEmpty || Int64(text) != nil else { return false }
                eventSeq = Int64(text)
            case "M":
                guard value.isEmpty else { return false }
                sessionMissing = true
            case "S": sessionLine = Data(text.utf8)
            case "R":
                let line = Data(text.utf8)
                guard let head = try? JSONDecoder().decode(RowHead.self, from: line) else {
                    return false
                }
                rows.append(OpenCodeRowLine(
                    id: head.id, seq: head.seq, timeUpdated: head.tu ?? 0,
                    isFinal: head.f ?? false, line: line))
            case "X":
                guard value.isEmpty else { return false }
                overBudget = true
            case "F":
                guard text.isEmpty || Int64(text) != nil else { return false }
                firstSeq = Int64(text)
            case "C":
                guard let count = Int(text) else { return false }
                windowCount = count
            case "I": inboxLine = Data(text.utf8)
            case "Z":
                guard let status = Int32(text) else { return false }
                exitLine = status
            case "W":
                let flags = text.split(separator: " ")
                guard flags.count == 2 else { return false }
                walPresent = flags[0] == "1"
            case "O": otherStores = text.split(separator: " ").map(String.init)
            default: return false
            }
            return true
        }

        func records(overflow: Bool) -> OpenCodeRecords {
            OpenCodeRecords(
                sqliteVersion: version, eventSeq: eventSeq, sessionLine: sessionLine,
                inboxLine: inboxLine, rows: rows.sorted { $0.seq < $1.seq }, firstSeq: firstSeq,
                windowCount: windowCount, overflow: overflow, ignoredLines: ignoredLines)
        }
    }

    /// Below 3.25 the statements' window functions do not parse.
    private static func isBelowFloor(_ version: String) -> Bool {
        let parts = version.split(separator: ".").prefix(2).compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        return parts[0] < 3 || (parts[0] == 3 && parts[1] < 25)
    }

    private static func isStoreName(_ name: String) -> Bool {
        guard name.hasPrefix("opencode-"), name.hasSuffix(".db") else { return false }
        let channel = name.utf8.dropFirst(9).dropLast(3)
        return (1...64).contains(channel.count)
            && channel.allSatisfy { byte in
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                    UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "_"),
                    UInt8(ascii: "-"):
                    true
                default:
                    false
                }
            }
    }

    /// The reader's last error, as a store problem when it names one. The
    /// CLI prefixes errors with `Error`, `Parse error` or `Runtime error`,
    /// and Python's reader copies the first; the prefix alone says nothing,
    /// because preparing a statement that names a missing table is a parse
    /// error too.
    private static func readerFailure(
        stderr: Data, status: Int32, version: String?, walPresent: Bool?
    ) throws -> OpenCodeQueryResponse {
        let lines = String(decoding: stderr, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let line =
            lines.last {
                $0.hasPrefix("Error") || $0.hasPrefix("Parse error") || $0.hasPrefix("Runtime error")
            } ?? lines.last { !$0.isEmpty } ?? ""
        // A Python built without SQLite cannot read the store at all.
        if line.hasPrefix("Error: ModuleNotFoundError") || line.hasPrefix("Error: ImportError") {
            return .unavailable(.noReader)
        }
        if line.contains("database is locked") || line.contains("database is busy") {
            throw TransportError.hostStoreUnreadable(detail: "OpenCode's database is busy.")
        }
        if line.contains("unable to open") {
            if walPresent == false {
                return .unavailable(.storeClosed)
            }
            throw TransportError.hostStoreUnreadable(detail: "OpenCode's database couldn't be opened.")
        }
        if line.contains("not a database") {
            throw TransportError.hostStoreUnreadable(
                detail: "OpenCode's database file isn't one Chat can read.")
        }
        for prefix in ["no such table: ", "no such column: "] {
            guard let range = line.range(of: prefix) else { continue }
            let name = String(line[range.upperBound...].prefix { !$0.isWhitespace })
            // SQLite without JSON1, or older than 3.16, reports its missing
            // table-valued functions as tables.
            if name.hasPrefix("json_") || name.hasPrefix("pragma_") {
                return .unavailable(.readerTooOld(version ?? "unknown"))
            }
            return .unavailable(.layout(missing: [printable(name, limit: 64)]))
        }
        // A SQLite whose fixed parser stack is smaller than the one releases
        // before 3.46 have cannot parse the statements at all.
        if line.contains("no such function: json") || line.contains("syntax error")
            || line.contains("GROUP BY clause is required") || line.contains("parser stack overflow")
        {
            return .unavailable(.readerTooOld(version ?? "unknown"))
        }
        let detail = printable(homeShownAsTilde(line), limit: 200)
        throw TransportError.hostStoreUnreadable(
            detail: detail.isEmpty ? "OpenCode's database reader exited with status \(status)." : detail)
    }

    /// `/Users/<name>` and `/home/<name>` read as `~`, so a reader's message
    /// never shows the account name.
    private static func homeShownAsTilde(_ line: String) -> String {
        var line = line
        for home in ["/Users/", "/home/"] {
            while let range = line.range(of: home) {
                let nameEnd =
                    line[range.upperBound...].firstIndex { $0 == "/" || $0.isWhitespace }
                    ?? line.endIndex
                line.replaceSubrange(range.lowerBound..<nameEnd, with: "~")
            }
        }
        return line
    }

    /// Printable ASCII only, cut to `limit` characters with an ellipsis.
    private static func printable(_ text: String, limit: Int) -> String {
        let shown = String(text.unicodeScalars.map { (0x20...0x7E).contains($0.value) ? Character($0) : "?" })
        return shown.count > limit ? shown.prefix(limit - 1) + "…" : shown
    }
}
