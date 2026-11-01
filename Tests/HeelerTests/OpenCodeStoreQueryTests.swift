import Foundation
import Testing

@testable import Heeler

/// `OpenCodeProbe.statements(_:)` against real SQLite: scratch stores built
/// from `ChatFixtures/opencode`, read in process the way the Host's
/// `sqlite3` reads them (`OpenCodeSQLiteHarness`).
@Suite("OpenCode store queries")
struct OpenCodeStoreQueryTests {
    // MARK: The schemas OpenCode itself made

    /// `host-evidence/opencode/schema-*.sql` came from real stores of these versions
    /// (ADR 0034), with no real provider's rows. The queries run against them, on
    /// captured rows of OpenCode 2.0.32's shape.
    @Test(arguments: ["2.2.5", "2.0.32"])
    func theQueriesRunAgainstARecordedSchema(_ version: String) throws {
        let schema = try ChatFixture.text("host-evidence/opencode/schema-\(version).sql")
        let fixture = try OpenCodeStoreFixture.named("pong")
        let session = try #require(fixture.sessionID)
        let harness = try OpenCodeSQLiteHarness(fixture, schema: schema)

        let tail = try harness.records(Self.tail(session))
        #expect(tail.rows.map(\.seq) == fixture.rows.map(\.seq))
        let cursor = try Self.cursor(after: tail)
        #expect(try harness.response(OpenCodeQuery(session: session, kind: .poll(cursor))) == .unchanged(eventSeq: 12))
        let other = try #require(OpenCodeSessionID("ses_e6a000000001Abcdefghijklmn"))
        #expect(
            try harness.response(OpenCodeQuery(session: other, kind: .tail(budget: 1024)))
                == .sessionMissing(otherStores: []))
    }

    // MARK: Recent sessions in a directory

    /// Chat's candidate list (ADR 0034), against what OpenCode's own stores hold.
    @Test(arguments: ["2.2.5", "2.0.32"])
    func recentSessionsAreTheDirectorysRootsNewestFirst(_ version: String) throws {
        let schema = try ChatFixture.text("host-evidence/opencode/schema-\(version).sql")
        let fixture = try OpenCodeStoreFixture.named("pong")
        let harness = try OpenCodeSQLiteHarness(fixture, schema: schema)
        let directory = "/work/it's \"odd\"; app"
        func add(_ id: String, directory: String, updated: Int64, parent: String? = nil) throws {
            var row = fixture.session
            row["id"] = .text(id)
            row["slug"] = .text(id)
            row["directory"] = .text(directory)
            row["time_updated"] = .integer(updated)
            row["parent_id"] = parent.map(OpenCodeColumnValue.text) ?? .null
            try harness.insert(into: "session_v2", row)
        }
        try add("ses_e6a000000001Abcdefghijklmn", directory: directory, updated: 100)
        try add("ses_e6a000000002Abcdefghijklmn", directory: directory, updated: 300)
        try add("ses_e6a000000003Abcdefghijklmn", directory: directory, updated: 200)
        try add("ses_e6a000000004Abcdefghijklmn", directory: directory, updated: 400, parent: "ses_e6a000000001Abcdefghijklmn")
        try add("ses_e6a000000005Abcdefghijklmn", directory: "/work/other", updated: 500)

        let query = OpenCodeQuery(session: nil, kind: .recentSessions(directory: directory, limit: 2))
        let rows = try harness.records(query).recentSessions

        #expect(rows.map(\.id) == ["ses_e6a000000002Abcdefghijklmn", "ses_e6a000000003Abcdefghijklmn"])
        #expect(rows.map(\.updated) == [300, 200])
        #expect(rows.first?.title == "Pong")
    }

    @Test func recentSessionsParseOnTheParserStackOfOlderSQLite() throws {
        let harness = try OpenCodeSQLiteHarness(scenario: "pong")
        let query = OpenCodeQuery(session: nil, kind: .recentSessions(directory: "/work/app", limit: 12))
        for statement in OpenCodeProbe.statements(query) {
            #expect(
                harness.prepareFailure(statement, parserStack: OpenCodeSQLiteHarness.fixedParserStack) == nil,
                "\(statement.prefix(60))")
        }
    }

    // MARK: Tail, poll and older pages

    @Test func aTailReadsTheNewestRowsWithinItsBudget() throws {
        let (harness, session) = try Self.store("undo-before")
        let all = try harness.records(Self.tail(session))
        #expect(all.rows.map(\.seq) == [4, 7, 12, 15, 16, 23, 27, 28, 33, 38])
        #expect(all.firstSeq == 4)
        #expect(all.eventSeq == 39)

        // Exactly the newest three rows' data: the fourth would start past
        // the budget. One byte more lets it in.
        let newest = try all.rows.suffix(3).map(Self.dataLength).reduce(0, +)
        let three = try harness.records(Self.tail(session, budget: newest))
        #expect(three.rows.map(\.seq) == [28, 33, 38])
        #expect(three.firstSeq == 4)
        #expect(try harness.records(Self.tail(session, budget: newest + 1)).rows.map(\.seq) == [27, 28, 33, 38])
    }

    @Test func aTailAlwaysIncludesTheNewestRow() throws {
        let (harness, session) = try Self.store("patch")
        let records = try harness.records(Self.tail(session, budget: 1))
        #expect(records.rows.map(\.seq) == [124])
        #expect(records.firstSeq == 91)
        #expect(!records.overflow)
    }

    @Test func aPollWithAnUnchangedCounterPrintsOnlyTheCounter() throws {
        let (harness, session) = try Self.store("pong")
        let cursor = try Self.cursor(after: harness.records(Self.tail(session)))
        #expect(cursor.eventSeq == 12)
        let poll = OpenCodeQuery(session: session, kind: .poll(cursor))
        #expect(try harness.response(poll) == .unchanged(eventSeq: 12))
        let lines = harness.lines(poll)
        #expect(lines.first?.hasPrefix("V 3.") == true)
        #expect(Array(lines.dropFirst()) == ["E 12", "Z 0", "W 1 1"])
    }

    /// The cursor comes from the store while a steer waits; the poll reads
    /// the store after the turn ended.
    @Test func aPollReadsNewAndOpenRowsAndTheWindowCount() throws {
        let (queued, session) = try Self.store("steer-queued")
        let cursor = try Self.cursor(after: queued.records(Self.tail(session)))
        #expect(cursor.openRows == [177])
        let (finished, _) = try Self.store("steer")

        let records = try finished.records(OpenCodeQuery(session: session, kind: .poll(cursor)))
        #expect(records.rows.map(\.seq) == [177, 187, 188, 193])
        #expect(records.rows.map(\.isFinal) == [true, true, true, true])
        #expect(records.windowCount == 2)
        #expect(records.firstSeq == 176)
        #expect(records.eventSeq == 194)
        let sessionLine = try Self.object(#require(records.sessionLine))
        #expect(sessionLine["id"] as? String == session.rawValue)
        let inbox = try Self.object(#require(records.inboxLine))
        #expect((inbox["items"] as? [Any])?.isEmpty == true)

        // Rows updated since the last read come back; without any, only
        // rows past the window do.
        var sinceStart = cursor
        sinceStart.updatedSince = 0
        #expect(
            try finished.records(OpenCodeQuery(session: session, kind: .poll(sinceStart))).rows.map(\.seq)
                == [176, 177, 187, 188, 193])
        var newOnly = cursor
        newOnly.openRows = []
        newOnly.updatedSince = .max
        #expect(
            try finished.records(OpenCodeQuery(session: session, kind: .poll(newOnly))).rows.map(\.seq)
                == [187, 188, 193])
    }

    /// A poll prints the rows that start inside its budget, oldest first,
    /// and one `X` for the rows it leaves out, which reads as an overflow.
    @Test func aPollPastItsBudgetMarksTheRowsLeftOut() throws {
        let (queued, session) = try Self.store("steer-queued")
        var cursor = try Self.cursor(after: queued.records(Self.tail(session)))
        let (finished, _) = try Self.store("steer")
        let whole = try finished.records(OpenCodeQuery(session: session, kind: .poll(cursor)))
        #expect(whole.rows.map(\.seq) == [177, 187, 188, 193])
        #expect(!whole.overflow)

        // The third row would start past the budget. One byte more lets it in.
        cursor.budget = try whole.rows.prefix(2).map(Self.dataLength).reduce(0, +)
        let poll = OpenCodeQuery(session: session, kind: .poll(cursor))
        let cut = try finished.records(poll)
        #expect(cut.rows.map(\.seq) == [177, 187])
        #expect(cut.overflow)
        #expect(finished.lines(poll).filter { $0 == "X" }.count == 1)
        cursor.budget += 1
        let more = try finished.records(OpenCodeQuery(session: session, kind: .poll(cursor)))
        #expect(more.rows.map(\.seq) == [177, 187, 188])
        #expect(more.overflow)
    }

    /// The cursor comes from the store before `/undo`. A staged revert keeps
    /// its rows and names its boundary; committed, the window counts fewer.
    @Test func aRevertCommitShowsAsAShorterWindow() throws {
        let (before, session) = try Self.store("undo-before")
        let cursor = try Self.cursor(after: before.records(Self.tail(session)))
        #expect(cursor.knownInWindow == 10)
        let poll = OpenCodeQuery(session: session, kind: .poll(cursor))
        #expect(try before.response(poll) == .unchanged(eventSeq: 39))

        let (staged, _) = try Self.store("undo-staged")
        let stagedRead = try staged.records(poll)
        #expect(stagedRead.windowCount == 10)
        let stagedSession = try Self.object(#require(stagedRead.sessionLine))
        #expect(stagedSession["revertMessage"] as? String == "msg_0a1b2c3d4e70LMbLuB1pGKgZbA")
        #expect(stagedSession["revertSeq"] as? Int == 27)
        #expect(stagedSession["revertFiles"] as? Int == 0)

        let (committed, _) = try Self.store("undo-committed")
        let committedRead = try committed.records(poll)
        #expect(committedRead.windowCount == 6)
        #expect(committedRead.rows.map(\.seq) == [45, 46, 51])
        let committedSession = try Self.object(#require(committedRead.sessionLine))
        #expect(committedSession["revertMessage"] is NSNull)
    }

    @Test func olderPagesReadBelowTheWindowOldestFirst() throws {
        let (harness, session) = try Self.store("undo-before")
        let older = try harness.records(OpenCodeQuery(session: session, kind: .older(before: 27, budget: 524_288)))
        #expect(older.rows.map(\.seq) == [4, 7, 12, 15, 16, 23])
        #expect(older.firstSeq == 4)
        #expect(older.sessionLine == nil)
        #expect(older.inboxLine == nil)

        let lastTwo = try older.rows.suffix(2).map(Self.dataLength).reduce(0, +)
        let page = try harness.records(OpenCodeQuery(session: session, kind: .older(before: 27, budget: lastTwo)))
        #expect(page.rows.map(\.seq) == [16, 23])
    }

    // MARK: Slim rows

    @Test func slimRowsDropProviderStateSnapshotsAndDiagnostics() throws {
        let (harness, session) = try Self.store("pong")
        try Self.insertRow(harness, session, seq: 20, type: "assistant", data: #"""
            {"time":{"created":1800000100000,"completed":1800000100500},"agent":"build",
             "providerState":{"opaque":"provider-state-marker"},"snapshot":"snapshot-marker",
             "content":[{"type":"tool","id":"call_slim","name":"edit",
               "state":{"status":"completed","input":{"filePath":"a.swift"},
                 "metadata":{"diagnostics":{"a.swift":[{"message":"diagnostic-marker"}]},
                   "preview":"preview-marker","output":"metadata-output-marker","loaded":["loaded-marker"],
                   "diff":"@@ -1 +1 @@\n-a\n+b\n",
                   "filediff":{"file":"a.swift","before":"filediff-before-marker","after":"filediff-after-marker",
                     "additions":1,"deletions":1},
                   "files":[{"relativePath":"a.swift","filePath":"/home/dev/a.swift","type":"update",
                     "before":"files-before-marker","after":"files-after-marker","patch":"@@ -1 +1 @@",
                     "additions":1,"deletions":1}]},
                 "content":[{"type":"text","text":"Edit applied."}]},
               "time":{"created":1800000100100,"completed":1800000100400}}]}
            """#)
        try Self.insertRow(harness, session, seq: 21, type: "user", data: #"""
            {"text":"What is in this picture?","agents":[],"time":{"created":1800000100600},
             "files":[{"name":"shot.png","mime":"image/png","mention":false,
               "data":"data:image/png;base64,ZmlsZS1ieXRlcy1tYXJrZXI="}]}
            """#)

        let query = Self.tail(session)
        let stdout = String(decoding: harness.output(query).stdout, as: UTF8.self)
        for marker in [
            "provider-state-marker", "snapshot-marker", "diagnostic-marker", "preview-marker",
            "metadata-output-marker", "loaded-marker", "filediff-before-marker", "filediff-after-marker",
            "files-before-marker", "files-after-marker", "ZmlsZS1ieXRlcy1tYXJrZXI=",
        ] {
            #expect(!stdout.contains(marker), "\(marker) reached the output")
        }

        let records = try harness.records(query)
        let step = try Self.data(#require(records.rows.first { $0.seq == 20 }))
        #expect(step["providerState"] == nil)
        #expect(step["snapshot"] == nil)
        #expect(step["agent"] as? String == "build")
        let tool = try Self.firstItem(of: step)
        #expect(tool["out"] as? String == "Edit applied.")
        #expect(tool["outN"] as? Int == 13)
        let meta = try #require(tool["meta"] as? [String: Any])
        #expect(Set(meta.keys) == ["diff", "filediff", "files"])
        #expect(meta["diff"] as? String == "@@ -1 +1 @@\n-a\n+b\n")
        #expect(meta["filediff"] as? NSDictionary == ["file": "a.swift", "additions": 1, "deletions": 1])
        #expect(
            meta["files"] as? NSArray == [
                ["file": "a.swift", "status": "update", "additions": 1, "deletions": 1, "patch": "@@ -1 +1 @@"]
                    as [String: Any]
            ])

        let user = try Self.data(#require(records.rows.first { $0.seq == 21 }))
        #expect(user["text"] as? String == "What is in this picture?")
        // `json_extract` reads a JSON boolean as 0 or 1.
        #expect(
            user["files"] as? NSArray == [["name": "shot.png", "mime": "image/png", "mention": 0] as [String: Any]])
    }

    @Test func slimToolItemsKeepWhatRowsShow() throws {
        // A completed read: its input, metadata and the start of its output.
        let read = try Self.toolItem(in: "approve", seq: 61, index: 1)
        #expect(read["id"] as? String == "call_0VAXHql8yFlIn5m43w3Efn46")
        #expect(read["name"] as? String == "read")
        #expect(read["status"] as? String == "completed")
        #expect(((read["input"] as? [String: Any])?["path"] as? String)?.hasSuffix("/project/.env") == true)
        #expect(read["error"] is NSNull)
        #expect(read["meta"] as? NSDictionary == ["truncated": false])
        #expect((read["out"] as? String)?.hasPrefix("Read file ") == true)
        #expect(read["outN"] as? Int == 100)

        // An interrupted shell command: its error and shell, and no output.
        let shell = try Self.toolItem(in: "esc-stop", seq: 150, index: 1)
        #expect(shell["name"] as? String == "shell")
        #expect(shell["status"] as? String == "error")
        #expect(shell["error"] as? NSDictionary == ["type": "aborted", "message": "Tool execution interrupted"])
        #expect(((shell["meta"] as? [String: Any])?["shellID"] as? String)?.hasPrefix("sh_") == true)
        #expect(shell["out"] is NSNull)
        #expect(shell["outN"] is NSNull)

        // A subagent: the child session it ran.
        let subagent = try Self.toolItem(in: "subagent", seq: 17, index: 0)
        #expect((subagent["meta"] as? [String: Any])?["sessionID"] as? String == "ses_0a1b2c3d4e10fn1YIRc07x6WEB")
        #expect(subagent["outN"] as? Int == 85)

        // A question still waiting, on a row that is still open.
        let (blocked, session) = try Self.store("question-blocked")
        let row = try #require(blocked.records(Self.tail(session)).rows.first { $0.seq == 108 })
        #expect(!row.isFinal)
        let question = try Self.firstItem(of: Self.data(row))
        #expect(question["name"] as? String == "question")
        #expect(question["status"] as? String == "running")
        let questions = (question["input"] as? [String: Any])?["questions"] as? [[String: Any]]
        #expect(questions?.first?["question"] as? String == "Which do you prefer, red or blue?")
        #expect(question["meta"] as? NSDictionary == [:])
    }

    /// OpenCode 2.0.32 keeps a shell-mode command's output as an object with
    /// its text, cursor, size and truncation; the slim row keeps the text.
    /// The fixtures' plain string output reads as it is.
    @Test func aShellRowKeepsItsOutputText() throws {
        let (harness, session) = try Self.store("pong")
        try Self.insertRow(harness, session, seq: 20, type: "shell", data: #"""
            {"metadata":{"background":true},"time":{"created":1800000100000,"completed":1800000100050},
             "shellID":"sh_0a1b2c3d4e60Q1w2E3r4T5y6U7","command":"ls","status":"exited","exit":0,
             "output":{"output":"README.md\nnotes.txt\n","cursor":20,"size":20,"truncated":false}}
            """#)

        let shell = try Self.data(#require(harness.records(Self.tail(session)).rows.first { $0.seq == 20 }))
        #expect(shell["command"] as? String == "ls")
        #expect(shell["output"] as? String == "README.md\nnotes.txt\n")
        #expect(shell["n"] as? Int == 20)

        let (rowTypes, rowTypesSession) = try Self.store("row-types")
        let plain = try #require(rowTypes.records(Self.tail(rowTypesSession)).rows.first { $0.seq == 4 })
        #expect(try Self.data(plain)["output"] as? String == "fatal: not a git repository\n")
    }

    /// OpenCode 2.0.32 records a `/compact` with nothing to compact as a
    /// failed compaction with its error (seq 363 as captured, its time
    /// moved). The slim row keeps the error's type and message, the message
    /// cut as a note's text is; a compaction that did not fail keeps none.
    @Test func aFailedCompactionKeepsItsError() throws {
        let (harness, session) = try Self.store("compact")
        try Self.insertRow(harness, session, seq: 363, type: "compaction", data: #"""
            {"time":{"created":1800000100363},"status":"failed","reason":"manual",
             "error":{"type":"compaction.unavailable","message":"Nothing to compact yet"}}
            """#)
        try Self.insertRow(harness, session, seq: 364, type: "compaction", data: """
            {"time":{"created":1800000100364},"status":"failed","reason":"auto",
             "error":{"type":"provider.transport","message":"\(String(repeating: "e", count: 20_000))"}}
            """)

        let rows = try harness.records(Self.tail(session)).rows
        let refused = try Self.data(#require(rows.first { $0.seq == 363 }))
        #expect(refused["status"] as? String == "failed")
        let error = refused["error"] as? NSDictionary
        #expect(error == ["type": "compaction.unavailable", "message": "Nothing to compact yet"])
        let failed = try Self.data(#require(rows.first { $0.seq == 364 }))
        let long = try #require(failed["error"] as? [String: Any])
        #expect(long["type"] as? String == "provider.transport")
        #expect((long["message"] as? String)?.count == 16_384)
        #expect(try Self.data(#require(rows.first { $0.seq == 210 }))["error"] is NSNull)
    }

    @Test func nestedArraysDecodeAsArrays() throws {
        let (harness, session) = try Self.store("odd-types")
        try harness.insert(into: "session_inbox", [
            "id": .text("msg_0a1b2c3d4e41InboxWithFile1"), "session_id": .text(session.rawValue),
            "type": .text("user"), "delivery": .text("steer"), "enqueued_seq": .integer(10),
            "time_created": .integer(1_800_000_000_700),
            "payload": .text(#"{"text":"See notes.","files":[{"name":"notes.md","mime":"text/markdown"}],"agents":[]}"#),
        ])
        let records = try harness.records(Self.tail(session))

        let step = try Self.data(#require(records.rows.first { $0.seq == 5 }))
        #expect((step["content"] as? [Any])?.count == 5)
        let user = try Self.data(#require(records.rows.first { $0.seq == 4 }))
        #expect((user["files"] as? [Any])?.count == 1)
        #expect((user["agents"] as? [Any])?.isEmpty == true)
        let inbox = try Self.object(#require(records.inboxLine))
        let items = try #require(inbox["items"] as? [[String: Any]])
        #expect(items.count == 2)
        #expect((items.first?["files"] as? [Any])?.isEmpty == true)
        #expect(items.last?["files"] as? [String] == ["notes.md"])
    }

    @Test func slimRowsTolerateUnexpectedJSONTypes() throws {
        let (harness, session) = try Self.store("odd-types")
        let records = try harness.records(Self.tail(session))
        #expect(records.ignoredLines == 0)
        let step = try Self.data(#require(records.rows.first { $0.seq == 5 }))
        let content = try #require(step["content"] as? [[String: Any]])
        try #require(content.count == 5)
        // A numeric time, a text input, a string error and no metadata.
        #expect(content[0]["type"] as? String == "reasoning")
        #expect(content[0]["time"] as? Int == 1_800_000_000_020)
        #expect(content[1]["input"] as? String == "file diagram.png")
        #expect(content[1]["error"] as? String == "Command failed with exit code 2")
        #expect(content[1]["meta"] is NSNull)
        // An unknown item type, and an item that is not an object.
        #expect(content[2] as NSDictionary == ["_i": 2, "type": "image"])
        #expect(content[3] as NSDictionary == ["_i": 3])
        #expect(content[4]["phase"] as? String == "final_answer")

        let (rowTypes, rowTypesSession) = try Self.store("row-types")
        let invalid = try #require(rowTypes.records(Self.tail(rowTypesSession)).rows.first { $0.seq == 20 })
        #expect(invalid.isFinal)
        #expect(try Self.data(invalid) as NSDictionary == ["k": "invalid"])
    }

    @Test func aStagedRevertWithLargePatchesStaysSmall() throws {
        let (harness, session) = try Self.store("undo-staged")
        // 3 MiB of patch text in the staged revert.
        try harness.execute("""
            UPDATE session_v2 SET revert = json_object('messageID', 'msg_0a1b2c3d4e70LMbLuB1pGKgZbA',
              'snapshot', 'abc123', 'files', json_array(
                json_object('file', 'big.txt', 'patch', hex(zeroblob(1572864))),
                json_object('file', 'small.txt', 'patch', '@@ -1 +1 @@')))
            """)
        let line = try #require(harness.records(Self.tail(session)).sessionLine)
        #expect(line.count < 1_024)
        let sessionLine = try Self.object(line)
        #expect(sessionLine["revertFiles"] as? Int == 2)
        #expect(sessionLine["revertSeq"] as? Int == 27)
    }

    @Test func theInboxLineIsBounded() throws {
        let (harness, session) = try Self.store("pong")
        let text = String(repeating: "a", count: 40_960)
        // Inserted newest first; the line lists items in queue order.
        for index in (0..<20).reversed() {
            try harness.insert(into: "session_inbox", [
                "id": .text("msg_inbox_\(index)"), "session_id": .text(session.rawValue),
                "type": .text("user"), "delivery": .text("queue"), "enqueued_seq": .integer(100 + Int64(index)),
                "time_created": .integer(1_800_000_200_000 + Int64(index)),
                "payload": .text(#"{"text":"\#(text)","files":[],"agents":[]}"#),
            ])
        }
        let inbox = try Self.object(#require(harness.records(Self.tail(session)).inboxLine))
        let items = try #require(inbox["items"] as? [[String: Any]])
        #expect(items.count == 16)
        #expect(items.compactMap { $0["seq"] as? Int } == Array(100..<116))
        #expect(items.allSatisfy { ($0["text"] as? String)?.count == 16_384 })
        #expect(items.allSatisfy { $0["n"] as? Int == 40_960 })
        #expect(inbox["more"] as? Int == 4)
    }

    /// The record source's largest older page reads in one query: its
    /// lines stay under the output cap even with the row that crosses its
    /// budget, so `head -c` never cuts it and the source never reads it
    /// again at half.
    @Test func theLargestOlderPageReadsInOneQuery() throws {
        let (harness, session) = try Self.store("pong")
        let item = #"{"type":"text","text":"\#(String(repeating: "t", count: 60_000))"}"#
        for seq in Int64(20)..<50 {
            try Self.insertRow(harness, session, seq: seq, type: "assistant", data: """
                {"time":{"created":1800000100000,"completed":1800000100500},"content":[\(item),\(item)]}
                """)
        }
        let budget = OpenCodeRecordSource.Budgets().olderMaximumPage
        let page = try harness.records(OpenCodeQuery(session: session, kind: .older(before: 50, budget: budget)))
        #expect(!page.overflow)
        #expect(page.rows.last?.seq == 49)
        // A full page: its rows reach the budget.
        #expect(try page.rows.map(Self.dataLength).reduce(0, +) >= budget)
    }

    @Test func aRowFetchReadsLargerOutput() throws {
        let (harness, session) = try Self.store("pong")
        let output = String(repeating: "o", count: 100_000)
        try Self.insertRow(harness, session, seq: 20, type: "assistant", data: #"""
            {"time":{"created":1800000100000,"completed":1800000100500},
             "content":[{"type":"tool","id":"call_large","name":"shell",
               "state":{"status":"completed","input":{"command":"seq 100000"},
                 "content":[{"type":"text","text":"\#(output)"}]}}]}
            """#)

        let tailStep = try Self.data(#require(harness.records(Self.tail(session)).rows.first { $0.seq == 20 }))
        let cut = try Self.firstItem(of: tailStep)
        #expect((cut["out"] as? String)?.count == 16_384)
        #expect(cut["outN"] as? Int == 100_000)

        let fetch = try harness.records(OpenCodeQuery(session: session, kind: .row(seq: 20, outputLimit: 262_144)))
        #expect(fetch.rows.map(\.seq) == [20])
        #expect(fetch.sessionLine == nil)
        #expect(fetch.inboxLine == nil)
        let whole = try Self.firstItem(of: Self.data(#require(fetch.rows.first)))
        #expect((whole["out"] as? String)?.count == 100_000)

        let short = try harness.records(OpenCodeQuery(session: session, kind: .row(seq: 20, outputLimit: 1_000)))
        let shortItem = try Self.firstItem(of: Self.data(#require(short.rows.first)))
        #expect((shortItem["out"] as? String)?.count == 1_000)
    }

    @Test func inboxItemsCarryTheirMessageIDAndText() throws {
        let (queued, session) = try Self.store("steer-queued")
        let inbox = try Self.object(#require(queued.records(Self.tail(session)).inboxLine))
        let item = try #require((inbox["items"] as? [[String: Any]])?.first)
        #expect(item["id"] as? String == "msg_0a1b2c3d4e30c6n5ci7hO7j2rp")
        #expect(item["delivery"] as? String == "steer")
        #expect(item["seq"] as? Int == 184)
        #expect(item["text"] as? String == "After that, reply with two.")
        #expect(item["n"] as? Int == 27)
        #expect(inbox["more"] as? Int == 0)

        // Delivered, the item becomes a user row under the same id.
        let (steer, _) = try Self.store("steer")
        let delivered = try #require(steer.records(Self.tail(session)).rows.first { $0.seq == 187 })
        #expect(delivered.id == "msg_0a1b2c3d4e30c6n5ci7hO7j2rp")
        #expect(try Self.data(delivered)["text"] as? String == "After that, reply with two.")
    }

    // MARK: Store problems

    @Test func aMissingColumnIsReportedByName() throws {
        let fixture = try OpenCodeStoreFixture.named("pong")
        let session = try #require(fixture.sessionID)
        let schema = try ChatFixture.text("opencode/schema.sql")

        let withoutRevert = schema.replacingOccurrences(of: "  revert TEXT,\n", with: "")
        try #require(withoutRevert != schema)
        let noRevert = try OpenCodeSQLiteHarness(fixture, schema: withoutRevert)
        #expect(try noRevert.response(Self.tail(session)) == .unavailable(.layout(missing: ["session_v2.revert"])))

        let withoutInbox = try #require(schema.components(separatedBy: "CREATE TABLE session_inbox").first)
        let noInbox = try OpenCodeSQLiteHarness(fixture, schema: withoutInbox)
        #expect(
            try noInbox.response(Self.tail(session))
                == .unavailable(.layout(missing: [
                    "session_inbox.id", "session_inbox.session_id", "session_inbox.type", "session_inbox.payload",
                    "session_inbox.delivery", "session_inbox.enqueued_seq", "session_inbox.time_created",
                ])))
    }

    @Test func aV1OnlyStoreIsAnOlderOpenCode() throws {
        let fixture = try OpenCodeStoreFixture.named("pong")
        let harness = try OpenCodeSQLiteHarness(fixture, schema: """
            CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT, time_updated INTEGER);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, data TEXT);
            """)
        #expect(try harness.response(Self.tail(#require(fixture.sessionID))) == .unavailable(.olderOpenCode))
    }

    @Test func aMissingSessionIsReported() throws {
        let (harness, _) = try Self.store("pong")
        harness.otherStores = ["opencode-beta.db"]
        let absent = try #require(OpenCodeSessionID("ses_0a1b2c3d4effAbsentSession1"))
        #expect(try harness.response(Self.tail(absent)) == .sessionMissing(otherStores: ["opencode-beta.db"]))
        // Only a tail names the other stores.
        let cursor = OpenCodePollCursor(
            eventSeq: nil, lowSeq: 4, highSeq: 12, knownInWindow: 3, openRows: [], updatedSince: 0,
            budget: 524_288)
        #expect(
            try harness.response(OpenCodeQuery(session: absent, kind: .poll(cursor)))
                == .sessionMissing(otherStores: []))
    }

    @Test func otherSessionsAreNeverRead() throws {
        let fixture = try OpenCodeStoreFixture.named("two-sessions")
        let session = try #require(fixture.sessionID)
        let other = try #require(fixture.otherSessions.first)
        let secrets =
            [try #require(other.sessionID).rawValue, "Other secret title", "kiwi-7731", "mango-4410"]
            + other.rows.map(\.id) + other.inbox.map(\.id)
        let harness = try OpenCodeSQLiteHarness(fixture)
        let cursor = OpenCodePollCursor(
            eventSeq: nil, lowSeq: 4, highSeq: 4, knownInWindow: 1, openRows: [7], updatedSince: 0,
            budget: 524_288)
        let kinds: [OpenCodeQuery.Kind] = [
            .tail(budget: 524_288), .poll(cursor), .older(before: 12, budget: 524_288),
            .row(seq: 7, outputLimit: 262_144),
        ]
        for kind in kinds {
            let stdout = String(
                decoding: harness.output(OpenCodeQuery(session: session, kind: kind)).stdout, as: UTF8.self)
            for secret in secrets {
                #expect(!stdout.contains(secret), "\(kind) printed \(secret)")
            }
        }
        #expect(try harness.records(Self.tail(session)).rows.map(\.seq) == [4, 7, 12])
    }

    /// SQLite reads a lone surrogate escape, as OpenCode stores a line its
    /// read tool cut inside an emoji, as bytes that are not UTF-8 and prints
    /// them raw. The row and the inbox keep the rest of their text.
    @Test func aLoneSurrogateReadsAsReplacementCharacters() throws {
        let (harness, session) = try Self.store("pong")
        try Self.insertRow(harness, session, seq: 20, type: "assistant", data: #"""
            {"time":{"created":1800000100000,"completed":1800000100500},
             "content":[{"type":"text","text":"before \ud83d after"}]}
            """#)
        try harness.insert(into: "session_inbox", [
            "id": .text("msg_0a1b2c3d4e41InboxSurrogate1"), "session_id": .text(session.rawValue),
            "type": .text("user"), "delivery": .text("steer"), "enqueued_seq": .integer(30),
            "time_created": .integer(1_800_000_100_700),
            "payload": .text(#"{"text":"queued \ud83d","files":[],"agents":[]}"#),
        ])

        #expect(harness.output(Self.tail(session)).stdout.range(of: Data([0xED, 0xA0, 0xBD])) != nil)
        let records = try harness.records(Self.tail(session))
        #expect(records.ignoredLines == 0)
        let replaced = "\u{FFFD}\u{FFFD}\u{FFFD}"
        guard case .row(let row) = OpenCodeLine(try #require(records.rows.first { $0.seq == 20 }).line),
            case .assistant(let step) = row.content, case .text(let text) = step.items.first?.kind,
            case .inbox(let inbox) = OpenCodeLine(try #require(records.inboxLine))
        else {
            Issue.record("a line did not decode")
            return
        }
        #expect(text.text == "before \(replaced) after")
        #expect(inbox.items.last?.text == "queued \(replaced)")
    }

    @Test func aRowOverTheLimitArrivesWithoutItsData() throws {
        let (harness, session) = try Self.store("pong")
        let item = #"{"type":"text","text":"\#(String(repeating: "t", count: 65_536))"}"#
        let items = Array(repeating: item, count: 20).joined(separator: ",")
        try Self.insertRow(harness, session, seq: 20, type: "assistant", data: """
            {"time":{"created":1800000100000,"completed":1800000100500},"content":[\(items)]}
            """)
        let row = try #require(harness.records(Self.tail(session)).rows.first { $0.seq == 20 })
        let object = try Self.object(row.line)
        #expect(object["d"] == nil)
        #expect(try #require(object["big"] as? Int) > OpenCodeProbe.rowDataLimit)
        #expect(row.isFinal)
        #expect(row.line.count < 512)
    }

    // MARK: Fixtures

    /// Every `store-<scenario>.json` read by a tail gives the lines its
    /// `rows-<scenario>.jsonl` holds: the session, the inbox, then the rows.
    /// Lines compare as JSON, so a SQLite that escapes differently still
    /// matches. With `HEELER_WRITE_OPENCODE_ROWS` naming a directory, the
    /// test writes the files there instead.
    @Test func rowFixturesMatchTheProbeOutput() throws {
        let destination = ProcessInfo.processInfo.environment["HEELER_WRITE_OPENCODE_ROWS"]
            .flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
        let scenarios = try OpenCodeStoreFixture.scenarios()
        try #require(!scenarios.isEmpty)
        for scenario in scenarios {
            let (harness, session) = try Self.store(scenario)
            let records = try harness.records(Self.tail(session))
            let lines = [records.sessionLine, records.inboxLine].compactMap { $0 } + records.rows.map(\.line)
            if let destination {
                try Data(lines.map { $0 + Data([0x0A]) }.joined())
                    .write(to: destination.appending(path: "rows-\(scenario).jsonl"))
                continue
            }
            let expected = try ChatFixture.data("opencode/rows-\(scenario).jsonl")
                .split(separator: 0x0A).map { Data($0) }
            #expect(lines.count == expected.count, "rows-\(scenario).jsonl")
            for (index, (line, expectedLine)) in zip(lines, expected).enumerated() {
                #expect(
                    try Self.json(line) == Self.json(expectedLine),
                    "rows-\(scenario).jsonl line \(index + 1)")
            }
        }
    }

    // MARK: Older SQLite

    /// SQLite before 3.46, as Debian 12, Ubuntu 24.04 and RHEL 9 ship it,
    /// parses on a fixed stack of 100 entries and fails a statement nested
    /// deeper. Where this SQLite can cap its parser stack, every statement
    /// parses with 20 entries to spare, about six levels of nesting. iOS
    /// 26's SQLite cannot, so on every SQLite the statements also nest no
    /// deeper than they do now, in parentheses and in expressions. A change
    /// that deepens one fails here first: check it against the capped stack
    /// before raising either limit, and lower a limit that is no longer
    /// reached.
    @Test func everyStatementParsesOnTheParserStackOfOlderSQLite() throws {
        let (harness, _) = try Self.store("pong")
        var statements: [(name: String, sql: String)] = []
        for query in OpenCodeProbeTests.queries {
            for (index, sql) in OpenCodeProbe.statements(query).enumerated() {
                statements.append(("\(query.kind) statement \(index)", sql))
            }
        }

        let depths = statements.map { Self.parenthesisDepth($0.sql) }
        #expect(depths.max() == Self.deepestParentheses)
        for (statement, depth) in zip(statements, depths) {
            #expect(depth <= Self.deepestParentheses, "\(statement.name)")
            #expect(
                harness.prepareFailure(statement.sql, expressionDepth: Self.deepestExpression) == nil,
                "\(statement.name)")
        }
        #expect(
            statements.contains { harness.prepareFailure($0.sql, expressionDepth: Self.deepestExpression - 1) != nil })

        guard OpenCodeSQLiteHarness.limitsParserDepth else { return }
        let spared = OpenCodeSQLiteHarness.fixedParserStack - 20
        // The cap holds below 100 entries: 28 nested calls fit 100, not 80.
        let nested = "SELECT " + String(repeating: "coalesce(", count: 28) + "1"
            + String(repeating: ", 2)", count: 28)
        #expect(harness.prepareFailure(nested, parserStack: OpenCodeSQLiteHarness.fixedParserStack) == nil)
        #expect(harness.prepareFailure(nested, parserStack: spared) != nil)
        for statement in statements {
            #expect(harness.prepareFailure(statement.sql, parserStack: spared) == nil, "\(statement.name)")
        }
    }

    /// How deep any statement nests parentheses and expressions now.
    private static let deepestParentheses = 11
    private static let deepestExpression: Int32 = 26

    /// The deepest parentheses in a statement, outside its string literals.
    private static func parenthesisDepth(_ statement: String) -> Int {
        var depth = 0
        var deepest = 0
        for character in OpenCodeProbeTests.split(statement).code {
            if character == "(" {
                depth += 1
                deepest = max(deepest, depth)
            } else if character == ")" {
                depth -= 1
            }
        }
        return deepest
    }

    // MARK: Helpers

    private static func store(_ scenario: String) throws -> (OpenCodeSQLiteHarness, OpenCodeSessionID) {
        let fixture = try OpenCodeStoreFixture.named(scenario)
        return (try OpenCodeSQLiteHarness(fixture), try #require(fixture.sessionID))
    }

    private static func tail(_ session: OpenCodeSessionID, budget: Int = 524_288) -> OpenCodeQuery {
        OpenCodeQuery(session: session, kind: .tail(budget: budget))
    }

    /// The cursor a source holds after reading `records`.
    private static func cursor(after records: OpenCodeRecords) throws -> OpenCodePollCursor {
        OpenCodePollCursor(
            eventSeq: records.eventSeq, lowSeq: try #require(records.rows.first?.seq),
            highSeq: try #require(records.rows.last?.seq), knownInWindow: records.rows.count,
            openRows: records.rows.filter { !$0.isFinal }.map(\.seq),
            updatedSince: (records.rows.map(\.timeUpdated).max() ?? 0) - 2_000, budget: 524_288)
    }

    /// Adds one `session_message` row holding `data`, a JSON text.
    private static func insertRow(
        _ harness: OpenCodeSQLiteHarness, _ session: OpenCodeSessionID, seq: Int64, type: String,
        data: String
    ) throws {
        let time = 1_800_000_100_000 + seq
        try harness.insert(into: "session_message", [
            "id": .text("msg_inserted_\(seq)"), "session_id": .text(session.rawValue), "type": .text(type),
            "seq": .integer(seq), "time_created": .integer(time), "time_updated": .integer(time),
            "data": .text(data),
        ])
    }

    private static func object(_ line: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    private static func json(_ line: Data) throws -> NSObject? {
        try JSONSerialization.jsonObject(with: line) as? NSObject
    }

    /// A row line's `d`.
    private static func data(_ row: OpenCodeRowLine) throws -> [String: Any] {
        try #require(try object(row.line)["d"] as? [String: Any])
    }

    /// The bytes of a row line's `d`, which is what a budget counts.
    private static func dataLength(_ row: OpenCodeRowLine) throws -> Int {
        let key = try #require(row.line.range(of: Data(#","d":"#.utf8)))
        return row.line.distance(from: key.upperBound, to: row.line.endIndex) - 1
    }

    private static func firstItem(of data: [String: Any]) throws -> [String: Any] {
        try #require((data["content"] as? [[String: Any]])?.first)
    }

    /// The content item `index` of row `seq` in a scenario's tail.
    private static func toolItem(in scenario: String, seq: Int64, index: Int) throws -> [String: Any] {
        let (harness, session) = try store(scenario)
        let row = try #require(harness.records(tail(session)).rows.first { $0.seq == seq })
        let content = try #require(data(row)["content"] as? [[String: Any]])
        return try #require(content.first { $0["_i"] as? Int == index })
    }
}
