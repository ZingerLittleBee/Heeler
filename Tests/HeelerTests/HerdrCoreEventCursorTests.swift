import Foundation
import Testing

@testable import Heeler

@Suite struct HerdrCoreEventCursorTests {
    private let vectors = HerdrCoreVectorFile.shared

    private func snapshot(sequence: Int) throws -> HerdrCoreSnapshot {
        try HerdrCoreSnapshot(result: .object([
            "seq": .number(Double(sequence)), "terminals": .array([]), "channel": .number(1),
        ]))
    }

    private func notification(type: String, target: String, sequence: Int) throws -> Data {
        try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "type": .string(type), "terminal": .string(target),
                "seq": .number(Double(sequence)), "data": .object([:]),
            ]),
        ]))
    }

    // MARK: Sequence rules, moved from the contributor's cursor tests

    @Test func missedSnapshotAdvancesCursorAndRejectsOlderBufferedEvents() throws {
        var cursor = HerdrCoreTypedEventCursor(snapshot: try snapshot(sequence: 10))
        #expect(try cursor.decode(line: notification(type: "removed", target: "t3", sequence: 10)) == nil)
        #expect(try cursor.decode(line: notification(type: "removed", target: "t3", sequence: 11)) == .removed(terminal: "t3"))
        let missed = Data(#"{"jsonrpc":"2.0","method":"missed","params":{"seq":20,"terminals":[]}}"#.utf8)
        guard case .missed(let replacement) = try cursor.decode(line: missed) else {
            Issue.record("missed must surface its snapshot")
            return
        }
        #expect(replacement.sequence == 20)
        #expect(replacement.terminals.isEmpty)
        #expect(try cursor.decode(line: notification(type: "removed", target: "t3", sequence: 19)) == nil)
        #expect(try cursor.decode(line: notification(type: "removed", target: "t3", sequence: 21)) != nil)
        let heartbeat = Data(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":21}}"#.utf8)
        #expect(try cursor.decode(line: heartbeat) == .heartbeat(sequence: 21))
        #expect(cursor.sequence == 21)
        #expect(throws: TransportError.self) { try HerdrCoreSnapshot(result: .object([:])) }
    }

    @Test func heartbeatDoesNotDiscardEventsStillQueuedForDelivery() throws {
        var cursor = HerdrCoreTypedEventCursor(snapshot: try snapshot(sequence: 10))
        let heartbeat = Data(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":12}}"#.utf8)
        #expect(try cursor.decode(line: heartbeat) == .heartbeat(sequence: 12))
        #expect(cursor.sequence == 10)
        #expect(try cursor.decode(line: notification(type: "removed", target: "t3", sequence: 11)) == .removed(terminal: "t3"))
        #expect(try cursor.decode(line: notification(type: "removed", target: "t3", sequence: 12)) == .removed(terminal: "t3"))
        #expect(cursor.sequence == 12)
    }

    @Test func aFreshCursorForAnotherConnectionAcceptsARestartedCoresLowerSequence() throws {
        var first = HerdrCoreTypedEventCursor(snapshot: try snapshot(sequence: 500))
        #expect(try first.decode(line: notification(type: "removed", target: "t3", sequence: 2)) == nil)
        // `seq` restarts at 0 with each core process and is never resumed.
        var next = HerdrCoreTypedEventCursor(snapshot: try snapshot(sequence: 1))
        #expect(try next.decode(line: notification(type: "removed", target: "t3", sequence: 2)) == .removed(terminal: "t3"))
    }

    @Test func anEventWithoutASequenceIsMalformed() {
        var cursor = HerdrCoreTypedEventCursor(sequence: 0)
        for line in [
            #"{"jsonrpc":"2.0","method":"event","params":{"type":"removed","terminal":"t3","data":{}}}"#,
            #"{"jsonrpc":"2.0","method":"heartbeat","params":{}}"#,
            #"{"jsonrpc":"2.0","method":"missed","params":{"terminals":[]}}"#,
            "not JSON",
        ] {
            #expect(throws: TransportError.self, "\(line)") { try cursor.decode(line: Data(line.utf8)) }
        }
    }

    @Test func unknownNotificationsAndFederatedTerminalsAreSkippedButAdvanceNothingElse() throws {
        var cursor = HerdrCoreTypedEventCursor(sequence: 0)
        let future = #"{"jsonrpc":"2.0","method":"future.notice","params":{"anything":true}}"#
        #expect(try cursor.decode(line: Data(future.utf8)) == nil)
        #expect(cursor.sequence == 0)
        #expect(try cursor.decode(line: notification(type: "removed", target: "rohan/t3", sequence: 1)) == nil)
        #expect(cursor.sequence == 1)
    }

    @Test func anUnknownEventKindAsksForAResync() throws {
        var cursor = HerdrCoreTypedEventCursor(sequence: 0)
        #expect(try cursor.decode(line: notification(type: "future", target: "t3", sequence: 1)) == .unknown(type: "future"))
    }

    @Test func aKnownEventMissingItsDataIsMalformed() {
        var cursor = HerdrCoreTypedEventCursor(sequence: 0)
        let line = #"{"jsonrpc":"2.0","method":"event","params":{"seq":1,"type":"title","terminal":"t3","data":{}}}"#
        #expect(throws: TransportError.self) { try cursor.decode(line: Data(line.utf8)) }
    }

    // MARK: Typed decoding from the shared vectors

    private func decodeVector(_ name: String) throws -> HerdrCoreEvent? {
        var cursor = HerdrCoreTypedEventCursor(sequence: 0)
        return try cursor.decode(line: vectors.event(name))
    }

    @Test func everyEventKindDecodesFromTheVectors() throws {
        #expect(try decodeVector("size") == .size(terminal: "t7", columns: 100, rows: 30))
        #expect(try decodeVector("title") == .title(terminal: "t7", title: "Working"))
        #expect(try decodeVector("foreground") == .foreground(
            terminal: "t7",
            HerdrCoreForeground(pid: 4300, name: "node", argv: ["node", "cli.js"], cwd: "/work/project")))
        #expect(try decodeVector("foreground-cleared") == .foreground(terminal: "t7", nil))
        #expect(try decodeVector("status") == .status(
            terminal: "t7",
            HerdrCoreTerminalStatus(state: "working", kind: nil, progress: 10, app: "claude-code", title: "", message: ""),
            records: [:], reported: true))
        #expect(try decodeVector("status-cleared") == .status(terminal: "t7", nil, records: [:], reported: true))
        #expect(try decodeVector("turn") == .turn(terminal: "t7", turn: 4, state: "done"))
        #expect(try decodeVector("turn-cleared") == .turn(terminal: "t7", turn: 5, state: nil))
        #expect(try decodeVector("labels") == .labels(terminal: "t7", ["heeler.workspace": "w2"]))
        #expect(try decodeVector("keep") == .keep(terminal: "t7", false))
        #expect(try decodeVector("doc") == .document(name: "herdr-app-layout", version: 9, machine: nil))
        #expect(try decodeVector("lost") == .lost(
            terminal: "t7",
            HerdrCoreTerminalEnd(reason: "signaled", exitCode: nil, signal: 9, finishedMilliseconds: nil)))
        #expect(try decodeVector("finished") == .finished(
            terminal: "t7",
            HerdrCoreTerminalEnd(reason: "exited", exitCode: 0, signal: nil, finishedMilliseconds: 1_790_000_001_000)))
        #expect(try decodeVector("removed") == .removed(terminal: "t7"))
        #expect(try decodeVector("heartbeat") == .heartbeat(sequence: 26))
        guard case .created(let created) = try decodeVector("created") else {
            Issue.record("created must carry its record")
            return
        }
        #expect(created.address == "t7")
        guard case .restarted(let restarted) = try decodeVector("restarted") else {
            Issue.record("restarted must carry its record")
            return
        }
        #expect(restarted.status == nil)
        #expect(restarted.reported == false)
    }

    @Test func everyVectorEventDecodesToATypedEvent() throws {
        for event in vectors.events {
            var cursor = HerdrCoreTypedEventCursor(sequence: 0)
            let decoded = try cursor.decode(line: Data(event.line.utf8))
            #expect(decoded != nil, "\(event.name)")
            if case .unknown = decoded { Issue.record("\(event.name) read as unknown") }
        }
    }

    @Test func everyTerminalRecordFieldDecodesAndUnknownFieldsAreIgnored() throws {
        guard case .created(let record) = try decodeVector("created") else {
            Issue.record("created must carry its record")
            return
        }
        #expect(record.address == "t7")
        #expect(record.name == "review")
        #expect(record.labels == ["heeler.workspace": "w1"])
        #expect(record.argv == ["/usr/local/bin/claude", "--resume"])
        #expect(record.cwd == "/work/project")
        #expect(record.keep)
        #expect(record.state == "live")
        #expect(record.pid == 4242)
        #expect(record.exitCode == nil)
        #expect(record.signal == nil)
        #expect(record.reason == nil)
        #expect(record.createdMilliseconds == 1_790_000_000_000)
        #expect(record.finishedMilliseconds == nil)
        #expect(record.screen == "exact")
        #expect(record.columns == 120)
        #expect(record.rows == 40)
        #expect(record.identity == "ghostty 1.4.0")
        #expect(record.status == HerdrCoreTerminalStatus(
            state: "blocked", kind: "permission", progress: 40, app: "claude-code",
            title: "Reviewing", message: "Allow edit?"))
        #expect(record.statusMilliseconds == 1_790_000_000_500)
        #expect(record.records == ["child": HerdrCoreTerminalStatus(
            state: "working", kind: nil, progress: nil, app: "claude-code", title: "", message: "")])
        #expect(record.turn == 3)
        #expect(record.reported)
        #expect(record.title == "Reviewing")
        #expect(record.parent == "t3")
        #expect(record.notify)
        #expect(record.dieWithParent == false)
        #expect(record.removeOnExit == false)
        #expect(record.template == "reviewer")
        #expect(record.submit == "enter")
        #expect(record.stop == "esc")
        #expect(record.pasteGapMilliseconds == 120)
        #expect(record.foreground == HerdrCoreForeground(
            pid: 4300, name: "node", argv: ["node", "/opt/claude/cli.js"], cwd: "/work/project/child"))
    }

    @Test func recordFieldsThatDefaultWhenAbsentDecodeTheirOwnValues() throws {
        guard case .missed(let snapshot) = try decodeVector("missed-killed-rm-record") else {
            Issue.record("missed must surface its snapshot")
            return
        }
        let record = try #require(snapshot.terminals.first)
        #expect(record.signal == 9)
        #expect(record.reason == "killed")
        #expect(record.finishedMilliseconds == 1_790_000_002_000)
        #expect(record.dieWithParent)
        #expect(record.removeOnExit)
    }

    @Test func theSubscribeSnapshotAndMissedCarryRecordsWithoutFederatedTerminals() throws {
        let exchange = try vectors.exchange("events-subscribe")
        let snapshot = try HerdrCoreSnapshot(result: exchange.result)
        #expect(snapshot.sequence == 10)
        #expect(snapshot.channel == 1)
        #expect(snapshot.terminals.map(\.address) == ["t7", "t8"])
        #expect(snapshot.terminals[1].state == "finished")
        #expect(snapshot.terminals[1].exitCode == 0)
        guard case .missed(let missed) = try decodeVector("missed") else {
            Issue.record("missed must surface its snapshot")
            return
        }
        #expect(missed.sequence == 40)
        #expect(missed.channel == nil)
        #expect(missed.terminals.map(\.address) == ["t7", "t8"])
    }

    @Test func onlyTheAddressOfARecordIsRequired() throws {
        let snapshot = try HerdrCoreSnapshot(result: .object([
            "seq": .number(1),
            "terminals": .array([
                .object([
                    "address": .string("t1"), "status": .object(["app": .string("pi")]),
                    "foreground": .object(["name": .string("pi")]),
                ])
            ]),
        ]))
        let record = try #require(snapshot.terminals.first)
        #expect(record.argv.isEmpty)
        #expect(record.status?.app == "pi")
        #expect(record.foreground == HerdrCoreForeground(pid: nil, name: "pi", argv: [], cwd: ""))
    }

    @Test func aRecordWithoutAnAddressCannotMasqueradeAsAnEmptySnapshot() {
        #expect(throws: TransportError.self) {
            try HerdrCoreSnapshot(result: .object([
                "seq": .number(1), "terminals": .array([.object(["cwd": .string("/a")])]),
            ]))
        }
    }

    // MARK: Line reassembly

    @Test func linesReassembleAcrossAndWithinChunks() throws {
        var buffer = HerdrCoreLineBuffer()
        #expect(try buffer.append(Data("{\"a\"".utf8)) == [])
        #expect(try buffer.append(Data(":1}\n{\"b\":2}\n\n{\"c\"".utf8)) == [
            Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8),
        ])
        #expect(try buffer.append(Data(":3}\n".utf8)) == [Data("{\"c\":3}".utf8)])
    }

    @Test func aLineOverTheLimitIsRefused() throws {
        var buffer = HerdrCoreLineBuffer(maximumLineBytes: 8)
        #expect(try buffer.append(Data("12345678\n".utf8)).count == 1)
        #expect(throws: TransportError.self) { try buffer.append(Data("123456789".utf8)) }
    }

    @Test func aFrameOfTwoLinesAndALineAcrossTwoFramesBothDecode() throws {
        for vector in vectors.eventFrames {
            var decoder = HerdrCoreFrameDecoder()
            decoder.append(HerdrCoreVectorFile.bytes(hex: vector.bytes))
            var buffer = HerdrCoreLineBuffer()
            var lines: [Data] = []
            while let frame = try decoder.next() { lines += try buffer.append(frame.payload) }
            #expect(lines.count == vector.lines, "\(vector.name)")
            var cursor = HerdrCoreTypedEventCursor(sequence: 0)
            for line in lines { #expect(try cursor.decode(line: line) != nil, "\(vector.name)") }
        }
    }
}

@Suite struct HerdrCoreVectorFileTests {
    @Test func theFileIsMarkedProvisionalAndEveryCaseNamesItsSource() {
        let vectors = HerdrCoreVectorFile.shared
        #expect(vectors.provisional)
        #expect(vectors.coreVersion == "0.1.13")
        #expect(vectors.coreCommit == "88fe4e7")
        // Pinned against the file: a section that stops decoding cannot pass quietly.
        #expect(vectors.allCases.count == 1 + 10 + 3 + 4 + 19 + 2)
        #expect(Set(vectors.allCases.map(\.name)).count == vectors.allCases.count)
        for testCase in vectors.allCases {
            #expect(testCase.source.contains("herdr-core v0.1.13"), "\(testCase.name)")
            #expect(testCase.source.contains(".rs"), "\(testCase.name)")
        }
    }

    @Test func everyFrameCaseDecodesAndReencodesToItsExactBytes() throws {
        for vector in HerdrCoreVectorFile.shared.frames {
            let bytes = HerdrCoreVectorFile.bytes(hex: vector.bytes)
            var decoder = HerdrCoreFrameDecoder()
            decoder.append(bytes)
            let frame = try #require(try decoder.next(), "\(vector.name)")
            #expect(try frame.encoded() == bytes, "\(vector.name)")
            #expect(try decoder.next() == nil, "\(vector.name)")
        }
    }

    @Test func everyExchangeFramesARequestAndAReplyOnChannelZero() throws {
        for exchange in HerdrCoreVectorFile.shared.exchanges {
            for hex in [exchange.requestFrame, exchange.replyFrame] {
                var decoder = HerdrCoreFrameDecoder()
                decoder.append(HerdrCoreVectorFile.bytes(hex: hex))
                let frame = try #require(try decoder.next(), "\(exchange.name)")
                #expect(frame.channel == 0)
                #expect(frame.kind == .data)
            }
            var decoder = HerdrCoreFrameDecoder()
            decoder.append(HerdrCoreVectorFile.bytes(hex: exchange.replyFrame))
            let reply = try #require(try decoder.next())
            let id = try #require(HerdrCoreWire.responseID(from: reply.payload))
            #expect(try HerdrCoreWire.result(from: reply.payload, id: id) == exchange.result)
        }
    }
}
