import Foundation
import Testing

@testable import Heeler

/// What a tmux control-mode client prints, read as tmux 3.3a and 3.7b print it
/// (ADR 0043): command blocks, pane output with its octal escapes, and the
/// notifications an Attach acts on.
@Suite("tmux control-mode reader")
struct TmuxControlReaderTests {
    private func read(_ text: String, in pieces: Int = 1) throws -> [TmuxControlReader.Event] {
        try read(Data(text.utf8), in: pieces)
    }

    /// `bytes` cut into `pieces` chunks of about the same size, as a channel can cut them.
    private func read(_ bytes: Data, in pieces: Int) throws -> [TmuxControlReader.Event] {
        var reader = TmuxControlReader()
        var events: [TmuxControlReader.Event] = []
        let size = max(1, bytes.count / pieces)
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes.index(start, offsetBy: size, limitedBy: bytes.endIndex) ?? bytes.endIndex
            events += try reader.read(bytes[start..<end])
            start = end
        }
        return events
    }

    private func reply(
        _ number: UInt64, fromClient: Bool = true, succeeded: Bool = true, _ lines: [String] = []
    ) -> TmuxControlReader.Event {
        .reply(
            TmuxControlReply(
                number: number, fromClient: fromClient, succeeded: succeeded, lines: lines.map { Data($0.utf8) }))
    }

    // MARK: Blocks

    @Test func aBlockIsOneReplyWithItsLines() throws {
        let events = try read(
            """
            %begin 1794339265 295 1
            0 0 1 0
            %end 1794339265 295 1

            """)
        #expect(events == [reply(295, ["0 0 1 0"])])
    }

    @Test func anErrorBlockIsAFailedReply() throws {
        let events = try read(
            """
            %begin 1794339265 296 1
            parse error: unknown command: bogus-command
            %error 1794339265 296 1

            """)
        #expect(events == [reply(296, succeeded: false, ["parse error: unknown command: bogus-command"])])
    }

    @Test func aBlockWithNothingInItHasNoLinesAndOneWithAnEmptyLineHasThatLine() throws {
        let events = try read("%begin 1 7 1\n%end 1 7 1\n%begin 1 8 1\n\n%end 1 8 1\n")
        #expect(events == [reply(7), reply(8, [""])])
    }

    /// The start command and anything else this client did not write carry flags 0.
    @Test func aBlockOfACommandThisClientDidNotWriteSaysSo() throws {
        let events = try read("%begin 1794339264 275 0\n%end 1794339264 275 0\n")
        #expect(events == [reply(275, fromClient: false)])
    }

    /// A pane can show anything, `%end` lines included: only the block's own
    /// time and number end it.
    @Test func aLineInsideABlockIsOutputWhateverItSays() throws {
        let events = try read(
            """
            %begin 1794339305 287 1
            \u{1B}[34mline32
            %end 1 2 1
            %output %0 hello
            %exit
            %end 1794339305 288 1
            %error 1794339304 287 1
            %end 1794339305 287 1

            """)
        #expect(
            events == [
                reply(
                    287,
                    [
                        "\u{1B}[34mline32", "%end 1 2 1", "%output %0 hello", "%exit", "%end 1794339305 288 1",
                        "%error 1794339304 287 1",
                    ])
            ])
    }

    /// A refresh-client that pauses or continues a pane prints that inside its own block.
    @Test func aPauseThatACommandCausedIsPartOfItsReply() throws {
        let events = try read("%begin 1794339305 288 1\n%pause %0\n%end 1794339305 288 1\n")
        #expect(events == [reply(288, ["%pause %0"])])
    }

    @Test func linesKeepTheirBytesAsTheyCame() throws {
        var bytes = Data("%begin 1 3 1\n".utf8)
        bytes += Data([0x1B, 0x5B, 0x31, 0x6D, 0xE4, 0xB8, 0xAD, 0xFF, 0x0A])
        bytes += Data("%end 1 3 1\n".utf8)
        let events = try read(bytes, in: 7)
        #expect(
            events == [
                .reply(
                    TmuxControlReply(
                        number: 3, fromClient: true, succeeded: true,
                        lines: [Data([0x1B, 0x5B, 0x31, 0x6D, 0xE4, 0xB8, 0xAD, 0xFF])]))
            ])
    }

    // MARK: Output

    @Test func outputIsThePanesBytesWithItsEscapesDecoded() throws {
        let events = try read(#"%output %12 abc\134x\015\012\033[1m"# + "\n")
        #expect(events == [.output(pane: "%12", bytes: Data("abc\\x\r\n\u{1B}[1m".utf8))])
    }

    /// The form tmux uses once `pause-after` is set.
    @Test func extendedOutputIsTheSameOutputWithItsAgeSetAside() throws {
        let events = try read(#"%extended-output %0 1250 future words : during \072 pause : here"# + "\n")
        #expect(events == [.output(pane: "%0", bytes: Data("during : pause : here".utf8))])
    }

    @Test func extendedOutputThatIsEmptyOrAllSpacesIsKept() throws {
        let events = try read("%extended-output %3 0 : \n%extended-output %3 0 :   \n")
        #expect(events == [.output(pane: "%3", bytes: Data()), .output(pane: "%3", bytes: Data("  ".utf8))])
    }

    @Test func bytesTmuxPassesAsTheyAreStayAsTheyAre() throws {
        var line = Data("%output %1 ".utf8)
        line += Data([0xE4, 0xB8, 0xAD, 0xF0, 0x9F, 0x91, 0x8D, 0x7F, 0x5C, 0x0A])
        let events = try read(line, in: 5)
        #expect(events == [.output(pane: "%1", bytes: Data([0xE4, 0xB8, 0xAD, 0xF0, 0x9F, 0x91, 0x8D, 0x7F, 0x5C]))])
    }

    @Test func aBackslashWithoutThreeOctalDigitsIsKept() throws {
        let events = try read(#"%output %1 a\9b\01"# + "\n")
        #expect(events == [.output(pane: "%1", bytes: Data(#"a\9b\01"#.utf8))])
    }

    // MARK: Notifications

    @Test func theNotificationsAnAttachActsOnAreNamed() throws {
        let events = try read(
            """
            %pause %4
            %continue %4
            %sessions-changed
            %window-close @2
            %unlinked-window-close @3
            %layout-change @2 b25f,80x24,0,0,2 b25f,80x24,0,0,2 *
            %window-renamed @2 cat
            %session-changed $5 heeler-attach-0a1b2c
            %exit
            %exit server exited unexpectedly

            """)
        #expect(
            events == [
                .notification(.paused(pane: "%4")),
                .notification(.continued(pane: "%4")),
                .notification(.sessionsChanged),
                .notification(.windowClosed(window: "@2")),
                .notification(.unlinkedWindowClosed(window: "@3")),
                .notification(.layoutChanged(window: "@2")),
                .notification(.other(name: "%window-renamed")),
                .notification(.sessionChanged(session: "$5")),
                .exit(reason: nil),
                .exit(reason: "server exited unexpectedly"),
            ])
    }

    @Test func linesOutsideABlockThatAreNotNotificationsAreDropped() throws {
        let events = try read("\nno server running\n%output %1 x\n")
        #expect(events == [.output(pane: "%1", bytes: Data("x".utf8))])
    }

    // MARK: Pieces

    @Test func anyCutOfTheStreamReadsTheSame() throws {
        let stream = """
            %begin 1794339264 275 0
            %end 1794339264 275 0
            %sessions-changed
            %extended-output %0 0 : abc\\134x
            %begin 1794339265 295 1
            0 0 1\u{20}
            %end 1794339265 295 1

            """
        let whole = try read(stream)
        #expect(whole.count == 4)
        for pieces in [2, 3, 5, 11, stream.utf8.count] {
            #expect(try read(stream, in: pieces) == whole)
        }
    }

    @Test func aLineLongerThanTheLimitIsAnError() {
        var reader = TmuxControlReader(lineLimit: 16)
        #expect(throws: TmuxControlReader.Overflow.self) {
            _ = try reader.read(Data(repeating: UInt8(ascii: "x"), count: 17))
        }
    }

    @Test func aBlockLongerThanTheLimitIsAnError() throws {
        var reader = TmuxControlReader(lineLimit: 64, blockLimit: 32)
        _ = try reader.read(Data("%begin 1 2 1\n".utf8))
        #expect(throws: TmuxControlReader.Overflow.self) {
            _ = try reader.read(Data(String(repeating: "line\n", count: 8).utf8))
        }
    }
}
