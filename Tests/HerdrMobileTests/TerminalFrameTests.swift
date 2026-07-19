import Foundation
import Testing

@testable import HerdrMobile

/// Observe-stream frame decoding (#9): NDJSON lines carrying base64 ANSI,
/// parsed leniently per the standing decoding rule.
@Suite("Terminal frame decoding")
struct TerminalFrameTests {
    private func line(_ text: String) -> Data {
        Data(text.utf8)
    }

    @Test func observeClaimsAControlSessionSoHerdrAppliesPhoneGeometry() {
        #expect(
            SSHTransportSettings.defaultObserveCommand
                == "herdr terminal session control")
    }

    @Test func decodesAFullRepaintFrame() throws {
        // The live-captured shape from the #9 probe: base64 of ANSI bytes.
        let payload = Data("\u{1B}[2J\u{1B}[Hhello".utf8)
        let frame = TerminalFrame.decode(
            fromLine: line(
                #"{"type":"terminal.frame","seq":1,"full":true,"width":80,"height":24,"# +
                    #""encoding":"ansi","bytes":"\#(payload.base64EncodedString())"}"#))

        let decoded = try #require(frame)
        #expect(decoded.seq == 1)
        #expect(decoded.isFull)
        #expect(decoded.width == 80)
        #expect(decoded.height == 24)
        #expect(decoded.bytes == payload)
    }

    @Test func missingFullFlagMeansIncremental() throws {
        let frame = TerminalFrame.decode(
            fromLine: line(#"{"type":"terminal.frame","seq":7,"encoding":"ansi","bytes":""}"#))
        let decoded = try #require(frame)
        #expect(!decoded.isFull)
        #expect(decoded.width == nil)
        #expect(decoded.bytes.isEmpty)
    }

    @Test func unknownFieldsAreIgnored() throws {
        // herdr's API has no stability guarantee; extra fields must not
        // break decoding.
        let frame = TerminalFrame.decode(
            fromLine: line(
                #"{"type":"terminal.frame","seq":2,"full":false,"encoding":"ansi","# +
                    #""bytes":"aGk=","cursor":{"x":1,"y":2},"flavor":"spooky"}"#))
        #expect(frame?.bytes == Data("hi".utf8))
    }

    @Test func unknownFrameTypesAreDroppedLeniently() {
        #expect(
            TerminalFrame.decode(
                fromLine: line(#"{"type":"terminal.bell","seq":3,"bytes":"aGk="}"#)) == nil)
    }

    @Test func unknownEncodingsAreDropped() {
        // Bytes in an encoding this build cannot render must not be fed to
        // the terminal as ANSI.
        #expect(
            TerminalFrame.decode(
                fromLine: line(
                    #"{"type":"terminal.frame","seq":4,"encoding":"protobuf","bytes":"aGk="}"#))
                == nil)
    }

    @Test func absentEncodingStillDecodes() {
        // Lenient: the field going missing in a future herdr must not kill
        // the pipeline; ANSI is the only encoding the stream has ever sent.
        let frame = TerminalFrame.decode(
            fromLine: line(#"{"type":"terminal.frame","seq":5,"bytes":"aGk="}"#))
        #expect(frame?.bytes == Data("hi".utf8))
    }

    @Test func junkLinesAreDropped() {
        #expect(TerminalFrame.decode(fromLine: line("not json at all")) == nil)
        #expect(TerminalFrame.decode(fromLine: line(#"{"seq":1,"bytes":"aGk="}"#)) == nil)
        #expect(
            TerminalFrame.decode(
                fromLine: line(#"{"type":"terminal.frame","seq":6,"bytes":"%%%"}"#)) == nil,
            "bytes that are not base64 must not crash or produce garbage")
        #expect(
            TerminalFrame.decode(
                fromLine: line(#"{"type":"terminal.frame","bytes":"aGk="}"#)) == nil,
            "a frame without a seq cannot participate in gap detection")
    }
}
