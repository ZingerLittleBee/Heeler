import Foundation
import Testing

@testable import Heeler

/// The script and the parse of an OpenCode store query, without a store:
/// what the script may carry and run, and how every line, problem and
/// reader failure reads. `OpenCodeStoreQueryTests` runs the statements
/// against real SQLite.
@Suite("OpenCode probe")
struct OpenCodeProbeTests {
    // MARK: Script

    @Test func theScriptCarriesOnlyValidatedValues() throws {
        let id = Self.session.rawValue
        for query in Self.queries {
            let nonce = OpenCodeProbe.makeNonce()
            let parts = ScriptParts(OpenCodeProbe.script(query, nonce: nonce), nonce: nonce)
            let shell = parts.shell.joined(separator: "\n")

            // The session id reaches the Host only inside SQL string literals.
            #expect(!shell.contains(id), "\(query.kind)")
            #expect(!parts.python.joined(separator: "\n").contains(id), "\(query.kind)")
            let sql = parts.sql.joined(separator: "\n")
            let occurrences = sql.ranges(of: id)
            #expect(!occurrences.isEmpty)
            for range in occurrences {
                #expect(sql[..<range.lowerBound].hasSuffix("'") && sql[range.upperBound...].hasPrefix("'"))
            }

            // Command substitution only for the fixed lookups; `$((` is
            // arithmetic on the script's own counter.
            for range in shell.ranges(of: "$(") where !shell[range.upperBound...].hasPrefix("(") {
                let substitution = shell[range.upperBound...]
                #expect(
                    ["uname -s)", "command -v sqlite3 2>/dev/null)", "command -v python3 2>/dev/null)"]
                        .contains { substitution.hasPrefix($0) },
                    "\(substitution.prefix(40))")
            }
            #expect(!shell.contains("`"))
            #expect(
                Self.unquotedVariables(in: shell).isSubset(
                    of: ["db", "N", "sq", "py", "d", "o", "HOME", "XDG_DATA_HOME"]),
                "\(Self.unquotedVariables(in: shell))")

            // The one here-document ends at a delimiter carrying the nonce,
            // so a statement cannot end it early. Python's program is fixed
            // text in single quotes.
            #expect(parts.shell.filter { $0.contains("<<") } == ["  fi <<'__HEELER_SQL_\(nonce)__'"])
            #expect(parts.shell.contains("__HEELER_SQL_\(nonce)__"))
            #expect(parts.python.joined(separator: "\n") == OpenCodeProbe.pythonReader)
            #expect(!OpenCodeProbe.pythonReader.contains("'"))
            #expect(parts.shell.first == "N=\(nonce)")
        }
    }

    @Test func theScriptPrefersSqliteThenPythonButNeverTheShim() throws {
        let nonce = OpenCodeProbe.makeNonce()
        let automatic = ScriptParts(OpenCodeProbe.script(Self.tail, nonce: nonce), nonce: nonce).shell
        // Darwin: the system CLI first, then one on PATH; never the
        // `python3` shim that offers to install the developer tools.
        let darwin = try #require(automatic.firstIndex(of: "if [ \"$(uname -s)\" = Darwin ]; then"))
        #expect(automatic[darwin + 1] == "  if [ -x /usr/bin/sqlite3 ]; then sq=/usr/bin/sqlite3; "
            + "else sq=$(command -v sqlite3 2>/dev/null) || sq=; fi")
        #expect(automatic[darwin + 2] == "  py=$(command -v python3 2>/dev/null) || py=")
        #expect(automatic[darwin + 3] == "  [ \"$py\" = /usr/bin/python3 ] && py=")
        #expect(automatic[darwin + 4] == "else")
        #expect(try #require(automatic.lastIndex(of: "sq=")) < darwin)

        // The CLI whenever there is one, Python only without it.
        let readers = try #require(automatic.firstIndex(of: "elif [ -n \"$sq$py\" ]; then"))
        #expect(automatic[readers + 1] == "  { if [ -n \"$sq\" ]; then")
        #expect(automatic[readers + 2].hasPrefix("    \"$sq\" "))
        #expect(automatic[readers + 3] == "  else")
        #expect(automatic[readers + 4] == "    \"$py\" -I -c '")
        let noReader = try #require(automatic.firstIndex(of: "  printf 'P noreader\\n'"))
        #expect(readers < noReader)

        // A test's Python-only read clears the CLI after the lookups.
        let pythonOnly = ScriptParts(
            OpenCodeProbe.script(Self.tail, nonce: nonce, reader: .pythonOnly), nonce: nonce
        ).shell
        let cleared = try #require(pythonOnly.lastIndex(of: "sq="))
        let lookupsEnd = try #require(pythonOnly[darwin...].firstIndex(of: "fi"))
        #expect(cleared > lookupsEnd && cleared < readers)
    }

    @Test func theScriptIgnoresTheUsersSqliterc() throws {
        let nonce = OpenCodeProbe.makeNonce()
        let shell = ScriptParts(OpenCodeProbe.script(Self.tail, nonce: nonce), nonce: nonce).shell
        let cli = try #require(shell.first { $0.hasPrefix("    \"$sq\" ") })
        #expect(cli.contains(" -init /dev/null "))
        #expect(cli.contains(" -batch -bail "))
    }

    /// Python fetches text as bytes and writes them as SQLite returns them,
    /// as the CLI does: decoding them would fail the whole read on text
    /// that is not UTF-8.
    @Test func thePythonReaderWritesUTF8Bytes() throws {
        let nonce = OpenCodeProbe.makeNonce()
        let python = ScriptParts(OpenCodeProbe.script(Self.tail, nonce: nonce), nonce: nonce)
            .python.joined(separator: "\n")
        #expect(python.contains("out = sys.stdout.buffer"))
        #expect(python.contains("c.text_factory = bytes"))
        #expect(python.contains("out.write((v if isinstance(v, bytes) else str(v).encode(\"utf-8\")) + b\"\\n\")"))
        #expect(python.contains("except Exception as e:"))
        #expect(!python.contains("print("))
    }

    /// Python runs what the CLI runs: each text in the here-document that
    /// ends in `;` at a line end, without the CLI's dot-command lines.
    @Test func everyStatementSplitsWhereBothReadersSplitIt() throws {
        for query in Self.queries {
            let statements = OpenCodeProbe.statements(query)
            for statement in statements {
                let lines = statement.split(separator: "\n")
                #expect(!statement.contains(";"), "\(statement.prefix(60))")
                #expect(!lines.contains { $0.hasPrefix(".") }, "\(statement.prefix(60))")
            }
            let nonce = OpenCodeProbe.makeNonce()
            let sql = ScriptParts(OpenCodeProbe.script(query, nonce: nonce), nonce: nonce).sql
            let texts = (sql.joined(separator: "\n") + "\n").components(separatedBy: ";\n").map { text in
                text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix(".") }
                    .joined(separator: "\n")
            }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            var run = ["PRAGMA query_only = 1"]
            run += statements.prefix(1)
            run.append("BEGIN")
            run += statements.dropFirst()
            run.append("COMMIT")
            #expect(texts == run)
        }
    }

    /// Every poll uploads its whole script, every 2 seconds while the Agent
    /// works: the statements go once, for whichever reader runs, and the
    /// poll's window is built once.
    @Test func aPollScriptStaysSmall() throws {
        for query in Self.queries {
            guard case .poll = query.kind else { continue }
            let script = OpenCodeProbe.script(query, nonce: OpenCodeProbe.makeNonce())
            let text = String(decoding: script, as: UTF8.self)
            #expect(script.count <= 16_384, "\(script.count) bytes")
            #expect(text.ranges(of: "w AS (").count == 1)
            for statement in OpenCodeProbe.statements(query) {
                #expect(text.ranges(of: statement).count == 1, "\(statement.prefix(60))")
            }
        }
    }

    @Test func everyOpenIsReadOnly() throws {
        for query in Self.queries {
            let nonce = OpenCodeProbe.makeNonce()
            let script = String(decoding: OpenCodeProbe.script(query, nonce: nonce), as: UTF8.self)
            let parts = ScriptParts(OpenCodeProbe.script(query, nonce: nonce), nonce: nonce)
            let cli = try #require(parts.shell.first { $0.hasPrefix("    \"$sq\" ") })
            #expect(cli.contains(" -readonly "))
            let python = parts.python.joined(separator: "\n")
            #expect(python.contains("\"?mode=ro\""))
            #expect(python.contains("PRAGMA query_only = 1"))
            #expect(parts.sql.contains("PRAGMA query_only = 1;"))
            for forbidden in ["immutable", "mode=rw", "mode=rwc", "nolock"] {
                #expect(!script.contains(forbidden), "\(forbidden)")
            }
        }
    }

    /// A statement reaches a table through `FROM` or `JOIN`, or by name
    /// through `sqlite_master` or `pragma_table_info`; only the 1.x check
    /// and the layout check do the latter.
    @Test func everyStatementReadsOnlyTheFourTables() throws {
        let tables: Set<String> = ["session_v2", "session_message", "event_sequence", "session_inbox"]
        let sources: Set<String> = ["raw", "m", "items", "slim_items", "r", "w", "need", "json_each"]
        let refused: Set<String> = [
            "credential", "account", "control_account", "kv", "event", "message", "part", "session",
            "project",
        ]
        for query in Self.queries {
            for statement in OpenCodeProbe.statements(query) {
                let (code, literals) = Self.split(statement)
                let tokens = Self.tokens(in: code)
                for (index, token) in tokens.enumerated()
                where ["FROM", "JOIN"].contains(token.uppercased()) && index + 1 < tokens.count {
                    let source = tokens[index + 1]
                    #expect(
                        source == "(" || tables.contains(source) || sources.contains(source)
                            || source == "sqlite_master" || source == "pragma_table_info",
                        "reads \(source)")
                }
                for token in tokens {
                    #expect(!refused.contains(token.lowercased()), "names \(token)")
                }
                if tokens.contains("sqlite_master") {
                    // The 1.x tables are named only to tell an older store apart.
                    #expect(statement == OpenCodeProbe.tablesStatement)
                    #expect(
                        Set(literals).isSubset(of: ["T ", ",", "table", "session", "message", "part", "session_v2"]))
                }
                if tokens.contains("pragma_table_info") {
                    // `need(t, c)` pairs, then the line's tag and separators.
                    #expect(statement == OpenCodeProbe.layoutStatement)
                    let pairs = Array(literals.dropLast(3))
                    #expect(literals.suffix(3) == ["L ", ".", ","])
                    #expect(Set(stride(from: 0, to: pairs.count, by: 2).map { pairs[$0] }) == tables)
                }
            }
        }
    }

    /// The version, the 1.x table check and the layout check name no
    /// session; everything else is filtered on the one id.
    @Test func everyStatementIsBoundToTheSession() throws {
        let unbound = [
            OpenCodeProbe.versionStatement, OpenCodeProbe.tablesStatement, OpenCodeProbe.layoutStatement,
        ]
        for query in Self.queries {
            let statements = OpenCodeProbe.statements(query)
            #expect(Array(statements.prefix(3)) == unbound)
            for statement in statements.dropFirst(3) {
                #expect(statement.contains("'\(Self.session.rawValue)'"), "\(statement.prefix(60))")
            }
        }
    }

    @Test func noStatementWrites() throws {
        let writes: Set<String> = [
            "INSERT", "UPDATE", "DELETE", "REPLACE", "CREATE", "DROP", "ALTER", "ATTACH", "DETACH",
            "VACUUM", "REINDEX", "PRAGMA", "UPSERT", "TRUNCATE", "ANALYZE",
        ]
        for query in Self.queries {
            for statement in OpenCodeProbe.statements(query) {
                for token in Self.tokens(in: Self.split(statement).code) {
                    #expect(!writes.contains(token.uppercased()), "\(token)")
                }
            }
            // The only PRAGMA in the script is the one that forbids writes.
            let nonce = OpenCodeProbe.makeNonce()
            let parts = ScriptParts(OpenCodeProbe.script(query, nonce: nonce), nonce: nonce)
            #expect(
                parts.sql.filter { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("PRAGMA") }
                    == ["PRAGMA query_only = 1;"])
        }
    }

    /// SQLite 3.25 with JSON1 is the floor (ADR 0025).
    @Test func statementsAvoidSyntaxNewerThanTheFloor() throws {
        let newer: Set<String> = [
            "IIF", "FILTER", "NULLS", "RETURNING", "MATERIALIZED", "HAVING", "GROUPS", "EXCLUDE",
            "FORMAT", "UNIXEPOCH", "CONCAT", "CONCAT_WS", "STRING_AGG", "OCTET_LENGTH", "UNHEX",
            "TIMEDIFF", "JSON_PRETTY", "JSON_ERROR_POSITION", "RIGHT", "FULL", "DISTINCT",
        ]
        let aggregates: Set<String> = [
            "GROUP_CONCAT", "JSON_GROUP_ARRAY", "JSON_GROUP_OBJECT", "SUM", "COUNT", "MIN", "MAX",
            "AVG", "TOTAL",
        ]
        for query in Self.queries {
            for statement in OpenCodeProbe.statements(query) {
                let code = Self.split(statement).code
                #expect(!code.contains("->"))
                let tokens = Self.tokens(in: code)
                var calls: [String] = []
                for (index, token) in tokens.enumerated() {
                    let upper = token.uppercased()
                    #expect(!newer.contains(upper) && !upper.hasPrefix("JSONB"), "\(token)")
                    if token == "(" {
                        calls.append(index > 0 ? tokens[index - 1].uppercased() : "")
                    } else if token == ")" {
                        _ = calls.popLast()
                    } else if upper == "ORDER" {
                        // ORDER BY inside an aggregate's arguments is 3.44.
                        #expect(!aggregates.contains(calls.last ?? ""), "ORDER BY inside \(calls.last ?? "")")
                    }
                }
                #expect(calls.isEmpty, "unbalanced parentheses")
            }
        }
    }

    @Test func aStoreWithoutASideFileReadsAsClosedBeforeAnyReaderStarts() throws {
        let nonce = OpenCodeProbe.makeNonce()
        let shell = ScriptParts(OpenCodeProbe.script(Self.tail, nonce: nonce), nonce: nonce).shell
        let closed = try #require(
            shell.firstIndex(of: "elif [ ! -e \"$db-wal\" ] || [ ! -e \"$db-shm\" ]; then"))
        let readers = try #require(shell.firstIndex(of: "elif [ -n \"$sq$py\" ]; then"))
        #expect(shell[closed + 1] == "  printf 'P closed\\n'")
        #expect(closed < readers)

        let response = try Self.parse(["P closed", "W 1 0"])
        #expect(response == .unavailable(.storeClosed))
    }

    // MARK: Parse

    @Test func parsesRecordsBetweenTheNonceMarkers() throws {
        let nonce = OpenCodeProbe.makeNonce()
        let session = #"{"k":"session","id":"ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9","parent":null}"#
        let older = #"{"k":"row","id":"msg_a","type":"user","seq":7,"tc":1,"tu":3,"f":true,"d":{}}"#
        let newer = #"{"k":"row","id":"msg_b","type":"assistant","seq":9,"tc":2,"tu":5,"f":false,"d":{}}"#
        let inbox = #"{"k":"inbox","items":[],"more":0}"#
        let stray = OpenCodeProbe.makeNonce()
        let stdout = Data(
            """
            Last login: noise from a login shell
            \(OpenCodeProbe.beginMarker(nonce: stray))
            R {"k":"row","id":"msg_stray","seq":1}
            \(OpenCodeProbe.beginMarker(nonce: nonce))
            V 3.54.0
            E 12
            S \(session)
            R \(newer)
            R \(older)
            F 4
            I \(inbox)
            Z 0
            W 1 1

            \(OpenCodeProbe.endMarker(nonce: nonce))
            R {"k":"row","id":"msg_after","seq":99}

            """.utf8)
        let response = try OpenCodeProbe.parse(
            stdout: stdout, stderr: Data(), exitStatus: 0, nonce: nonce, query: Self.tail)
        guard case .records(let records) = response else {
            Issue.record("expected records, read \(response)")
            return
        }
        #expect(records.sqliteVersion == "3.54.0")
        #expect(records.eventSeq == 12)
        #expect(records.sessionLine == Data(session.utf8))
        #expect(records.inboxLine == Data(inbox.utf8))
        #expect(records.rows.map(\.id) == ["msg_a", "msg_b"])
        #expect(records.rows.map(\.seq) == [7, 9])
        #expect(records.rows.map(\.timeUpdated) == [3, 5])
        #expect(records.rows.map(\.isFinal) == [true, false])
        #expect(records.rows.map(\.line) == [Data(older.utf8), Data(newer.utf8)])
        #expect(records.firstSeq == 4)
        #expect(records.windowCount == nil)
        #expect(!records.overflow)
        #expect(records.ignoredLines == 0)

        for cut in [
            Data("\(OpenCodeProbe.beginMarker(nonce: nonce))\nV 3.54.0\nZ 0\n".utf8),
            Data("V 3.54.0\n\n\(OpenCodeProbe.endMarker(nonce: nonce))\n".utf8),
            Data("\(OpenCodeProbe.beginMarker(nonce: stray))\nZ 0\n\n\(OpenCodeProbe.endMarker(nonce: stray))\n".utf8),
        ] {
            #expect(throws: TransportError.malformedResponse(
                "OpenCode's store query stopped before its end (exit status 137)")
            ) {
                try OpenCodeProbe.parse(stdout: cut, stderr: Data(), exitStatus: 137, nonce: nonce, query: Self.tail)
            }
        }
    }

    @Test func blankAndUntaggedLinesAreIgnoredAndCounted() throws {
        let response = try Self.parse([
            "V 3.54.0", "", "Last login: noise", "R {\"k\":\"row\",\"id\":", "E twelve", "Q 1", "X extra",
            "M extra", "E 12", "Z 0", "W 1 1",
        ])
        guard case .records(let records) = response else {
            Issue.record("expected records, read \(response)")
            return
        }
        #expect(records.ignoredLines == 7)
        #expect(records.eventSeq == 12)
        #expect(records.rows.isEmpty)
        #expect(!records.overflow)
    }

    /// A Python built without SQLite has no `sqlite3` module. The import
    /// sits inside the reader's `try`, so its failure arrives in the CLI's
    /// form and reads as no reader, as no Python at all does.
    @Test func aPythonWithoutItsSQLiteModuleIsNoReader() throws {
        let nonce = OpenCodeProbe.makeNonce()
        let python = ScriptParts(OpenCodeProbe.script(Self.tail, nonce: nonce), nonce: nonce).python
        let opening = try #require(python.firstIndex(of: "try:"))
        #expect(python.filter { $0.contains("sqlite3") && $0.contains("import") } == ["    import sqlite3"])
        #expect(python.firstIndex(of: "    import sqlite3") == opening + 1)
        #expect(
            try Self.parse(["Z 1", "W 1 1"], stderr: "Error: ModuleNotFoundError: No module named '_sqlite3'\n")
                == .unavailable(.noReader))
    }

    /// SQLite writes a lone surrogate escape (`\ud83d`, as OpenCode stores a
    /// line its read tool cut inside an emoji) as bytes that are not UTF-8.
    /// The session, row and inbox lines keep the rest of their text.
    @Test func textThatIsNotUTF8ReadsAsReplacementCharacters() throws {
        let nonce = OpenCodeProbe.makeNonce()
        let surrogate = Data([0xED, 0xA0, 0xBD])
        var stdout = Data("\(OpenCodeProbe.beginMarker(nonce: nonce))\nV 3.54.0\nE 12\n".utf8)
        stdout += Data(#"S {"k":"session","id":"ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9","title":"cut "#.utf8)
        stdout += surrogate + Data("\"}\n".utf8)
        stdout += Data(#"R {"k":"row","id":"msg_a","type":"assistant","seq":7,"tc":1,"tu":3,"f":true,"#.utf8)
        stdout += Data(#""d":{"content":[{"_i":0,"type":"text","text":"before "#.utf8)
        stdout += surrogate + Data(#" after","n":14}]}}"#.utf8) + Data("\n".utf8)
        stdout += Data(#"I {"k":"inbox","items":[{"id":"msg_b","type":"user","seq":9,"text":"queued "#.utf8)
        stdout += surrogate + Data(#""}],"more":0}"#.utf8) + Data("\n".utf8)
        stdout += Data("Z 0\nW 1 1\n\n\(OpenCodeProbe.endMarker(nonce: nonce))\n".utf8)

        let response = try OpenCodeProbe.parse(
            stdout: stdout, stderr: Data(), exitStatus: 0, nonce: nonce, query: Self.tail)
        guard case .records(let records) = response else {
            Issue.record("expected records, read \(response)")
            return
        }
        #expect(records.ignoredLines == 0)
        let replaced = "\u{FFFD}\u{FFFD}\u{FFFD}"
        guard case .session(let session) = OpenCodeLine(try #require(records.sessionLine)),
            case .row(let row) = OpenCodeLine(try #require(records.rows.first?.line)),
            case .assistant(let step) = row.content, case .text(let text) = step.items.first?.kind,
            case .inbox(let inbox) = OpenCodeLine(try #require(records.inboxLine))
        else {
            Issue.record("a line did not decode")
            return
        }
        #expect(session.title == "cut \(replaced)")
        #expect(text.text == "before \(replaced) after")
        #expect(inbox.items.first?.text == "queued \(replaced)")
    }

    /// `head -c` cut the reader's output, its exit line with it: the poll
    /// reads the tail instead.
    @Test func aMissingExitLineIsAnOverflow() throws {
        let read = ["V 3.54.0", "E 12", #"R {"k":"row","id":"msg_a","type":"user","seq":7,"tu":3,"f":true,"d":{}}"#]
        let readBytes = read.map { $0.utf8.count + 1 }.reduce(0, +)
        let row = #"R {"k":"row","id":"msg_b","type":"assistant","seq":9,"tu":5,"f":true,"d":{"t":""#
        let filler = OpenCodeProbe.outputCap - readBytes - row.utf8.count
        // Cut inside a row, so the script's `W` line joins it; and cut at
        // the end of a line.
        let cutInsideARow = read + [row + String(repeating: "x", count: filler) + "W 1 1"]
        let cutAtALineEnd = read + [row + String(repeating: "x", count: filler - 4) + #""}}"#, "W 1 1"]
        for (lines, rows, ignored) in [(cutInsideARow, [Int64(7)], 1), (cutAtALineEnd, [7, 9], 0)] {
            let response = try Self.parse(lines)
            guard case .records(let records) = response else {
                Issue.record("expected records, read \(response)")
                continue
            }
            #expect(records.overflow)
            #expect(records.rows.map(\.seq) == rows)
            #expect(records.ignoredLines == ignored)
        }
    }

    /// Short of the cap, the reader's output always ends with its exit
    /// line. Without it the script went wrong: BusyBox's `tr -c '[:print:]'`
    /// once turned a missing store's line into this.
    @Test func aMissingExitLineShortOfTheCapIsMalformed() throws {
        let malformed = TransportError.malformedResponse(
            "OpenCode's store query printed no exit status (exit status 0)")
        #expect(throws: malformed) { try Self.parse(["??n?????????????????r???p?n?????????p?n???????", "W 0 0"]) }
        #expect(throws: malformed) {
            try Self.parse(["V 3.54.0", "E 12", #"R {"k":"row","id":"msg_b","type":"assistant","se"#])
        }
    }

    /// The missing store's path reaches the line as printable ASCII through
    /// a byte range: BusyBox's `tr` has no character classes in a
    /// complement.
    @Test func theMissingStorePathPrintsThroughAByteRange() throws {
        let nonce = OpenCodeProbe.makeNonce()
        let shell = ScriptParts(OpenCodeProbe.script(Self.tail, nonce: nonce), nonce: nonce).shell
        #expect(shell.contains("  printf 'P nodb %s\\n' \"$p\" | tr -c ' -~\\n' '?'"))
        #expect(!shell.contains { $0.contains("[:") })
    }

    /// The reader's last error line, read with the side files the script
    /// saw.
    @Test(arguments: [
        (
            ReaderFailure("Parse error near line 9: no such column: data"),
            ReaderFailureReading.problem(.layout(missing: ["data"]))
        ),
        (ReaderFailure("Runtime error near line 9: database is locked (5)"), .unreadable("OpenCode's database is busy.")),
        (ReaderFailure("Parse error near line 4: no such function: json_object"), .problem(.readerTooOld("3.54.0"))),
        (
            ReaderFailure("Error: near line 7: a GROUP BY clause is required before HAVING"),
            .problem(.readerTooOld("3.54.0"))
        ),
        (ReaderFailure("Error: unable to open database file", sideFiles: false), .problem(.storeClosed)),
        (
            ReaderFailure("Error: unable to open database file"),
            .unreadable("OpenCode's database couldn't be opened.")
        ),
        (ReaderFailure("Error: OperationalError: database is locked"), .unreadable("OpenCode's database is busy.")),
        (ReaderFailure("Error: OperationalError: parser stack overflow"), .problem(.readerTooOld("3.54.0"))),
        (ReaderFailure("Parse error near line 12: parser stack overflow"), .problem(.readerTooOld("3.54.0"))),
        (ReaderFailure("Error: ModuleNotFoundError: No module named '_sqlite3'"), .problem(.noReader)),
        (
            ReaderFailure("Error: ImportError: libsqlite3.so.0: cannot open shared object file: No such file or directory"),
            .problem(.noReader)
        ),
    ])
    func classifiesReaderErrors(stderr: ReaderFailure, expected: ReaderFailureReading) throws {
        let sideFiles = stderr.sideFiles ? "W 1 1" : "W 0 0"
        do {
            let response = try Self.parse(["V 3.54.0", "E 12", "Z 1", sideFiles], stderr: stderr.text)
            guard case .unavailable(let problem) = response else {
                Issue.record("unexpected \(response)")
                return
            }
            #expect(.problem(problem) == expected)
        } catch let error as TransportError {
            guard case .hostStoreUnreadable(let detail) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(.unreadable(detail) == expected)
        }
    }

    @Test func anUnexplainedReaderFailureShowsItsLineWithoutTheAccountName() throws {
        let stderr = "Error: disk I/O error reading /Users/someone/.local/share/opencode/opencode.db\n"
        #expect(
            throws: TransportError.hostStoreUnreadable(
                detail: "Error: disk I/O error reading ~/.local/share/opencode/opencode.db")
        ) {
            try Self.parse(["V 3.54.0", "Z 1", "W 1 1"], stderr: "warning: noise\n" + stderr)
        }
        #expect(throws: TransportError.hostStoreUnreadable(detail: "OpenCode's database reader exited with status 2.")) {
            try Self.parse(["V 3.54.0", "Z 2", "W 1 1"])
        }
        let long = String(repeating: "x", count: 300)
        do {
            _ = try Self.parse(["V 3.54.0", "Z 1", "W 1 1"], stderr: "Error: \(long)")
            Issue.record("expected a failure")
        } catch TransportError.hostStoreUnreadable(let detail) {
            #expect(detail.count == 200)
            #expect(detail.hasSuffix("…"))
        }
    }

    @Test func theStoreProblemWinsOverTheErrorItCaused() throws {
        #expect(
            try Self.parse(
                ["V 3.54.0", "L session_message.data,session_inbox.delivery", "E 12", "Z 1", "W 1 1"],
                stderr: "Parse error near line 9: no such column: data")
                == .unavailable(.layout(missing: ["session_message.data", "session_inbox.delivery"])))
        #expect(
            try Self.parse(
                ["V 3.54.0", "T session,message,part", "Z 1", "W 1 1"],
                stderr: "Parse error near line 31: no such table: event_sequence")
                == .unavailable(.olderOpenCode))
    }

    @Test func anOldSQLiteIsTooOld() throws {
        #expect(
            try Self.parse(["V 3.24.0", "Z 1", "W 1 1"], stderr: "Parse error near line 5: near \"(\": syntax error")
                == .unavailable(.readerTooOld("3.24.0")))
        #expect(try Self.parse(["V 2.8.17", "Z 0", "W 1 1"]) == .unavailable(.readerTooOld("2.8.17")))
        guard case .records(let records) = try Self.parse(["V 3.25.0", "E 12", "Z 0", "W 1 1"]) else {
            Issue.record("3.25 is the floor, not below it")
            return
        }
        #expect(records.sqliteVersion == "3.25.0")
    }

    @Test func nodbAndNoReaderAreProblems() throws {
        #expect(
            try Self.parse(["P nodb ~/.local/share/opencode/opencode.db", "W 0 0"])
                == .unavailable(.noStore(path: "~/.local/share/opencode/opencode.db")))
        #expect(
            try Self.parse(["P nodb /srv/data/opencode/opencode.db", "W 0 0"])
                == .unavailable(.noStore(path: "/srv/data/opencode/opencode.db")))
        #expect(try Self.parse(["P noreader", "W 1 1"]) == .unavailable(.noReader))
    }

    @Test func aMissingSessionNamesOtherStores() throws {
        #expect(
            try Self.parse(["V 3.54.0", "E ", "M", "Z 0", "W 1 1", "O opencode-beta.db notes.db opencode-.db opencode-dev_2.db"])
                == .sessionMissing(otherStores: ["opencode-beta.db", "opencode-dev_2.db"]))
        #expect(try Self.parse(["V 3.54.0", "E ", "M", "Z 0", "W 1 1"]) == .sessionMissing(otherStores: []))
    }

    @Test func loginShellNoiseOnStderrIsIgnoredOnSuccess() throws {
        let response = try Self.parse(
            ["V 3.54.0", "E 12", "Z 0", "W 1 1"],
            stderr: "bash: warning: setlocale: LC_ALL: cannot change locale\nError: unable to open database file\n")
        guard case .records(let records) = response else {
            Issue.record("expected records, read \(response)")
            return
        }
        #expect(records.eventSeq == 12)
    }

    @Test func anUnchangedCounterReadsAsUnchangedOnlyForAPoll() throws {
        guard case .records = try Self.parse(["V 3.54.0", "E 12", "Z 0", "W 1 1"]) else {
            Issue.record("a tail always reads records")
            return
        }
        let cursor = OpenCodePollCursor(
            eventSeq: 12, lowSeq: 4, highSeq: 12, knownInWindow: 3, openRows: [], updatedSince: 0,
            budget: 1_048_576)
        let poll = OpenCodeQuery(session: Self.session, kind: .poll(cursor))
        #expect(try Self.parse(["V 3.54.0", "E 12", "Z 0", "W 1 1"], query: poll) == .unchanged(eventSeq: 12))
        guard case .records = try Self.parse(["V 3.54.0", "E 13", "Z 0", "W 1 1"], query: poll) else {
            Issue.record("a moved counter reads records")
            return
        }
        var unread = cursor
        unread.eventSeq = nil
        guard case .records = try Self.parse(["V 3.54.0", "E 12", "Z 0", "W 1 1"], query: OpenCodeQuery(
            session: Self.session, kind: .poll(unread)))
        else {
            Issue.record("a cursor without a counter always reads records")
            return
        }
    }

    // MARK: Helpers

    static let session = OpenCodeSessionID("ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9")!
    static let tail = OpenCodeQuery(session: session, kind: .tail(budget: 524_288))

    /// One query of each kind.
    static let queries = [
        tail,
        OpenCodeQuery(session: session, kind: .poll(OpenCodePollCursor(
            eventSeq: 12, lowSeq: 4, highSeq: 12, knownInWindow: 3, openRows: [7, 9], updatedSince: 1_800_000_000_000,
            budget: 1_048_576))),
        OpenCodeQuery(session: session, kind: .poll(OpenCodePollCursor(
            eventSeq: nil, lowSeq: 4, highSeq: 12, knownInWindow: 3, openRows: [], updatedSince: 0,
            budget: 1_048_576))),
        OpenCodeQuery(session: session, kind: .older(before: 40, budget: 524_288)),
        OpenCodeQuery(session: session, kind: .row(seq: 7, outputLimit: 262_144)),
    ]

    /// Parses `lines` printed between the markers, the way the script
    /// prints them: `terminated` adds the newline `head -c` may have cut.
    static func parse(
        _ lines: [String], stderr: String = "", query: OpenCodeQuery = tail, terminated: Bool = true
    ) throws -> OpenCodeQueryResponse {
        let nonce = OpenCodeProbe.makeNonce()
        let body = lines.joined(separator: "\n") + (terminated ? "\n" : "")
        let stdout = Data(
            "\(OpenCodeProbe.beginMarker(nonce: nonce))\n\(body)\n\(OpenCodeProbe.endMarker(nonce: nonce))\n".utf8)
        return try OpenCodeProbe.parse(
            stdout: stdout, stderr: Data(stderr.utf8), exitStatus: 0, nonce: nonce, query: query)
    }

    /// Variables the shell expands outside any quotes.
    static func unquotedVariables(in shell: String) -> Set<String> {
        var names: Set<String> = []
        var quote: Character?
        let characters = Array(shell)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "$", index + 1 < characters.count {
                var next = index + 1
                if characters[next] == "{" { next += 1 }
                var name = ""
                while next < characters.count, characters[next].isLetter || characters[next].isNumber
                    || characters[next] == "_"
                {
                    name.append(characters[next])
                    next += 1
                }
                if name.isEmpty, characters[index + 1] != "(" {
                    name = String(characters[index + 1])
                }
                if !name.isEmpty { names.insert(name) }
            }
            index += 1
        }
        return names
    }

    /// A statement's text without its string literals, and the literals.
    static func split(_ statement: String) -> (code: String, literals: [String]) {
        var code = ""
        var literals: [String] = []
        var literal: String?
        for character in statement {
            if var open = literal {
                if character == "'" {
                    literals.append(open)
                    literal = nil
                    code.append("''")
                } else {
                    open.append(character)
                    literal = open
                }
            } else if character == "'" {
                literal = ""
            } else {
                code.append(character)
            }
        }
        return (code, literals)
    }

    /// Identifiers, and parentheses as tokens of their own.
    static func tokens(in code: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for character in code {
            if character.isASCII, character.isLetter || character.isNumber || character == "_" {
                word.append(character)
                continue
            }
            if !word.isEmpty {
                tokens.append(word)
                word = ""
            }
            if character == "(" || character == ")" {
                tokens.append(String(character))
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens.filter { !($0.first?.isNumber ?? false) }
    }
}

/// The script's lines outside its here-document and Python's program, the
/// here-document's SQL, and the program.
private struct ScriptParts {
    var shell: [String] = []
    var sql: [String] = []
    var python: [String] = []

    /// The here-document's lines go to `sql`; the program in single quotes
    /// after Python's `-c` goes to `python`, the quote lines staying shell.
    init(_ script: Data, nonce: String) {
        let sqlDelimiter = "__HEELER_SQL_\(nonce)__"
        var body: WritableKeyPath<ScriptParts, [String]>?
        for line in String(decoding: script, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if let current = body {
                if current == \.sql ? line == sqlDelimiter : line.hasPrefix("' ") {
                    body = nil
                    shell.append(line)
                } else {
                    self[keyPath: current].append(line)
                }
                continue
            }
            shell.append(line)
            if line.hasSuffix("<<'\(sqlDelimiter)'") {
                body = \.sql
            } else if line.hasSuffix(" -c '") {
                body = \.python
            }
        }
    }
}

extension OpenCodeProbeTests {
    /// A reader's stderr, and whether the script found the side files.
    struct ReaderFailure: Sendable, CustomTestStringConvertible {
        var text: String
        var sideFiles: Bool

        init(_ text: String, sideFiles: Bool = true) {
            self.text = text
            self.sideFiles = sideFiles
        }

        var testDescription: String { sideFiles ? text : "\(text), no side files" }
    }

    enum ReaderFailureReading: Equatable, Sendable {
        case problem(OpenCodeStoreProblem)
        /// `TransportError.hostStoreUnreadable` with this detail.
        case unreadable(String)
    }
}
