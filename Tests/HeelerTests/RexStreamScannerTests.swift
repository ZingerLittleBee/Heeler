import Foundation
import Testing

@testable import Heeler

/// The scanner that splits a Rex terminal stream into program bytes and the
/// stream's own messages, over hand-built streams: a stand-in snapshot,
/// look-alike sequences, and messages cut anywhere. Nonces are invented.
@Suite("Rex stream scanner")
struct RexStreamScannerTests {
    static let nonce: UInt64 = 0x1D2C_3B4A_5968_7786
    static let esc: UInt8 = 0x1B

    /// Everything a stream may carry, in one: a snapshot full of decoys, the
    /// first resize, program output with a foreign-nonce message and escape
    /// sequences in it, a theme, an unreadable own message, an unknown type,
    /// and the program's exit.
    static let snapshot = FakeRexStream.snapshot(byteCount: 700, decoys: nonce)
    static let foreign = FakeRexStream.message(#"{"type":"resize","cols":2,"rows":2}"#, nonce: nonce &+ 1)
    static let programA = Data("\u{1B}[31mred\u{1B}[0m\r\n".utf8) + foreign + Data("after\u{1B}]0;title\u{07}".utf8)
    static let programB = Data("\u{1B}_rex1;\u{1B}\\ plain \u{1B}".utf8) + Data("[2J".utf8)
    static let programC = Data("tail é 漢\r\n".utf8)
    static let stream: Data =
        snapshot + FakeRexStream.resize(columns: 120, rows: 40, nonce: nonce) + programA
        + FakeRexStream.theme(nonce: nonce) + programB + FakeRexStream.message("{not json", nonce: nonce)
        + FakeRexStream.message(#"{"type":"bell"}"#, nonce: nonce) + programC
        + FakeRexStream.childExited(code: 0, nonce: nonce)

    static let expected: [RexStreamScanner.Item] = [
        .message(.resize(RexTerminalGrid(columns: 120, rows: 40, cellWidth: 9, cellHeight: 18, owner: "client:fake-owner"))),
        .program(programA),
        .message(
            .theme(
                RexTerminalTheme(
                    foreground: "#d0d0d0", background: "#101010", cursor: nil, palette: ["1=aa2020"], scheme: "dark"))),
        .program(programB),
        .message(.unknown(type: "bell")),
        .program(programC),
        .message(.childExited(exitCode: 0)),
    ]

    /// Adjacent program runs joined, since where they split depends on the chunks.
    static func joined(_ items: [RexStreamScanner.Item]) -> [RexStreamScanner.Item] {
        var result: [RexStreamScanner.Item] = []
        for item in items {
            if case .program(let next) = item, case .program(let last)? = result.last {
                result[result.count - 1] = .program(last + next)
            } else {
                result.append(item)
            }
        }
        return result
    }

    static func scan(_ chunks: [Data]) -> (items: [RexStreamScanner.Item], scanner: RexStreamScanner) {
        var scanner = RexStreamScanner(nonce: nonce)
        var items: [RexStreamScanner.Item] = []
        for chunk in chunks { items += scanner.scan(chunk) }
        return (joined(items), scanner)
    }

    @Test func theWholeStreamReadsAsExpected() {
        let (items, scanner) = Self.scan([Self.stream])
        #expect(items == Self.expected)
        #expect(scanner.isPastSnapshot)
        #expect(scanner.skippedSnapshotBytes == UInt64(Self.snapshot.count))
        #expect(scanner.programByteCount == UInt64(Self.programA.count + Self.programB.count + Self.programC.count))
        #expect(scanner.droppedMessageCount == 1)
    }

    /// Cut in two at every offset, the stream reads the same.
    @Test func aCutAnywhereChangesNothing() {
        for cut in 0...Self.stream.count {
            let (items, scanner) = Self.scan([Self.stream.prefix(cut), Self.stream.dropFirst(cut)])
            #expect(items == Self.expected, "cut at \(cut)")
            #expect(scanner.skippedSnapshotBytes == UInt64(Self.snapshot.count), "cut at \(cut)")
            #expect(scanner.droppedMessageCount == 1, "cut at \(cut)")
        }
    }

    @Test func oneByteAtATimeChangesNothing() {
        let (items, scanner) = Self.scan(Self.stream.map { Data([$0]) })
        #expect(items == Self.expected)
        #expect(scanner.skippedSnapshotBytes == UInt64(Self.snapshot.count))
    }

    @Test func cutsInThreeChangeNothing() {
        let stride = 7
        for first in Swift.stride(from: 0, through: Self.stream.count, by: stride) {
            for second in Swift.stride(from: first, through: Self.stream.count, by: 13) {
                let chunks = [
                    Self.stream.prefix(first), Self.stream.dropFirst(first).prefix(second - first),
                    Self.stream.dropFirst(second),
                ]
                #expect(Self.scan(chunks).items == Self.expected, "cuts at \(first), \(second)")
            }
        }
    }

    /// Nothing is yielded before the first own message, however much
    /// look-alike the snapshot holds.
    @Test func theSnapshotIsSkippedWholeDecoysAndAll() {
        var scanner = RexStreamScanner(nonce: Self.nonce)
        #expect(scanner.scan(Self.snapshot).isEmpty)
        #expect(!scanner.isPastSnapshot)
        // What is kept between chunks is shorter than the prefix it may begin.
        #expect(scanner.skippedSnapshotBytes >= UInt64(Self.snapshot.count - 32))
        let items = scanner.scan(FakeRexStream.resize(columns: 80, rows: 24, nonce: Self.nonce))
        #expect(items.count == 1)
        #expect(scanner.skippedSnapshotBytes == UInt64(Self.snapshot.count))
    }

    /// However long the snapshot, skipping it keeps no more than a partial
    /// prefix between chunks, even when every chunk ends in one.
    @Test func aLongSnapshotIsSkippedInLittleMemory() {
        var scanner = RexStreamScanner(nonce: Self.nonce)
        let prefix = Data([Self.esc]) + Data("_rex1;\(Self.nonce);".utf8)
        let partial = prefix.prefix(prefix.count - 1)
        // A look-alike escape, then a chunk's worth of snapshot, then the
        // start of a prefix the next chunk's first byte turns out not to be.
        let filler = Data([Self.esc, 0x5F]) + Data(repeating: 0x61, count: 32 * 1024)
        var fed: UInt64 = 0
        for _ in 0..<64 {
            let chunk = Data("x".utf8) + filler + partial
            #expect(scanner.scan(chunk).isEmpty)
            fed += UInt64(chunk.count)
            #expect(fed - scanner.skippedSnapshotBytes < UInt64(prefix.count))
        }
        #expect(!scanner.isPastSnapshot)
        let items = scanner.scan(FakeRexStream.resize(columns: 80, rows: 24, nonce: Self.nonce))
        #expect(items.count == 1)
        #expect(scanner.skippedSnapshotBytes == fed)
    }

    @Test func aForeignNoncePassesThroughAsProgramBytes() {
        let (items, _) = Self.scan([
            FakeRexStream.resize(columns: 80, rows: 24, nonce: Self.nonce), Self.foreign,
        ])
        #expect(items.last == .program(Self.foreign))
    }

    /// A chunk that ends partway into what may be an own message holds those
    /// bytes back; the next chunk decides what they were.
    @Test func aPartialSequenceIsHeldBack() {
        var scanner = RexStreamScanner(nonce: Self.nonce)
        _ = scanner.scan(FakeRexStream.resize(columns: 80, rows: 24, nonce: Self.nonce))
        let message = FakeRexStream.childExited(code: 0, nonce: Self.nonce)

        #expect(scanner.scan(Data("ab".utf8) + message.prefix(9)) == [.program(Data("ab".utf8))])
        #expect(scanner.scan(message.dropFirst(9).dropLast(1)) == [])
        #expect(scanner.scan(message.suffix(1) + Data("cd".utf8)) == [.message(.childExited(exitCode: 0)), .program(Data("cd".utf8))])

        // A held ESC that turns out to begin something else is the program's.
        #expect(scanner.scan(Data([Self.esc])) == [])
        #expect(scanner.scan(Data("[1m".utf8)) == [.program(Data("\u{1B}[1m".utf8))])
        #expect(scanner.programByteCount == 8)
    }

    @Test func anUnreadableOwnMessageIsDroppedAndScanningGoesOn() {
        let (items, scanner) = Self.scan([
            FakeRexStream.resize(columns: 80, rows: 24, nonce: Self.nonce),
            FakeRexStream.message(#"{"cols":3}"#, nonce: Self.nonce),
            FakeRexStream.message(#"{"type":"resize","cols":"wide","rows":2}"#, nonce: Self.nonce),
            FakeRexStream.message("[]", nonce: Self.nonce),
            Data("ok".utf8),
        ])
        #expect(Array(items.dropFirst()) == [.program(Data("ok".utf8))])
        #expect(scanner.droppedMessageCount == 3)
    }

    /// An own message that never ends is not kept whole: past the bound it is
    /// dropped up to its terminator, and what follows is read again.
    @Test func anOwnMessageThatNeverEndsIsDroppedPastTheBound() {
        var scanner = RexStreamScanner(nonce: Self.nonce)
        _ = scanner.scan(FakeRexStream.resize(columns: 80, rows: 24, nonce: Self.nonce))
        let opening = Data([Self.esc]) + Data("_rex1;\(Self.nonce);{\"type\":\"theme\",\"x\":\"".utf8)
        #expect(scanner.scan(opening) == [])
        let filler = Data(repeating: 0x61, count: 40 * 1024)
        #expect(scanner.scan(filler) == [])
        #expect(scanner.scan(filler) == [])
        #expect(scanner.droppedMessageCount == 1)
        #expect(scanner.scan(filler + Data([Self.esc])) == [])
        #expect(scanner.scan(Data("\\after".utf8)) == [.program(Data("after".utf8))])
    }

    @Test func theFirstMessageMayEndTheSameChunkAsTheSnapshot() {
        var scanner = RexStreamScanner(nonce: Self.nonce)
        let items = scanner.scan(
            FakeRexStream.snapshot(byteCount: 64) + FakeRexStream.resize(columns: 80, rows: 24, nonce: Self.nonce)
                + Data("x".utf8))
        #expect(items.count == 2)
        #expect(items.last == .program(Data("x".utf8)))
        #expect(scanner.skippedSnapshotBytes == 64)
    }

    @Test func messagesReadTheirFields() {
        #expect(
            RexStreamScanner.message(Data(#"{"type":"resize","cols":80,"rows":24}"#.utf8))
                == .resize(RexTerminalGrid(columns: 80, rows: 24, cellWidth: 0, cellHeight: 0, owner: nil)))
        #expect(
            RexStreamScanner.message(Data(#"{"type":"child_exited","exit_code":null}"#.utf8))
                == .childExited(exitCode: nil))
        #expect(
            RexStreamScanner.message(Data(#"{"type":"theme","palette":[]}"#.utf8))
                == .theme(RexTerminalTheme(foreground: nil, background: nil, cursor: nil, palette: [], scheme: nil)))
        #expect(RexStreamScanner.message(Data(#"{"type":"resize","rows":24}"#.utf8)) == nil)
    }
}
