import Foundation

@testable import Heeler

/// A conversation read by query rather than from a file (ADR 0025), for the
/// engine's tests of record sources. A `Store` holds the records as JSONL
/// bytes, framed at their offsets as a file's lines are, and every source
/// made for it reads them:
///
/// - an open reads the lines that start in the last `tail` bytes;
/// - a poll hands on the lines past the read offset, starts over with a
///   fresh tail once `write` replaced the records, and finds the session
///   missing while the store says so;
/// - a page reads the lines that start in the `length` bytes before the
///   window, at least one, and a request for older history is spent once
///   its pages moved the window back `olderSearch` bytes;
/// - an output line is the line at the reference's offset, with its length.
///
/// The store records every call, and `failNext` scripts what the next one
/// throws. The source's path is `memory:<session>`, and its head the
/// session id.
struct InMemoryRecordSource: ChatTranscriptSource {
    struct Limits: Sendable {
        var tail = 64
        var olderPage = 32
        var olderMaximumPage = 128
        var olderSearch = 1_024
    }

    enum Call: Equatable, Sendable {
        case open
        case poll
        case older(length: Int?)
        case line(ChatOutputReference)
    }

    actor Store {
        struct Contents: Sendable {
            var records: Data
            var generation: Int
        }

        private(set) var calls: [Call] = []
        private var records = Data()
        /// Bumped by `write`: offsets read before may locate other records.
        private var generation = 0
        private var isMissing = false
        private var failures: [any Error] = []

        /// Replaces every record.
        func write(_ text: String) {
            records = Data(text.utf8)
            generation += 1
        }

        func append(_ text: String) {
            records.append(Data(text.utf8))
        }

        func setMissing(_ missing: Bool) {
            isMissing = missing
        }

        /// The next call throws `error` instead of answering.
        func failNext(with error: any Error) {
            failures.append(error)
        }

        /// The length each page of older records was asked for, in order.
        var olderLengths: [Int?] {
            var lengths: [Int?] = []
            for case .older(let length) in calls {
                lengths.append(length)
            }
            return lengths
        }

        /// Records `call`, then throws the failure scripted next or answers
        /// with the records; nil while the session is missing.
        fileprivate func answer(_ call: Call) throws -> Contents? {
            calls.append(call)
            if !failures.isEmpty { throw failures.removeFirst() }
            return isMissing ? nil : Contents(records: records, generation: generation)
        }
    }

    let store: Store
    let sessionID: String
    let limits: Limits
    private(set) var readOffset: UInt64 = 0
    private(set) var windowStart: UInt64?
    private var generation = 0
    private var olderSearchEnd: UInt64?

    init(store: Store, sessionID: String, limits: Limits = Limits()) {
        self.store = store
        self.sessionID = sessionID
        self.limits = limits
    }

    /// `NumberedChatReducer`'s adapter, reading `store` by query as the
    /// session `sessionID`; any other id makes no source.
    static func adapter(
        _ store: Store, sessionID: String, limits: Limits = Limits(), wantsFirstLine: Bool = false
    ) -> ChatTranscriptAdapter {
        var adapter = NumberedChatReducer.adapter(wantsFirstLine: wantsFirstLine)
        adapter.makeRecordSource = { id in
            id == sessionID ? InMemoryRecordSource(store: store, sessionID: id, limits: limits) : nil
        }
        return adapter
    }

    var path: String { "memory:\(sessionID)" }
    var head: Data? { Data(sessionID.utf8) }
    var hasOlder: Bool { (windowStart ?? 0) > 0 }
    var olderPageLengths: (first: Int, maximum: Int) { (limits.olderPage, limits.olderMaximumPage) }
    var automaticOlderSearch: Int? { nil }

    var olderSearchExhausted: Bool {
        guard let end = olderSearchEnd else { return false }
        return end - min(end, windowStart ?? 0) >= UInt64(limits.olderSearch)
    }

    mutating func open(_ files: ChatHostFiles) async throws -> [ChatLine]? {
        guard let contents = try await store.answer(.open) else { return nil }
        return readTail(contents)
    }

    mutating func poll(_ files: ChatHostFiles) async throws -> TranscriptFollower.Change {
        guard let contents = try await store.answer(.poll) else { return .missing }
        guard contents.generation == generation else { return .reset(readTail(contents), replaced: false) }
        let end = UInt64(contents.records.count)
        guard end > readOffset else { return .unchanged }
        let lines = JSONLLineFramer.lines(
            in: Data(contents.records[Int(readOffset)...]), startOffset: readOffset)
        readOffset = end
        return .appended(lines)
    }

    mutating func loadOlder(_ files: ChatHostFiles, length: Int?, limit: Int?) async throws
        -> TranscriptFollower.OlderPage
    {
        guard let contents = try await store.answer(.older(length: length)) else { return .missing }
        guard contents.generation == generation else { return .rewritten }
        guard let end = windowStart, end > 0 else { return .headReached }
        let page = UInt64(min(max(limits.olderPage, length ?? 0), limits.olderMaximumPage))
        let start = end > page ? end - page : 0
        let before = JSONLLineFramer.lines(in: contents.records).filter { $0.offset < end }
        var lines = before.filter { $0.offset >= start }
        if lines.isEmpty, let last = before.last { lines = [last] }
        windowStart = lines.first?.offset ?? 0
        return .lines(lines)
    }

    mutating func beginOlderSearch() {
        olderSearchEnd = windowStart ?? 0
    }

    func line(at reference: ChatOutputReference, files: ChatHostFiles) async throws -> ChatLine? {
        guard let contents = try await store.answer(.line(reference)) else { return nil }
        return JSONLLineFramer.lines(in: contents.records).first {
            $0.offset == reference.offset && $0.length == reference.length
        }
    }

    private mutating func readTail(_ contents: Store.Contents) -> [ChatLine] {
        let end = UInt64(contents.records.count)
        let start = end > UInt64(limits.tail) ? end - UInt64(limits.tail) : 0
        let lines = JSONLLineFramer.lines(in: contents.records).filter { $0.offset >= start }
        windowStart = lines.first?.offset ?? end
        readOffset = end
        generation = contents.generation
        return lines
    }
}
