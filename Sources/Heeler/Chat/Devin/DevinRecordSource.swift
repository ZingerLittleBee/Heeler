import Foundation

/// Public message IDs survive the database writer replacing intermediate nodes.
struct DevinRecordSource: ChatTranscriptSource {
    let session, root: String
    private var first = 0
    private var next = 0
    private var total = 0
    private var olderRead = 0
    private var held: [Int: DevinSessionPage.Row] = [:]

    init?(session: String, root: String?) {
        guard DevinSession.id(session) != nil, let root, RemoteFilePath.isAcceptable(root), root.hasSuffix("/devin/cli") else { return nil }
        self.session = session
        self.root = root
    }

    var path: String { root + "/sessions.db#" + session }
    var head: Data? { Data(session.utf8) }
    var readOffset: UInt64 { UInt64(next) }
    var windowStart: UInt64? { UInt64(first) }
    var hasOlder: Bool { first > 0 }
    var hasUnreadRecords: Bool { next < total }
    var olderPageLengths: (first: Int, maximum: Int) { (24, 24) }
    var automaticOlderSearch: Int? { 24 }
    var olderSearchExhausted: Bool { olderRead >= 240 }

    private func read(_ files: ChatHostFiles, offset: Int?, count: Int, expanded: Bool = false, earlierWork: Bool = false) async throws -> DevinSessionPage {
        guard let query = files.queryDevin else { throw TransportError.hostFeatureUnavailable(feature: String(localized: "Devin Chat")) }
        var page = try await query(.init(session: session, root: root, offset: offset, limit: count, expanded: expanded, earlierWork: earlierWork))
        guard page.offset >= 0, page.total >= page.offset, page.rows.count <= count,
              page.rows.count <= page.total - page.offset,
              !page.rows.contains(where: { $0.id.isEmpty }) else { throw TransportError.hostStoreUnreadable(detail: "Invalid Devin page") }
        if expanded { return page } // Tool details verify the call ID before using the row.
        for i in page.rows.indices {
            let row = page.rows[i]
            guard row.truncated, row.role == "user" || row.role == "assistant" else { continue }
            page.rows[i].text = try await completeText(of: row, at: page.offset + i, query: query)
            page.rows[i].truncated = false
        }
        return page
    }

    private func completeText(of row: DevinSessionPage.Row, at position: Int,
                              query: @Sendable (DevinSessionQuery) async throws -> DevinSessionPage) async throws -> String {
        var start = row.text.unicodeScalars.count
        guard let body = row.fullText, body.length > start else {
            throw TransportError.hostStoreUnreadable(detail: String(localized: "Devin returned an invalid message length."))
        }
        if let previous = held[position], previous.id == row.id, previous.fullText == body, !previous.truncated {
            return previous.text
        }
        var text = row.text
        while start < body.length {
            try Task.checkCancellation()
            let part = DevinSessionQuery.MessageText(id: row.id, sha256: body.sha256, start: start)
            let reply = try await query(.init(session: session, root: root, offset: position, limit: 1, messageText: part))
            guard reply.offset == position, let chunk = reply.textChunk, !chunk.isEmpty else {
                throw TransportError.hostStoreUnreadable(detail: String(localized: "The Devin message changed while Chat was reading it."))
            }
            let length = chunk.unicodeScalars.count
            guard length <= body.length - start else {
                throw TransportError.hostStoreUnreadable(detail: String(localized: "Devin returned an invalid message range."))
            }
            text += chunk
            start += length
        }
        return text
    }

    mutating func open(_ files: ChatHostFiles) async throws -> [ChatLine]? {
        let page = try await read(files, offset: nil, count: 24, earlierWork: true)
        first = page.offset
        next = first + page.rows.count
        total = page.total
        held.removeAll()
        return try merge(page)
    }

    mutating func poll(_ files: ChatHostFiles) async throws -> TranscriptFollower.Change {
        let start = max(first, next - 2)
        let page = try await read(files, offset: start, count: 26)
        guard page.offset == start, page.total >= next, page.rows.enumerated().allSatisfy({ index, row in
            held[start + index].map { $0.id == row.id } ?? true
        }) else { return .reset(try await open(files) ?? [], replaced: false) }
        next = max(next, start + page.rows.count)
        total = page.total
        let lines = try merge(page)
        return lines.isEmpty ? .unchanged : .appended(lines)
    }

    mutating func beginOlderSearch() { olderRead = 0 }

    mutating func loadOlder(_ files: ChatHostFiles, length: Int?, limit: Int?) async throws -> TranscriptFollower.OlderPage {
        guard first > 0 else { return .headReached }
        let count = min(24, first, limit ?? 24)
        guard count > 0 else { return .beyondLimit }
        let page = try await read(files, offset: first - count, count: count + 1)
        guard page.rows.count == count + 1, page.rows.last?.id == held[first]?.id else { return .rewritten }
        first = page.offset
        olderRead += count
        return .lines(try merge(page))
    }

    func line(at reference: ChatOutputReference, files: ChatHostFiles) async throws -> ChatLine? {
        guard let i = Int(exactly: reference.offset), let previous = held[i],
              let call = reference.callID, previous.resultFor == call else { return nil }
        let page = try await read(files, offset: i, count: 1, expanded: true)
        guard let row = page.rows.first, row.id == previous.id, row.resultFor == call else { return nil }
        return try ChatLine(offset: reference.offset, data: JSONEncoder().encode(row))
    }

    private mutating func merge(_ page: DevinSessionPage) throws -> [ChatLine] {
        var result: [ChatLine] = []
        for (offset, var row) in page.rows.enumerated() {
            let position = page.offset + offset
            row.title = page.title
            row.model = page.model
            row.earlierWork = row.earlierWork ?? held[position]?.earlierWork
            guard held[position] != row else { continue }
            held[position] = row
            result.append(try ChatLine(offset: UInt64(position), data: JSONEncoder().encode(row)))
        }
        return result
    }
}
