import Foundation
import HeelerSSH
import Testing

@testable import Heeler

/// OpenCode store queries through a real exec on the fixture Host (ADR
/// 0025). The store is a scratch one the harness builds, uploaded over SFTP
/// to the fixture account's default path; a Host that already has a store
/// there is refused rather than touched.
extension HeelerSSHTransportBehaviorE2ETests {
    @Test("an OpenCode query reads a scratch store read-only through a real exec")
    func openCodeQueryReadsAScratchStoreReadOnly() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let fixture = try OpenCodeStoreFixture.named("steer")
        let tail = OpenCodeQuery(session: try #require(fixture.sessionID), kind: .tail(budget: 524_288))
        // The harness's connection stays open, so the store has its side
        // files, as a running OpenCode's does.
        let harness = try OpenCodeSQLiteHarness(fixture, journal: .wal)
        try OpenCodeScratchStore.addRefusedCompaction(to: harness, session: tail.session)
        let files = try harness.storeFiles()
        try #require(Set(files.keys) == ["opencode.db", "opencode.db-wal", "opencode.db-shm"])
        try await OpenCodeScratchStore.with(files, environment: environment) { store in
            let transport = try await HeelerSSHTransport.connect(settings: environment.directSettings())
            defer { Task { try? await transport.close() } }
            let before = try await store.snapshot()

            let response = try await transport.queryOpenCode(tail)
            guard case .records(let records) = response else {
                Issue.record("expected records, read \(response)")
                return
            }
            try OpenCodeScratchStore.expect(records, matches: harness.records(tail))
            try OpenCodeScratchStore.expectRefusedCompaction(in: records)
            let cursor = OpenCodePollCursor(
                eventSeq: records.eventSeq, lowSeq: try #require(records.rows.first?.seq),
                highSeq: try #require(records.rows.last?.seq), knownInWindow: records.rows.count,
                openRows: [], updatedSince: 0, budget: 524_288)
            let poll = OpenCodeQuery(session: tail.session, kind: .poll(cursor))
            #expect(try await transport.queryOpenCode(poll) == .unchanged(eventSeq: records.eventSeq))

            // A reader may rewrite the `-shm` index; nothing else changes.
            let after = try await store.snapshot()
            #expect(after.names == before.names)
            #expect(after.database == before.database, "the query changed opencode.db")
            #expect(after.wal == before.wal, "the query changed opencode.db-wal")
        }
    }

    @Test("a closed OpenCode store reads as closed")
    func aClosedOpenCodeStoreReadsAsClosed() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let fixture = try OpenCodeStoreFixture.named("pong")
        let tail = OpenCodeQuery(session: try #require(fixture.sessionID), kind: .tail(budget: 524_288))
        // OpenCode's last connection closing checkpoints the store and
        // removes its side files, so only the database is uploaded.
        let harness = try OpenCodeSQLiteHarness(fixture, journal: .wal)
        harness.closeConnection()
        let database = try #require(try harness.storeFiles()["opencode.db"])
        try await OpenCodeScratchStore.with(["opencode.db": database], environment: environment) { store in
            let transport = try await HeelerSSHTransport.connect(settings: environment.directSettings())
            defer { Task { try? await transport.close() } }
            let before = try await store.snapshot()

            #expect(try await transport.queryOpenCode(tail) == .unavailable(.storeClosed))
            #expect(try await transport.queryOpenCode(tail, reader: .pythonOnly) == .unavailable(.storeClosed))

            let after = try await store.snapshot()
            #expect(after.names == ["opencode.db"], "a reader created \(after.names)")
            #expect(after.database == before.database)
        }
    }

    /// Reads only where the Host has a `python3` that is not Darwin's
    /// install shim; elsewhere the Python-only script finds no reader, and
    /// the test says so and stops.
    @Test("an OpenCode query reads through python3")
    func openCodeQueryReadsThroughPython() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let fixture = try OpenCodeStoreFixture.named("patch")
        let session = try #require(fixture.sessionID)
        let tail = OpenCodeQuery(session: session, kind: .tail(budget: 524_288))
        let row = OpenCodeQuery(session: session, kind: .row(seq: 92, outputLimit: 262_144))
        let harness = try OpenCodeSQLiteHarness(fixture, journal: .wal)
        try OpenCodeScratchStore.addRefusedCompaction(to: harness, session: session)
        let files = try harness.storeFiles()
        try await OpenCodeScratchStore.with(files, environment: environment) { store in
            let transport = try await HeelerSSHTransport.connect(settings: environment.directSettings())
            defer { Task { try? await transport.close() } }
            let before = try await store.snapshot()

            let response = try await transport.queryOpenCode(tail, reader: .pythonOnly)
            if response == .unavailable(.noReader) {
                print("[opencode-store] no python3 but Darwin's shim on the fixture Host; Python not exercised")
                return
            }
            guard case .records(let records) = response else {
                Issue.record("expected records, read \(response)")
                return
            }
            try OpenCodeScratchStore.expect(records, matches: harness.records(tail))
            try OpenCodeScratchStore.expectRefusedCompaction(in: records)
            let fetched = try await transport.queryOpenCode(row, reader: .pythonOnly)
            guard case .records(let single) = fetched else {
                Issue.record("expected the row, read \(fetched)")
                return
            }
            try OpenCodeScratchStore.expect(single, matches: harness.records(row))

            let after = try await store.snapshot()
            #expect(after.names == before.names)
            #expect(after.database == before.database)
            #expect(after.wal == before.wal)
        }
    }
}

/// A scratch OpenCode store at `~/.local/share/opencode` on the fixture Host,
/// uploaded over SFTP through a connection of its own and removed afterwards.
private struct OpenCodeScratchStore {
    struct Snapshot: Equatable {
        var names: [String]
        var database: Data?
        var wal: Data?
    }

    struct Refused: Error, CustomStringConvertible {
        let description: String
    }

    private static let timeout: Duration = .seconds(15)

    let connection: SSHConnection
    let directory: String
    let quoted: String

    /// Uploads `files` into a new store directory, runs `body`, then removes
    /// the directory. Refuses when the directory already exists.
    static func with(
        _ files: [String: Data], environment: HeelerSSHTransportBehaviorEnvironment,
        _ body: (OpenCodeScratchStore) async throws -> Void
    ) async throws {
        let directory = environment.homePath + "/.local/share/opencode"
        let quoted = try #require(RemoteShellPath.quotedAbsolute(directory))
        let deviceKey = DeviceKey(privateKey: environment.deviceKey)
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: environment.host, port: environment.port),
            timeout: RealSSHFixture.setupTimeout)
        do {
            try await connection.authenticate(
                username: environment.username, publicKey: deviceKey.publicKeyBlob,
                signer: { data in try deviceKey.privateKey.signature(for: data) },
                timeout: RealSSHFixture.setupTimeout)
            let created = try await connection.execute(
                "if [ -e \(quoted) ]; then echo exists; else mkdir -p \(quoted) && chmod 700 \(quoted) && echo created; fi",
                timeout: timeout)
            guard created.stdout == Data("created\n".utf8) else {
                throw Refused(
                    description: "the fixture Host already has \(directory), or it could not be created: "
                        + String(decoding: created.stdout + created.stderr, as: UTF8.self))
            }
            let store = OpenCodeScratchStore(connection: connection, directory: directory, quoted: quoted)
            do {
                try await store.upload(files)
                try await body(store)
            } catch {
                _ = try? await connection.execute("rm -rf \(quoted)", timeout: timeout)
                throw error
            }
            let removed = try await connection.execute("rm -rf \(quoted)", timeout: timeout)
            #expect(removed.exitStatus == 0)
            try await connection.close(timeout: .seconds(2))
        } catch {
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
    }

    private func upload(_ files: [String: Data]) async throws {
        let sftp = try await connection.openSFTP(timeout: Self.timeout)
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            let file = try await sftp.openFileForWriting(
                at: "\(directory)/\(name)", permissions: 0o600, timeout: Self.timeout)
            try await file.write(data, timeout: Self.timeout)
            try await file.close(timeout: Self.timeout)
        }
        try await sftp.close(timeout: Self.timeout)
    }

    /// The directory's names, and the bytes a reader must never change.
    func snapshot() async throws -> Snapshot {
        let listing = try await connection.execute("ls -A \(quoted)", timeout: Self.timeout)
        let sftp = try await connection.openSFTP(timeout: Self.timeout)
        let database = try await sftp.readFileIfPresent(at: "\(directory)/opencode.db", timeout: Self.timeout)
        let wal = try await sftp.readFileIfPresent(at: "\(directory)/opencode.db-wal", timeout: Self.timeout)
        try await sftp.close(timeout: Self.timeout)
        return Snapshot(
            names: String(decoding: listing.stdout, as: UTF8.self).split(separator: "\n").map(String.init).sorted(),
            database: database, wal: wal)
    }

    /// Where `addRefusedCompaction` puts its row: past every fixture's rows.
    private static let refusedCompactionSeq: Int64 = 363

    /// Adds the row OpenCode 2.0.32 records for a `/compact` with nothing
    /// to compact, as captured (its time moved).
    static func addRefusedCompaction(to harness: OpenCodeSQLiteHarness, session: OpenCodeSessionID) throws {
        try harness.insert(into: "session_message", [
            "id": .text("msg_refused_compaction"), "session_id": .text(session.rawValue),
            "type": .text("compaction"), "seq": .integer(refusedCompactionSeq),
            "time_created": .integer(1_800_000_100_363), "time_updated": .integer(1_800_000_100_363),
            "data": .text(
                #"{"time":{"created":1800000100363},"status":"failed","reason":"manual","#
                    + #""error":{"type":"compaction.unavailable","message":"Nothing to compact yet"}}"#),
        ])
    }

    /// The Host's reader keeps that row's error in its slim row.
    static func expectRefusedCompaction(in records: OpenCodeRecords) throws {
        let row = try #require(records.rows.first { $0.seq == refusedCompactionSeq })
        let line = try #require(try JSONSerialization.jsonObject(with: row.line) as? [String: Any])
        let data = try #require(line["d"] as? [String: Any])
        let error = data["error"] as? NSDictionary
        #expect(error == ["type": "compaction.unavailable", "message": "Nothing to compact yet"])
    }

    /// The Host's reader and the in-process one print the same records. JSON
    /// is compared parsed, since SQLite versions may escape it differently.
    static func expect(_ records: OpenCodeRecords, matches expected: OpenCodeRecords) throws {
        #expect(records.eventSeq == expected.eventSeq)
        #expect(records.firstSeq == expected.firstSeq)
        #expect(records.windowCount == expected.windowCount)
        #expect(!records.overflow)
        #expect(records.ignoredLines == 0)
        #expect(records.rows.map(\.seq) == expected.rows.map(\.seq))
        #expect(records.rows.map(\.isFinal) == expected.rows.map(\.isFinal))
        #expect(try parsed(records.sessionLine) == parsed(expected.sessionLine))
        #expect(try parsed(records.inboxLine) == parsed(expected.inboxLine))
        for (row, expectedRow) in zip(records.rows, expected.rows) {
            #expect(try parsed(row.line) == parsed(expectedRow.line), "row \(row.seq)")
        }
    }

    private static func parsed(_ line: Data?) throws -> NSObject? {
        guard let line else { return nil }
        return try JSONSerialization.jsonObject(with: line) as? NSObject
    }
}
