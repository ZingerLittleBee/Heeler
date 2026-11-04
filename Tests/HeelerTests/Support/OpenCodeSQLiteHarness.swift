import Foundation
import SQLite3

@testable import Heeler

/// One value of a `session_v2` column in a store fixture.
enum OpenCodeColumnValue: Decodable, Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .real(value)
        } else {
            self = .text(try container.decode(String.self))
        }
    }
}

/// `ChatFixtures/opencode/store-<scenario>.json` (the README there records
/// where each comes from): one session's `session_v2` row, its event
/// counter, its `session_message` rows and its inbox, plus other sessions in
/// the same store. `data` and `payload` hold JSON text, as OpenCode stores
/// them.
struct OpenCodeStoreFixture: Decodable, Sendable {
    struct Row: Decodable, Sendable {
        var id: String
        var type: String
        var seq: Int64
        var timeCreated: Int64
        var timeUpdated: Int64
        var data: String

        private enum CodingKeys: String, CodingKey {
            case id, type, seq, data
            case timeCreated = "time_created"
            case timeUpdated = "time_updated"
        }
    }

    struct InboxItem: Decodable, Sendable {
        var id: String
        var type: String
        var payload: String
        var delivery: String
        var enqueuedSeq: Int64
        var timeCreated: Int64

        private enum CodingKeys: String, CodingKey {
            case id, type, payload, delivery
            case enqueuedSeq = "enqueued_seq"
            case timeCreated = "time_created"
        }
    }

    var session: [String: OpenCodeColumnValue]
    var eventSeq: Int64?
    var rows: [Row]
    var inbox: [InboxItem]
    var otherSessions: [OpenCodeStoreFixture]

    private enum CodingKeys: String, CodingKey {
        case session, rows, inbox, otherSessions
        case eventSeq = "event_seq"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode([String: OpenCodeColumnValue].self, forKey: .session)
        eventSeq = try container.decodeIfPresent(Int64.self, forKey: .eventSeq)
        rows = try container.decode([Row].self, forKey: .rows)
        inbox = try container.decode([InboxItem].self, forKey: .inbox)
        otherSessions =
            try container.decodeIfPresent([OpenCodeStoreFixture].self, forKey: .otherSessions) ?? []
    }

    var sessionID: OpenCodeSessionID? {
        guard case .text(let id) = session["id"] else { return nil }
        return OpenCodeSessionID(id)
    }

    static func named(_ scenario: String) throws -> OpenCodeStoreFixture {
        try JSONDecoder().decode(Self.self, from: ChatFixture.data("opencode/store-\(scenario).json"))
    }

    /// The scenario of every `store-<scenario>.json`.
    static func scenarios() throws -> [String] {
        try ChatFixture.fileNames(in: "opencode").compactMap { name in
            guard name.hasPrefix("store-"), name.hasSuffix(".json") else { return nil }
            return String(name.dropFirst(6).dropLast(5))
        }
    }
}

/// A scratch OpenCode store, built from `ChatFixtures/opencode/schema.sql`
/// and store fixtures, that answers `OpenCodeProbe.statements(_:)` in
/// process the way the Host's `sqlite3` CLI does: read-only, `query_only`,
/// the version and then every other statement inside one transaction, each
/// row's text on its own line as `-list` prints it (an empty line for NULL),
/// and a failure on stderr in the CLI's words. The output carries the
/// script's markers and its `Z`, `W` and `O` lines, with the rows and the
/// `Z` line cut at `OpenCodeProbe.outputCap` as the script's `head -c` cuts
/// them, so `OpenCodeProbe.parse` reads it as it reads a Host's.
///
/// Where the test's SQLite can cap its parser stack, every read parses on
/// the fixed stack SQLite had before 3.46, as Debian 12's does.
final class OpenCodeSQLiteHarness {
    /// `SQLITE_LIMIT_PARSER_DEPTH` (SQLite 3.51 and newer), which the SDKs
    /// CI builds with do not name.
    static let parserDepthLimit: Int32 = 12
    /// The parser stack of SQLite before 3.46, which could not grow: a
    /// statement nested deeper fails with "parser stack overflow".
    static let fixedParserStack: Int32 = 100

    /// Whether this SQLite can cap its parser stack, and so read as one
    /// before 3.46 does. iOS 26's SQLite 3.50 cannot.
    static let limitsParserDepth: Bool = {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard sqlite3_open_v2(":memory:", &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        else { return false }
        return sqlite3_limit(connection, parserDepthLimit, -1) >= 0
    }()

    enum Journal {
        /// No side files: the store as a test reads it in process.
        case rollback
        /// OpenCode's own mode: `-wal` and `-shm` exist while the harness's
        /// connection is open.
        case wal
    }

    struct Output {
        var stdout: Data
        var stderr: Data
        var exitStatus: Int32
        var nonce: String
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The store's `XDG_DATA_HOME`: the database is `opencode/opencode.db`
    /// below it.
    let dataHome: URL
    let databaseURL: URL
    /// The script's `W` line: whether the `-wal` and `-shm` files exist.
    var walPresent = true
    var shmPresent = true
    /// Store names the script's `O` line prints after a tail read.
    var otherStores: [String] = []

    private var writer: OpaquePointer?

    /// - Parameter schema: DDL in place of `schema.sql`. Fixture columns the
    ///   schema lacks are left out, so a test can drop a column or a table.
    init(_ fixture: OpenCodeStoreFixture, schema: String? = nil, journal: Journal = .rollback) throws {
        dataHome = FileManager.default.temporaryDirectory
            .appending(path: "opencode-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        let directory = dataHome.appending(path: "opencode", directoryHint: .isDirectory)
        databaseURL = directory.appending(path: "opencode.db")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var connection: OpaquePointer?
        let opened = sqlite3_open_v2(
            databaseURL.path(percentEncoded: false), &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        writer = connection
        guard opened == SQLITE_OK else {
            throw Failure(description: "could not create the store: \(Self.message(connection))")
        }
        if journal == .wal {
            try execute("PRAGMA journal_mode = WAL")
        }
        try execute(schema ?? ChatFixture.text("opencode/schema.sql"))
        try insert(fixture)
    }

    convenience init(scenario: String, schema: String? = nil, journal: Journal = .rollback) throws {
        try self.init(OpenCodeStoreFixture.named(scenario), schema: schema, journal: journal)
    }

    deinit {
        sqlite3_close(writer)
        try? FileManager.default.removeItem(at: dataHome)
    }

    // MARK: Changing the store

    /// Runs SQL on the harness's own read-write connection, to change the
    /// store between reads the way OpenCode would.
    func execute(_ sql: String) throws {
        guard let writer else { throw Failure(description: "the harness's connection is closed") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(writer, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw Failure(description: error.map { String(cString: $0) } ?? Self.message(writer))
        }
    }

    /// Adds a fixture's session row, counter, rows and inbox, then its other
    /// sessions.
    func insert(_ fixture: OpenCodeStoreFixture) throws {
        try insert(into: "session_v2", fixture.session)
        if let eventSeq = fixture.eventSeq, let id = fixture.session["id"] {
            try insert(into: "event_sequence", ["aggregate_id": id, "seq": .integer(eventSeq)])
        }
        let sessionID = fixture.session["id"] ?? .null
        for row in fixture.rows {
            try insert(into: "session_message", [
                "id": .text(row.id), "session_id": sessionID, "type": .text(row.type),
                "seq": .integer(row.seq), "time_created": .integer(row.timeCreated),
                "time_updated": .integer(row.timeUpdated), "data": .text(row.data),
            ])
        }
        for item in fixture.inbox {
            try insert(into: "session_inbox", [
                "id": .text(item.id), "session_id": sessionID, "type": .text(item.type),
                "payload": .text(item.payload), "delivery": .text(item.delivery),
                "enqueued_seq": .integer(item.enqueuedSeq), "time_created": .integer(item.timeCreated),
            ])
        }
        for other in fixture.otherSessions {
            try insert(other)
        }
    }

    /// Inserts the columns of `values` that `table` has; nothing when the
    /// table is missing.
    func insert(into table: String, _ values: [String: OpenCodeColumnValue]) throws {
        let present = try columns(of: table)
        let names = values.keys.filter(present.contains).sorted()
        guard !names.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ", ")
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard
            sqlite3_prepare_v2(
                writer, "INSERT INTO \(table) (\(names.joined(separator: ", "))) VALUES (\(placeholders))",
                -1, &statement, nil) == SQLITE_OK
        else {
            throw Failure(description: "insert into \(table): \(Self.message(writer))")
        }
        for (index, name) in names.enumerated() {
            Self.bind(values[name] ?? .null, at: Int32(index + 1), in: statement)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw Failure(description: "insert into \(table): \(Self.message(writer))")
        }
    }

    /// Closes the harness's own connection, as OpenCode's last connection
    /// closing does: a WAL store is checkpointed into `opencode.db`.
    func closeConnection() {
        sqlite3_close(writer)
        writer = nil
    }

    /// The store's files as they are now, by name: `opencode.db`, plus
    /// `-wal` and `-shm` while a WAL store's connection is open.
    func storeFiles() throws -> [String: Data] {
        let directory = databaseURL.deletingLastPathComponent()
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) {
            files[name] = try Data(contentsOf: directory.appending(path: name))
        }
        return files
    }

    // MARK: Reading

    /// What the Host script prints for `query` against this store.
    func output(_ query: OpenCodeQuery, nonce: String = OpenCodeProbe.makeNonce()) -> Output {
        var body = Data()
        var stderr = Data()
        var status: Int32 = 0
        var reader: OpaquePointer?
        defer { sqlite3_close(reader) }
        if sqlite3_open_v2(databaseURL.path(percentEncoded: false), &reader, SQLITE_OPEN_READONLY, nil)
            != SQLITE_OK
        {
            stderr.append(Data("Error: unable to open database file\n".utf8))
            status = 1
        } else {
            sqlite3_busy_timeout(reader, 1000)
            sqlite3_limit(reader, Self.parserDepthLimit, Self.fixedParserStack)
            let statements = OpenCodeProbe.statements(query)
            // The CLI reads `.timeout` from line 1 of its input.
            var line = 2
            for sql in ["PRAGMA query_only = 1"] + statements.prefix(1) + ["BEGIN"]
                + statements.dropFirst() + ["COMMIT"]
            {
                if let failure = Self.print(sql, reader: reader, line: line, into: &body) {
                    stderr.append(Data("\(failure)\n".utf8))
                    status = 1
                    break
                }
                line += sql.split(separator: "\n", omittingEmptySubsequences: false).count
            }
        }
        var stdout = Data("\(OpenCodeProbe.beginMarker(nonce: nonce))\n".utf8)
        body.append(Data("Z \(status)\n".utf8))
        stdout.append(body.prefix(OpenCodeProbe.outputCap))
        stdout.append(Data("W \(walPresent ? 1 : 0) \(shmPresent ? 1 : 0)\n".utf8))
        if case .tail = query.kind, !otherStores.isEmpty {
            stdout.append(Data("O \(otherStores.joined(separator: " "))\n".utf8))
        }
        stdout.append(Data("\n\(OpenCodeProbe.endMarker(nonce: nonce))\n".utf8))
        return Output(stdout: stdout, stderr: stderr, exitStatus: 0, nonce: nonce)
    }

    /// The text between the markers, one element per line.
    func lines(_ query: OpenCodeQuery) -> [String] {
        let output = output(query)
        let text = String(decoding: output.stdout, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return Array(lines.dropFirst().dropLast(3))
    }

    func response(_ query: OpenCodeQuery) throws -> OpenCodeQueryResponse {
        let output = output(query)
        return try OpenCodeProbe.parse(
            stdout: output.stdout, stderr: output.stderr, exitStatus: output.exitStatus,
            nonce: output.nonce, query: query)
    }

    func records(_ query: OpenCodeQuery) throws -> OpenCodeRecords {
        let response = try response(query)
        guard case .records(let records) = response else {
            throw Failure(description: "expected records, read \(response)")
        }
        return records
    }

    /// Prepares `sql` against this store without running it, on a parser
    /// stack of at most `parserStack` entries or with expressions at most
    /// `expressionDepth` deep: nil when it parses, else SQLite's message.
    func prepareFailure(_ sql: String, parserStack: Int32? = nil, expressionDepth: Int32? = nil) -> String? {
        var reader: OpaquePointer?
        defer { sqlite3_close(reader) }
        guard sqlite3_open_v2(databaseURL.path(percentEncoded: false), &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { return "unable to open database file" }
        if let parserStack {
            sqlite3_limit(reader, Self.parserDepthLimit, parserStack)
        }
        if let expressionDepth {
            sqlite3_limit(reader, SQLITE_LIMIT_EXPR_DEPTH, expressionDepth)
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        return sqlite3_prepare_v2(reader, sql, -1, &statement, nil) == SQLITE_OK ? nil : Self.message(reader)
    }

    // MARK: SQLite

    private func columns(of table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard
            sqlite3_prepare_v2(writer, "SELECT name FROM pragma_table_info(?)", -1, &statement, nil)
                == SQLITE_OK
        else {
            throw Failure(description: "table info: \(Self.message(writer))")
        }
        Self.bind(.text(table), at: 1, in: statement)
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 0) {
                names.insert(String(cString: name))
            }
        }
        return names
    }

    /// Prints one statement's rows as the CLI's list mode does, or returns
    /// its failure as the CLI words it.
    private static func print(
        _ sql: String, reader: OpaquePointer?, line: Int, into body: inout Data
    ) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(reader, sql, -1, &statement, nil) == SQLITE_OK else {
            return "Parse error near line \(line): \(message(reader))"
        }
        while true {
            let step = sqlite3_step(statement)
            switch step {
            case SQLITE_ROW:
                if let text = sqlite3_column_text(statement, 0) {
                    body.append(text, count: Int(sqlite3_column_bytes(statement, 0)))
                }
                body.append(0x0A)
            case SQLITE_DONE:
                return nil
            default:
                return "Runtime error near line \(line): \(message(reader)) (\(step))"
            }
        }
    }

    private static func bind(_ value: OpenCodeColumnValue, at index: Int32, in statement: OpaquePointer?) {
        switch value {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer(let value):
            sqlite3_bind_int64(statement, index, value)
        case .real(let value):
            sqlite3_bind_double(statement, index, value)
        case .text(let value):
            sqlite3_bind_text(statement, index, value, -1, transient)
        }
    }

    /// `SQLITE_TRANSIENT`: SQLite copies the bound text.
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static func message(_ connection: OpaquePointer?) -> String {
        sqlite3_errmsg(connection).map { String(cString: $0) } ?? "SQLite error"
    }
}
