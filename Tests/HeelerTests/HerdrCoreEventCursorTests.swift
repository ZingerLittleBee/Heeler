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
        #expect(try decodeVector("size") == .size(terminal: "t3", columns: 100, rows: 30))
        #expect(try decodeVector("title") == .title(terminal: "t3", title: "Working"))
        guard case .foreground("t3", let foreground?) = try decodeVector("foreground") else {
            Issue.record("foreground must carry its process")
            return
        }
        #expect((foreground.pid ?? 0) > 0)
        #expect(foreground.name == "zsh")
        #expect(foreground.argv == ["/bin/zsh"])
        #expect(foreground.cwd == "/home/user")
        #expect(try decodeVector("foreground-cleared") == .foreground(terminal: "t6", nil))
        #expect(try decodeVector("status") == .status(
            terminal: "t3",
            HerdrCoreTerminalStatus(state: "working", kind: nil, progress: 10, app: "claude-code", title: "", message: ""),
            records: [:], reported: true))
        #expect(try decodeVector("status-cleared") == .status(terminal: "t3", nil, records: [:], reported: true))
        #expect(try decodeVector("turn") == .turn(terminal: "t3", turn: 1, state: "done"))
        #expect(try decodeVector("turn-cleared") == .turn(terminal: "t3", turn: 2, state: nil))
        #expect(try decodeVector("labels") == .labels(terminal: "t3", ["heeler.workspace": "w2"]))
        #expect(try decodeVector("keep") == .keep(terminal: "t3", false))
        #expect(try decodeVector("doc") == .document(name: "herdr-app-layout", version: 1, machine: nil))
        #expect(try decodeVector("lost") == .lost(
            terminal: "t3",
            HerdrCoreTerminalEnd(reason: "signaled", exitCode: nil, signal: 9, finishedMilliseconds: nil)))
        guard case .finished("t4", let end) = try decodeVector("finished") else {
            Issue.record("finished must carry how it ended")
            return
        }
        #expect(end.reason == "exited")
        #expect(end.exitCode == 0)
        #expect(end.signal == nil)
        #expect((end.finishedMilliseconds ?? 0) > 0)
        #expect(try decodeVector("removed") == .removed(terminal: "t4"))
        guard case .heartbeat(let sequence) = try decodeVector("heartbeat") else {
            Issue.record("heartbeat must carry its sequence")
            return
        }
        #expect(sequence > 0)
        guard case .created(let created) = try decodeVector("created") else {
            Issue.record("created must carry its record")
            return
        }
        #expect(created.address == "t3")
        #expect(created.name == "review")
        #expect(created.labels == ["heeler.workspace": "w1"])
        #expect(created.keep)
        guard case .restarted(let restarted) = try decodeVector("restarted") else {
            Issue.record("restarted must carry its record")
            return
        }
        #expect(restarted.status == nil)
        #expect(restarted.reported == false)
        #expect(restarted.argv == ["/bin/zsh"])
    }

    @Test func everyVectorEventDecodesToATypedEvent() throws {
        for event in vectors.events {
            var cursor = HerdrCoreTypedEventCursor(sequence: 0)
            let decoded = try cursor.decode(line: Data(event.line.utf8))
            #expect(decoded != nil, "\(event.name)")
            if case .unknown = decoded { Issue.record("\(event.name) read as unknown") }
        }
    }

    /// A record from the captured `missed` snapshot, by the name the capture gave it.
    private func missedRecord(named name: String) throws -> HerdrCoreTerminalRecord {
        guard case .missed(let snapshot) = try decodeVector("missed") else {
            throw CocoaError(.coderReadCorrupt, userInfo: [NSDebugDescriptionErrorKey: "missed must surface its snapshot"])
        }
        return try #require(snapshot.terminals.first { $0.name == name })
    }

    @Test func everyFieldOfALiveRecordDecodes() throws {
        let record = try missedRecord(named: "full-record")
        #expect(record.address == "t10")
        #expect(record.labels == ["heeler.workspace": "w1"])
        #expect(record.argv == ["sh", "<scrubbed>", "<scrubbed>"])
        #expect(record.cwd == "/home/user")
        #expect(record.keep)
        #expect(record.state == "live")
        #expect((record.pid ?? 0) > 0)
        #expect(record.exitCode == nil)
        #expect(record.signal == nil)
        #expect(record.reason == nil)
        #expect((record.createdMilliseconds ?? 0) > 0)
        #expect(record.finishedMilliseconds == nil)
        #expect(record.screen == "exact")
        #expect(record.columns == 200)
        #expect(record.rows == 120)
        #expect(record.identity == "ghostty")
        #expect(record.status == HerdrCoreTerminalStatus(
            state: "blocked", kind: "permission", progress: 40, app: "claude-code",
            title: "Reviewing", message: "Allow"))
        #expect((record.statusMilliseconds ?? 0) > 0)
        #expect(record.records == ["child": HerdrCoreTerminalStatus(
            state: "working", kind: nil, progress: nil, app: "claude-code", title: "", message: "")])
        #expect(record.turn == 1)
        #expect(record.reported)
        #expect(record.title == "Reviewing")
        #expect(record.parent == "t7")
        #expect(record.notify)
        #expect(record.dieWithParent)
        #expect(record.removeOnExit == false)
        #expect(record.template == "reviewer")
        #expect(record.submit == "enter")
        #expect(record.stop == "esc")
        #expect(record.pasteGapMilliseconds == 120)
        let foreground = try #require(record.foreground)
        #expect((foreground.pid ?? 0) > 0)
        #expect(foreground.name == "Python")
        #expect(foreground.argv == ["/usr/local/bin/python3", "<scrubbed>"])
        #expect(foreground.cwd == "/home/user")
    }

    @Test func aCreatedRecordCarriesItsTemplateAndParent() throws {
        guard case .created(let record) = try decodeVector("created-from-template") else {
            Issue.record("created must carry its record")
            return
        }
        #expect(record.parent == "t7")
        #expect(record.template == "reviewer")
        #expect(record.submit == "enter")
        #expect(record.stop == "esc")
        #expect(record.pasteGapMilliseconds == 120)
        #expect(record.status == nil)
        #expect(record.foreground == nil)
    }

    @Test func anUnknownRecordFieldIsIgnored() throws {
        let captured = try #require(String(data: try vectors.event("created-from-template"), encoding: .utf8))
        let extended = captured.replacingOccurrences(of: #""data":{"#, with: #""data":{"future_field":{"ignored":true},"#)
        #expect(extended != captured)
        var cursor = HerdrCoreTypedEventCursor(sequence: 0)
        var original = HerdrCoreTypedEventCursor(sequence: 0)
        #expect(try cursor.decode(line: Data(extended.utf8)) == original.decode(line: Data(captured.utf8)))
    }

    @Test func recordFieldsThatDefaultWhenAbsentDecodeTheirOwnValues() throws {
        // The core ends a killed program with SIGHUP, and a wait on its parent's
        // children keeps an `rm` child in the record once it has finished.
        let record = try missedRecord(named: "killed-child")
        #expect(record.state == "finished")
        #expect(record.signal == 1)
        #expect(record.exitCode == nil)
        #expect(record.reason == "killed")
        #expect((record.finishedMilliseconds ?? 0) > 0)
        #expect(record.parent == "t7")
        #expect(record.dieWithParent)
        #expect(record.removeOnExit)
    }

    @Test func theSubscribeSnapshotAndMissedCarryRecordsWithoutFederatedTerminals() throws {
        let exchange = try vectors.exchange("events-subscribe")
        let snapshot = try HerdrCoreSnapshot(result: exchange.result)
        #expect(snapshot.sequence > 0)
        #expect(snapshot.channel == 1)
        #expect(snapshot.terminals.map(\.address) == ["t1", "t2"])
        #expect(snapshot.terminals[1].state == "finished")
        #expect(snapshot.terminals[1].exitCode == 0)
        guard case .missed(let missed) = try decodeVector("missed") else {
            Issue.record("missed must surface its snapshot")
            return
        }
        #expect(missed.sequence > snapshot.sequence)
        #expect(missed.channel == nil)
        #expect(missed.terminals.map(\.address).prefix(2) == ["t1", "t2"])
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
    @Test func everyCaseNamesItsCapture() {
        let vectors = HerdrCoreVectorFile.shared
        #expect(vectors.provisional == false)
        #expect(vectors.coreVersion == "0.1.13")
        #expect(vectors.coreCommit == "88fe4e7")
        // Pinned against the file: a section that stops decoding cannot pass quietly.
        #expect(vectors.allCases.count == 1 + 10 + 3 + 4 + 19 + 2)
        #expect(Set(vectors.allCases.map(\.name)).count == vectors.allCases.count)
        for testCase in vectors.allCases {
            #expect(testCase.source.hasPrefix("captured from herdr-core 0.1.13 by "), "\(testCase.name)")
        }
    }

    @Test func theLargestResizeCarriesAU16PerSide() throws {
        let vector = try #require(HerdrCoreVectorFile.shared.frames.first { $0.name == "resize-largest" })
        var decoder = HerdrCoreFrameDecoder()
        decoder.append(HerdrCoreVectorFile.bytes(hex: vector.bytes))
        let frame = try #require(try decoder.next())
        #expect(frame == (try HerdrCoreFrame.resize(channel: frame.channel, columns: 65535, rows: 65535)))
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
