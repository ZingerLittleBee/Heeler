import Foundation
import Testing

@testable import Heeler

@Suite("OpenCode record source")
struct OpenCodeRecordSourceTests {
    private static let session = OpenCodeSessionID("ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9")!
    private static let host = UUID(uuidString: "6F1D5C2A-0000-4000-8000-00000000000A")!
    private static let start = Date(timeIntervalSince1970: 1_791_266_400)
    /// Milliseconds: a row's default `time_updated` is this plus its `seq`.
    private static let epoch: Int64 = 1_800_000_000_000

    /// Answers OpenCode queries with scripted responses, in order, and keeps
    /// every query asked. A source read by query never reads the Host's
    /// files: each file operation is counted and fails.
    private actor ScriptedQueries {
        private(set) var queries: [OpenCodeQuery] = []
        private(set) var fileCalls = 0
        private var answers: [Result<OpenCodeQueryResponse, any Error>] = []

        func answer(_ responses: OpenCodeQueryResponse...) {
            answers += responses.map { .success($0) }
        }

        func fail(with error: any Error) {
            answers.append(.failure(error))
        }

        /// Each query's kind, a poll without its cursor.
        var shapes: [String] {
            queries.map { query in
                switch query.kind {
                case .tail(let budget): "tail \(budget)"
                case .poll: "poll"
                case .older(let before, let budget): "older \(before) \(budget)"
                case .row(let seq, let outputLimit): "row \(seq) \(outputLimit)"
                case .recentSessions: "recent sessions"
                }
            }
        }

        var lastCursor: OpenCodePollCursor? {
            for query in queries.reversed() {
                if case .poll(let cursor) = query.kind { return cursor }
            }
            return nil
        }

        private func respond(_ query: OpenCodeQuery) throws -> OpenCodeQueryResponse {
            queries.append(query)
            guard !answers.isEmpty else { throw TransportError.malformedResponse("no answer scripted") }
            return try answers.removeFirst().get()
        }

        private func countFileCall() {
            fileCalls += 1
        }

        nonisolated var files: ChatHostFiles {
            let refused = TransportError.hostFileUnreadable(status: 3)
            return ChatHostFiles(
                status: { _ in
                    await self.countFileCall()
                    throw refused
                },
                list: { _ in
                    await self.countFileCall()
                    throw refused
                },
                read: { _ in
                    await self.countFileCall()
                    throw refused
                },
                home: {
                    await self.countFileCall()
                    throw refused
                },
                queryOpenCode: { try await self.respond($0) })
        }
    }

    /// A `{"k":"row",…}` line as the store query prints it.
    private static func row(
        _ seq: Int64, type: String = "user", isFinal: Bool = true, updated: Int64? = nil,
        data: String = #"{"text":"Hello.","n":6,"files":[],"agents":[]}"#
    ) -> OpenCodeRowLine {
        let id = "msg_\(seq)"
        let updated = updated ?? epoch + seq
        let line =
            #"{"k":"row","id":"\#(id)","type":"\#(type)","seq":\#(seq),"tc":\#(updated),"tu":\#(updated),"#
            + #""f":\#(isFinal),"d":\#(data)}"#
        return OpenCodeRowLine(id: id, seq: seq, timeUpdated: updated, isFinal: isFinal, line: Data(line.utf8))
    }

    private static func sessionLine(parent: String? = nil) -> Data {
        let parent = parent.map { #""\#($0)""# } ?? "null"
        return Data(
            (#"{"k":"session","id":"\#(session)","parent":\#(parent),"title":"Pong","version":"2.0.32","#
                + #""revertMessage":null,"revertFiles":null,"revertSeq":null,"updated":1800000013841}"#).utf8)
    }

    private static let inboxLine = Data(#"{"k":"inbox","items":[],"more":0}"#.utf8)

    private static func records(
        _ rows: [OpenCodeRowLine], eventSeq: Int64?, firstSeq: Int64? = nil, windowCount: Int? = nil,
        sessionLine: Data? = OpenCodeRecordSourceTests.sessionLine(), overflow: Bool = false
    ) -> OpenCodeQueryResponse {
        .records(
            OpenCodeRecords(
                sqliteVersion: "3.51.0", eventSeq: eventSeq, sessionLine: sessionLine,
                inboxLine: sessionLine == nil ? nil : inboxLine, rows: rows, firstSeq: firstSeq,
                windowCount: windowCount, overflow: overflow, ignoredLines: 0))
    }

    private static func line(_ row: OpenCodeRowLine) -> ChatLine {
        ChatLine(offset: UInt64(row.seq), data: row.line)
    }

    /// The session and inbox lines, which follow the rows at `offset`.
    private static func trailer(at offset: UInt64) -> [ChatLine] {
        [ChatLine(offset: offset, data: sessionLine()), ChatLine(offset: offset, data: inboxLine)]
    }

    private static func cursor(
        eventSeq: Int64?, lowSeq: Int64, highSeq: Int64, knownInWindow: Int, openRows: [Int64] = [],
        newestUpdate: Int64
    ) -> OpenCodePollCursor {
        OpenCodePollCursor(
            eventSeq: eventSeq, lowSeq: lowSeq, highSeq: highSeq, knownInWindow: knownInWindow,
            openRows: openRows, updatedSince: newestUpdate - 2_000, budget: 1 << 20)
    }

    // MARK: Opening and polling

    @Test func openReadsTheTailAndNamesTheSession() async throws {
        let queries = ScriptedQueries()
        let rows = [Self.row(4), Self.row(7, type: "assistant"), Self.row(12, type: "idle")]
        await queries.answer(Self.records(rows, eventSeq: 12, firstSeq: 4))
        var source = OpenCodeRecordSource(session: Self.session)
        #expect(source.path == "opencode:ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9")
        #expect(source.head == Data("ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9".utf8))
        #expect(source.windowStart == nil)

        let lines = try await source.open(queries.files)

        // Each row at its `seq`, then the session and its inbox past them.
        #expect(lines == rows.map(Self.line) + Self.trailer(at: 13))
        #expect(source.readOffset == 13)
        #expect(source.windowStart == 0)
        #expect(!source.hasOlder)
        #expect(await queries.queries == [OpenCodeQuery(session: Self.session, kind: .tail(budget: 512 << 10))])
        #expect(await queries.fileCalls == 0)
    }

    @Test func anUnchangedCounterReadsNothingMore() async throws {
        let queries = ScriptedQueries()
        let step = Self.row(7, type: "assistant", isFinal: false, updated: Self.epoch + 5_000)
        await queries.answer(Self.records([Self.row(4), step], eventSeq: 9, firstSeq: 4), .unchanged(eventSeq: 9))
        var source = OpenCodeRecordSource(session: Self.session)
        _ = try await source.open(queries.files)

        #expect(try await source.poll(queries.files) == .unchanged)

        // One query, whose cursor names what the source holds.
        #expect(await queries.shapes == ["tail \(512 << 10)", "poll"])
        #expect(
            await queries.lastCursor
                == Self.cursor(
                    eventSeq: 9, lowSeq: 4, highSeq: 7, knownInWindow: 2, openRows: [7],
                    newestUpdate: Self.epoch + 5_000))
        #expect(source.readOffset == 10)
    }

    /// A session without an event counter has none to compare, so every
    /// poll reads; the session and inbox lines still come after the rows.
    @Test func aNilCounterAlwaysReadsAsChanged() async throws {
        let queries = ScriptedQueries()
        await queries.answer(
            Self.records([Self.row(4), Self.row(7)], eventSeq: nil, firstSeq: 4),
            Self.records([], eventSeq: nil, firstSeq: 4, windowCount: 2))
        var source = OpenCodeRecordSource(session: Self.session)
        let opened = try await source.open(queries.files)
        #expect(opened?.map(\.offset) == [4, 7, 8, 8])

        let change = try await source.poll(queries.files)

        #expect(await queries.lastCursor?.eventSeq == nil)
        #expect(change == .appended(Self.trailer(at: 8)))
        #expect(source.readOffset == 8)
    }

    @Test func newAndUpdatedRowsAppend() async throws {
        let queries = ScriptedQueries()
        let running = Self.row(7, type: "assistant", isFinal: false, updated: Self.epoch + 5_000)
        let finished = Self.row(7, type: "assistant", updated: Self.epoch + 9_000)
        let idle = Self.row(12, type: "idle", updated: Self.epoch + 9_500)
        await queries.answer(
            Self.records([Self.row(4), running], eventSeq: 7, firstSeq: 4),
            Self.records([finished, idle], eventSeq: 12, firstSeq: 4, windowCount: 2),
            .unchanged(eventSeq: 12))
        var source = OpenCodeRecordSource(session: Self.session)
        _ = try await source.open(queries.files)

        let change = try await source.poll(queries.files)

        #expect(change == .appended([Self.line(finished), Self.line(idle)] + Self.trailer(at: 13)))
        #expect(
            await queries.lastCursor
                == Self.cursor(
                    eventSeq: 7, lowSeq: 4, highSeq: 7, knownInWindow: 2, openRows: [7],
                    newestUpdate: Self.epoch + 5_000))

        // The next poll holds the new row and no longer names the finished
        // step.
        _ = try await source.poll(queries.files)

        #expect(
            await queries.lastCursor
                == Self.cursor(
                    eventSeq: 12, lowSeq: 4, highSeq: 12, knownInWindow: 3, newestUpdate: Self.epoch + 9_500))
        #expect(source.readOffset == 13)
    }

    /// A committed `/undo` deletes rows at or above its boundary while the
    /// counter moves on: the window holds fewer rows than the source read.
    @Test func aShorterWindowResetsTheConversation() async throws {
        let queries = ScriptedQueries()
        let before = [Self.row(4), Self.row(7, type: "assistant"), Self.row(12, type: "idle")]
        let after = [Self.row(4), Self.row(7, type: "assistant"), Self.row(14)]
        await queries.answer(
            Self.records(before, eventSeq: 12, firstSeq: 4),
            Self.records([Self.row(14)], eventSeq: 15, firstSeq: 4, windowCount: 2),
            Self.records(after, eventSeq: 15, firstSeq: 4),
            .unchanged(eventSeq: 15))
        var source = OpenCodeRecordSource(session: Self.session)
        _ = try await source.open(queries.files)

        let change = try await source.poll(queries.files)

        #expect(change == .reset(after.map(Self.line) + Self.trailer(at: 16), replaced: false))
        #expect(await queries.shapes == ["tail \(512 << 10)", "poll", "tail \(512 << 10)"])

        _ = try await source.poll(queries.files)

        #expect(
            await queries.lastCursor
                == Self.cursor(eventSeq: 15, lowSeq: 4, highSeq: 14, knownInWindow: 3, newestUpdate: Self.epoch + 14))
    }

    @Test func anOverflowReadsTheTailAgain() async throws {
        let queries = ScriptedQueries()
        let later = [Self.row(4), Self.row(7), Self.row(9)]
        await queries.answer(
            Self.records([Self.row(4), Self.row(7)], eventSeq: 7, firstSeq: 4),
            // More changed than one poll reads.
            Self.records([Self.row(9)], eventSeq: 9, firstSeq: 4, windowCount: 2, overflow: true),
            Self.records(later, eventSeq: 9, firstSeq: 4))
        var source = OpenCodeRecordSource(session: Self.session)
        _ = try await source.open(queries.files)

        #expect(
            try await source.poll(queries.files)
                == .reset(later.map(Self.line) + Self.trailer(at: 10), replaced: false))
        #expect(await queries.shapes == ["tail \(512 << 10)", "poll", "tail \(512 << 10)"])

        // More rows still running than a poll names: the newest 64 are
        // named, and a poll that finds a change reads the tail instead.
        let running = (100...164).map { Self.row(Int64($0), type: "assistant", isFinal: false) }
        await queries.answer(
            Self.records(running, eventSeq: 164, firstSeq: 4),
            Self.records([], eventSeq: 165, firstSeq: 4, windowCount: 65),
            Self.records(running, eventSeq: 165, firstSeq: 4))
        var busy = OpenCodeRecordSource(session: Self.session)
        _ = try await busy.open(queries.files)

        #expect(
            try await busy.poll(queries.files)
                == .reset(running.map(Self.line) + Self.trailer(at: 166), replaced: false))
        #expect(await queries.lastCursor?.openRows == Array(Int64(101)...164))
        #expect(await queries.shapes.suffix(3) == ["tail \(512 << 10)", "poll", "tail \(512 << 10)"])
    }

    @Test func aTruncatedReadHalvesItsBudgetThenFails() async throws {
        let queries = ScriptedQueries()
        let cut = Self.records([Self.row(4)], eventSeq: 4, firstSeq: 4, overflow: true)
        await queries.answer(cut, cut, cut)
        var source = OpenCodeRecordSource(session: Self.session)

        await #expect(
            throws: TransportError.hostStoreUnreadable(
                detail: "OpenCode's conversation is too large to read in one query.")
        ) {
            _ = try await source.open(queries.files)
        }
        #expect(await queries.shapes == ["tail \(512 << 10)", "tail \(256 << 10)", "tail \(128 << 10)"])

        // Half the budget fits.
        await queries.answer(cut, Self.records([Self.row(4)], eventSeq: 4, firstSeq: 4))
        let lines = try await source.open(queries.files)

        #expect(lines == [Self.line(Self.row(4))] + Self.trailer(at: 5))
        #expect(await queries.shapes.suffix(2) == ["tail \(512 << 10)", "tail \(256 << 10)"])
    }

    @Test func aMissingSessionIsMissingOnPollAndUnavailableOnOpen() async throws {
        let queries = ScriptedQueries()
        await queries.answer(.sessionMissing(otherStores: ["opencode-beta.db"]))
        var source = OpenCodeRecordSource(session: Self.session)

        // Opening says which other stores the Host has.
        await #expect(
            throws: ChatSourceUnavailable(
                reason: .sessionStore(.opencode, .sessionMissing(otherStores: ["opencode-beta.db"])))
        ) {
            _ = try await source.open(queries.files)
        }

        // Once followed, it goes missing, and the engine opens again.
        await queries.answer(
            Self.records([Self.row(4), Self.row(7)], eventSeq: 7, firstSeq: 2),
            .sessionMissing(otherStores: []), .sessionMissing(otherStores: []), .sessionMissing(otherStores: []))
        _ = try await source.open(queries.files)

        #expect(try await source.poll(queries.files) == .missing)
        #expect(try await source.loadOlder(queries.files, length: nil) == .missing)
        #expect(try await source.line(at: ChatOutputReference(offset: 7, length: 120), files: queries.files) == nil)
        #expect(await queries.fileCalls == 0)
    }

    @Test func aChildSessionIsNotFollowed() async throws {
        let queries = ScriptedQueries()
        let child = Self.sessionLine(parent: "ses_0a1b2c3d4e00Aa1Bb2Cc3Dd4Ee")
        let subagent = ChatSourceUnavailable(reason: .sessionStore(.opencode, .subagentSession))
        await queries.answer(Self.records([Self.row(4)], eventSeq: 4, firstSeq: 4, sessionLine: child))
        var source = OpenCodeRecordSource(session: Self.session)

        await #expect(throws: subagent) { _ = try await source.open(queries.files) }

        // Every read of the session line checks it again.
        await queries.answer(
            Self.records([Self.row(4)], eventSeq: 4, firstSeq: 4),
            Self.records([Self.row(5)], eventSeq: 5, firstSeq: 4, windowCount: 1, sessionLine: child))
        _ = try await source.open(queries.files)

        await #expect(throws: subagent) { _ = try await source.poll(queries.files) }
    }

    @Test(arguments: [
        (
            OpenCodeStoreProblem.noStore(path: "~/.local/share/opencode/opencode.db"),
            ChatSessionStoreProblem.noStore(path: "~/.local/share/opencode/opencode.db")
        ),
        (.noReader, .noReader),
        (.readerTooOld("3.24.0"), .readerTooOld("3.24.0")),
        (.storeClosed, .storeClosed),
        (.olderOpenCode, .olderOpenCode),
        (
            .layout(missing: ["session_v2.revert", "session_inbox.delivery"]),
            .unsupportedLayout("session_v2.revert, session_inbox.delivery")
        ),
    ])
    func storeProblemsBecomeUnavailableReasons(
        problem: OpenCodeStoreProblem, reason: ChatSessionStoreProblem
    ) async throws {
        let queries = ScriptedQueries()
        await queries.answer(
            .unavailable(problem), Self.records([Self.row(4)], eventSeq: 4, firstSeq: 2), .unavailable(problem),
            .unavailable(problem), .unavailable(problem))
        let unavailable = ChatSourceUnavailable(reason: .sessionStore(.opencode, reason))
        var source = OpenCodeRecordSource(session: Self.session)

        await #expect(throws: unavailable) { _ = try await source.open(queries.files) }
        _ = try await source.open(queries.files)
        await #expect(throws: unavailable) { _ = try await source.poll(queries.files) }
        await #expect(throws: unavailable) { _ = try await source.loadOlder(queries.files, length: nil) }
        await #expect(throws: unavailable) {
            _ = try await source.line(at: ChatOutputReference(offset: 4, length: 120), files: queries.files)
        }
    }

    // MARK: Older pages

    @Test func olderPagesPrependUntilTheFirstRow() async throws {
        let queries = ScriptedQueries()
        let tail = [Self.row(10), Self.row(12), Self.row(14)]
        let page = [Self.row(6), Self.row(8, type: "assistant", isFinal: false)]
        let first = [Self.row(2), Self.row(4)]
        await queries.answer(
            Self.records(tail, eventSeq: 14, firstSeq: 2),
            // An older read prints the counter too, which only a newer
            // read may take.
            Self.records(page, eventSeq: 20, firstSeq: 2),
            Self.records(first, eventSeq: 21, firstSeq: 2),
            .unchanged(eventSeq: 14))
        var source = OpenCodeRecordSource(session: Self.session)
        _ = try await source.open(queries.files)
        #expect(source.windowStart == 10)
        #expect(source.hasOlder)
        #expect(source.olderPageLengths.first == 512 << 10)
        #expect(source.olderPageLengths.maximum == 1 << 20)

        // Pages hold only rows: the session and inbox lines are newer.
        #expect(try await source.loadOlder(queries.files, length: nil) == .lines(page.map(Self.line)))
        #expect(source.windowStart == 6)
        // A page asks for at most the largest page.
        #expect(try await source.loadOlder(queries.files, length: 4 << 20) == .lines(first.map(Self.line)))
        #expect(source.windowStart == 0)
        #expect(!source.hasOlder)
        #expect(try await source.loadOlder(queries.files, length: nil) == .headReached)
        #expect(source.readOffset == 15)

        _ = try await source.poll(queries.files)

        #expect(await queries.shapes == ["tail \(512 << 10)", "older 10 \(512 << 10)", "older 6 \(1 << 20)", "poll"])
        #expect(
            await queries.lastCursor
                == Self.cursor(
                    eventSeq: 14, lowSeq: 2, highSeq: 14, knownInWindow: 7, openRows: [8],
                    newestUpdate: Self.epoch + 14))

        // The rows below a window can be gone: a page that finds none
        // reaches the start.
        await queries.answer(Self.records(tail, eventSeq: 14, firstSeq: 2), Self.records([], eventSeq: 14))
        var emptied = OpenCodeRecordSource(session: Self.session)
        _ = try await emptied.open(queries.files)

        #expect(try await emptied.loadOlder(queries.files, length: nil) == .headReached)
        #expect(emptied.windowStart == 0)
    }

    @Test func anOlderSearchIsSpentAfterItsBudget() async throws {
        let queries = ScriptedQueries()
        let page = [Self.row(16), Self.row(18)]
        let pageBytes = page.map(\.line.count).reduce(0, +)
        await queries.answer(
            Self.records([Self.row(20), Self.row(22)], eventSeq: 22, firstSeq: 2),
            Self.records(page, eventSeq: 22, firstSeq: 2),
            Self.records([Self.row(12), Self.row(14)], eventSeq: 22, firstSeq: 2))
        var source = OpenCodeRecordSource(
            session: Self.session, budgets: OpenCodeRecordSource.Budgets(olderSearch: pageBytes + 1))
        _ = try await source.open(queries.files)

        source.beginOlderSearch()
        _ = try await source.loadOlder(queries.files, length: nil)
        #expect(!source.olderSearchExhausted)
        _ = try await source.loadOlder(queries.files, length: nil)
        #expect(source.olderSearchExhausted)

        // The next request searches as far again.
        source.beginOlderSearch()
        #expect(!source.olderSearchExhausted)
    }

    /// A page that timed out ends the request, and the next request starts
    /// small again rather than at the size the last one reached.
    @Test func olderPagesRestartSmallAfterATimeout() async throws {
        let queries = ScriptedQueries()
        let prompt = Self.row(10, data: #"{"text":"Reply with exactly the word pong.","n":33,"files":[],"agents":[]}"#)
        let reply = Self.row(
            11, type: "assistant",
            data: #"{"time":{"created":1800000000011,"completed":1800000000012},"finish":"stop","#
                + #""content":[{"_i":0,"type":"text","text":"pong","n":4}]}"#)
        let idle = Self.row(12, type: "idle", data: #"{"time":{"created":1800000000012},"outcome":"succeeded"}"#)
        // Rows of a type the reducer does not know show nothing, so a page
        // of them opens no turn and the search goes on.
        let unknown = [Self.row(6, type: "x-later"), Self.row(8, type: "x-later")]
        let earlier = Self.row(2, data: #"{"text":"Earlier.","n":8,"files":[],"agents":[]}"#)
        await queries.answer(
            Self.records([prompt, reply, idle], eventSeq: 12, firstSeq: 2), Self.records(unknown, eventSeq: 12))
        await queries.fail(with: TransportError.hostFileTimedOut)
        await queries.answer(Self.records([earlier], eventSeq: 12, firstSeq: 2))
        let engine = ChatConversationEngine(
            reference: ConversationReference(program: .opencode, sessionID: Self.session.rawValue),
            cacheKey: ChatCacheKey(
                hostID: Self.host, herdrSession: "", program: .opencode, conversationID: Self.session.rawValue),
            files: queries.files, cache: VolatileChatTranscriptCache(), adapter: .openCode, now: { Self.start })
        let context = ChatProjectionContext(activity: .idle)
        let opened = await engine.open(directories: [], context: context)
        #expect(opened.phase == .following(path: "opencode:\(Self.session)"))
        #expect(opened.older == .available)

        var failed = await engine.loadOlder(context: context)
        while failed.older == .loading {
            failed = await engine.loadOlder(context: context)
        }

        #expect(failed.readFailure == .hostFileTimedOut)
        #expect(failed.older == .failed("Reading the conversation timed out"))

        var paged = await engine.loadOlder(context: context)
        while paged.older == .loading {
            paged = await engine.loadOlder(context: context)
        }

        #expect(paged.readFailure == nil)
        #expect(paged.older == .reachedStart)
        #expect(paged.transcript.entries.count > opened.transcript.entries.count)
        #expect(
            await queries.shapes == [
                "tail \(512 << 10)", "older 10 \(512 << 10)", "older 6 \(1 << 20)", "older 6 \(512 << 10)",
            ])
        #expect(await queries.fileCalls == 0)
    }

    // MARK: Output and the Host

    @Test func aRowIsReadAgainForItsExpandedOutput() async throws {
        let queries = ScriptedQueries()
        let expanded = Self.row(7, type: "assistant", data: #"{"content":[]}"#)
        await queries.answer(
            Self.records([expanded], eventSeq: 9),
            Self.records([expanded], eventSeq: 9, overflow: true),
            Self.records([expanded], eventSeq: 9),
            Self.records([], eventSeq: 9))
        let source = OpenCodeRecordSource(session: Self.session)
        let reference = ChatOutputReference(offset: 7, length: 4_096)

        // The row at the reference's `seq`, with 256 Ki characters of tool
        // output rather than 16 Ki.
        #expect(try await source.line(at: reference, files: queries.files) == Self.line(expanded))
        // Output cut short asks for half as much.
        #expect(try await source.line(at: reference, files: queries.files) == Self.line(expanded))
        // A row the store no longer holds is gone.
        #expect(try await source.line(at: reference, files: queries.files) == nil)
        #expect(
            await queries.shapes == [
                "row 7 \(256 << 10)", "row 7 \(256 << 10)", "row 7 \(128 << 10)", "row 7 \(256 << 10)",
            ])
        #expect(await queries.fileCalls == 0)
    }

    /// A row still over the output cap at a quarter of its output is too
    /// long to show, which reading it again would not change.
    @Test func aRowStillCutShortIsTooLong() async throws {
        let queries = ScriptedQueries()
        let expanded = Self.row(7, type: "assistant", data: #"{"content":[]}"#)
        let cut = Self.records([expanded], eventSeq: 9, overflow: true)
        await queries.answer(cut, cut, cut)
        let source = OpenCodeRecordSource(session: Self.session)

        await #expect(throws: ChatToolOutputFailure.tooLong) {
            _ = try await source.line(at: ChatOutputReference(offset: 7, length: 4_096), files: queries.files)
        }
        #expect(await queries.shapes == ["row 7 \(256 << 10)", "row 7 \(128 << 10)", "row 7 \(64 << 10)"])
    }

    /// A transport that cannot query OpenCode, as in the demo, says so the
    /// way its other Chat operations do.
    @Test func withoutAQueryTheHostCannotReadOpenCode() async throws {
        let files = ChatHostFiles(
            status: { _ in nil }, list: { _ in nil }, read: { _ in RemoteFileSlice(data: Data(), length: nil) },
            home: { "/home/dev" })
        let unavailable = TransportError.hostFeatureUnavailable(feature: "Chat")
        var source = OpenCodeRecordSource(session: Self.session)

        await #expect(throws: unavailable) { _ = try await source.open(files) }
        await #expect(throws: unavailable) { _ = try await source.poll(files) }
        await #expect(throws: unavailable) {
            _ = try await source.line(at: ChatOutputReference(offset: 4, length: 120), files: files)
        }
    }

    @Test func everyStoreProblemHasCopyAndItsRetryRule() {
        let problems: [ChatSessionStoreProblem] = [
            .noStore(path: "~/.local/share/opencode/opencode.db"), .sessionMissing(otherStores: []),
            .sessionMissing(otherStores: ["opencode-beta.db", "opencode-dev.db"]), .noReader,
            .readerTooOld("3.24.0"), .storeClosed, .olderOpenCode, .unsupportedLayout("session_v2.revert"),
            .subagentSession,
        ]
        for problem in problems {
            let reason = ChatUnavailableReason.sessionStore(.opencode, problem)
            #expect(reason.explanation == problem.explanation)
            #expect(reason.offersRetry == problem.isRetryable)
            #expect(!reason.isWaiting)
            #expect(
                reason.bannerText(showingSavedMessages: true)
                    == "Chat can't read this conversation from OpenCode's database now. Showing saved messages.")
        }
        #expect(
            problems.map { ChatUnavailableReason.sessionStore(.opencode, $0).title }
                == ["Conversation Not Readable"] + Array(repeating: "Conversation Not Found", count: 2)
                + Array(repeating: "Conversation Not Readable", count: 6))
        // The user can fix the Host's store or reader; the rest are what
        // OpenCode or herdr report.
        #expect(problems.map(\.isRetryable) == [true, true, true, true, true, true, false, false, false])
        // Only what OpenCode itself changes, such as its database opening,
        // is looked at again unprompted.
        #expect(problems.map(\.reopensByItself) == [true, true, true, false, false, true, false, false, false])
        #expect(problems[0].explanation.contains("~/.local/share/opencode/opencode.db"))
        #expect(problems[1].explanation.contains("OPENCODE_DB"))
        #expect(problems[2].explanation.contains("opencode-beta.db, opencode-dev.db"))
        #expect(problems[4].explanation.contains("SQLite 3.24.0"))
        #expect(problems[7].explanation.contains("(session_v2.revert)"))
    }
}
