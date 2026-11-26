import Foundation

/// Positions are Amp's absolute message indexes in the full thread. Every
/// adjacent page overlaps by ID so an append or a rewrite cannot shift the window.
struct AmpRecordSource: ChatTranscriptSource {
    let thread: String
    var path: String { "amp/" + thread }
    var head: Data? { Data(thread.utf8) }
    private var target: AmpChatTarget?
    private var first = 0
    private var next = 0
    private var total = 0
    private var held: [Int: AmpChatPage.Row] = [:]
    private var olderRead = 0
    var readOffset: UInt64 { UInt64(next) }
    var windowStart: UInt64? { UInt64(first) }
    var hasUnreadRecords: Bool { next < total }
    var hasOlder: Bool { first > 0 }
    var olderPageLengths: (first: Int, maximum: Int) { (19, 19) }
    var automaticOlderSearch: Int? { 19 }
    var olderSearchExhausted: Bool { olderRead >= 190 }

    init(thread: String) { self.thread = thread }

    mutating func open(_ files: ChatHostFiles) async throws -> [ChatLine]? {
        let (binding, page) = try await read(files, offset: nil, limit: 20)
        target = binding
        first = page.offset
        next = first + page.rows.count
        total = page.total
        held.removeAll(keepingCapacity: true)
        return try merge(page)
    }

    mutating func poll(_ files: ChatHostFiles) async throws -> TranscriptFollower.Change {
        let offset = max(first, next - 3)
        let (_, page) = try await read(files, offset: offset, limit: 20)
        guard page.total >= next, page.rows.enumerated().allSatisfy({ index, row in
            held[offset + index].map { $0.id == row.id } ?? true
        }) else { return .reset(try await open(files) ?? [], replaced: false) }
        total = page.total
        next = max(next, offset + page.rows.count)
        let lines = try merge(page)
        return lines.isEmpty ? .unchanged : .appended(lines)
    }

    mutating func beginOlderSearch() { olderRead = 0 }

    mutating func loadOlder(_ files: ChatHostFiles, length: Int?, limit: Int?) async throws -> TranscriptFollower.OlderPage {
        guard first > 0 else { return .headReached }
        let count = min(19, first, limit ?? 19)
        guard count > 0 else { return .beyondLimit }
        let (_, page) = try await read(files, offset: first - count, limit: count + 1)
        guard page.rows.count == count + 1, page.rows.last?.id == held[first]?.id else { return .rewritten }
        first = page.offset
        olderRead += count
        return .lines(try merge(page))
    }

    func line(at reference: ChatOutputReference, files: ChatHostFiles) async throws -> ChatLine? {
        guard let index = Int(exactly: reference.offset), let heldRow = held[index], let target,
            let call = reference.callID, heldRow.blocks.contains(where: { $0.type == "tool_result" && $0.call == call }),
            let amp = files.amp else { return nil }
        let (_, page) = try await amp.page(thread: thread, expected: target, offset: index, limit: 1, expandedCall: call)
        guard let row = page.rows.first, row.id == heldRow.id else { return nil }
        return try ChatLine(offset: reference.offset, data: JSONEncoder().encode(row))
    }

    private func read(_ files: ChatHostFiles, offset: Int?, limit: Int) async throws -> (AmpChatTarget, AmpChatPage) {
        guard let amp = files.amp else { throw ChatSourceUnavailable(reason: .amp(.unreachable)) }
        return try await amp.page(thread: thread, expected: target, offset: offset, limit: limit)
    }

    private mutating func merge(_ page: AmpChatPage) throws -> [ChatLine] {
        var lines: [ChatLine] = []
        for (index, row) in page.rows.enumerated() {
            let position = page.offset + index
            guard held[position] != row else { continue }
            held[position] = row
            lines.append(try ChatLine(offset: UInt64(position), data: JSONEncoder().encode(row)))
        }
        return lines
    }
}
