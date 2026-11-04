import Foundation

/// Follows one OpenCode session through queries of OpenCode's own database
/// on the Host (ADR 0025), handing the reducer the lines `OpenCodeProbe`
/// prints. A row's offset is its `seq`; the session and inbox lines sit at
/// `readOffset`, past every row read.
///
/// The session's event counter moves with every change to its rows, so a
/// poll whose counter has not moved reads nothing more. Otherwise the poll
/// reads the rows past the window, the rows still open and the rows updated
/// since the last read, and counts the rows in the window: a count other
/// than the rows held means rows were deleted, as a committed `/undo` does,
/// and the source starts over from a tail read. Older pages read below the
/// window and never move the counter, which only a newer read may.
///
/// A read whose output was cut reads again at half its budget, twice at
/// most.
struct OpenCodeRecordSource: ChatTranscriptSource {
    /// Bytes of slimmed JSON each read asks for.
    struct Budgets: Sendable {
        /// An open, or a poll that starts over.
        var tail = 512 << 10
        /// The most one poll reads; past it the source reads the tail.
        var poll = 1 << 20
        /// The first older page; it doubles to `olderMaximumPage`.
        var olderPage = 512 << 10
        /// Half the output cap: a page's lines run past its rows' data, and
        /// it may end with a row that crosses the budget.
        var olderMaximumPage = 1 << 20
        /// How much one request for older history reads back.
        var olderSearch = 8 << 20
        /// Characters of a tool's output a row read again for an expanded
        /// tool row keeps.
        var outputLimit = 256 << 10
    }

    let session: OpenCodeSessionID
    let budgets: Budgets
    private var isOpen = false
    /// The event counter at the last newer read.
    private var eventSeq: Int64?
    /// The rows held, by `seq`: every row from `lowSeq` to `highSeq`.
    private var held: Set<Int64> = []
    /// The held rows that can still change.
    private var openRows: Set<Int64> = []
    private var lowSeq: Int64?
    private var highSeq: Int64?
    /// The session's oldest row, as the last read that printed it said.
    private var firstSeq: Int64?
    /// The newest `time_updated` a newer read saw, in milliseconds.
    private var newestUpdate: Int64?
    /// Bytes the request for older history begun last has read.
    private var olderSearchRead = 0

    init(session: OpenCodeSessionID, budgets: Budgets = Budgets()) {
        self.session = session
        self.budgets = budgets
    }

    var path: String { "opencode:\(session.rawValue)" }
    var head: Data? { Data(session.rawValue.utf8) }

    /// Past the counter and every row read. A session with no counter row
    /// has a nil counter.
    var readOffset: UInt64 { Self.offset(max(eventSeq ?? 0, highSeq ?? 0)) + 1 }

    var windowStart: UInt64? {
        guard isOpen else { return nil }
        guard let lowSeq, lowSeq > firstSeq ?? .min else { return 0 }
        return Self.offset(lowSeq)
    }

    var hasOlder: Bool { (windowStart ?? 0) > 0 }
    var olderPageLengths: (first: Int, maximum: Int) { (budgets.olderPage, budgets.olderMaximumPage) }
    /// OpenCode's automatic requests read as the user's do.
    var automaticOlderSearch: Int? { nil }
    var olderSearchExhausted: Bool { olderSearchRead >= budgets.olderSearch }

    // MARK: Reading

    /// Reads the newest rows. A missing session is unavailable rather than
    /// nil, so Chat can say which other stores the Host has.
    mutating func open(_ files: ChatHostFiles) async throws -> [ChatLine]? {
        switch try await readTail(files) {
        case .lines(let lines):
            return lines
        case .missing(let otherStores):
            throw ChatSourceUnavailable(reason: .sessionStore(.opencode, .sessionMissing(otherStores: otherStores)))
        }
    }

    mutating func poll(_ files: ChatHostFiles) async throws -> TranscriptFollower.Change {
        guard isOpen else { return try await startOver(files) }
        let cursor = OpenCodePollCursor(
            eventSeq: eventSeq, lowSeq: lowSeq ?? 0, highSeq: highSeq ?? 0, knownInWindow: held.count,
            openRows: Array(openRows.sorted().suffix(OpenCodeProbe.openRowLimit)),
            updatedSince: (newestUpdate ?? 0) - 2_000, budget: budgets.poll)
        switch try await query(files, .poll(cursor)) {
        case .unchanged:
            return .unchanged
        case .sessionMissing:
            return .missing
        case .unavailable(let problem):
            throw Self.unavailable(problem)
        case .records(let records):
            try Self.checkSession(records)
            // Over budget, rows deleted from the window, or too many open
            // rows to name: read the tail instead.
            guard !records.overflow, records.windowCount == cursor.knownInWindow,
                openRows.count <= OpenCodeProbe.openRowLimit
            else { return try await startOver(files) }
            eventSeq = records.eventSeq
            if let first = records.firstSeq { firstSeq = first }
            for row in records.rows {
                hold(row, isNewer: true)
            }
            let lines = chatLines(records)
            return lines.isEmpty ? .unchanged : .appended(lines)
        }
    }

    /// `limit` stays nil: with no `automaticOlderSearch`, no request bounds
    /// its pages.
    mutating func loadOlder(_ files: ChatHostFiles, length: Int?, limit: Int? = nil) async throws
        -> TranscriptFollower.OlderPage
    {
        guard hasOlder, let lowSeq else { return .headReached }
        var budget = min(max(budgets.olderPage, length ?? 0), budgets.olderMaximumPage)
        for _ in 0..<Self.attempts {
            switch try await query(files, .older(before: lowSeq, budget: budget)) {
            case .records(let records) where records.overflow:
                budget /= 2
            case .records(let records):
                if let first = records.firstSeq { firstSeq = first }
                guard !records.rows.isEmpty else {
                    // Nothing below the window: it starts at the first row.
                    firstSeq = lowSeq
                    return .headReached
                }
                for row in records.rows {
                    hold(row, isNewer: false)
                    olderSearchRead += row.line.count
                }
                return .lines(records.rows.map { ChatLine(offset: Self.offset($0.seq), data: $0.line) })
            case .sessionMissing:
                return .missing
            case .unavailable(let problem):
                throw Self.unavailable(problem)
            case .unchanged:
                throw Self.unexpectedUnchanged
            }
        }
        throw Self.tooLarge
    }

    mutating func beginOlderSearch() {
        olderSearchRead = 0
    }

    /// The row at the reference's `seq` again, its tool output cut at
    /// `outputLimit` characters rather than the usual 16 Ki. A row still
    /// over the output cap at a quarter of that is too long to show.
    func line(at reference: ChatOutputReference, files: ChatHostFiles) async throws -> ChatLine? {
        let seq = Int64(clamping: reference.offset)
        var limit = budgets.outputLimit
        for _ in 0..<Self.attempts {
            switch try await query(files, .row(seq: seq, outputLimit: limit)) {
            case .records(let records) where records.overflow:
                limit /= 2
            case .records(let records):
                return records.rows.first { $0.seq == seq }.map { ChatLine(offset: reference.offset, data: $0.line) }
            case .sessionMissing:
                return nil
            case .unavailable(let problem):
                throw Self.unavailable(problem)
            case .unchanged:
                throw Self.unexpectedUnchanged
            }
        }
        throw ChatToolOutputFailure.tooLong
    }

    // MARK: Tail

    private enum Tail {
        case lines([ChatLine])
        case missing(otherStores: [String])
    }

    /// A tail read that replaces everything held.
    private mutating func startOver(_ files: ChatHostFiles) async throws -> TranscriptFollower.Change {
        switch try await readTail(files) {
        case .lines(let lines): .reset(lines, replaced: false)
        case .missing: .missing
        }
    }

    private mutating func readTail(_ files: ChatHostFiles) async throws -> Tail {
        var budget = budgets.tail
        for _ in 0..<Self.attempts {
            switch try await query(files, .tail(budget: budget)) {
            case .records(let records) where records.overflow:
                budget /= 2
            case .records(let records):
                try Self.checkSession(records)
                isOpen = true
                eventSeq = records.eventSeq
                firstSeq = records.firstSeq
                held = []
                openRows = []
                lowSeq = nil
                highSeq = nil
                newestUpdate = nil
                for row in records.rows {
                    hold(row, isNewer: true)
                }
                return .lines(chatLines(records))
            case .sessionMissing(let otherStores):
                return .missing(otherStores: otherStores)
            case .unavailable(let problem):
                throw Self.unavailable(problem)
            case .unchanged:
                throw Self.unexpectedUnchanged
            }
        }
        throw Self.tooLarge
    }

    // MARK: State

    private mutating func hold(_ row: OpenCodeRowLine, isNewer: Bool) {
        held.insert(row.seq)
        if row.isFinal {
            openRows.remove(row.seq)
        } else {
            openRows.insert(row.seq)
        }
        lowSeq = min(lowSeq ?? row.seq, row.seq)
        highSeq = max(highSeq ?? row.seq, row.seq)
        if isNewer { newestUpdate = max(newestUpdate ?? row.timeUpdated, row.timeUpdated) }
    }

    /// The rows oldest first, then the session and its inbox.
    private func chatLines(_ records: OpenCodeRecords) -> [ChatLine] {
        var lines = records.rows.map { ChatLine(offset: Self.offset($0.seq), data: $0.line) }
        for line in [records.sessionLine, records.inboxLine].compactMap(\.self) {
            lines.append(ChatLine(offset: readOffset, data: line))
        }
        return lines
    }

    // MARK: Queries

    /// A cut read is tried at its full budget, then at half and a quarter.
    private static let attempts = 3

    private static let tooLarge = TransportError.hostStoreUnreadable(
        detail: "OpenCode's conversation is too large to read in one query.")

    private static let unexpectedUnchanged = TransportError.malformedResponse(
        "OpenCode's store answered a read with an unchanged counter")

    private func query(_ files: ChatHostFiles, _ kind: OpenCodeQuery.Kind) async throws -> OpenCodeQueryResponse {
        guard let queryOpenCode = files.queryOpenCode else {
            throw TransportError.hostFeatureUnavailable(feature: "Chat")
        }
        return try await queryOpenCode(OpenCodeQuery(session: session, kind: kind))
    }

    /// Chat shows a subagent's session only inside its parent's.
    private static func checkSession(_ records: OpenCodeRecords) throws {
        guard let line = records.sessionLine, case .session(let session) = OpenCodeLine(line),
            session.parent != nil
        else { return }
        throw ChatSourceUnavailable(reason: .sessionStore(.opencode, .subagentSession))
    }

    private static func unavailable(_ problem: OpenCodeStoreProblem) -> ChatSourceUnavailable {
        let reason: ChatSessionStoreProblem =
            switch problem {
            case .noStore(let path): .noStore(path: path)
            case .noReader: .noReader
            case .readerTooOld(let version): .readerTooOld(version)
            case .storeClosed: .storeClosed
            case .olderOpenCode: .olderOpenCode
            case .layout(let missing): .unsupportedLayout(missing.joined(separator: ", "))
            }
        return ChatSourceUnavailable(reason: .sessionStore(.opencode, reason))
    }

    private static func offset(_ seq: Int64) -> UInt64 {
        UInt64(max(seq, 0))
    }
}
